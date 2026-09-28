#!/usr/bin/env python3
"""cmd_908 T1: CodeRabbit rate-limited PR 自動再引き金 — 実装。

設計: queue/reports/cmd908_ratelimit_retrigger_design.md
  (§1〜§7が基本設計、末尾「確定版(cmd_909【D】)」§8〜§11が最終版。
   食い違う所は確定版を優先する。)

★このモジュールは決定論的な純関数群(classify/parse_wait/next_attempt_at/
may_query/select_targets/assert_allowed_body)と、それらを束ねる薄い
main()のみで構成する。LLMを実行経路に一切含めない。

本T1の範囲外(T2・家老の担当): launchd登録・Keychain設定・
本番HCのcheck作成。本モジュールはファイルを置くのみで、それらには触れない。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

# ── §1: allowlist・上流拒否 ──────────────────────────────────────────
UPSTREAM_DENYLIST_PREFIXES = ("yohey-w/", "digital-go-jp/")

# ── §8.1: 投稿してよい本文はこの2定数のみ(完全一致) ──────────────────
TRIGGER_BODY = "[AI] @coderabbitai review"
QUERY_BODY = "[AI] @coderabbitai rate limit"
ALLOWED_BODIES = frozenset({TRIGGER_BODY, QUERY_BODY})

_REVIEWED_EXACT = {"Review completed", "Review approved"}
_WAITING_EXACT = {"Review in progress", "Review queued"}

CANDIDATE_CATEGORIES = frozenset({"rate_limited", "paused"})

# §2: 待ち時間の正規表現(「wait 4 minutes」「wait **44 minutes and 12 seconds**」の両形)
_WAIT_RE = re.compile(
    r"wait\s+\**\s*(?:(\d+)\s*minutes?)?\s*(?:and\s*)?(?:(\d+)\s*seconds?)?",
    re.IGNORECASE,
)


def classify(desc):
    """commit status の description を分類する(§1の表)。state は見ない。

    戻り値: "reviewed" | "waiting" | "rate_limited" | "paused" | "skip" |
            "no_status" | "unknown"
    """
    d = desc or ""
    if d in _REVIEWED_EXACT or d.startswith("Approve command performed:"):
        return "reviewed"
    if d.startswith("Review skipped"):
        return "skip"
    if d == "Review rate limited":
        return "rate_limited"
    if d == "Review paused" or d.startswith("Reviews paused"):
        return "paused"
    if d in _WAITING_EXACT:
        return "waiting"
    if d == "":
        return "no_status"
    return "unknown"


def is_allowed_repo(repo, allowlist):
    """allowlistにあっても上流(yohey-w/*・digital-go-jp/*)は拒む(§1)。"""
    if repo.startswith(UPSTREAM_DENYLIST_PREFIXES):
        return False
    return repo in allowlist


def parse_wait(notice_body):
    """通知本文から待ち時間(分・float)を読む。読めなければNone(§2)。"""
    if not notice_body:
        return None
    m = _WAIT_RE.search(notice_body)
    if not m:
        return None
    minutes, seconds = m.group(1), m.group(2)
    if minutes is None and seconds is None:
        return None
    return float(minutes or 0) + float(seconds or 0) / 60.0


def next_attempt_at(sources, now, mode="window"):
    """次に試してよい刻限を求める(確定版§9.2)。上の手段で分かれば下は使わない。

    sources (dict, いずれも省略可):
      notice_updated_at:    通知の更新時刻(datetime)
      notice_wait_minutes:  parse_wait()の結果(float | None)
      query_answered_at:    問い合わせの答えを得た時刻(datetime)
      query_answer_minutes: 答えの待ち時間(float)
      recent_review_starts: 直前60分に実際に走ったレビューの開始時刻のlist[datetime]
    mode: "window"(既定・移動窓の知見) | "hourly"(正時のリセット)
    """
    notice_updated_at = sources.get("notice_updated_at")
    notice_wait_minutes = sources.get("notice_wait_minutes")
    if notice_updated_at is not None and notice_wait_minutes is not None:
        return notice_updated_at + timedelta(minutes=notice_wait_minutes + 2)

    query_answered_at = sources.get("query_answered_at")
    query_answer_minutes = sources.get("query_answer_minutes")
    if query_answered_at is not None and query_answer_minutes is not None:
        return query_answered_at + timedelta(minutes=query_answer_minutes)

    if mode == "hourly":
        next_hour = now.replace(minute=0, second=0, microsecond=0) + timedelta(hours=1)
        return next_hour + timedelta(minutes=2)

    # mode == "window"(既定): 待ち時間の読めぬ通知は60分の退きに倒れる。
    recent = sources.get("recent_review_starts") or []
    if recent:
        oldest = min(recent)
        return oldest + timedelta(minutes=62)
    return now + timedelta(minutes=60)


def assert_allowed_body(body):
    """post_commentが投稿してよい本文は定型2文言のみ(確定版§8.1)。
    それ以外(人へ話しかける文面を含む)は例外を投げ、投稿しない。
    """
    if body not in ALLOWED_BODIES:
        raise ValueError(f"disallowed comment body: {body!r}")


def post_comment(repo, pr, body, gh_bin="gh", timeout=30):
    """投稿してよい本文かをまず確かめてから gh api で issue コメントを投じる。"""
    assert_allowed_body(body)
    cmd = [gh_bin, "api", f"repos/{repo}/issues/{pr}/comments", "-f", f"body={body}"]
    subprocess.run(cmd, check=True, timeout=timeout)


def is_killed(stop_path):
    """logs/cr_retrigger.stopが有れば一切投じない(§5)。周回・ログ・pingは続く。"""
    return os.path.exists(stop_path)


def may_query(incident_key, state, now, cfg):
    """予備の問い合わせ`[AI] @coderabbitai rate limit`の下限(確定版§9.2)。

    - 一つの件(incident_key)につき1回だけ。
    - 全体で30分に1回まで・1日に6回まで。
    """
    incidents = state.get("query_incidents", {})
    if incident_key in incidents:
        return False
    query_log = state.get("query_log", [])
    per_day = cfg.get("query_per_day", 6)
    day_count = sum(1 for t in query_log if now - t < timedelta(days=1))
    if day_count >= per_day:
        return False
    min_interval = cfg.get("query_min_interval_min", 30)
    if query_log:
        last = max(query_log)
        if now - last < timedelta(minutes=min_interval):
            return False
    return True


def select_targets(state, prs, budget, now, killed=False):
    """投げ直す候補を選ぶ(§3.2の冪等性・上限、確定版§9.1の毎時/毎日の予算)。

    prs: [{repo, pr, head_sha, description, draft, allowed,
           next_attempt_at(省略可・省略時はnowとみなし即時候補)}]
    state: {"heads": {"repo#pr#sha": {"attempts": int}}, "sent_log": [datetime,...]}
    budget: {"trigger_per_hour": int, "trigger_per_day": int}
    killed: kill switch(§5)が有るか
    """
    if killed:
        return []

    heads = state.get("heads", {})
    candidates = []
    for pr in prs:
        if pr.get("draft"):
            continue
        if not pr.get("allowed", True):
            continue
        if classify(pr.get("description", "")) not in CANDIDATE_CATEGORIES:
            continue
        key = f"{pr['repo']}#{pr['pr']}#{pr['head_sha']}"
        attempts = heads.get(key, {}).get("attempts", 0)
        # §3.2: 同じheadへの試行は最大3回まで。
        if attempts >= 3:
            continue
        next_at = pr.get("next_attempt_at", now)
        if next_at > now:
            continue
        candidates.append(pr)

    candidates.sort(key=lambda p: p.get("next_attempt_at", now))

    sent_log = state.get("sent_log", [])
    hour_count = sum(1 for t in sent_log if now - t < timedelta(hours=1))
    day_count = sum(1 for t in sent_log if now - t < timedelta(days=1))
    hour_remaining = budget.get("trigger_per_hour", 1) - hour_count
    day_remaining = budget.get("trigger_per_day", 8) - day_count
    remaining = max(0, min(hour_remaining, day_remaining))

    return candidates[:remaining]


# ── main(): T1の範囲では実配線のみ。本番のgh呼び出しはCI/ローカルでは
#    走らない(引数無しでは何もしない)。orchestration のみを担い、
#    判定規則そのものは上の純関数に閉じ込めてある。────────────────────

def _load_config(path):
    import yaml  # PyYAML — CI/開発環境にインストール済み(claude_usage_report等と同様)

    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def _load_state(path):
    if not os.path.exists(path):
        return {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    raw["sent_log"] = [datetime.fromisoformat(t) for t in raw.get("sent_log", [])]
    raw["query_log"] = [datetime.fromisoformat(t) for t in raw.get("query_log", [])]
    raw.setdefault("heads", {})
    raw.setdefault("query_incidents", {})
    return raw


def _save_state(path, state):
    out = dict(state)
    out["sent_log"] = [t.isoformat() for t in state.get("sent_log", [])]
    out["query_log"] = [t.isoformat() for t in state.get("query_log", [])]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)


def _gh_json(args, gh_bin="gh", timeout=30):
    """`gh <args...>` を実行し、stdoutをJSONとして返す。非0終了はraiseする。"""
    result = subprocess.run(
        [gh_bin, *args], capture_output=True, text=True, timeout=timeout, check=True,
    )
    return json.loads(result.stdout) if result.stdout.strip() else None


def _fetch_open_prs(repo, gh_bin="gh", timeout=30):
    """repo の halsk 名義の open PR を列挙する(§1)。"""
    return _gh_json(
        ["pr", "list", "--repo", repo, "--author", "halsk", "--state", "open",
         "--json", "number,headRefOid,isDraft"],
        gh_bin=gh_bin, timeout=timeout,
    ) or []


def _fetch_coderabbit_status(repo, sha, gh_bin="gh", timeout=30):
    """head commitのCodeRabbit commit statusから(description, updated_at)を読む(§1)。
    見つからなければ(None, None)。"""
    data = _gh_json(
        ["api", f"repos/{repo}/commits/{sha}/status"], gh_bin=gh_bin, timeout=timeout,
    ) or {}
    for status in data.get("statuses", []):
        if "coderabbit" in (status.get("context") or "").lower():
            updated_at = status.get("updated_at")
            dt = datetime.fromisoformat(updated_at.replace("Z", "+00:00")) if updated_at else None
            return status.get("description") or "", dt
    return None, None


def _fetch_latest_wait_notice(repo, pr_number, gh_bin="gh", timeout=30, since_hours=6):
    """CodeRabbitの要約コメントから待ち時間の通知を読む(§2)。
    見つからなければ(None, None)。

    ★`since`で直近`since_hours`時間に絞る(古いPRの全コメント履歴を毎周回
    無制限に取得しないため。10分毎に回る本ジョブでは直近の通知で足りる)。
    """
    since = (datetime.now(timezone.utc) - timedelta(hours=since_hours)).strftime(
        "%Y-%m-%dT%H:%M:%SZ")
    comments = _gh_json(
        ["api", f"repos/{repo}/issues/{pr_number}/comments",
         "-f", f"since={since}", "--paginate"],
        gh_bin=gh_bin, timeout=timeout,
    ) or []
    for comment in reversed(comments):
        login = ((comment.get("user") or {}).get("login") or "")
        if "coderabbit" not in login.lower():
            continue
        body = comment.get("body") or ""
        wait = parse_wait(body)
        if wait is not None:
            updated_at = comment.get("updated_at") or comment.get("created_at")
            dt = datetime.fromisoformat(updated_at.replace("Z", "+00:00")) if updated_at else None
            return dt, wait
    return None, None


def run(cfg, state, now, stop_path, gh_bin="gh", dry_run=False, log_path=None):
    """1周回ぶんの判定・投げ直しを行う(§1〜§3・確定版§8〜§9)。

    戻り値: (更新後のstate, 実行ログの行のlist)
    """
    killed = is_killed(stop_path)
    allowlist = cfg.get("allowlist", [])
    fallback_mode = cfg.get("fallback_mode", "window")
    budget = cfg.get("budget", {})
    log_lines = []

    prs = []
    for repo in allowlist:
        if not is_allowed_repo(repo, allowlist):
            continue  # 上流denylistとの重複防御(§1)
        try:
            raw_prs = _fetch_open_prs(repo, gh_bin=gh_bin)
        except (subprocess.SubprocessError, subprocess.TimeoutExpired, ValueError) as exc:
            log_lines.append({"ts": now.isoformat(), "repo": repo, "error": str(exc)})
            continue
        for raw in raw_prs:
            sha = raw.get("headRefOid")
            desc, updated_at = _fetch_coderabbit_status(repo, sha, gh_bin=gh_bin)
            if desc is None:
                log_lines.append({"ts": now.isoformat(), "repo": repo,
                                   "pr": raw.get("number"), "result": "no_status"})
                continue
            sources = {}
            if updated_at is not None:
                sources["notice_updated_at"] = updated_at
                sources["notice_wait_minutes"] = parse_wait(desc)
            if sources.get("notice_wait_minutes") is None:
                notice_at, wait_minutes = _fetch_latest_wait_notice(
                    repo, raw.get("number"), gh_bin=gh_bin)
                if notice_at is not None:
                    sources["notice_updated_at"] = notice_at
                    sources["notice_wait_minutes"] = wait_minutes
            next_at = next_attempt_at(sources, now, mode=fallback_mode)
            prs.append({
                "repo": repo, "pr": raw.get("number"), "head_sha": sha,
                "description": desc, "draft": bool(raw.get("isDraft")),
                "allowed": is_allowed_repo(repo, allowlist),
                "next_attempt_at": next_at,
            })

    targets = select_targets(state, prs, budget, now, killed=killed)

    for pr in targets:
        key = f"{pr['repo']}#{pr['pr']}#{pr['head_sha']}"
        entry = {"ts": now.isoformat(), "repo": pr["repo"], "pr": pr["pr"],
                  "head_sha": pr["head_sha"], "result": "triggered", "dry_run": dry_run}
        if not dry_run:
            try:
                post_comment(pr["repo"], pr["pr"], TRIGGER_BODY, gh_bin=gh_bin)
            except (subprocess.SubprocessError, subprocess.TimeoutExpired, ValueError) as exc:
                entry["result"] = "post_failed"
                entry["error"] = str(exc)
                log_lines.append(entry)
                continue
            state.setdefault("heads", {}).setdefault(key, {"attempts": 0})
            state["heads"][key]["attempts"] = state["heads"][key].get("attempts", 0) + 1
            state.setdefault("sent_log", []).append(now)
        log_lines.append(entry)

    if log_path:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as f:
            for entry in log_lines:
                f.write(json.dumps(entry, ensure_ascii=False, default=str) + "\n")

    return state, log_lines


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=os.path.join(
        os.path.dirname(__file__), "..", "config", "cr_retrigger.yaml"))
    parser.add_argument("--state", default=os.path.join(
        os.path.dirname(__file__), "..", "state", "cr_retrigger.json"))
    parser.add_argument("--stop-file", default=os.path.join(
        os.path.dirname(__file__), "..", "logs", "cr_retrigger.stop"))
    parser.add_argument("--log-file", default=os.path.join(
        os.path.dirname(__file__), "..", "logs", "cr_retrigger.jsonl"))
    parser.add_argument("--dry-run", action="store_true",
                         help="投稿せず、候補のみログへ出す")
    args = parser.parse_args(argv)

    cfg = _load_config(args.config)
    if not cfg.get("enabled", True):
        print("[cr_retrigger] disabled by config — exit")
        return 0

    now = datetime.now(timezone.utc)
    state = _load_state(args.state)

    state, log_lines = run(
        cfg, state, now, args.stop_file, dry_run=args.dry_run, log_path=args.log_file,
    )
    _save_state(args.state, state)

    for entry in log_lines:
        print(json.dumps(entry, ensure_ascii=False, default=str))
    print(f"[cr_retrigger] {now.isoformat()} 周回終了(候補{len(log_lines)}件・dry_run={args.dry_run})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
