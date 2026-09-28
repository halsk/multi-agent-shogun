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


def _decision_reason(pr, state, now):
    """このPRが投げ直しの候補かどうかと、その理由をログ向けに一語で返す(§1・§3.2・確定版F2)。

    select_targets()はこの戻り値が"candidate"のものだけを候補とする。
    select_targets自身の絞り込み条件をここへ一本化し、ログ用の理由づけと
    実際の選定ロジックが食い違わないようにする。

    戻り値: "draft" | "not_allowed" | classify()の結果(reviewed/waiting/skip/
            no_status/unknown) | "head_recent_push"(§3.3) | "max_attempts" |
            "stale_no_fresh_rate_limit"(確定版F2) | "not_due" | "candidate"
    """
    if pr.get("draft"):
        return "draft"
    if not pr.get("allowed", True):
        return "not_allowed"
    category = classify(pr.get("description", ""))
    if category not in CANDIDATE_CATEGORIES:
        return category

    # §3.3: この10分の間にheadが変わったPRは待つ(pushでCodeRabbitが自ら走るため)。
    pushed_at = pr.get("head_pushed_at")
    if pushed_at is not None and now - pushed_at < timedelta(minutes=10):
        return "head_recent_push"

    key = f"{pr['repo']}#{pr['pr']}#{pr['head_sha']}"
    head_state = state.get("heads", {}).get(key, {})
    attempts = head_state.get("attempts", 0)
    # §3.2: 同じheadへの試行は最大3回まで。
    if attempts >= 3:
        return "max_attempts"

    # 確定版F2: 同じheadへ再び投げてよいのは、前回の投げの後にCodeRabbitが
    # 改めてrate limited/pausedを返した時だけ(status の updated_at で判じる)。
    last_trigger_at = head_state.get("last_trigger_at")
    if attempts > 0 and last_trigger_at is not None:
        status_updated_at = pr.get("status_updated_at")
        if status_updated_at is None or status_updated_at <= last_trigger_at:
            return "stale_no_fresh_rate_limit"

    next_at = pr.get("next_attempt_at", now)
    if next_at > now:
        return "not_due"
    return "candidate"


def select_targets(state, prs, budget, now, killed=False):
    """投げ直す候補を選ぶ(§3.2の冪等性・上限、確定版§9.1の毎時/毎日の予算)。

    prs: [{repo, pr, head_sha, description, draft, allowed,
           next_attempt_at(省略可・省略時はnowとみなし即時候補),
           status_updated_at(省略可・確定版F2の再投げ判定に使う),
           head_pushed_at(省略可・§3.3の判定に使う)}]
    state: {"heads": {"repo#pr#sha": {"attempts": int, "last_trigger_at": datetime(省略可)}},
            "sent_log": [datetime,...]}
    budget: {"trigger_per_hour": int, "trigger_per_day": int}
    killed: kill switch(§5)が有るか
    """
    if killed:
        return []

    candidates = [pr for pr in prs if _decision_reason(pr, state, now) == "candidate"]
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
    raw["query_incidents"] = {
        k: datetime.fromisoformat(v) for k, v in raw.get("query_incidents", {}).items()
    }
    heads = raw.get("heads", {})
    for head_state in heads.values():
        # F2: last_trigger_atはdatetimeとして扱う(select_targetsの再投げ判定に使う)。
        if head_state.get("last_trigger_at"):
            head_state["last_trigger_at"] = datetime.fromisoformat(head_state["last_trigger_at"])
    raw["heads"] = heads
    return raw


def _save_state(path, state):
    out = dict(state)
    out["sent_log"] = [t.isoformat() for t in state.get("sent_log", [])]
    out["query_log"] = [t.isoformat() for t in state.get("query_log", [])]
    out["query_incidents"] = {
        k: v.isoformat() for k, v in state.get("query_incidents", {}).items()
    }
    heads_out = {}
    for key, head_state in state.get("heads", {}).items():
        hs = dict(head_state)
        if hs.get("last_trigger_at") is not None:
            hs["last_trigger_at"] = hs["last_trigger_at"].isoformat()
        heads_out[key] = hs
    out["heads"] = heads_out
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
         "--json", "number,headRefOid,isDraft,createdAt"],
        gh_bin=gh_bin, timeout=timeout,
    ) or []


def _fetch_coderabbit_status(repo, sha, gh_bin="gh", timeout=30):
    """head commitのCodeRabbit commit statusから(description, updated_at)を読む(§1)。
    見つからなければ(None, None)。"""
    data = _gh_json(
        ["api", f"repos/{repo}/commits/{sha}/status", "--method", "GET"],
        gh_bin=gh_bin, timeout=timeout,
    ) or {}
    for status in data.get("statuses", []):
        if "coderabbit" in (status.get("context") or "").lower():
            updated_at = status.get("updated_at")
            dt = datetime.fromisoformat(updated_at.replace("Z", "+00:00")) if updated_at else None
            return status.get("description") or "", dt
    return None, None


def _fetch_commit_pushed_at(repo, sha, gh_bin="gh", timeout=30):
    """headのcommitがpushされたおおよその時刻(§3.3のheadが変わったかの判定に使う)。
    committerのdateを使う(pushの正確な時刻はGitHub APIから直接取れないため近似)。
    見つからなければNone。"""
    data = _gh_json(
        ["api", f"repos/{repo}/commits/{sha}", "--method", "GET"],
        gh_bin=gh_bin, timeout=timeout,
    ) or {}
    date_str = ((data.get("commit") or {}).get("committer") or {}).get("date")
    if not date_str:
        return None
    return datetime.fromisoformat(date_str.replace("Z", "+00:00"))


def _fetch_recent_review_starts(allowlist, gh_bin="gh", timeout=30, now=None, window_minutes=60):
    """直前window_minutes分に実際に走ったhalskのレビュー開始時刻(確定版§9.2手段3の元データ)。

    取得に失敗しても空listを返す(呼び出し側のnext_attempt_at()はnow+60分の
    一律退きへ倒れる。壊れない設計・確定版§9.3)。

    ★既知の限界: 割当は開発者ごと(cmd_870)で、設計はgeolonia org全体を数える
    ことを求める(§9.2)が、org全体のPR検索はレート・権限の負担が大きいため、
    本実装はallowlist配下のrepoに絞って近似する。allowlist外repoでのレビュー
    消費は見えない——効くように見せて実は効かないままにしないため、この限界は
    正直にコードコメントへ残す(cmd_908 F4)。
    """
    if now is None:
        now = datetime.now(timezone.utc)
    since = now - timedelta(minutes=window_minutes)
    starts = []
    for repo in allowlist:
        try:
            prs = _fetch_open_prs(repo, gh_bin=gh_bin, timeout=timeout)
        except (subprocess.SubprocessError, subprocess.TimeoutExpired, ValueError):
            continue
        for pr in prs:
            sha = pr.get("headRefOid")
            if not sha:
                continue
            try:
                data = _gh_json(
                    ["api", f"repos/{repo}/commits/{sha}/status", "--method", "GET"],
                    gh_bin=gh_bin, timeout=timeout) or {}
            except (subprocess.SubprocessError, subprocess.TimeoutExpired, ValueError):
                continue
            for status in data.get("statuses", []):
                if "coderabbit" not in (status.get("context") or "").lower():
                    continue
                if classify(status.get("description") or "") != "reviewed":
                    continue
                created_at = status.get("created_at")
                if not created_at:
                    continue
                dt = datetime.fromisoformat(created_at.replace("Z", "+00:00"))
                if dt >= since:
                    starts.append(dt)
    return starts


def _fetch_latest_wait_notice(repo, pr_number, gh_bin="gh", timeout=30, since_hours=6,
                               min_updated_at=None):
    """CodeRabbitの要約コメントから待ち時間の通知を読む(§2)。
    見つからなければ(None, None)。

    ★`since`で直近`since_hours`時間(または`min_updated_at`指定時はそれ以後)に絞る
    (古いPRの全コメント履歴を毎周回無制限に取得しないため。10分毎に回る本ジョブでは
    直近の通知で足りる)。

    ★F1是正: `-f`付きのgh api呼び出しはghが既定でPOSTにする(gh api --help)。
    `-f since=...`だけを渡すと、issueへのコメント作成のPOSTになってしまい
    assert_allowed_bodyを通らぬ書き込み経路が生じていた。`--method GET`を
    明示し、読み取り専用であることをコードで固定する。

    ★F2是正: `min_updated_at`(通常はcommit statusのupdated_at)を渡せば、
    それより古いコメントの通知は使わない(古い別件の通知を拾わない)。
    """
    since_dt = min_updated_at if min_updated_at is not None else (
        datetime.now(timezone.utc) - timedelta(hours=since_hours))
    since = since_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    comments = _gh_json(
        ["api", f"repos/{repo}/issues/{pr_number}/comments",
         "--method", "GET", "-f", f"since={since}", "--paginate"],
        gh_bin=gh_bin, timeout=timeout,
    ) or []
    for comment in reversed(comments):
        login = ((comment.get("user") or {}).get("login") or "")
        if "coderabbit" not in login.lower():
            continue
        body = comment.get("body") or ""
        wait = parse_wait(body)
        if wait is None:
            continue
        updated_at = comment.get("updated_at") or comment.get("created_at")
        dt = datetime.fromisoformat(updated_at.replace("Z", "+00:00")) if updated_at else None
        if min_updated_at is not None and dt is not None and dt < min_updated_at:
            continue  # F2: statusのupdated_at以前の通知(古い別件)は使わない
        return dt, wait
    return None, None


def run(cfg, state, now, stop_path, gh_bin="gh", dry_run=False, log_path=None,
        run_id=None, runner=None):
    """1周回ぶんの判定・投げ直しを行う(§1〜§3・確定版§8〜§9)。

    ★F1是正: PRごとの取得(status/通知)は個別にtry/exceptで囲み、1件の失敗で
    run()全体を落とさず次のPRへ進む。
    ★F3是正: 周回ごとに1行(runner・run_id・見たPR数)、PRごとに判定と理由の行を
    log_linesへ積む(呼び出し側がlog_pathへ書く)。
    ★F4是正: query.enabled/query_policy/may_query/recent_review_startsを
    実際にここから呼ぶ。
    ★F6是正: §3.3(直近10分にheadが変わったPRは待つ)・未知description・
    2時間status無しの警告をここで判定する。

    戻り値: (更新後のstate, 実行ログの行のlist)
    """
    killed = is_killed(stop_path)
    allowlist = cfg.get("allowlist", [])
    fallback_mode = cfg.get("fallback_mode", "window")
    budget = cfg.get("budget", {})
    query_cfg = cfg.get("query", {})
    query_enabled = bool(query_cfg.get("enabled", False))
    query_policy = cfg.get("query_policy", "before_computed")
    log_lines = []

    recent_review_starts = []
    if fallback_mode == "window":
        try:
            recent_review_starts = _fetch_recent_review_starts(
                allowlist, gh_bin=gh_bin, now=now)
        except (subprocess.SubprocessError, subprocess.TimeoutExpired, ValueError) as exc:
            log_lines.append({"ts": now.isoformat(), "event": "recent_review_starts_error",
                               "error": str(exc)})

    prs = []
    pr_count = 0
    for repo in allowlist:
        if not is_allowed_repo(repo, allowlist):
            continue  # 上流denylistとの重複防御(§1)
        try:
            raw_prs = _fetch_open_prs(repo, gh_bin=gh_bin)
        except (subprocess.SubprocessError, subprocess.TimeoutExpired, ValueError) as exc:
            log_lines.append({"ts": now.isoformat(), "repo": repo,
                               "event": "pr_list_error", "error": str(exc)})
            continue
        for raw in raw_prs:
            pr_count += 1
            pr_number = raw.get("number")
            sha = raw.get("headRefOid")
            try:
                desc, updated_at = _fetch_coderabbit_status(repo, sha, gh_bin=gh_bin)
            except (subprocess.SubprocessError, subprocess.TimeoutExpired, ValueError) as exc:
                # F1: 1件の取得失敗で全体を止めず、次のPRへ進む。
                log_lines.append({"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                   "event": "status_fetch_error", "error": str(exc)})
                continue

            if desc is None:
                entry = {"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                          "category": "no_status", "decision": "skip"}
                # F6: non-draftで2時間以上statusが無ければ警告のみ。
                created_at_str = raw.get("createdAt")
                created_at = (datetime.fromisoformat(created_at_str.replace("Z", "+00:00"))
                              if created_at_str else None)
                if (not raw.get("isDraft") and created_at is not None
                        and now - created_at > timedelta(hours=2)):
                    entry["level"] = "warn"
                    entry["reason"] = "no_status_over_2h"
                log_lines.append(entry)
                continue

            category = classify(desc)

            sources = {}
            if updated_at is not None:
                sources["notice_updated_at"] = updated_at
                sources["notice_wait_minutes"] = parse_wait(desc)
            if sources.get("notice_wait_minutes") is None and category in CANDIDATE_CATEGORIES:
                try:
                    notice_at, wait_minutes = _fetch_latest_wait_notice(
                        repo, pr_number, gh_bin=gh_bin, min_updated_at=updated_at)
                except (subprocess.SubprocessError, subprocess.TimeoutExpired, ValueError) as exc:
                    log_lines.append({"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                       "event": "notice_fetch_error", "error": str(exc)})
                    notice_at, wait_minutes = None, None
                if notice_at is not None:
                    sources["notice_updated_at"] = notice_at
                    sources["notice_wait_minutes"] = wait_minutes

            # F4: 通知の待ち時間が読めぬ時、予備の問い合わせ(may_query)を条件つきで使う。
            if category in CANDIDATE_CATEGORIES and sources.get("notice_wait_minutes") is None:
                incident_key = (
                    f"{repo}#{pr_number}#{sha}#"
                    f"{updated_at.isoformat() if updated_at else 'na'}"
                )
                should_query = query_policy != "after_computed_miss"
                if query_policy == "after_computed_miss":
                    computed = next_attempt_at(
                        {"recent_review_starts": recent_review_starts}, now, mode=fallback_mode)
                    should_query = computed <= now  # 手段3の刻限を過ぎてなお読めぬ=外れ
                if query_enabled and should_query and may_query(incident_key, state, now, budget):
                    if not dry_run:
                        try:
                            post_comment(repo, pr_number, QUERY_BODY, gh_bin=gh_bin)
                            state.setdefault("query_incidents", {})[incident_key] = now
                            state.setdefault("query_log", []).append(now)
                            log_lines.append({"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                               "event": "query_posted",
                                               "incident_key": incident_key})
                        except (subprocess.SubprocessError, subprocess.TimeoutExpired,
                                ValueError) as exc:
                            log_lines.append({"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                               "event": "query_post_failed", "error": str(exc)})
                sources["recent_review_starts"] = recent_review_starts

            next_at = next_attempt_at(sources, now, mode=fallback_mode)
            pr_entry = {
                "repo": repo, "pr": pr_number, "head_sha": sha,
                "description": desc, "draft": bool(raw.get("isDraft")),
                "allowed": is_allowed_repo(repo, allowlist),
                "next_attempt_at": next_at,
                "status_updated_at": updated_at,
            }
            if category in CANDIDATE_CATEGORIES:
                # §3.3: 直近10分にheadが変わったPRは待つ。
                try:
                    pr_entry["head_pushed_at"] = _fetch_commit_pushed_at(
                        repo, sha, gh_bin=gh_bin)
                except (subprocess.SubprocessError, subprocess.TimeoutExpired,
                        ValueError) as exc:
                    log_lines.append({"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                       "event": "commit_fetch_error", "error": str(exc)})
                    pr_entry["head_pushed_at"] = None
            prs.append(pr_entry)

            reason = _decision_reason(pr_entry, state, now)
            entry = {"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                      "head_sha": sha, "category": category, "decision": reason}
            if category == "unknown":
                entry["level"] = "warn"
            if reason == "stale_no_fresh_rate_limit":
                head_state = state.get("heads", {}).get(
                    f"{repo}#{pr_number}#{sha}", {})
                last_trigger_at = head_state.get("last_trigger_at")
                if (last_trigger_at is not None
                        and now - last_trigger_at > timedelta(minutes=60)):
                    # §3.2: 投げた後60分たってもrate limitedでもreviewedでもなければ警告のみ。
                    entry["level"] = "warn"
                    entry["reason"] = "no_response_after_trigger_60min"
            log_lines.append(entry)

    targets = select_targets(state, prs, budget, now, killed=killed)

    for pr in targets:
        key = f"{pr['repo']}#{pr['pr']}#{pr['head_sha']}"
        entry = {"ts": now.isoformat(), "repo": pr["repo"], "pr": pr["pr"],
                  "head_sha": pr["head_sha"], "event": "triggered", "dry_run": dry_run}
        if not dry_run:
            try:
                post_comment(pr["repo"], pr["pr"], TRIGGER_BODY, gh_bin=gh_bin)
            except (subprocess.SubprocessError, subprocess.TimeoutExpired, ValueError) as exc:
                entry["event"] = "post_failed"
                entry["error"] = str(exc)
                log_lines.append(entry)
                continue
            head_state = state.setdefault("heads", {}).setdefault(key, {"attempts": 0})
            head_state["attempts"] = head_state.get("attempts", 0) + 1
            head_state["last_trigger_at"] = now  # F2: 再投げの鮮度判定に使う
            state.setdefault("sent_log", []).append(now)
        log_lines.append(entry)

    log_lines.append({"ts": now.isoformat(), "event": "cycle", "runner": runner,
                       "run_id": run_id, "prs_seen": pr_count})

    if log_path:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as f:
            for entry in log_lines:
                f.write(json.dumps(entry, ensure_ascii=False, default=str) + "\n")

    return state, log_lines


def _write_status_summary(status_path, log_path, now, window_hours=24):
    """queue/reports/cr_retrigger_status.yaml: 直近window_hours時間の要約(確定版§4)。
    cmd_861の『朝に分かること』のため、家老が巡回でdashboardへ写せる形にする。
    """
    import yaml  # PyYAML

    entries = []
    if log_path and os.path.exists(log_path):
        cutoff = now - timedelta(hours=window_hours)
        with open(log_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = entry.get("ts")
                dt = None
                if ts:
                    try:
                        dt = datetime.fromisoformat(ts)
                    except ValueError:
                        dt = None
                if dt is not None and dt < cutoff:
                    continue
                entries.append(entry)

    triggered = [e for e in entries if e.get("event") == "triggered"]
    failed = [e for e in entries if e.get("event") in (
        "post_failed", "status_fetch_error", "notice_fetch_error",
        "pr_list_error", "query_post_failed", "commit_fetch_error",
        "recent_review_starts_error")]
    warnings = [e for e in entries if e.get("level") == "warn"]
    cycles = [e for e in entries if e.get("event") == "cycle"]

    summary = {
        "generated_at": now.isoformat(),
        "window_hours": window_hours,
        "cycles_seen": len(cycles),
        "triggered_count": len(triggered),
        "triggered": [
            {"repo": e.get("repo"), "pr": e.get("pr"), "ts": e.get("ts")} for e in triggered
        ],
        "failed_count": len(failed),
        "failed": [
            {"repo": e.get("repo"), "pr": e.get("pr"), "event": e.get("event"), "ts": e.get("ts")}
            for e in failed
        ],
        "warning_count": len(warnings),
        "warnings": [
            {"repo": e.get("repo"), "pr": e.get("pr"), "reason": e.get("reason"), "ts": e.get("ts")}
            for e in warnings
        ],
    }
    os.makedirs(os.path.dirname(status_path), exist_ok=True)
    with open(status_path, "w", encoding="utf-8") as f:
        yaml.safe_dump(summary, f, allow_unicode=True, sort_keys=False)
    return summary


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
    parser.add_argument("--status-file", default=os.path.join(
        os.path.dirname(__file__), "..", "queue", "reports", "cr_retrigger_status.yaml"))
    parser.add_argument("--dry-run", action="store_true",
                         help="投稿せず、候補のみログへ出す")
    args = parser.parse_args(argv)

    cfg = _load_config(args.config)
    if not cfg.get("enabled", True):
        print("[cr_retrigger] disabled by config — exit")
        return 0

    now = datetime.now(timezone.utc)
    state = _load_state(args.state)
    # F3: launcherがplistのEnvironmentVariablesで渡すrunner/run_id(§10.3の目印)。
    run_id = os.environ.get("CR_RETRIGGER_RUN_ID")
    runner = os.environ.get("CR_RETRIGGER_RUNNER")

    state, log_lines = run(
        cfg, state, now, args.stop_file, dry_run=args.dry_run, log_path=args.log_file,
        run_id=run_id, runner=runner,
    )
    _save_state(args.state, state)
    _write_status_summary(args.status_file, args.log_file, now)

    for entry in log_lines:
        print(json.dumps(entry, ensure_ascii=False, default=str))
    print(f"[cr_retrigger] {now.isoformat()} 周回終了(候補{len(log_lines)}件・dry_run={args.dry_run})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
