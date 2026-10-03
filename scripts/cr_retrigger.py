#!/usr/bin/env python3
"""cmd_908 T1 + cmd_913 + cmd_934 T1: CodeRabbit rate-limited PR 自動再引き金 — 実装。

設計: queue/reports/cmd908_ratelimit_retrigger_design.md
  (§1〜§7が基本設計、末尾「確定版(cmd_909【D】)」§8〜§11が最終版。
   食い違う所は確定版を優先する。)
  cmd_913: queue/reports/cmd913_crdecide_integration.md §5 —
  「決める」部分をgeolonia/skillsのcr-decide.mjsへ寄せる(一段め)。
  cmd_934 T1: queue/reports/cmd934_decompose.md「一」節 —
  「決める」部分をreview-next(cr-decideの改名後)の言うとおりに動くだけの
  係へ格下げする。当家の自前の判断(may_query・head_recent_push・
  stale_no_fresh_rate_limit・rate_limited/pausedのみを見る足切り)を捨て、
  足軽・家老のhookと同じ決める部品(review-next.mjs)に揃える。

★このモジュールは決定論的な純関数群(classify/query_fuse_ok/select_targets/
assert_allowed_body)と、それらを束ねる薄いrun()/main()のみで構成する。
LLMを実行経路に一切含めない。「決める」はreview-next(node子プロセス)に
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
import pwd
import re
import subprocess
import sys
import tempfile
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


def query_fuse_ok(incident_key, state, now, fuse_min):
    """予備の問い合わせ`[AI] @coderabbitai rate limit`の安全の上限(cmd_934 T1)。

    判断ではなく、暴走を止める枷である。同じ件(incident_key)への問い合わせ
    自体が fuse_min 分に1回を超えて出ないよう止めるだけで、全体で何回まで・
    何分に1回まで、という旧来の横断的な枷(確定版§9.2のmay_query)は
    持たない——review-nextのcheckは費えを使わぬ問い合わせであり、他のPRへの
    問い合わせを待たせる理由が無いため(queue/reports/cmd934_decompose.md
    §1-2)。旧may_queryはここから削除した(state["query_incidents"]・
    state["query_log"]は読み捨てとして残るが、以後このモジュールは書かない)。
    """
    fuse = state.get("query_fuse", {})
    last = fuse.get(incident_key)
    if last is None:
        return True
    return now - last >= timedelta(minutes=fuse_min)


def _decision_reason(pr, state, now):
    """このPRが投げ直しの候補かどうかと、その理由をログ向けに一語で返す(§1・§3.2・確定版F2・cmd_934 T1)。

    select_targets()はこの戻り値が"candidate"のものだけを候補とする。
    select_targets自身の絞り込み条件をここへ一本化し、ログ用の理由づけと
    実際の選定ロジックが食い違わないようにする。

    cmd_934 T1: 「決める」はreview-nextに一本化したため、ここでの絞り込みは
    安全の枷(draft・allowlist・reviewed済みの安い足切り・review-nextが
    reviewを勧めたか・同じheadへの最大試行回数・次回時刻)だけに留め、
    自前の判断(head_recent_push・stale_no_fresh_rate_limit)は持たない。

    戻り値: "draft" | "not_allowed" | "reviewed"(classify()の安い足切り) |
            "cr_decide_not_review"(review-nextがreview以外を返した/
            まだ呼んでいない) | "max_attempts" | "not_due" | "candidate"
    """
    if pr.get("draft"):
        return "draft"
    if not pr.get("allowed", True):
        return "not_allowed"
    # cheapな足切り(cmd934_decompose.md §1-2 g): reviewed済みのheadだけは
    # review-nextを呼ぶまでもなく除く。それ以外(waiting/skip/no_status/
    # unknown含む)は、review-nextが"review"を勧めるかどうかで決まる
    # (下のcr_decide_recommends_reviewチェック)。
    if classify(pr.get("description", "")) == "reviewed":
        return "reviewed"

    # review-nextを呼んだPRは、その答えが"review"の時だけ候補になる。
    # このキーが無いpr(review-nextを呼ばない/呼んでいない古い呼び出し形)は
    # 従来どおり素通りする(既定True・既存の純関数テストへの非回帰)。
    if not pr.get("cr_decide_recommends_review", True):
        return "cr_decide_not_review"

    key = f"{pr['repo']}#{pr['pr']}#{pr['head_sha']}"
    head_state = state.get("heads", {}).get(key, {})
    attempts = head_state.get("attempts", 0)
    # §3.2: 同じheadへの試行は最大3回まで。
    if attempts >= 3:
        return "max_attempts"

    # cmd_913: next_attempt_atはもはや自前の移動窓計算では埋めない。
    # review-nextがretryAtを返した時だけ埋まる(run()参照)。無ければnowのまま
    # (=review-nextが"review"を返した以上、待つ理由が無い)。
    next_at = pr.get("next_attempt_at", now)
    if next_at > now:
        return "not_due"
    return "candidate"


def select_targets(state, prs, budget, now, killed=False):
    """投げ直す候補を選ぶ(§3.2の冪等性・上限、確定版§9.1の毎時/毎日の予算)。

    prs: [{repo, pr, head_sha, description, draft, allowed,
           next_attempt_at(省略可・省略時はnowとみなし即時候補),
           cr_decide_recommends_review(省略可・既定True・cmd_934 T1で
           review-nextが"review"を勧めた時だけTrueになる)}]
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


def _child_env():
    """子プロセス(git・gh・node)へ渡す環境(cmd_934 T1)。

    GIT_*を外した上で(_clean_git_env)、HOMEを利用者のpasswdの家へ明示する。
    launchdのplistはHOMEを設定せぬため、review-next.mjsが読むqueue
    (`os.homedir()/.claude/cr-decide/queue/`)の置き場所がnodeの
    os.homedir()の推測に委ねられてしまう——これを避け、常に
    `pwd.getpwuid(os.getuid()).pw_dir`で固定する。親の環境にHOMEが
    有っても無くても、子には必ずこの値を渡す。
    """
    env = _clean_git_env()
    env["HOME"] = pwd.getpwuid(os.getuid()).pw_dir
    return env


def _ensure_clone(repo, clones_dir, gh_bin="gh", git_bin="git", timeout=60):
    """repoの読み取り専用cloneを用意する(cr-decideのrebase判定に手元gitが要るため)。
    既に有ればfetchのみ・無ければ`gh repo clone`する。戻り値: cloneのpath。
    """
    clone_dir = os.path.join(clones_dir, repo.replace("/", "__"))
    env = _child_env()
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
    """review-next.mjs・policy.jsonの実物を用意する(geolonia/skillsのclone、
    検めた特定commitへpinする — cmd_913 X2是正)。

    ★origin/mainやbranch名への自動追随(reset --hard origin/main等)は
    禁止する。org側で誰かがgeolonia/skillsのmainへmergeした内容が、
    当家の検めなしに殿のgh権限で自動実行される穴になるため
    (review-next.mjsを子プロセスとして呼ぶ以上、そのコードが実行される)。
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
    env = _child_env()
    subprocess.run(
        [git_bin, "-C", clone_dir, "checkout", "--quiet", "--detach", tool_ref],
        check=True, timeout=timeout, env=env,
    )
    script_path = os.path.join(
        clone_dir,
        cr_decide_cfg.get("script_relpath", "skills/pr-review-flow/scripts/review-next.mjs"),
    )
    policy_path = os.path.join(
        clone_dir,
        cr_decide_cfg.get("policy_relpath", "skills/pr-review-flow/policy.json"),
    )
    return script_path, policy_path


def call_cr_decide(repo, pr_number, clone_dir, script_path, policy_path=None,
                    node_bin="node", timeout=30):
    """review-next.mjsを子プロセスとして呼び、次の一手のJSONを返す(cmd_913§5・cmd_934 T1)。

    呼出・パース双方の失敗はfail closedで{"action": "error", "reason": str}を
    返す(投じない側へ倒す)。大きいPRのENOBUFS(Daniel殿の直しを待つ間の暫定)
    もこの経路でerrorとして受け止める。
    """
    cmd = [node_bin, script_path, str(pr_number), "--repo", repo]
    if policy_path:
        cmd += ["--policy", policy_path]
    env = _child_env()
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


def _pay_incident_key(repo, pr_number):
    """このPRを一意に指す鍵(重複ntfy防止の台帳キー)。

    ★cmd_913 P2是正: 旧版はrepo#pr#head(headごと)だったため、殿の返答を
    待つ間にpushがあると同じPRへまた通知が飛んでいた。下命は『同じPRに
    ついて何度も送るな(一度送ったら殿のご返答まで黙る)』のため、鍵から
    headを外しrepo#prのみにする。headの変化はpay_ntfy_headsへ記録だけする
    (返答時にどのheadへの裁可かを確かめられるように)。
    """
    return f"{repo}#{pr_number}"


def _fetch_open_prs_with_files(repo, gh_bin="gh", timeout=30):
    """repoのhalsk名義で開いているPR全件をfiles付きで返す(§P1: draftとの
    ファイル重なり判定に使う)。"""
    return _gh_json(
        ["pr", "list", "--repo", repo, "--author", "halsk", "--state", "open",
         "--json", "number,isDraft,files"],
        gh_bin=gh_bin, timeout=timeout,
    ) or []


def _count_blocked_drafts(repo, pr_number, gh_bin="gh", timeout=30):
    """このPRと同じファイルを触る、halskの開いているdraft PR番号のlistを返す。

    ★cmd_913 P1是正: 『払わぬ間はこの1本のPRのマージが遅れるのみ』という
    決め打ちの文言を廃し、実際に同じファイルを触るdraftが後続に控えていれば
    それも待つ、という実況を書くため。gh呼出に失敗、またはこのPR自身が
    一覧に見つからなければNoneを返す(呼び出し側が『確かめられず』へ倒す)。
    """
    try:
        prs = _fetch_open_prs_with_files(repo, gh_bin=gh_bin, timeout=timeout)
    except (subprocess.SubprocessError, subprocess.TimeoutExpired, ValueError):
        return None
    own_files = None
    others = []
    for raw in prs:
        if raw.get("number") == pr_number:
            own_files = {f["path"] for f in raw.get("files", [])}
        elif raw.get("isDraft"):
            others.append(raw)
    if own_files is None:
        return None
    blocked = []
    for raw in others:
        other_files = {f["path"] for f in raw.get("files", [])}
        if own_files & other_files:
            blocked.append(raw["number"])
    return sorted(blocked)


# cmd_913 Q1是正(軍師QC・queue/reports/gunshi_report_cmd913_pay2.yaml):
# 当家のrepoのCIはGitHub Actionsのcheck-runsであり、commit statusは
# 一件も無い(status APIはtotal_count=0の時state=pendingを返すため、
# 旧実装は「緑のmain」を「実行中main」と誤って報せていた)。
_CI_FAILURE_CONCLUSIONS = frozenset({"failure", "timed_out", "cancelled"})
_CI_OK_CONCLUSIONS = frozenset({"success", "skipped", "neutral"})


def _fetch_main_ci_status(repo, gh_bin="gh", timeout=30):
    """mainブランチ最新commitのCI状態を返す('success'|'failure'|'pending'|None)。

    ★cmd_913 P1是正(初版): 『mainは赤くならぬ』という決め打ちの文言を廃した。
    ★cmd_913 Q1是正: 初版はcommits/{sha}/status(commit statusをまとめたAPI)
    を読んでいたが、当家のCIはcheck-runsであり、statusは常に0件・
    state=pendingを返す(軍師実測)。commits/main/check-runsを読み、
    conclusionで決める: failure/timed_out/cancelledが一つでもあれば赤、
    statusがcompletedでないものがあれば実行中、残りがsuccess/skipped/
    neutralだけなら緑。check-runsが0件、またはgh呼出に失敗すればNone
    (呼び出し側が『確かめられず』へ倒す)。
    """
    try:
        data = _gh_json(
            ["api", f"repos/{repo}/commits/main/check-runs", "--method", "GET"],
            gh_bin=gh_bin, timeout=timeout,
        ) or {}
    except (subprocess.SubprocessError, subprocess.TimeoutExpired, ValueError):
        return None
    runs = data.get("check_runs", [])
    if not runs:
        return None
    if any(r.get("conclusion") in _CI_FAILURE_CONCLUSIONS for r in runs):
        return "failure"
    if any(r.get("status") != "completed" for r in runs):
        return "pending"
    if all(r.get("conclusion") in _CI_OK_CONCLUSIONS for r in runs):
        return "success"
    return None


def _describe_blocked_scope(repo, pr_number, gh_bin="gh", timeout=30):
    """『止まる範囲』の文言を組み立てる(§P1是正)。

    殿の下命は『実際のPRの状況を見て具体的に書け』。同じファイルを触る
    draftの実本数と、mainの最新CI結果を実際に読んで書く(決め打ち禁止)。
    """
    blocked = _count_blocked_drafts(repo, pr_number, gh_bin=gh_bin, timeout=timeout)
    if blocked is None:
        drafts_desc = "これを待つdraftの本数は確かめられず(gh呼出失敗)"
    elif blocked:
        nums = "・".join(f"#{n}" for n in blocked)
        drafts_desc = f"これを待つdraftが{len(blocked)}本({nums})"
    else:
        drafts_desc = "この1本だけが遅れる"

    main_state = _fetch_main_ci_status(repo, gh_bin=gh_bin, timeout=timeout)
    if main_state == "success":
        main_desc = "mainの最新CIは緑"
    elif main_state in ("failure", "error"):
        main_desc = "mainの最新CIは赤(このPRとは別要因の可能性あり・要確認)"
    elif main_state == "pending":
        main_desc = "mainの最新CIは実行中"
    else:
        main_desc = "mainの最新CI状態は確かめられず(check-runs0件またはgh呼出失敗)"

    return f"{drafts_desc}。{main_desc}。"


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


def _build_pay_ntfy_body(pending_pays, seq, now, gh_bin="gh", timeout=30):
    """複数PRのpay判定を1通のntfy本文へまとめる(鳴らしすぎ防止)。

    PRごとに印(N{seq}-P1・N{seq}-P2…)・URL・見込み費え(推定なら明記)・
    払わぬ場合の待ち見込み・止まる範囲(実際のdraft本数・mainの最新CI結果を
    読んで決め打ちにせず書く・cmd_913 P1是正)を書く。末尾に返答書式を明記する
    (cmd_913 P3是正)。

    ★cmd_913 Q2是正(軍師QC): 印を通知ごとの通し番号seqを含む形
    (N{seq}-P1)にする。旧版は通知のたびP1から振り直し、台帳
    pay_ntfy_labelsをupdateで上書きしていたため、一通めのP1の返答を
    待つ間に別PRの二通めが出ると、その印P1が一通めのP1を台帳上で
    踏み潰した(殿が一通めのつもりで「はい P1」と答えても、将軍側は
    二通めのPRを払うと読み違える)。seqを呼び出し側(run())が単調増加で
    払い出すことで、異なる通知のラベルは文字列としても衝突せず、
    pay_ntfy_labelsは通知ごとに分離されたキーを持つ。

    戻り値: (body: str, labels: dict[str, dict])。labelsは"N{seq}-P1"などの
    印→{repo, pr, head_sha}の対応(呼び出し側が台帳へ残し、殿の返答が
    どのPRを指すか将軍側で引けるようにする)。
    """
    lines = []
    labels = {}
    for i, p in enumerate(pending_pays, start=1):
        label = f"N{seq}-P{i}"
        labels[label] = {"repo": p["repo"], "pr": p["pr"], "head_sha": p["head_sha"]}
        file_count, cost_usd, wait_minutes, is_estimate = _estimate_pay_cost(p["decision"])
        est_mark = "(推定)" if is_estimate else ""
        wait_desc = f"約{wait_minutes}分" if wait_minutes is not None else "不明(cr-decideの答えから読み取れず)"
        url = f"https://github.com/{p['repo']}/pull/{p['pr']}"
        scope_desc = _describe_blocked_scope(p["repo"], p["pr"], gh_bin=gh_bin, timeout=timeout)
        lines.append(
            f"[{label}] {url} : 見込みの費え 約${cost_usd:.2f}{est_mark}"
            f"({file_count}ファイル×$0.25)。払わねば{wait_desc}待ち。{scope_desc}"
        )
    if len(lines) == 1:
        header = "cr-decideがpay(課金レビュー)を勧めておる。実行はせず止まっておる。ご裁可を賜りたし。"
    else:
        header = (
            f"cr-decideが{len(lines)}件のPRでpay(課金レビュー)を勧めておる。"
            "実行はせず止まっておる。ご裁可を賜りたし(鳴らしすぎぬよう一通にまとめた)。"
        )
    footer = (
        f"全て払うなら「はい」、一部なら「はい N{seq}-P1」のように印で指定、"
        "払わぬなら「いいえ」、とご返答賜りたし。"
    )
    return header + "\n" + "\n".join(lines) + "\n" + footer, labels


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
                 "query_fuse": {},
                 "pay_ntfy_sent": {}, "pay_ntfy_heads": {}, "pay_ntfy_labels": {},
                 "pay_ntfy_seq": 0}
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    raw["sent_log"] = [datetime.fromisoformat(t) for t in raw.get("sent_log", [])]
    # cmd_934 T1: query_log・query_incidentsはmay_query削除に伴い読み捨てる
    # (旧state fileの互換のため読めはするが、以後このモジュールは書かない)。
    raw["query_log"] = [datetime.fromisoformat(t) for t in raw.get("query_log", [])]
    raw["query_incidents"] = {
        k: datetime.fromisoformat(v) for k, v in raw.get("query_incidents", {}).items()
    }
    raw["query_fuse"] = {
        k: datetime.fromisoformat(v) for k, v in raw.get("query_fuse", {}).items()
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
    out["query_fuse"] = {
        k: v.isoformat() for k, v in state.get("query_fuse", {}).items()
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


def run(cfg, state, now, stop_path, gh_bin="gh", dry_run=False, log_path=None,
        run_id=None, runner=None):
    """1周回ぶんの判定・投げ直しを行う(§1〜§3・確定版§8〜§9・cmd_913§5・cmd_934 T1)。

    ★F1是正: PRごとの取得(status)は個別にtry/exceptで囲み、1件の失敗で
    run()全体を落とさず次のPRへ進む。
    ★F3是正: 周回ごとに1行(runner・run_id・見たPR数)、PRごとに判定と理由の行を
    log_linesへ積む(呼び出し側がlog_pathへ書く)。
    ★F6是正(未知description・2時間status無しの警告)はここで判定する。
    ★cmd_934 T1: draftでなくreviewed済みでないPR全てについてreview-next
    (cr-decideの改名後)を呼び、「決める」を一本化する(旧来のrate_limited/
    paused限定の足切り・§3.3のhead_recent_push・確定版F2のstale判定は
    捨てた——review-next自身がwait/queue/in-progress等で適切に待たせる)。
    台帳(同一head最大3回・毎時毎日の予算・問い合わせの安全弁query_fuse_min・
    停止スイッチ)は引き続きここで守る。review-nextのcommandが投じてよい
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

            # cmd_934 T1: 「見つける」で渡すのは、draftでなく・allowlist内で・
            # reviewed済みでないPR全て(cmd934_decompose.md §1-2 g・旧来の
            # rate_limited/pausedのみの縛りは外した——review-next自身が
            # waiting/skip/no_status/unknownの各caseを判じる)。
            is_cr_decide_target = (
                category != "reviewed"
                and not pr_entry["draft"]
                and pr_entry["allowed"]
            )

            if is_cr_decide_target:
                # 既定は「review-nextを呼べていない」= reviewを投じる候補にしない
                # (安全側。呼べて初めてTrueへ倒す)。
                pr_entry["cr_decide_recommends_review"] = False

                if not cr_decide_enabled:
                    log_lines.append({"ts": now.isoformat(), "repo": repo, "pr": pr_number,
                                       "event": "cr_decide_disabled"})
                else:
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
                            fuse_min = budget.get("query_fuse_min", 60)
                            if (query_enabled and not killed
                                    and query_fuse_ok(incident_key, state, now, fuse_min)):
                                if not dry_run:
                                    try:
                                        post_comment(repo, pr_number, QUERY_BODY, gh_bin=gh_bin)
                                        state.setdefault("query_fuse", {})[incident_key] = now
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
                                               else "killed" if killed else "fused"),
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
        # cmd_913至急+P2是正: pay判定は実行せず、殿へntfyして止まる。
        # 同一PR(=repo#pr。headの変化では再送しない)は殿の返答があるまで
        # 再送しない(台帳=state["pay_ntfy_sent"])。headの変化は記録だけ
        # state["pay_ntfy_heads"]へ残す。同一周回内の複数PRは一通にまとめる。
        pay_ntfy_sent = state.setdefault("pay_ntfy_sent", {})
        pay_ntfy_heads = state.setdefault("pay_ntfy_heads", {})
        to_notify = []
        for p in pending_pays:
            key = _pay_incident_key(p["repo"], p["pr"])
            if key in pay_ntfy_sent:
                prev_head = pay_ntfy_heads.get(key)
                head_changed = prev_head is not None and prev_head != p["head_sha"]
                pay_ntfy_heads[key] = p["head_sha"]  # P2: 台帳に記録だけ(再送はしない)
                log_lines.append({
                    "ts": now.isoformat(), "repo": p["repo"], "pr": p["pr"],
                    "event": "pay_ntfy_not_resent",
                    "reason": "already_notified_waiting_for_lord",
                    "head_sha": p["head_sha"],
                    "head_changed_since_notify": head_changed,
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
                # cmd_913 Q2是正: 印(N{seq}-P1…)のseqは通知ごとに単調増加させる。
                # 送信が成功して初めてstateへ確定させる(失敗時は据え置き、
                # 次回同じseqを使い直せるようにする)。
                seq = state.get("pay_ntfy_seq", 0) + 1
                body, labels = _build_pay_ntfy_body(
                    to_notify, seq, now, gh_bin=gh_bin, timeout=cr_decide_timeout)
                try:
                    _post_pay_ntfy(body, ntfy_bin=ntfy_bin, timeout=ntfy_timeout)
                except (subprocess.SubprocessError, subprocess.TimeoutExpired, OSError) as exc:
                    log_lines.append({
                        "ts": now.isoformat(), "event": "pay_ntfy_failed", "level": "warn",
                        "error": str(exc),
                    })
                else:
                    state["pay_ntfy_seq"] = seq
                    for p in to_notify:
                        key = _pay_incident_key(p["repo"], p["pr"])
                        pay_ntfy_sent[key] = now
                        pay_ntfy_heads[key] = p["head_sha"]
                    # P3是正+Q2是正: 印(N{seq}-P1・N{seq}-P2…、通知ごとに
                    # 重ならない)→repo#pr#headの対応を台帳へ残す
                    # (将軍側が殿の返答からどのPRかを引けるように)。
                    state.setdefault("pay_ntfy_labels", {}).update(labels)
                    log_lines.append({
                        "ts": now.isoformat(), "event": "pay_ntfy_sent",
                        "prs": [f"{p['repo']}#{p['pr']}" for p in to_notify],
                        "labels": labels,
                    })

    log_lines.append({"ts": now.isoformat(), "event": "cycle", "runner": runner,
                       "run_id": run_id, "prs_seen": pr_count})

    if log_path:
        os.makedirs(os.path.dirname(log_path), exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as f:
            for entry in log_lines:
                f.write(json.dumps(entry, ensure_ascii=False, default=str) + "\n")

    return state, log_lines


def _read_recent_log_entries(log_path, now, window_hours=24):
    """log_path(jsonl)から直近window_hours時間分のentryを読む(破損行はスキップ)。
    _write_status_summaryと_detect_cr_decide_error_streaksで共用する。
    """
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
    return entries


# cmd_928【四】: 同一repo#prでcr_decide_errorが連続して検知を知らせる閾値。
# com.swarm.cr-retrigger.plistのStartInterval=600秒(10分)・実測ログでも
# 周回間隔10:11〜10:28(平均約10分強)を確認した(2026-10-01)。6回×約10分強
# ≒ 約60〜62分であり、「約1時間」の目安に合う値として6を採る。
CR_DECIDE_ERROR_STREAK_THRESHOLD = 6


def _detect_cr_decide_error_streaks(log_path, now, threshold=CR_DECIDE_ERROR_STREAK_THRESHOLD,
                                     window_hours=24):
    """同一repo#prでcr_decide_errorが連続threshold回以上続く"streak"を検出する。

    run()は、cr_decideの候補となった各PRについて毎周回必ず1本の判定記録
    ("decision"キーを持つentry、771-776行のcr_decide_errorログとは別本・同一ts)を
    log_lines(ひいてはjsonl)へ残す。errorの周回はそこにcr_decide_action="error"が
    乗る(call_cr_decideがfail closedで{"action":"error",...}を返す経路)。

    「連続」は、この判定記録をrepo#pr単位で時系列に並べ、末尾から遡って
    cr_decide_action=="error"が途切れずに続いた回数で数える。それ以外の判定
    (cr_decideが正常に何らかのactionを返した・categoryが変わりcr_decide対象
    から外れた等、いずれも「このPRでエラー以外の処理が出来た」ことを意味する)
    が1回でも挟まればstreakは0に戻る——これが「cr_decide_success相当の正常
    処理が挟まれば連続は途切れる」の実装である。
    """
    entries = _read_recent_log_entries(log_path, now, window_hours)

    per_pr = {}
    for e in entries:
        if "decision" not in e:
            continue
        repo = e.get("repo")
        pr = e.get("pr")
        if repo is None or pr is None:
            continue
        ts = e.get("ts")
        try:
            dt = datetime.fromisoformat(ts) if ts else None
        except ValueError:
            dt = None
        is_error = e.get("cr_decide_action") == "error"
        per_pr.setdefault((repo, pr), []).append((ts, dt, is_error))

    streaks = []
    for (repo, pr), records in per_pr.items():
        records.sort(key=lambda r: (r[1] is None, r[1]))
        count = 0
        first_ts = None
        last_ts = None
        for ts, _dt, is_error in records:
            if is_error:
                if count == 0:
                    first_ts = ts
                count += 1
                last_ts = ts
            else:
                count = 0
                first_ts = None
                last_ts = None
        if count >= threshold:
            streaks.append({
                "repo": repo, "pr": pr, "count": count,
                "first_ts": first_ts, "last_ts": last_ts,
            })
    return streaks


def _format_cr_decide_error_streak_alert(streak, threshold):
    return (
        f"- ⚠️ [cr_retrigger watchdog] {streak['repo']}#{streak['pr']} で "
        f"cr_decide_error が{streak['count']}回連続(閾値{threshold}回=約1時間)。"
        f"最初={streak['first_ts']} 最後={streak['last_ts']}。"
        f"cr-decide呼出が繰り返し失敗している——原因確認要(ntfyは鳴らしていない)。"
    )


def _append_dashboard_alerts(dashboard_path, alert_lines):
    """dashboard.mdの先頭(タイトル行の直後)へ新規行を追記する。
    stall_watchdog.shのnotify_dashboard()と同じ『先頭近くに積む』流儀に合わせる。

    cmd_928【四】やり直し(M1): 一時ファイルへ書いてからos.replace()で
    置き換える(途中でプロセスが落ちてもdashboard.mdが空にならない)。
    flockでの排他はここでは行わない(他の書き手全員が同じlockを使わねば
    効かぬため、別途task化が要る所見——報告参照)。
    """
    if not alert_lines or not dashboard_path or not os.path.exists(dashboard_path):
        return
    with open(dashboard_path, encoding="utf-8") as f:
        lines = f.readlines()
    insert_at = 1 if lines else 0
    new_lines = [line + "\n" for line in alert_lines]
    lines[insert_at:insert_at] = new_lines

    dashboard_dir = os.path.dirname(dashboard_path) or "."
    fd, tmp_path = tempfile.mkstemp(
        prefix=".dashboard_tmp_", dir=dashboard_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.writelines(lines)
        os.replace(tmp_path, dashboard_path)
    except BaseException:
        if os.path.exists(tmp_path):
            os.remove(tmp_path)
        raise


def _check_cr_decide_error_streaks_and_notify(
        state, log_path, dashboard_path, now,
        threshold=CR_DECIDE_ERROR_STREAK_THRESHOLD, window_hours=24):
    """cmd_928【四】本体。streakを検出し、未通知のものだけdashboard.mdへ追記する。

    重複連投対策: state["cr_decide_error_streak_notified"][repo#pr] に
    「直近で通知した時のstreak開始ts(first_ts)」を覚えておく。streakが
    途切れず続いているだけなら first_ts は変わらないため再通知しない。
    一度途切れて再度閾値を跨いだ(=first_tsが変わった)時だけ再通知する。
    """
    streaks = _detect_cr_decide_error_streaks(
        log_path, now, threshold=threshold, window_hours=window_hours)
    notified = state.setdefault("cr_decide_error_streak_notified", {})
    new_alerts = []
    for s in streaks:
        key = f"{s['repo']}#{s['pr']}"
        if notified.get(key) == s["first_ts"]:
            continue
        new_alerts.append(s)
        notified[key] = s["first_ts"]
    if new_alerts:
        _append_dashboard_alerts(
            dashboard_path,
            [_format_cr_decide_error_streak_alert(s, threshold) for s in new_alerts],
        )
    return new_alerts


def _write_status_summary(status_path, log_path, now, window_hours=24):
    """queue/reports/cr_retrigger_status.yaml: 直近window_hours時間の要約(確定版§4)。
    cmd_861の『朝に分かること』のため、家老が巡回でdashboardへ写せる形にする。
    ★cmd_913: cr-decideのerror・observed_not_posted(approve/pay)の件数も加える
    (観察のため・pay/approveの枝がいつ・何度出たかを見える形にする)。
    """
    import yaml  # PyYAML

    entries = _read_recent_log_entries(log_path, now, window_hours)

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
    parser.add_argument("--dashboard-file", default=os.path.join(
        os.path.dirname(__file__), "..", "dashboard.md"))
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
    # cmd_928【四】: 当家側の見張り——同一repo#prでcr_decide_errorが連続した時、
    # dashboard.mdへ気づける形で記す(ntfyは鳴らさない)。state更新はsave前に行う。
    _check_cr_decide_error_streaks_and_notify(
        state, args.log_file, args.dashboard_file, now)
    _save_state(args.state, state)
    _write_status_summary(args.status_file, args.log_file, now)

    for entry in log_lines:
        print(json.dumps(entry, ensure_ascii=False, default=str))
    print(f"[cr_retrigger] {now.isoformat()} 周回終了(候補{len(log_lines)}件・dry_run={args.dry_run})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
