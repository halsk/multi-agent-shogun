#!/usr/bin/env python3
"""cmd_908 T1 + cmd_913: CodeRabbit rate-limited PR 自動再引き金 — 実装。

設計: queue/reports/cmd908_ratelimit_retrigger_design.md
  (§1〜§7が基本設計、末尾「確定版(cmd_909【D】)」§8〜§11が最終版。
   食い違う所は確定版を優先する。)
  cmd_913: queue/reports/cmd913_crdecide_integration.md §5 —
  「決める」部分をgeolonia/skillsのcr-decide.mjsへ寄せる(一段め)。

★このモジュールは決定論的な純関数群(classify/may_query/select_targets/
assert_allowed_body)と、それらを束ねる薄いrun()/main()のみで構成する。
LLMを実行経路に一切含めない。「決める」はcr-decide(node子プロセス)に
寄せ、本モジュールは「見つける・呼ぶ・守る(台帳)・投じる・記録する」を持つ。

本T1の範囲外(T2・家老の担当): launchd登録・Keychain設定・
本番HCのcheck作成。本モジュールはファイルを置くのみで、それらには触れない。
cr-decideのapprove(@coderabbitai approve)を実際に投じることも範囲外
(cmd_913一段め・殿/将軍のご判断待ち)——記録のみ行う。

cmd_913至急(殿ご下命・shogun msg_20260928_191226_5ee0f443・
msg_20260928_191314_539b160e): cr-decideがpay(`@coderabbitai review
--use-credits`)と判じた時は、実行(投稿)せず殿へntfyし、ご裁可(「はい」)を
待つ形に拡張する。実行そのものの接続(殿の「はい」を受けて次周回で
実際に投じる経路)は本T1の範囲外——ここでは「止まる」「ntfyする」
「答えを待つ」までを実装する。
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

# cmd_913 §5: cr-decideのcommandのうち、投じてよいのはこの2つの写像のみ。
# approve(@coderabbitai approve)・pay(@coderabbitai review --use-credits)は
# ここに無いため、cr-decideが返しても投じず記録だけする(一段め・観察用)。
CR_DECIDE_POSTABLE_COMMANDS = {
    "@coderabbitai review": TRIGGER_BODY,
    "@coderabbitai rate limit": QUERY_BODY,
}

_REVIEWED_EXACT = {"Review completed", "Review approved"}
_WAITING_EXACT = {"Review in progress", "Review queued"}

CANDIDATE_CATEGORIES = frozenset({"rate_limited", "paused"})


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
            no_status/unknown) | "head_recent_push"(§3.3) |
            "cr_decide_not_review"(cmd_913§5・cr-decideがreview以外を返した) |
            "max_attempts" | "stale_no_fresh_rate_limit"(確定版F2) |
            "not_due" | "candidate"
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

    # cmd_913 §5: cr-decideを呼んだPRは、その答えが"review"の時だけ候補になる。
    # このキーが無いpr(cr-decideを呼ばない/呼んでいない古い呼び出し形)は
    # 従来どおり素通りする(既定True・既存の純関数テストへの非回帰)。
    if not pr.get("cr_decide_recommends_review", True):
        return "cr_decide_not_review"

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

    # cmd_913: next_attempt_atはもはや自前の移動窓計算では埋めない。
    # cr-decideがretryAtを返した時だけ埋まる(run()参照)。無ければnowのまま
    # (=cr-decideが"review"を返した以上、待つ理由が無い)。
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


# ── cmd_913 §5: cr-decideへの「呼ぶ」統合 ────────────────────────────

def _clean_git_env():
    """GIT_*を全て外した環境を返す(cmd_901/903/906と同型の事故を防ぐ)。
    呼び出し元プロセスのGIT_DIR等が子プロセス(node/git)へ漏れて、
    意図しないリポジトリを触る事故を防ぐための隔離。"""
    return {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def _ensure_clone(repo, clones_dir, gh_bin="gh", git_bin="git", timeout=60):
    """repoの読み取り専用cloneを用意する(cr-decideのrebase判定に手元gitが要るため)。
    既に有ればfetchのみ・無ければ`gh repo clone`する。戻り値: cloneのpath。
    """
    clone_dir = os.path.join(clones_dir, repo.replace("/", "__"))
    env = _clean_git_env()
    if not os.path.isdir(os.path.join(clone_dir, ".git")):
        os.makedirs(clones_dir, exist_ok=True)
        subprocess.run(
            [gh_bin, "repo", "clone", repo, clone_dir],
            check=True, timeout=timeout, env=env,
        )
    else:
        subprocess.run(
            [git_bin, "-C", clone_dir, "fetch", "--quiet", "origin"],
            check=True, timeout=timeout, env=env,
        )
    return clone_dir


def _ensure_cr_decide_tool(cr_decide_cfg, clones_dir, gh_bin="gh", git_bin="git", timeout=60):
    """cr-decide.mjs・policy.jsonの実物を用意する(geolonia/skillsのclone、
    検めた特定commitへpinする — cmd_913 X2是正)。

    ★origin/mainやbranch名への自動追随(reset --hard origin/main等)は
    禁止する。org側で誰かがgeolonia/skillsのmainへmergeした内容が、
    当家の検めなしに殿のgh権限で自動実行される穴になるため
    (cr-decide.mjsを子プロセスとして呼ぶ以上、そのコードが実行される)。
    cr_decide_cfg["tool_ref"](検めたcommit SHA)を必須とし、
    そのSHAをdetached HEADでcheckoutする。更新は家老が差分を検めた
    上でtool_refの値を明示的に書き換える運用とする。

    戻り値: (script_path, policy_path)。
    """
    tool_repo = cr_decide_cfg.get("tool_repo", "geolonia/skills")
    tool_ref = cr_decide_cfg.get("tool_ref")
    if not tool_ref:
        raise ValueError(
            "cr_decide.tool_ref is required (pinned, vetted commit SHA). "
            "origin/main auto-tracking is forbidden (cmd_913 X2)."
        )
    clone_dir = _ensure_clone(tool_repo, clones_dir, gh_bin=gh_bin, git_bin=git_bin, timeout=timeout)
    env = _clean_git_env()
    subprocess.run(
        [git_bin, "-C", clone_dir, "checkout", "--quiet", "--detach", tool_ref],
        check=True, timeout=timeout, env=env,
    )
    script_path = os.path.join(
        clone_dir,
        cr_decide_cfg.get("script_relpath", "skills/coderabbit-pr-flow/scripts/cr-decide.mjs"),
    )
    policy_path = os.path.join(
        clone_dir,
        cr_decide_cfg.get("policy_relpath", "skills/coderabbit-pr-flow/policy.json"),
    )
    return script_path, policy_path


def call_cr_decide(repo, pr_number, clone_dir, script_path, policy_path=None,
                    node_bin="node", timeout=30):
    """cr-decide.mjsを子プロセスとして呼び、次の一手のJSONを返す(cmd_913§5)。

    呼出・パース双方の失敗はfail closedで{"action": "error", "reason": str}を
    返す(投じない側へ倒す)。大きいPRのENOBUFS(Daniel殿の直しを待つ間の暫定)
    もこの経路でerrorとして受け止める。
    """
    cmd = [node_bin, script_path, str(pr_number), "--repo", repo]
    if policy_path:
        cmd += ["--policy", policy_path]
    env = _clean_git_env()
    try:
        result = subprocess.run(
            cmd, cwd=clone_dir, capture_output=True, text=True, timeout=timeout, env=env,
        )
        data = json.loads(result.stdout)
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError, ValueError) as exc:
        return {"action": "error", "reason": str(exc)}
    if not isinstance(data, dict) or "action" not in data:
        return {"action": "error", "reason": "malformed cr-decide output"}
    return data


def _parse_retry_at(retry_at_str):
    if not retry_at_str:
        return None
    try:
        return datetime.fromisoformat(retry_at_str.replace("Z", "+00:00"))
    except ValueError:
        return None


# ── cmd_913至急: pay裁可制ntfy ──────────────────────────────────────

# cr-decide.mjsのpay分岐の文言(検めたtool_ref固定・§8.1と同じ「検めた
# 文言だけを信じる」流儀): "Wait ~90 min is too long; 2 file(s) cost
# about $0.50." から待ち分数・ファイル数・費えを取り出す。取れなければ
# _build_pay_ntfy_bodyが「推定」と明記した代替値へ倒す。
_PAY_COST_RE = re.compile(r"(\d+) file\(s\) cost about \$(\d+(?:\.\d+)?)")
_PAY_WAIT_RE = re.compile(r"Wait ~(\d+) min")

# 正規表現で取れなかった時の代替ファイル数(cr-decideのpolicy.jsonの
# pay.maxFiles相当の上限値。実測できないので上限側に倒し、費えを
# 少なく見せない)。
PAY_COST_FALLBACK_FILES = 4


def _pay_incident_key(repo, pr_number, head_sha):
    """このPR・このhead・このpay判定を一意に指す鍵(重複ntfy防止の台帳キー)。"""
    return f"{repo}#{pr_number}#{head_sha}"


def _estimate_pay_cost(decision):
    """cr-decideのreason文字列から、待ち分数・ファイル数・費えを取り出す。

    戻り値: (file_count, cost_usd, wait_minutes, is_estimate)。
    reasonの形が変わって取れない場合は、file_count/cost_usdをフォールバック値で
    埋めた上でis_estimate=Trueを返す(呼び出し側が「推定」と明記する)。
    """
    reason = decision.get("reason") or ""
    cost_match = _PAY_COST_RE.search(reason)
    wait_match = _PAY_WAIT_RE.search(reason)
    wait_minutes = int(wait_match.group(1)) if wait_match else None
    if cost_match:
        return int(cost_match.group(1)), float(cost_match.group(2)), wait_minutes, False
    file_count = PAY_COST_FALLBACK_FILES
    return file_count, round(file_count * 0.25, 2), wait_minutes, True


def _build_pay_ntfy_body(pending_pays, now):
    """複数PRのpay判定を1通のntfy本文へまとめる(鳴らしすぎ防止)。

    PRごとにURL・見込み費え(推定なら明記)・払わぬ場合の待ち見込み・
    その間止まる範囲(このPR1本の遅延のみ・mainは赤くならない)を書く。
    """
    lines = []
    for p in pending_pays:
        file_count, cost_usd, wait_minutes, is_estimate = _estimate_pay_cost(p["decision"])
        est_mark = "(推定)" if is_estimate else ""
        wait_desc = f"約{wait_minutes}分" if wait_minutes is not None else "不明(cr-decideの答えから読み取れず)"
        url = f"https://github.com/{p['repo']}/pull/{p['pr']}"
        lines.append(
            f"{url} : 見込みの費え 約${cost_usd:.2f}{est_mark}"
            f"({file_count}ファイル×$0.25)。払わねば{wait_desc}待ち。"
            f"払わぬ間はこの1本のPRのマージが遅れるのみ(mainは赤くならぬ——"
            f"当家のマージ門はCodeRabbitレビュー完了を要すため、未マージの"
            f"PRがmainへ影響することは無い)。"
        )
    if len(lines) == 1:
        header = "cr-decideがpay(課金レビュー)を勧めておる。実行はせず止まっておる。ご裁可(「はい」)を賜りたし。"
    else:
        header = (
            f"cr-decideが{len(lines)}件のPRでpay(課金レビュー)を勧めておる。"
            "実行はせず止まっておる。ご裁可(「はい」)を賜りたし(鳴らしすぎぬよう一通にまとめた)。"
        )
    return header + "\n" + "\n".join(lines)


def _post_pay_ntfy(body, ntfy_bin=None, cmd_id="cmd_913", timeout=30):
    """殿へpay裁可要求のntfyを送る(scripts/ntfy.shの`--kind 要承認`型を使う。
    新しい流儀は作らない——cmd_913至急の指示どおり既存経路に乗せる)。"""
    if ntfy_bin is None:
        ntfy_bin = os.path.join(os.path.dirname(__file__), "ntfy.sh")
    subprocess.run(
        [ntfy_bin, "--cmd", cmd_id, "--kind", "要承認", "--eta", "殿のご返答まで", "--body", body],
        check=True, timeout=timeout,
    )


# ── main(): T1の範囲では実配線のみ。本番のgh呼び出しはCI/ローカルでは
#    走らない(引数無しでは何もしない)。orchestration のみを担い、
#    判定規則そのものは上の純関数に閉じ込めてある。────────────────────

def _load_config(path):
    import yaml  # PyYAML — CI/開発環境にインストール済み(claude_usage_report等と同様)

    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def _load_state(path):
    if not os.path.exists(path):
        return {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                 "pay_ntfy_sent": {}}
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    raw["sent_log"] = [datetime.fromisoformat(t) for t in raw.get("sent_log", [])]
    raw["query_log"] = [datetime.fromisoformat(t) for t in raw.get("query_log", [])]
    raw["query_incidents"] = {
        k: datetime.fromisoformat(v) for k, v in raw.get("query_incidents", {}).items()
    }
    raw["pay_ntfy_sent"] = {
        k: datetime.fromisoformat(v) for k, v in raw.get("pay_ntfy_sent", {}).items()
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
    out["pay_ntfy_sent"] = {
        k: v.isoformat() for k, v in state.get("pay_ntfy_sent", {}).items()
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


def run(cfg, state, now, stop_path, gh_bin="gh", dry_run=False, log_path=None,
        run_id=None, runner=None):
    """1周回ぶんの判定・投げ直しを行う(§1〜§3・確定版§8〜§9・cmd_913§5)。

    ★F1是正: PRごとの取得(status)は個別にtry/exceptで囲み、1件の失敗で
    run()全体を落とさず次のPRへ進む。
    ★F3是正: 周回ごとに1行(runner・run_id・見たPR数)、PRごとに判定と理由の行を
    log_linesへ積む(呼び出し側がlog_pathへ書く)。
    ★F6是正: §3.3(直近10分にheadが変わったPRは待つ)・未知description・
    2時間status無しの警告をここで判定する。
    ★cmd_913: rate_limited/pausedのPRごとにcr-decideを呼び、「決める」を
    寄せる。台帳(同一head1回・毎時毎日の予算・checkの下限・最大3回・
    停止スイッチ)は引き続きここで守る。cr-decideのcommandが投じてよい
    2文言の外(approve・pay)なら、投じずに記録だけする(観察用)。

    戻り値: (更新後のstate, 実行ログの行のlist)
    """
    killed = is_killed(stop_path)
    allowlist = cfg.get("allowlist", [])
    budget = cfg.get("budget", {})
    query_cfg = cfg.get("query", {})
    query_enabled = bool(query_cfg.get("enabled", False))
    cr_decide_cfg = cfg.get("cr_decide", {})
    cr_decide_enabled = bool(cr_decide_cfg.get("enabled", True))
    clones_dir_raw = cr_decide_cfg.get("clones_dir") or os.path.join(
        os.path.dirname(__file__), "..", "state", "cr_decide_clones")
    # 相対path(config既定値の"state/cr_decide_clones"等)はproject rootから解く
    # (launchd等、cwdがproject rootでない起動元でも壊れないため)。
    clones_dir = clones_dir_raw if os.path.isabs(clones_dir_raw) else os.path.join(
        os.path.dirname(__file__), "..", clones_dir_raw)
    node_bin = cr_decide_cfg.get("node_bin", "node")
    cr_decide_timeout = cr_decide_cfg.get("timeout", 30)
    ntfy_cfg = cfg.get("ntfy", {})
    ntfy_bin = ntfy_cfg.get("bin")
    ntfy_timeout = ntfy_cfg.get("timeout", 30)
    log_lines = []

    tool_paths = None  # (script_path, policy_path) — 最初のcandidateで初期化する
    repo_clone_dirs = {}
    pending_pays = []  # cmd_913至急: このcycleでpay判定になったPR(ntfy候補)

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

            pr_entry = {
                "repo": repo, "pr": pr_number, "head_sha": sha,
                "description": desc, "draft": bool(raw.get("isDraft")),
                "allowed": is_allowed_repo(repo, allowlist),
                "next_attempt_at": now,
                "status_updated_at": updated_at,
            }

            # cmd_913 §5: 「見つける」で渡すのはrate_limited・paused状態の
            # (draftでない・allowlist内の)PRのみ。skippedは渡さない(既存動作)。
            is_cr_decide_target = (
                category in CANDIDATE_CATEGORIES
                and not pr_entry["draft"]
                and pr_entry["allowed"]
            )

            if is_cr_decide_target:
                # 既定は「cr-decideを呼べていない」= reviewを投じる候補にしない
                # (安全側。呼べて初めてTrueへ倒す)。
                pr_entry["cr_decide_recommends_review"] = False

                # §3.3: 直近10分にheadが変わったPRは待つ(cr-decideを呼ぶ前の安価な足切り)。
                try:
                    pr_entry["head_pushed_at"] = _fetch_commit_pushed_at(
                        repo, sha, gh_bin=gh_bin)
                except (subprocess.SubprocessError, subprocess.TimeoutExpired,
                        ValueError) as exc:
                    log_lines.append({"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                       "event": "commit_fetch_error", "error": str(exc)})
                    pr_entry["head_pushed_at"] = None

                recent_push = (
                    pr_entry["head_pushed_at"] is not None
                    and now - pr_entry["head_pushed_at"] < timedelta(minutes=10)
                )

                if not cr_decide_enabled:
                    log_lines.append({"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                       "event": "cr_decide_disabled"})
                elif not recent_push:
                    try:
                        if tool_paths is None:
                            tool_paths = _ensure_cr_decide_tool(
                                cr_decide_cfg, clones_dir, gh_bin=gh_bin, timeout=cr_decide_timeout)
                        script_path, policy_path = tool_paths
                        if repo not in repo_clone_dirs:
                            repo_clone_dirs[repo] = _ensure_clone(
                                repo, clones_dir, gh_bin=gh_bin, timeout=cr_decide_timeout)
                        clone_dir = repo_clone_dirs[repo]
                    except (subprocess.SubprocessError, subprocess.TimeoutExpired,
                            OSError) as exc:
                        log_lines.append({"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                           "event": "cr_decide_clone_error", "level": "warn",
                                           "error": str(exc)})
                        clone_dir = None

                    if clone_dir is not None:
                        decision = call_cr_decide(
                            repo, pr_number, clone_dir, script_path, policy_path=policy_path,
                            node_bin=node_bin, timeout=cr_decide_timeout)
                        action = decision.get("action")
                        command = decision.get("command")
                        pr_entry["cr_decide_action"] = action

                        if action == "error":
                            log_lines.append({
                                "ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                "event": "cr_decide_error", "level": "warn",
                                "reason": decision.get("reason"),
                            })
                        elif command and command not in CR_DECIDE_POSTABLE_COMMANDS:
                            # approve・pay(--use-credits): 一段めは投じず記録のみ。
                            log_lines.append({
                                "ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                "event": "cr_decide_observed_not_posted",
                                "action": action, "command": command,
                                "reason": decision.get("reason"),
                            })
                            if action == "pay":
                                # cmd_913至急: payは実行せず殿へntfyして止まる
                                # (ntfy本体は全PR分見終えた後に一通へまとめる)。
                                pending_pays.append({
                                    "repo": repo, "pr": pr_number, "head_sha": sha,
                                    "decision": decision,
                                })
                        elif command == "@coderabbitai rate limit":
                            incident_key = f"{repo}#{pr_number}#{sha}#{action}"
                            if (query_enabled and not killed
                                    and may_query(incident_key, state, now, budget)):
                                if not dry_run:
                                    try:
                                        post_comment(repo, pr_number, QUERY_BODY, gh_bin=gh_bin)
                                        state.setdefault("query_incidents", {})[incident_key] = now
                                        state.setdefault("query_log", []).append(now)
                                        log_lines.append({
                                            "ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                            "event": "query_posted", "incident_key": incident_key,
                                        })
                                    except (subprocess.SubprocessError,
                                            subprocess.TimeoutExpired, ValueError) as exc:
                                        log_lines.append({
                                            "ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                            "event": "query_post_failed", "error": str(exc),
                                        })
                            else:
                                log_lines.append({
                                    "ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                    "event": "query_not_posted",
                                    "reason": ("disabled" if not query_enabled
                                               else "killed" if killed else "rate_limited"),
                                })
                        elif command == "@coderabbitai review":
                            # 通常のTRIGGER_BODYルートへ乗せる(台帳はselect_targetsが守る)。
                            pr_entry["cr_decide_recommends_review"] = True
                        else:
                            # wait / queue / in-progress / done / skip / wait-ready:
                            # 投じるcommandは無い。retryAtがあれば次回のcr-decide呼び出しを
                            # 間引くためnext_attempt_atへ反映する。
                            retry_at = _parse_retry_at(decision.get("retryAt"))
                            if retry_at is not None:
                                pr_entry["next_attempt_at"] = retry_at

            prs.append(pr_entry)

            reason = _decision_reason(pr_entry, state, now)
            entry = {"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                      "head_sha": sha, "category": category, "decision": reason}
            if pr_entry.get("cr_decide_action"):
                entry["cr_decide_action"] = pr_entry["cr_decide_action"]
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

    if pending_pays:
        # cmd_913至急: pay判定は実行せず、殿へntfyして止まる。
        # 同一PR・同一head(=同一判定)は殿の返答があるまで再送しない
        # (台帳=state["pay_ntfy_sent"])。同一周回内の複数PRは一通にまとめる。
        pay_ntfy_sent = state.setdefault("pay_ntfy_sent", {})
        to_notify = []
        for p in pending_pays:
            key = _pay_incident_key(p["repo"], p["pr"], p["head_sha"])
            if key in pay_ntfy_sent:
                log_lines.append({
                    "ts": now.isoformat(), "repo": p["repo"], "pr": p["pr"],
                    "event": "pay_ntfy_not_resent",
                    "reason": "already_notified_waiting_for_lord",
                })
            else:
                to_notify.append(p)

        if to_notify:
            if dry_run:
                log_lines.append({
                    "ts": now.isoformat(), "event": "pay_ntfy_would_send", "dry_run": True,
                    "prs": [f"{p['repo']}#{p['pr']}" for p in to_notify],
                })
            else:
                body = _build_pay_ntfy_body(to_notify, now)
                try:
                    _post_pay_ntfy(body, ntfy_bin=ntfy_bin, timeout=ntfy_timeout)
                except (subprocess.SubprocessError, subprocess.TimeoutExpired, OSError) as exc:
                    log_lines.append({
                        "ts": now.isoformat(), "event": "pay_ntfy_failed", "level": "warn",
                        "error": str(exc),
                    })
                else:
                    for p in to_notify:
                        pay_ntfy_sent[_pay_incident_key(p["repo"], p["pr"], p["head_sha"])] = now
                    log_lines.append({
                        "ts": now.isoformat(), "event": "pay_ntfy_sent",
                        "prs": [f"{p['repo']}#{p['pr']}" for p in to_notify],
                    })

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
    ★cmd_913: cr-decideのerror・observed_not_posted(approve/pay)の件数も加える
    (観察のため・pay/approveの枝がいつ・何度出たかを見える形にする)。
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
        "post_failed", "status_fetch_error", "pr_list_error", "query_post_failed",
        "commit_fetch_error", "cr_decide_clone_error")]
    warnings = [e for e in entries if e.get("level") == "warn"]
    cycles = [e for e in entries if e.get("event") == "cycle"]
    cr_decide_errors = [e for e in entries if e.get("event") == "cr_decide_error"]
    observed_not_posted = [e for e in entries if e.get("event") == "cr_decide_observed_not_posted"]

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
        "cr_decide_error_count": len(cr_decide_errors),
        "cr_decide_observed_not_posted_count": len(observed_not_posted),
        "cr_decide_observed_not_posted": [
            {"repo": e.get("repo"), "pr": e.get("pr"), "action": e.get("action"),
             "command": e.get("command"), "ts": e.get("ts")}
            for e in observed_not_posted
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
