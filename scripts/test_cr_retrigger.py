#!/usr/bin/env python3
"""cr_retrigger.py のテスト(cmd_908 T1 + cmd_913 + cmd_934 T1)。
実行: python3 -m unittest scripts.test_cr_retrigger -v

設計文書§7の8項目 + 確定版の2項目、計10項目を固定する(SKIP 0)。
★cmd_908 T1やり直し(軍師QC PR#170・head d84d825 = FAIL是正): F1〜F6の
回帰試験をTest11以降に追加する。
★cmd_913: 「決める」部分をcr-decideへ寄せた統合の試験をTest18以降に追加する
(queue/reports/cmd913_crdecide_integration.md §5の5項目・RED→GREEN)。
parse_wait/next_attempt_at/_fetch_latest_wait_notice/_fetch_recent_review_starts
はcr_retrigger.pyから削除したため、これらを直接叩いていた旧試験は削除・
cr-decide経由の等価な試験へ置き換えた。
★cmd_934 T1(queue/reports/cmd934_decompose.md「一」節): 「決める」を
review-next(cr-decideの改名後)の言うとおりに動くだけへ格下げしたため、
may_query・§3.3のhead_recent_push・確定版F2のstale_no_fresh_rate_limitを
試験していたTest10・Test13・Test17の一部を削除/更新し、is_cr_decide_target
のrate_limited/paused縛りが外れたことに伴いTest23の「skippedはcr-decideを
呼ばぬ」を「呼ぶ」へ反転した。Test35〜Test37にcmd_934 T1のRED対照3件
(問い合わせの安全弁・二重の依頼の防止・HOME明示)を追加する。
★cmd_934 T2(assert_allowed_bodyのpay/approve本文拒否): Test38・Test39に
固定する(PR#185)。
★cmd_934続き(queue/reports/cmd934_trigger_per_day_judgment.md §6・案B):
trigger_per_hour・trigger_per_day(数の枷)を除き、「壊れた徴」
(trigger_breaker_open)で止める形へ替えた。旧来の毎時/毎日の予算試験
(Test8)は、当家の数の枷がreview-nextの判断を盲目に上書きしていたことの
RED対照(PR#246の再現)へ置き換えた——除去前のselect_targetsの核をテスト内に
歴史の記録として再現し(cr_retrigger.py本体からは削除済み)、是正前後の
挙動差を示す。Test40以降にtrigger_breakerの試験(壊れた徴の検知・開く・
解除file)を追加する(PR#185のTest38・Test39との衝突を避けrebase時に
採番し直した)。
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
import unittest.mock as mock
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(__file__))
import cr_retrigger as cr

NOW = datetime(2026, 9, 28, 12, 0, 0, tzinfo=timezone.utc)


def make_pr(repo="geolonia/geonicdb-console", pr=1, head_sha="sha1",
            description="Review rate limited", draft=False, allowed=True,
            next_attempt_at=None, cr_decide_recommends_review=None):
    d = {"repo": repo, "pr": pr, "head_sha": head_sha, "description": description,
         "draft": draft, "allowed": allowed}
    if next_attempt_at is not None:
        d["next_attempt_at"] = next_attempt_at
    # cmd_934 T1: 省略時は既定(未設定=_decision_reasonがTrue扱いする)のまま。
    # 明示的に渡された時だけキーを立てる(Falseも含め、渡した値どおりにする)。
    if cr_decide_recommends_review is not None:
        d["cr_decide_recommends_review"] = cr_decide_recommends_review
    return d


def _cr_decide_cfg(allowlist, query_enabled=False, cr_decide_enabled=True):
    return {
        "allowlist": allowlist,
        "budget": {"trigger_per_hour": 10, "trigger_per_day": 10,
                    "query_fuse_min": 60},
        "query": {"enabled": query_enabled},
        "cr_decide": {"enabled": cr_decide_enabled},
    }


class Test1ReviewedHeadNotSelected(unittest.TestCase):
    """§7-1: レビュー済みheadを選ばぬ。"""

    def test_reviewed_head_excluded(self):
        prs = [make_pr(description="Review completed"),
               make_pr(pr=2, head_sha="sha2", description="Review approved")]
        state = {"heads": {}, "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, prs, budget, NOW)
        self.assertEqual(targets, [])


class Test2SameHeadMaxThreeAttempts(unittest.TestCase):
    """§7-2/§3.2: 同じheadへ二度投げぬ(rate limited再発時は最大3回まで)。"""

    def test_head_excluded_after_three_attempts(self):
        pr = make_pr()
        state = {"heads": {"geolonia/geonicdb-console#1#sha1": {"attempts": 3}},
                  "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, [pr], budget, NOW)
        self.assertEqual(targets, [])

    def test_head_still_eligible_below_three_attempts(self):
        pr = make_pr()
        state = {"heads": {"geolonia/geonicdb-console#1#sha1": {"attempts": 2}},
                  "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, [pr], budget, NOW)
        self.assertEqual(len(targets), 1)

    def test_head_not_reselected_before_next_attempt_at(self):
        pr = make_pr(next_attempt_at=NOW + timedelta(minutes=30))
        state = {"heads": {"geolonia/geonicdb-console#1#sha1": {"attempts": 1}},
                  "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, [pr], budget, NOW)
        self.assertEqual(targets, [])


class Test3SkippedNotSelected(unittest.TestCase):
    """§7-3: skippedを投げぬ(cmd_934 T1で、投げぬ理由はcategory自体の縛り
    ではなくreview-nextがreviewを勧めなかったことに変わった——Test23参照。
    ここはそのcr_decide_recommends_review=Falseの状態を、select_targetsの
    純関数レベルで固定する)。"""

    def test_skipped_excluded(self):
        prs = [make_pr(description="Review skipped: draft",
                        cr_decide_recommends_review=False),
               make_pr(pr=2, head_sha="sha2", description="Review skipped: WIP title",
                        cr_decide_recommends_review=False)]
        state = {"heads": {}, "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, prs, budget, NOW)
        self.assertEqual(targets, [])


class Test4UpstreamRejectedEvenInAllowlist(unittest.TestCase):
    """§7-4: 上流repoをallowlistに書いても拒む。"""

    def test_upstream_rejected_despite_allowlist_entry(self):
        allowlist = ["yohey-w/geonicdb", "digital-go-jp/geonicdb"]
        self.assertFalse(cr.is_allowed_repo("yohey-w/geonicdb", allowlist))
        self.assertFalse(cr.is_allowed_repo("digital-go-jp/geonicdb", allowlist))

    def test_own_allowlisted_repo_allowed(self):
        allowlist = ["geolonia/geonicdb-console"]
        self.assertTrue(cr.is_allowed_repo("geolonia/geonicdb-console", allowlist))


class Test5KillSwitchBlocksAll(unittest.TestCase):
    """§7-5: kill switchで投げぬ。"""

    def test_killed_returns_no_targets(self):
        pr = make_pr()
        state = {"heads": {}, "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, [pr], budget, NOW, killed=True)
        self.assertEqual(targets, [])


class Test7UnknownDescriptionNotSelected(unittest.TestCase):
    """§7-7: 未知のdescriptionで投げぬ(cmd_934 T1: review-nextがreviewを
    勧めなかった状態=cr_decide_recommends_review=Falseを固定する)。"""

    def test_unknown_description_classified_and_excluded(self):
        self.assertEqual(cr.classify("Review failed"), "unknown")
        prs = [make_pr(description="Review failed", cr_decide_recommends_review=False)]
        state = {"heads": {}, "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, prs, budget, NOW)
        self.assertEqual(targets, [])

    def test_empty_description_is_no_status_and_excluded(self):
        self.assertEqual(cr.classify(""), "no_status")
        self.assertEqual(cr.classify(None), "no_status")


class Test8TriggerPerHourDayRemoved(unittest.TestCase):
    """cmd_934続き(queue/reports/cmd934_trigger_per_day_judgment.md §6・案B・
    RED対照・PR#246の再現): 旧来のtrigger_per_hour・trigger_per_dayは、
    review-nextが実際の空きを測った上でreviewを勧めていても、当家の数の枷で
    握りつぶしていた(今日の実例: PR#246が41周回reviewを勧められながら
    一度も投じられなかった)。是正後のselect_targetsはこの数の枷を持たない
    (同じheadへの最大試行回数=max_attemptsは_decision_reason側に残る・
    Test2参照)。
    """

    def _old_select_targets_with_hour_day_budget(self, state, prs, budget, now, killed=False):
        """除去前のselect_targetsの核(毎時/毎日budgetの絞り込み)を、
        歴史の記録として再現する(cr_retrigger.py本体からは削除済み・
        Test35の old_may_query_once_per_incident と同じ流儀)。"""
        if killed:
            return []
        candidates = [pr for pr in prs if cr._decision_reason(pr, state, now) == "candidate"]
        candidates.sort(key=lambda p: p.get("next_attempt_at", now))
        sent_log = state.get("sent_log", [])
        hour_count = sum(1 for t in sent_log if now - t < timedelta(hours=1))
        day_count = sum(1 for t in sent_log if now - t < timedelta(days=1))
        hour_remaining = budget.get("trigger_per_hour", 1) - hour_count
        day_remaining = budget.get("trigger_per_day", 8) - day_count
        remaining = max(0, min(hour_remaining, day_remaining))
        return candidates[:remaining]

    def test_red_old_day_budget_blocks_despite_review_next_recommends_review(self):
        """RED対照: 24時間窓に8件のsent_logがある状態(PR#246と同じ詰まり)で、
        review-nextがreviewを返し続けても、旧ロジックは一度も投じない。"""
        pr = make_pr(cr_decide_recommends_review=True)
        sent_log = [NOW - timedelta(hours=h, minutes=1) for h in range(1, 9)]
        state = {"heads": {}, "sent_log": sent_log}
        budget = {"trigger_per_hour": 1, "trigger_per_day": 8}
        targets = self._old_select_targets_with_hour_day_budget(state, [pr], budget, NOW)
        self.assertEqual(targets, [])

    def test_green_select_targets_ignores_hour_and_day_budget(self):
        """是正後: 同じ24時間窓に8件のsent_logがあっても、review-nextが
        reviewを勧めている限り投じる(PR#246の握りつぶしが直ったこと)。"""
        pr = make_pr(cr_decide_recommends_review=True)
        sent_log = [NOW - timedelta(hours=h, minutes=1) for h in range(1, 9)]
        state = {"heads": {}, "sent_log": sent_log}
        budget = {"trigger_per_hour": 1, "trigger_per_day": 8}
        targets = cr.select_targets(state, [pr], budget, NOW)
        self.assertEqual(len(targets), 1)

    def test_green_select_targets_works_with_empty_budget_dict(self):
        """budgetがhour/day予算を一切持たなくても(空dict)動くこと。"""
        pr = make_pr(cr_decide_recommends_review=True)
        state = {"heads": {}, "sent_log": []}
        targets = cr.select_targets(state, [pr], {}, NOW)
        self.assertEqual(len(targets), 1)

    def test_max_attempts_still_enforced_without_hour_day_budget(self):
        """同じheadへの最大試行回数(max_attempts=3)は、数の枷を除いた後も
        引き続き効くこと(Test2の回帰確認・is_cr_decide_target経由)。"""
        pr = make_pr(cr_decide_recommends_review=True)
        state = {"heads": {"geolonia/geonicdb-console#1#sha1": {"attempts": 3}},
                  "sent_log": []}
        targets = cr.select_targets(state, [pr], {}, NOW)
        self.assertEqual(targets, [])


class Test9PostCommentRejectsUnknownBody(unittest.TestCase):
    """確定版§8.1: post_comment()が定型2文言以外を拒む(例外を投げる)。"""

    def test_assert_allowed_body_rejects_free_text(self):
        with self.assertRaises(ValueError):
            cr.assert_allowed_body("[AI] please fix this yourself")

    def test_post_comment_raises_before_calling_gh(self):
        called = []

        def fake_run(*a, **k):
            called.append(a)

        with mock.patch("subprocess.run", side_effect=fake_run):
            with self.assertRaises(ValueError):
                cr.post_comment("geolonia/geonicdb-console", 1, "こちらで直してください")
        self.assertEqual(called, [])

    def test_post_comment_accepts_trigger_body(self):
        with mock.patch("subprocess.run") as run:
            cr.post_comment("geolonia/geonicdb-console", 1, cr.TRIGGER_BODY)
            run.assert_called_once()


# Test10QueryRespectsRateLimits(確定版§9.2のmay_query試験)はcmd_934 T1で
# may_query自体をcr_retrigger.pyから削除したため撤去した。後継の
# query_fuse_ok()の試験はTest35RedControl1QueryFuseReplacesMayQueryに
# 置いた(RED対照1)。


class Test12F1PerPrFailureIsolation(unittest.TestCase):
    """cmd_908やり直しF1: PRごとの取得失敗はcatchしてlogに記し、
    次のPRへ進む(run()全体を落とさない)。"""

    def test_one_pr_status_fetch_failure_does_not_abort_other_prs(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [
                {"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None},
                {"number": 2, "headRefOid": "sha2", "isDraft": False, "createdAt": None},
            ]

        import subprocess as sp

        def fake_status(repo, sha, gh_bin="gh", timeout=30):
            if sha == "sha1":
                raise sp.CalledProcessError(1, ["gh"])
            return "Review completed", NOW

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status", side_effect=fake_status):
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        errors = [e for e in log_lines if e.get("event") == "status_fetch_error"]
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0]["pr"], 1)
        # PR2は失敗せず、reviewedとして判定行が積まれている。
        pr2_entries = [e for e in log_lines if e.get("pr") == 2 and e.get("category") == "reviewed"]
        self.assertEqual(len(pr2_entries), 1)


# Test13F2ReselectRequiresFreshRateLimit(確定版F2のstale_no_fresh_rate_limit
# 試験)はcmd_934 T1で該当ロジックごと_decision_reason()から削除したため
# 撤去した(queue/reports/cmd934_decompose.md §1-2 eの「捨てる」判断——
# review-next自身がwait/queue等で適切に待たせるため、cr_retrigger側の
# 二重の鮮度判定は不要になった)。同じheadへの最大試行回数(Test2)は
# そのまま残る。


class Test15F3LoggingAndStatusSummary(unittest.TestCase):
    """cmd_908やり直しF3: 周回ごと・PRごとのlog行とqueue/reports/
    cr_retrigger_status.yamlの出力(T2完了条件・cmd_861の朝に分かること)。"""

    def test_cycle_line_carries_runner_run_id_and_pr_count(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review completed", NOW)):
            state, log_lines = cr.run(
                cfg, state, NOW, "/nonexistent/.stop", dry_run=True,
                run_id="20260928T120000Z-123", runner="launchd")

        cycle_lines = [e for e in log_lines if e.get("event") == "cycle"]
        self.assertEqual(len(cycle_lines), 1)
        self.assertEqual(cycle_lines[0]["runner"], "launchd")
        self.assertEqual(cycle_lines[0]["run_id"], "20260928T120000Z-123")
        self.assertEqual(cycle_lines[0]["prs_seen"], 1)

    def test_per_pr_decision_line_present(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review completed", NOW)):
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        pr_lines = [e for e in log_lines if e.get("pr") == 1 and "decision" in e]
        self.assertEqual(len(pr_lines), 1)
        self.assertEqual(pr_lines[0]["category"], "reviewed")
        self.assertEqual(pr_lines[0]["decision"], "reviewed")

    def test_status_summary_yaml_written_from_log(self):
        import yaml
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_status_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            status_path = os.path.join(tmpdir, "cr_retrigger_status.yaml")
            with open(log_path, "w", encoding="utf-8") as f:
                f.write(json.dumps({"ts": NOW.isoformat(), "repo": "geolonia/geonicdb-console",
                                     "pr": 1, "event": "triggered"}) + "\n")
                f.write(json.dumps({"ts": NOW.isoformat(), "event": "cycle",
                                     "runner": "launchd", "run_id": "x", "prs_seen": 1}) + "\n")
            summary = cr._write_status_summary(status_path, log_path, NOW)
            self.assertEqual(summary["triggered_count"], 1)
            self.assertTrue(os.path.exists(status_path))
            with open(status_path, encoding="utf-8") as f:
                loaded = yaml.safe_load(f)
            self.assertEqual(loaded["triggered_count"], 1)
            self.assertEqual(loaded["cycles_seen"], 1)
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_state_roundtrip_preserves_last_trigger_at_and_query_incidents(self):
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_state_")
        try:
            state_path = os.path.join(tmpdir, "state.json")
            state = {
                "heads": {"geolonia/geonicdb-console#1#sha1":
                          {"attempts": 1, "last_trigger_at": NOW}},
                "sent_log": [NOW],
                "query_log": [NOW],
                "query_incidents": {"incident-1": NOW},
            }
            cr._save_state(state_path, state)
            loaded = cr._load_state(state_path)
            self.assertEqual(
                loaded["heads"]["geolonia/geonicdb-console#1#sha1"]["last_trigger_at"], NOW)
            self.assertEqual(loaded["query_incidents"]["incident-1"], NOW)
            self.assertEqual(loaded["sent_log"], [NOW])
        finally:
            import shutil
            shutil.rmtree(tmpdir)


# Test17F6HeadRecentPushAndWarnings の§3.3(head_pushed_at)試験2本は
# cmd_934 T1でhead_recent_push判定ごと削除したため撤去した
# (queue/reports/cmd934_decompose.md §1-2 fの「捨てる」判断——review-next
# 自身のwait/in-progressに任せる)。未知description・2時間status無しの
# 警告はF6是正の別項目として残す(下のTest17F6UnknownAndNoStatusWarnings)。


class Test17F6UnknownAndNoStatusWarnings(unittest.TestCase):
    """cmd_908やり直しF6(low): 未知description・2時間status無しの警告。"""

    def test_unknown_description_logged_as_warning(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        # cmd_934 T1: "unknown"もreviewed以外ゆえreview-nextを呼ぶ対象に
        # なった(decision自体はこの試験の主眼ではないため、素通りする
        # "wait"相当を返すだけにする)。
        decisions = {1: {"action": "wait", "reason": "n/a",
                          "retryAt": (NOW + timedelta(minutes=5)).isoformat().replace("+00:00", "Z")}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review failed", NOW)), \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        warn_lines = [e for e in log_lines if e.get("level") == "warn" and e.get("pr") == 1]
        self.assertEqual(len(warn_lines), 1)
        self.assertEqual(warn_lines[0]["category"], "unknown")

    def test_no_status_over_2h_logged_as_warning(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}
        created_at = (NOW - timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ")

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": created_at}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status", return_value=(None, None)):
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        warn_lines = [e for e in log_lines if e.get("level") == "warn" and e.get("pr") == 1]
        self.assertEqual(len(warn_lines), 1)
        self.assertEqual(warn_lines[0]["reason"], "no_status_over_2h")

    def test_no_status_under_2h_not_warned(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}
        created_at = (NOW - timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ")

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": created_at}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status", return_value=(None, None)):
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        warn_lines = [e for e in log_lines if e.get("level") == "warn"]
        self.assertEqual(warn_lines, [])


# ── cmd_913: cr-decide統合(queue/reports/cmd913_crdecide_integration.md §5) ──

def _patch_cr_decide_wiring(decision_by_pr):
    """_ensure_cr_decide_tool/_ensure_clone/call_cr_decideを、実clone・実node
    無しで試験する共通の下ごしらえ。decision_by_prはpr番号→cr-decideの
    戻り値dictの写像。"""
    def fake_call_cr_decide(repo, pr_number, clone_dir, script_path,
                             policy_path=None, node_bin="node", timeout=30):
        return decision_by_pr[pr_number]

    return (
        mock.patch.object(cr, "_ensure_cr_decide_tool",
                           return_value=("/fake/cr-decide.mjs", "/fake/policy.json")),
        mock.patch.object(cr, "_ensure_clone", return_value="/fake/clone"),
        mock.patch.object(cr, "call_cr_decide", side_effect=fake_call_cr_decide),
    )


class Test18CrDecideCallWiring(unittest.TestCase):
    """call_cr_decide(): 子プロセスの呼出・fail closedの形を固定する。"""

    def test_valid_json_stdout_is_parsed(self):
        with mock.patch("subprocess.run") as run:
            run.return_value = mock.Mock(
                stdout=json.dumps({"action": "review", "command": "@coderabbitai review"}))
            result = cr.call_cr_decide(
                "geolonia/geonicdb-console", 1, "/fake/clone", "/fake/cr-decide.mjs")
        self.assertEqual(result["action"], "review")
        self.assertEqual(result["command"], "@coderabbitai review")

    def test_timeout_is_fail_closed_error(self):
        import subprocess as sp
        with mock.patch("subprocess.run", side_effect=sp.TimeoutExpired(cmd="node", timeout=30)):
            result = cr.call_cr_decide(
                "geolonia/geonicdb-console", 1, "/fake/clone", "/fake/cr-decide.mjs")
        self.assertEqual(result["action"], "error")

    def test_malformed_stdout_is_fail_closed_error(self):
        with mock.patch("subprocess.run") as run:
            run.return_value = mock.Mock(stdout="not json")
            result = cr.call_cr_decide(
                "geolonia/geonicdb-console", 1, "/fake/clone", "/fake/cr-decide.mjs")
        self.assertEqual(result["action"], "error")

    def test_git_env_vars_are_stripped_before_invoking_node(self):
        # cmd_901/903/906と同型の事故を防ぐ: 呼び出し元にGIT_*が有っても
        # 子プロセスへ渡す環境からは外れていること。
        captured = {}

        def fake_run(cmd, **kwargs):
            captured["env"] = kwargs.get("env")
            return mock.Mock(stdout=json.dumps({"action": "check",
                                                 "command": "@coderabbitai rate limit"}))

        with mock.patch.dict(os.environ, {"GIT_DIR": "/some/other/repo/.git"}), \
             mock.patch("subprocess.run", side_effect=fake_run):
            cr.call_cr_decide(
                "geolonia/geonicdb-console", 1, "/fake/clone", "/fake/cr-decide.mjs")

        self.assertIsNotNone(captured["env"])
        self.assertFalse(any(k.startswith("GIT_") for k in captured["env"]))


class Test19CrDecideReviewCommandPostsWithAiPrefix(unittest.TestCase):
    """RED→GREEN③: cr-decideのcommandが`@coderabbitai review`の時、
    投稿する本文には`[AI] `が付く(TRIGGER_BODY定数と一致)。"""

    def test_review_action_posts_trigger_body_with_ai_prefix(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "review", "reason": "1 review available",
                          "command": "@coderabbitai review"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_called_once_with(
            "geolonia/geonicdb-console", 1, "[AI] @coderabbitai review", gh_bin="gh")
        self.assertTrue(post_mock.call_args.args[2].startswith("[AI] "))
        self.assertEqual(post_mock.call_args.args[2], cr.TRIGGER_BODY)


class Test20CrDecideErrorNeverPosted(unittest.TestCase):
    """RED→GREEN②: cr-decideがerrorを返したら投じず、警告として記録する。"""

    def test_error_action_does_not_post_and_logs_warning(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "error", "reason": "spawnSync gh ENOBUFS"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review paused", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        error_lines = [e for e in log_lines if e.get("event") == "cr_decide_error"]
        self.assertEqual(len(error_lines), 1)
        self.assertEqual(error_lines[0]["level"], "warn")
        self.assertEqual(error_lines[0]["reason"], "spawnSync gh ENOBUFS")


class Test21CrDecideApproveAndPayObservedNotPosted(unittest.TestCase):
    """RED→GREEN④: 許していない文面(approve・pay)は投じず、記録だけする
    (cmd_913一段め・観察のため)。"""

    def test_approve_command_is_recorded_not_posted(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "approve", "reason": "rebase only",
                          "command": "@coderabbitai approve"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        observed = [e for e in log_lines if e.get("event") == "cr_decide_observed_not_posted"]
        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0]["command"], "@coderabbitai approve")
        self.assertEqual(observed[0]["action"], "approve")

    def test_pay_command_is_recorded_not_posted(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "pay", "reason": "wait too long",
                          "command": "@coderabbitai review --use-credits"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        observed = [e for e in log_lines if e.get("event") == "cr_decide_observed_not_posted"]
        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0]["command"], "@coderabbitai review --use-credits")


class Test22CrDecideCheckThrottledByLedger(unittest.TestCase):
    """RED→GREEN①(cmd_913時点): cr-decideの答えがcheckでも、台帳(may_query・
    全体30分に1回)が抑えていた。
    ★cmd_934 T1でmay_queryを削除し、台帳はincident_key(repo#pr#sha#action)
    ごとのquery_fuse_min(安全の上限・暴走を止める枷であって判断ではない)
    だけになった——review-nextのcheckは費えを使わぬ問い合わせであり、
    他のPRへの問い合わせを待たせる理由が無いため(queue/reports/
    cmd934_decompose.md §1-2)。ゆえに「別々のincidentは互いを待たせぬ」
    ことを是正後の挙動として固定する(旧来の「全体で30分に1回」の横断的
    throttleは撤去)。同一incidentの再問い合わせ抑制はTest35
    (RED対照1)で固定する。"""

    def test_two_different_incidents_both_posted_no_cross_incident_throttle(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"], query_enabled=True)
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [
                {"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None},
                {"number": 2, "headRefOid": "sha2", "isDraft": False, "createdAt": None},
            ]

        def fake_status(repo, sha, gh_bin="gh", timeout=30):
            return "Review rate limited", NOW

        decisions = {
            1: {"action": "check", "reason": "budget unknown",
                "command": "@coderabbitai rate limit"},
            2: {"action": "check", "reason": "budget unknown",
                "command": "@coderabbitai rate limit"},
        }
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status", side_effect=fake_status), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        # cmd_934 T1是正後: query_fuse_minはincident_key単位の枷ゆえ、
        # 別のPR(=別のincident)はどちらも投じられる。
        self.assertEqual(post_mock.call_count, 2)
        not_posted = [e for e in log_lines if e.get("event") == "query_not_posted"]
        self.assertEqual(not_posted, [])

    def test_check_not_posted_when_query_disabled(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"], query_enabled=False)
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "check", "reason": "budget unknown",
                          "command": "@coderabbitai rate limit"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        self.assertEqual(state.get("query_fuse", {}), {})


class Test23CrDecidePausedVsSkippedRouting(unittest.TestCase):
    """RED→GREEN⑤(cmd_913時点): 「見つける」でcr-decideへ渡すのはrate_limited・
    pausedのみ・skippedは渡さない、だった。
    ★cmd_934 T1でこの縛りを外した(queue/reports/cmd934_decompose.md
    §1-2 g「広げる」)。reviewed以外は全てreview-nextに問う設計へ変えたため、
    test_skipped_never_calls_cr_decideは逆向きのtest_skipped_now_calls_cr_decide
    へ置き換える——これはcr_retrigger.py側の意図した仕様変更であり、
    テストが古い仕様に追従しなかっただけではない。"""

    def test_paused_calls_cr_decide(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "check", "reason": "budget unknown",
                          "command": "@coderabbitai rate limit"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review paused", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             patches[0], patches[1] as ensure_clone_mock, patches[2] as call_mock:
            cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        call_mock.assert_called_once()
        ensure_clone_mock.assert_called()

    def test_skipped_now_calls_cr_decide(self):
        """cmd_934 T1: skipped(意図したskip)もreview-nextへ問う対象になった
        ——review-next自身がこのPRをどう扱うか(skip/human等)を判じる。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "skip", "reason": "trivial change",
                          "command": None}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review skipped: draft", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0] as tool_mock, patches[1] as ensure_clone_mock, \
             patches[2] as call_mock:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        call_mock.assert_called_once()
        ensure_clone_mock.assert_called()
        tool_mock.assert_called()
        post_mock.assert_not_called()
        pr_lines = [e for e in log_lines if e.get("pr") == 1 and "decision" in e]
        self.assertEqual(pr_lines[0]["category"], "skip")


class Test24CrDecideDisabledFallsBackSafely(unittest.TestCase):
    """cr_decide.enabled=falseの時は、決めるすべが無いため安全側(投じない)へ倒す。"""

    def test_cr_decide_disabled_does_not_post_review(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"], cr_decide_enabled=False)
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        disabled_lines = [e for e in log_lines if e.get("event") == "cr_decide_disabled"]
        self.assertEqual(len(disabled_lines), 1)


# ── cmd_913続き(PR#173 QC是正): X1 query.enabled有効化・X2 pin検証 ──

class Test25QueryEnabledEndToEndFlow(unittest.TestCase):
    """X1是正: query.enabled=trueで、check→問い合わせ→(答えが付いた後の
    次周回の)review投稿、まで実際に流れることをend-to-endで固定する。
    RED対照(是正前・query.enabled=false)はTest22.
    test_check_not_posted_when_query_disabledが固定済み
    (checkがdisabledとして記録され続け、投稿もreviewへも進まない)。"""

    def test_check_then_query_then_review_across_two_cycles(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"], query_enabled=True)
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        # 1周回め: 待ち時間が読めず、cr-decideはcheckを返す。
        decisions_cycle1 = {1: {"action": "check", "reason": "budget unknown",
                                  "command": "@coderabbitai rate limit"}}
        patches1 = _patch_cr_decide_wiring(decisions_cycle1)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock1, \
             patches1[0], patches1[1], patches1[2]:
            state, log_lines1 = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock1.assert_called_once_with(
            "geolonia/geonicdb-console", 1, cr.QUERY_BODY, gh_bin="gh")
        # cmd_934 T1: 台帳はquery_incidentsからquery_fuseへ変わった。
        self.assertIn("geolonia/geonicdb-console#1#sha1#check", state["query_fuse"])

        # 2周回め(10分後): 問い合わせの答えをcr-decide自身が読んだ想定
        # (答えの読み取り自体はcr-decideの役目・cmd913_crdecide_integration.md
        # §1)。答えが付いたのでcr-decideはreviewを返す。
        now2 = NOW + timedelta(minutes=10)
        decisions_cycle2 = {1: {"action": "review", "reason": "1 review available now",
                                  "command": "@coderabbitai review"}}
        patches2 = _patch_cr_decide_wiring(decisions_cycle2)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", now2)), \
             mock.patch.object(cr, "post_comment") as post_mock2, \
             patches2[0], patches2[1], patches2[2]:
            state, log_lines2 = cr.run(cfg, state, now2, "/nonexistent/.stop", dry_run=False)

        post_mock2.assert_called_once_with(
            "geolonia/geonicdb-console", 1, cr.TRIGGER_BODY, gh_bin="gh")

    # test_second_incident_query_within_30min_stays_throttled_by_ledgerは
    # cmd_934 T1でmay_queryの全体30分に1回の横断throttleを撤去したため撤去
    # した(query_logに古いエントリが残っていても別incidentには影響しない
    # ——Test22.test_two_different_incidents_both_posted_no_cross_incident_throttle
    # が後継)。同一incidentの再問い合わせ抑制はTest35(RED対照1)で固定する。


class Test26CrDecideToolPinnedShaNotAutoTracked(unittest.TestCase):
    """X2是正: geolonia/skillsの取り込みが検めた特定SHAへdetached checkoutで
    固定され、origin/mainへのreset --hard(自動追随)になっていないことを
    固定する。"""

    def test_checks_out_pinned_sha_via_detached_head(self):
        captured = {}

        def fake_run(cmd, **kwargs):
            captured.setdefault("calls", []).append(cmd)
            return mock.Mock(returncode=0)

        cfg = {"tool_repo": "geolonia/skills",
                "tool_ref": "d42738355cd994382f5fadf4febdf2089842ce83",
                "script_relpath": "skills/coderabbit-pr-flow/scripts/cr-decide.mjs",
                "policy_relpath": "skills/coderabbit-pr-flow/policy.json"}
        with mock.patch.object(cr, "_ensure_clone", return_value="/fake/skills-clone"), \
             mock.patch("subprocess.run", side_effect=fake_run):
            script_path, policy_path = cr._ensure_cr_decide_tool(cfg, "/fake/clones")

        checkout_calls = [c for c in captured["calls"] if "checkout" in c]
        self.assertEqual(len(checkout_calls), 1)
        self.assertIn("d42738355cd994382f5fadf4febdf2089842ce83", checkout_calls[0])
        self.assertIn("--detach", checkout_calls[0])
        # origin/mainへの自動追随(reset --hard等)が残っていないこと。
        self.assertFalse(any("reset" in c for c in captured["calls"]))
        self.assertFalse(any("origin/main" in c for c in captured["calls"]))
        self.assertTrue(script_path.endswith("cr-decide.mjs"))
        self.assertTrue(policy_path.endswith("policy.json"))

    def test_missing_tool_ref_raises_without_touching_git(self):
        captured = {"called": False}

        def fake_run(cmd, **kwargs):
            captured["called"] = True
            return mock.Mock(returncode=0)

        cfg = {"tool_repo": "geolonia/skills"}  # tool_ref無し
        with mock.patch.object(cr, "_ensure_clone", return_value="/fake/skills-clone"), \
             mock.patch("subprocess.run", side_effect=fake_run):
            with self.assertRaises(ValueError):
                cr._ensure_cr_decide_tool(cfg, "/fake/clones")

        self.assertFalse(captured["called"])


# ── cmd_913至急: pay裁可制ntfy(shogun msg_20260928_191226_5ee0f443・
#    msg_20260928_191314_539b160e)。RED対照: 本節追加前のcr_retrigger.pyは
#    cr._post_pay_ntfyを持たず、pay判定はcr_decide_observed_not_postedの
#    ログのみで止まる(ntfyは飛ばない)。以下は是正後の期待を固定する。

def _pay_decision(reason="Wait ~90 min is too long; 2 file(s) cost about $0.50."):
    return {"action": "pay", "reason": reason, "command": "@coderabbitai review --use-credits"}


class Test27PayGateSendsNtfyInsteadOfPosting(unittest.TestCase):
    """RED→GREEN⑥: pay判定は実行(投稿)せず、殿へntfyして止まる
    (PR URL・見込み費え・待ち見込み・止まる範囲を含む本文)。"""

    def test_pay_action_never_posts_and_sends_ntfy_with_details(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: _pay_decision()}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        ntfy_mock.assert_called_once()
        body = ntfy_mock.call_args.args[0]
        self.assertIn("https://github.com/geolonia/geonicdb-console/pull/1", body)
        self.assertIn("0.50", body)
        self.assertIn("90", body)
        self.assertNotIn("推定", body)
        sent_lines = [e for e in log_lines if e.get("event") == "pay_ntfy_sent"]
        self.assertEqual(len(sent_lines), 1)

    def test_pay_ntfy_body_marks_estimate_when_cost_not_parseable(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "pay", "reason": "format changed, no numbers here",
                          "command": "@coderabbitai review --use-credits"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches[0], patches[1], patches[2]:
            cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        ntfy_mock.assert_called_once()
        body = ntfy_mock.call_args.args[0]
        self.assertIn("推定", body)
        self.assertIn("https://github.com/geolonia/geonicdb-console/pull/1", body)

    def test_approve_action_does_not_send_pay_ntfy(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "approve", "reason": "rebase only",
                          "command": "@coderabbitai approve"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches[0], patches[1], patches[2]:
            cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        ntfy_mock.assert_not_called()


class Test28PayNtfyNotResentUntilLordAnswers(unittest.TestCase):
    """同一PR・同一head(=同一判定)への重複ntfyを防ぐ。殿の返答が来るまで
    (=台帳から消えるまで)は次周回でも再送しない。"""

    def test_same_pr_same_head_not_renotified_across_cycles(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: _pay_decision()}
        patches1 = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock1, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches1[0], patches1[1], patches1[2]:
            state, _ = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)
        ntfy_mock1.assert_called_once()

        now2 = NOW + timedelta(minutes=10)
        patches2 = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", now2)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock2, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches2[0], patches2[1], patches2[2]:
            state, log_lines2 = cr.run(cfg, state, now2, "/nonexistent/.stop", dry_run=False)

        ntfy_mock2.assert_not_called()
        not_resent = [e for e in log_lines2 if e.get("event") == "pay_ntfy_not_resent"]
        self.assertEqual(len(not_resent), 1)
        self.assertEqual(not_resent[0]["pr"], 1)

    def test_ntfy_failure_does_not_mark_sent_so_next_cycle_retries(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: _pay_decision()}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy",
                                side_effect=OSError("ntfy.sh not found")) as ntfy_mock, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        ntfy_mock.assert_called_once()
        self.assertEqual(state.get("pay_ntfy_sent", {}), {})
        failed = [e for e in log_lines if e.get("event") == "pay_ntfy_failed"]
        self.assertEqual(len(failed), 1)
        self.assertEqual(failed[0]["level"], "warn")


class Test29MultiplePayDecisionsBatchedIntoOneNtfy(unittest.TestCase):
    """同一周回内で複数PRがpay判定になった場合、一通のntfyにまとめる
    (鳴らしすぎ防止)。"""

    def test_two_prs_pay_same_cycle_batched_into_one_ntfy(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [
                {"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None},
                {"number": 2, "headRefOid": "sha2", "isDraft": False, "createdAt": None},
            ]

        decisions = {
            1: _pay_decision("Wait ~90 min is too long; 2 file(s) cost about $0.50."),
            2: _pay_decision("Wait ~120 min is too long; 3 file(s) cost about $0.75."),
        }
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        ntfy_mock.assert_called_once()
        body = ntfy_mock.call_args.args[0]
        self.assertIn("https://github.com/geolonia/geonicdb-console/pull/1", body)
        self.assertIn("https://github.com/geolonia/geonicdb-console/pull/2", body)
        sent_lines = [e for e in log_lines if e.get("event") == "pay_ntfy_sent"]
        self.assertEqual(len(sent_lines), 1)
        self.assertEqual(len(sent_lines[0]["prs"]), 2)


# ── cmd_913至急続き: PR#175軍師指摘P1〜P3是正(queue/reports/gunshi_report_cmd913_pay.yaml)。
#    RED対照: 本節追加前は、_pay_incident_keyがheadを含み(P2)、
#    _build_pay_ntfy_bodyが止まる範囲を決め打ちで書き(P1)、複数PRの各行に
#    印が付かず返答書式も無かった(P3)。以下は是正後の期待を固定する。

class Test30P1BlockedScopeReflectsActualState(unittest.TestCase):
    """RED→GREEN: 『止まる範囲』の文言は決め打ちでなく、実際に同じファイルを
    触るdraft本数・mainの最新CI結果を読んで書く(cmd_913 P1是正)。"""

    def test_count_blocked_drafts_finds_overlapping_files(self):
        def fake_list(repo, gh_bin="gh", timeout=30):
            return [
                {"number": 1, "isDraft": False, "files": [{"path": "a.py"}, {"path": "b.py"}]},
                {"number": 2, "isDraft": True, "files": [{"path": "b.py"}]},
                {"number": 3, "isDraft": True, "files": [{"path": "c.py"}]},
            ]
        with mock.patch.object(cr, "_fetch_open_prs_with_files", side_effect=fake_list):
            blocked = cr._count_blocked_drafts("geolonia/geonicdb-console", 1)
        self.assertEqual(blocked, [2])

    def test_count_blocked_drafts_empty_when_no_overlap(self):
        def fake_list(repo, gh_bin="gh", timeout=30):
            return [
                {"number": 1, "isDraft": False, "files": [{"path": "a.py"}]},
                {"number": 2, "isDraft": True, "files": [{"path": "c.py"}]},
            ]
        with mock.patch.object(cr, "_fetch_open_prs_with_files", side_effect=fake_list):
            blocked = cr._count_blocked_drafts("geolonia/geonicdb-console", 1)
        self.assertEqual(blocked, [])

    def test_count_blocked_drafts_none_on_gh_failure(self):
        with mock.patch.object(
                cr, "_fetch_open_prs_with_files",
                side_effect=subprocess.TimeoutExpired(cmd="gh", timeout=30)):
            blocked = cr._count_blocked_drafts("geolonia/geonicdb-console", 1)
        self.assertIsNone(blocked)

    def test_main_ci_status_green_when_status_zero_and_checkruns_all_success(self):
        """RED→GREEN(cmd_913 Q1是正): 当家のrepoはcommit statusを一件も
        使わずGitHub Actions check-runsのみでCIを回す。旧実装は
        commits/main/statusを読み、total_count=0の時にstate=pendingを
        返すAPIの仕様のせいで、mainが実際は緑でも常に「実行中main」と
        誤って報せていた(軍師実測: halsk/multi-agent-shogun・
        geolonia/geonicdb-consoleいずれもstatus0件・check-runs全緑)。
        是正後はcheck-runsのconclusionを見て「緑」と正しく判定することを
        確かめる(是正前のこの試験はcommits/main/statusのstate=pendingを
        検めており、緑のmainを誤って実行中と読んでいた)。"""
        checkruns_resp = {
            "total_count": 6,
            "check_runs": [
                {"status": "completed", "conclusion": "success"} for _ in range(5)
            ] + [{"status": "completed", "conclusion": "skipped"}],
        }
        with mock.patch.object(cr, "_gh_json", return_value=checkruns_resp) as gh_mock:
            result = cr._fetch_main_ci_status("geolonia/geonicdb-console")
        self.assertEqual(result, "success")
        args = gh_mock.call_args.args[0]
        self.assertIn("commits/main/check-runs", args[1])

    def test_main_ci_status_pending_when_any_run_not_completed(self):
        checkruns_resp = {
            "total_count": 2,
            "check_runs": [
                {"status": "completed", "conclusion": "success"},
                {"status": "in_progress", "conclusion": None},
            ],
        }
        with mock.patch.object(cr, "_gh_json", return_value=checkruns_resp):
            result = cr._fetch_main_ci_status("geolonia/geonicdb-console")
        self.assertEqual(result, "pending")

    def test_main_ci_status_failure_when_any_run_failed(self):
        checkruns_resp = {
            "total_count": 2,
            "check_runs": [
                {"status": "completed", "conclusion": "success"},
                {"status": "completed", "conclusion": "failure"},
            ],
        }
        with mock.patch.object(cr, "_gh_json", return_value=checkruns_resp):
            result = cr._fetch_main_ci_status("geolonia/geonicdb-console")
        self.assertEqual(result, "failure")

    def test_main_ci_status_none_when_no_checkruns(self):
        with mock.patch.object(cr, "_gh_json", return_value={"total_count": 0, "check_runs": []}):
            result = cr._fetch_main_ci_status("geolonia/geonicdb-console")
        self.assertIsNone(result)

    def test_describe_blocked_scope_reflects_blocked_drafts_and_red_main(self):
        with mock.patch.object(cr, "_count_blocked_drafts", return_value=[2, 3]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="failure"):
            desc = cr._describe_blocked_scope("geolonia/geonicdb-console", 1)
        self.assertIn("2本", desc)
        self.assertIn("#2", desc)
        self.assertIn("#3", desc)
        self.assertIn("赤", desc)

    def test_describe_blocked_scope_single_pr_only_when_no_overlap(self):
        with mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"):
            desc = cr._describe_blocked_scope("geolonia/geonicdb-console", 1)
        self.assertIn("この1本だけが遅れる", desc)
        self.assertIn("緑", desc)

    def test_pay_ntfy_body_reflects_actual_state_not_hardcoded(self):
        """RED対照: 旧版は常に固定文『払わぬ間はこの1本のPRのマージが遅れる
        のみ(mainは赤くならぬ…)』を書いていた(PRの状況を読んでいなかった)。
        是正後は、モックの戻り値を変えれば本文の中身も変わることを示す。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: _pay_decision()}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[7, 9]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches[0], patches[1], patches[2]:
            cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        body = ntfy_mock.call_args.args[0]
        self.assertIn("2本", body)
        self.assertIn("#7", body)
        self.assertIn("#9", body)
        self.assertIn("mainの最新CIは緑", body)
        self.assertNotIn("mainは赤くならぬ", body)  # 旧・決め打ち文言が消えたことを確認


class Test31P2KeyIsRepoPrNotHead(unittest.TestCase):
    """RED→GREEN: 重複防止の鍵をrepo#prへ変更(cmd_913 P2是正)。殿の返答を
    待つ間にheadがpushで変わっても再送しない。headの変化は台帳
    (state['pay_ntfy_heads'])へ記録だけする。"""

    def test_head_change_after_notify_does_not_resend_but_is_recorded(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs_head1(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: _pay_decision()}
        patches1 = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs_head1), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock1, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches1[0], patches1[1], patches1[2]:
            state, _ = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)
        ntfy_mock1.assert_called_once()
        self.assertEqual(state["pay_ntfy_heads"]["geolonia/geonicdb-console#1"], "sha1")

        # push発生: headが変わる(sha1→sha2)。殿はまだ答えていない。
        def fake_open_prs_head2(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha2", "isDraft": False, "createdAt": None}]

        now2 = NOW + timedelta(minutes=15)
        decisions2 = {1: _pay_decision()}
        patches2 = _patch_cr_decide_wiring(decisions2)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs_head2), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", now2)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock2, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches2[0], patches2[1], patches2[2]:
            state, log_lines2 = cr.run(cfg, state, now2, "/nonexistent/.stop", dry_run=False)

        # P2是正の核心: headが変わっても再送しない。
        ntfy_mock2.assert_not_called()
        # だが台帳のheadは新しい値へ更新される(記録だけ・返答時にどのheadへの
        # 裁可かを確かめられるように)。
        self.assertEqual(state["pay_ntfy_heads"]["geolonia/geonicdb-console#1"], "sha2")
        not_resent = [e for e in log_lines2 if e.get("event") == "pay_ntfy_not_resent"]
        self.assertEqual(len(not_resent), 1)
        self.assertTrue(not_resent[0]["head_changed_since_notify"])
        self.assertEqual(not_resent[0]["head_sha"], "sha2")

    def test_key_function_no_longer_takes_head_sha(self):
        # 旧版(repo#pr#head)ならheadが変わった瞬間に鍵自体が変わり、
        # 台帳の "already notified" 判定に引っかからず再送されてしまっていた。
        # 是正後は署名からheadを外し、repo#prのみで一意に定まることを確認する。
        import inspect
        params = list(inspect.signature(cr._pay_incident_key).parameters)
        self.assertEqual(params, ["repo", "pr_number"])
        self.assertEqual(cr._pay_incident_key("geolonia/geonicdb-console", 1),
                          "geolonia/geonicdb-console#1")


class Test32P3LabelsAndReplyFormatForMultiplePrs(unittest.TestCase):
    """RED→GREEN: 複数PR一通化時、各行に印(P1・P2…)が付き、返答書式が
    本文末尾に明記される(cmd_913 P3是正)。印→repo#pr#headの対応が
    台帳(state['pay_ntfy_labels'])に残る。"""

    def test_multiple_prs_get_labels_and_reply_format_footer(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [
                {"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None},
                {"number": 2, "headRefOid": "sha2", "isDraft": False, "createdAt": None},
            ]

        decisions = {
            1: _pay_decision("Wait ~90 min is too long; 2 file(s) cost about $0.50."),
            2: _pay_decision("Wait ~120 min is too long; 3 file(s) cost about $0.75."),
        }
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        body = ntfy_mock.call_args.args[0]
        self.assertIn("[N1-P1]", body)
        self.assertIn("[N1-P2]", body)
        self.assertIn("はい N1-P1", body)
        self.assertIn("いいえ", body)

        sent_lines = [e for e in log_lines if e.get("event") == "pay_ntfy_sent"]
        self.assertEqual(len(sent_lines), 1)
        self.assertEqual(sent_lines[0]["labels"]["N1-P1"],
                          {"repo": "geolonia/geonicdb-console", "pr": 1, "head_sha": "sha1"})
        self.assertEqual(sent_lines[0]["labels"]["N1-P2"],
                          {"repo": "geolonia/geonicdb-console", "pr": 2, "head_sha": "sha2"})
        self.assertEqual(state["pay_ntfy_labels"]["N1-P1"]["pr"], 1)
        self.assertEqual(state["pay_ntfy_labels"]["N1-P2"]["pr"], 2)

    def test_single_pr_still_gets_label_and_reply_format(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: _pay_decision()}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches[0], patches[1], patches[2]:
            cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        body = ntfy_mock.call_args.args[0]
        self.assertIn("[N1-P1]", body)
        self.assertIn("全て払うなら「はい」", body)


class Test33Q2LabelsDoNotCollideAcrossNotifications(unittest.TestCase):
    """RED→GREEN(cmd_913 Q2是正・軍師QC): 印は通知ごとにP1から振り直す
    仕様のままだと、台帳pay_ntfy_labelsはupdateで上書きされるため、
    一通めのP1(#1)の返答を待つ間に別PRの二通めが出ると、その印P1が
    一通めの台帳を踏み潰す(殿が一通めのつもりで「はいP1」と答えても、
    将軍側は二通めのPRを払うと読み違える——課金の誤りに直結)。
    是正後は通知ごとの通し番号(N{seq})を印へ含め、二通目のP1相当が
    別の文字列(N2-P1)になるため、一通めの記録(N1-P1)が保持されたまま
    残ることを確かめる。"""

    def test_second_notification_does_not_overwrite_first_labels(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        # 一通め: PR#1がpay判定。
        def fake_open_prs_1(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions1 = {1: _pay_decision()}
        patches1 = _patch_cr_decide_wiring(decisions1)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs_1), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock1, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches1[0], patches1[1], patches1[2]:
            state, log_lines1 = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)
        ntfy_mock1.assert_called_once()
        sent1 = [e for e in log_lines1 if e.get("event") == "pay_ntfy_sent"][0]
        self.assertEqual(list(sent1["labels"].keys()), ["N1-P1"])
        self.assertEqual(state["pay_ntfy_labels"]["N1-P1"],
                          {"repo": "geolonia/geonicdb-console", "pr": 1, "head_sha": "sha1"})

        # 二通め(殿がまだ一通めへ答えていない間に、別PR#2がpay判定になる)。
        now2 = NOW + timedelta(minutes=5)

        def fake_open_prs_2(repo, gh_bin="gh", timeout=30):
            return [
                {"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None},
                {"number": 2, "headRefOid": "sha2", "isDraft": False, "createdAt": None},
            ]

        decisions2 = {1: _pay_decision(), 2: _pay_decision()}
        patches2 = _patch_cr_decide_wiring(decisions2)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs_2), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", now2)), \
             mock.patch.object(cr, "post_comment"), \
             mock.patch.object(cr, "_post_pay_ntfy") as ntfy_mock2, \
             mock.patch.object(cr, "_count_blocked_drafts", return_value=[]), \
             mock.patch.object(cr, "_fetch_main_ci_status", return_value="success"), \
             patches2[0], patches2[1], patches2[2]:
            state, log_lines2 = cr.run(cfg, state, now2, "/nonexistent/.stop", dry_run=False)

        # PR#1は「返答待ち」で再送されないので、二通めはPR#2のみを含む。
        ntfy_mock2.assert_called_once()
        sent2 = [e for e in log_lines2 if e.get("event") == "pay_ntfy_sent"][0]
        self.assertEqual(list(sent2["labels"].keys()), ["N2-P1"])

        # ★是正の核心: 二通めのN2-P1は一通めのN1-P1を上書きしない。
        # 是正前は両方とも"P1"という同じキーだったため、ここでPR#1の記録が
        # PR#2で踏み潰され、self.assertEqual(...pr...1)が失敗していた。
        self.assertEqual(state["pay_ntfy_labels"]["N1-P1"]["pr"], 1)
        self.assertEqual(state["pay_ntfy_labels"]["N2-P1"]["pr"], 2)
        self.assertEqual(state["pay_ntfy_seq"], 2)


class Test34CrDecideErrorStreakWatchdog(unittest.TestCase):
    """cmd_928【四】: 当家側cr_decide_error連続検知の見張り。

    RED→GREENの構造: まず「閾値未満」「途中で正常処理が挟まった」場合に
    streakが検出されない(=鳴らない)ことを確かめ(RED対照)、次に閾値以上
    連続した場合にのみ検出・dashboard.mdへの追記・重複抑制が働く(GREEN)
    ことを確かめる。
    """

    def _write_jsonl(self, path, lines):
        with open(path, "w", encoding="utf-8") as f:
            for line in lines:
                f.write(json.dumps(line, ensure_ascii=False, default=str) + "\n")

    def _error_decision(self, ts, repo="geolonia/geonicdb-docs", pr=226):
        return {"ts": ts.isoformat(), "repo": repo, "pr": pr, "head_sha": "sha1",
                "category": "rate_limited", "decision": "cr_decide_error_wait",
                "cr_decide_action": "error"}

    def _ok_decision(self, ts, repo="geolonia/geonicdb-docs", pr=226):
        return {"ts": ts.isoformat(), "repo": repo, "pr": pr, "head_sha": "sha1",
                "category": "reviewed", "decision": "reviewed"}

    def test_red_below_threshold_not_detected(self):
        """RED対照①: 5回連続(閾値6未満)では検知されない=鳴らない。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_decide_streak_red1_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            lines = [self._error_decision(NOW + timedelta(minutes=10 * i)) for i in range(5)]
            self._write_jsonl(log_path, lines)
            streaks = cr._detect_cr_decide_error_streaks(
                log_path, NOW + timedelta(minutes=60), threshold=6)
            self.assertEqual(streaks, [])
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_red_normal_processing_interrupts_streak(self):
        """RED対照②: 6回連続の手前で正常処理(cr_decide_error以外)が挟まれば
        連続は途切れ、検知されない。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_decide_streak_red2_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            lines = [self._error_decision(NOW + timedelta(minutes=10 * i)) for i in range(5)]
            lines.append(self._ok_decision(NOW + timedelta(minutes=50)))  # 正常処理が割込み
            lines.append(self._error_decision(NOW + timedelta(minutes=60)))
            self._write_jsonl(log_path, lines)
            streaks = cr._detect_cr_decide_error_streaks(
                log_path, NOW + timedelta(minutes=70), threshold=6)
            self.assertEqual(streaks, [])
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_green_six_consecutive_errors_detected(self):
        """GREEN: 同一repo#prで6回連続cr_decide_errorが出れば検知される。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_decide_streak_green1_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            start = NOW
            lines = [self._error_decision(start + timedelta(minutes=10 * i)) for i in range(6)]
            self._write_jsonl(log_path, lines)
            streaks = cr._detect_cr_decide_error_streaks(
                log_path, start + timedelta(minutes=70), threshold=6)
            self.assertEqual(len(streaks), 1)
            s = streaks[0]
            self.assertEqual(s["repo"], "geolonia/geonicdb-docs")
            self.assertEqual(s["pr"], 226)
            self.assertEqual(s["count"], 6)
            self.assertEqual(s["first_ts"], start.isoformat())
            self.assertEqual(s["last_ts"], (start + timedelta(minutes=50)).isoformat())
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_green_other_pr_not_mixed_in(self):
        """GREEN: 別PRのcr_decide_errorは数え込まない(repo#pr単位で独立)。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_decide_streak_green2_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            start = NOW
            lines = []
            for i in range(5):
                lines.append(self._error_decision(start + timedelta(minutes=10 * i), pr=226))
            lines.append(self._error_decision(start + timedelta(minutes=50), pr=999))
            self._write_jsonl(log_path, lines)
            streaks = cr._detect_cr_decide_error_streaks(
                log_path, start + timedelta(minutes=70), threshold=6)
            self.assertEqual(streaks, [])
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_green_dashboard_alert_appended_once(self):
        """GREEN: 閾値到達でdashboard.mdへ追記され、同一streakでは再追記しない
        (重複連投防止)。ntfyは一切呼ばない設計(関数シグネチャにntfy系の
        引数・呼出が無いことはソース上も自明——本試験はdashboard挙動を見る)。
        """
        tmpdir = tempfile.mkdtemp(prefix="cr_decide_streak_green3_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            dashboard_path = os.path.join(tmpdir, "dashboard.md")
            with open(dashboard_path, "w", encoding="utf-8") as f:
                f.write("# 📊 戦況報告 (Battle Status Report)\n- 既存の1行目\n")

            start = NOW
            lines = [self._error_decision(start + timedelta(minutes=10 * i)) for i in range(6)]
            self._write_jsonl(log_path, lines)

            state = {}
            now1 = start + timedelta(minutes=70)
            new_alerts = cr._check_cr_decide_error_streaks_and_notify(
                state, log_path, dashboard_path, now1, threshold=6)
            self.assertEqual(len(new_alerts), 1)

            with open(dashboard_path, encoding="utf-8") as f:
                content_after_first = f.read()
            self.assertIn("cr_decide_error", content_after_first)
            self.assertIn("geolonia/geonicdb-docs#226", content_after_first)
            self.assertIn("6回連続", content_after_first)
            self.assertIn("ntfyは鳴らしていない", content_after_first)
            # 見出し直後(タイトル行の次)に積まれ、既存1行目の上に来ること。
            lines_after = content_after_first.splitlines()
            self.assertEqual(lines_after[0], "# 📊 戦況報告 (Battle Status Report)")
            self.assertIn("cr_decide_error", lines_after[1])

            # 同一streak(first_ts不変)のまま再度呼んでも追記されない。
            now2 = now1 + timedelta(minutes=10)
            lines.append(self._error_decision(start + timedelta(minutes=60)))  # streak継続
            self._write_jsonl(log_path, lines)
            new_alerts2 = cr._check_cr_decide_error_streaks_and_notify(
                state, log_path, dashboard_path, now2, threshold=6)
            self.assertEqual(new_alerts2, [])
            with open(dashboard_path, encoding="utf-8") as f:
                content_after_second = f.read()
            self.assertEqual(content_after_first, content_after_second)
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_green_streak_renotifies_after_break_and_rethreshold(self):
        """GREEN: streakが途切れた後、再度閾値を跨げば改めて通知される。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_decide_streak_green4_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            dashboard_path = os.path.join(tmpdir, "dashboard.md")
            with open(dashboard_path, "w", encoding="utf-8") as f:
                f.write("# 📊 戦況報告 (Battle Status Report)\n")

            start = NOW
            lines = [self._error_decision(start + timedelta(minutes=10 * i)) for i in range(6)]
            self._write_jsonl(log_path, lines)
            state = {}
            first = cr._check_cr_decide_error_streaks_and_notify(
                state, log_path, dashboard_path, start + timedelta(minutes=70), threshold=6)
            self.assertEqual(len(first), 1)

            # streakが途切れる(正常処理)→新しいstreakが別のfirst_tsで6回連続。
            lines.append(self._ok_decision(start + timedelta(minutes=60)))
            break_start = start + timedelta(minutes=70)
            lines += [self._error_decision(break_start + timedelta(minutes=10 * i))
                      for i in range(6)]
            self._write_jsonl(log_path, lines)
            second = cr._check_cr_decide_error_streaks_and_notify(
                state, log_path, dashboard_path, break_start + timedelta(minutes=70),
                threshold=6)
            self.assertEqual(len(second), 1)
            self.assertNotEqual(first[0]["first_ts"], second[0]["first_ts"])
        finally:
            import shutil
            shutil.rmtree(tmpdir)


class TestAppendDashboardAlertsAtomicWrite(unittest.TestCase):
    """cmd_928【四】やり直し(M1): dashboard.md書込みの一時ファイル+rename方式を固定する。"""

    def test_normal_write_updates_dashboard(self):
        tmpdir = tempfile.mkdtemp(prefix="dashboard_atomic_write_")
        try:
            dashboard_path = os.path.join(tmpdir, "dashboard.md")
            with open(dashboard_path, "w", encoding="utf-8") as f:
                f.write("# 📊 戦況報告 (Battle Status Report)\n既存行\n")
            cr._append_dashboard_alerts(dashboard_path, ["- 新規アラート"])
            with open(dashboard_path, encoding="utf-8") as f:
                content = f.read()
            self.assertIn("新規アラート", content)
            self.assertIn("既存行", content)
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_no_leftover_tmp_file_after_success(self):
        """成功時、一時ファイル(.dashboard_tmp_*)が残骸として残らないこと。"""
        tmpdir = tempfile.mkdtemp(prefix="dashboard_atomic_write_tmp_")
        try:
            dashboard_path = os.path.join(tmpdir, "dashboard.md")
            with open(dashboard_path, "w", encoding="utf-8") as f:
                f.write("# 📊 戦況報告 (Battle Status Report)\n")
            cr._append_dashboard_alerts(dashboard_path, ["- アラート"])
            remaining = [n for n in os.listdir(tmpdir) if n != "dashboard.md"]
            self.assertEqual(remaining, [])
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_write_failure_does_not_corrupt_dashboard(self):
        """RED→GREEN: 書込み途中(os.fdopen後のwritelines中)で例外が起きても、
        dashboard.mdは一時ファイルへの書込み中であり本体は未着手のため空/破損に
        ならないこと。是正前(open(dashboard_path, "w")で直接truncateして書く形)
        であれば、この種の中断で本体が空になる——是正後はそれが起きないことを示す。
        """
        tmpdir = tempfile.mkdtemp(prefix="dashboard_atomic_write_fail_")
        try:
            dashboard_path = os.path.join(tmpdir, "dashboard.md")
            original_content = "# 📊 戦況報告 (Battle Status Report)\n既存の内容\n"
            with open(dashboard_path, "w", encoding="utf-8") as f:
                f.write(original_content)

            boom = mock.MagicMock()
            boom.__enter__ = mock.Mock(return_value=boom)
            boom.__exit__ = mock.Mock(return_value=False)
            boom.writelines = mock.Mock(
                side_effect=OSError("simulated crash mid-write"))

            def fake_fdopen(fd, *a, **kw):
                os.close(fd)  # mkstempが開いた実fdをここで畳む(リーク防止)
                return boom

            with mock.patch("os.fdopen", side_effect=fake_fdopen):
                with self.assertRaises(OSError):
                    cr._append_dashboard_alerts(dashboard_path, ["- アラート"])

            with open(dashboard_path, encoding="utf-8") as f:
                content_after = f.read()
            self.assertEqual(content_after, original_content)

            leftover_tmp = [n for n in os.listdir(tmpdir) if n != "dashboard.md"]
            self.assertEqual(leftover_tmp, [])
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_replace_failure_does_not_corrupt_dashboard(self):
        """os.replace自体が失敗した場合も本体は未変更のままであること。"""
        tmpdir = tempfile.mkdtemp(prefix="dashboard_atomic_write_replacefail_")
        try:
            dashboard_path = os.path.join(tmpdir, "dashboard.md")
            original_content = "# 📊 戦況報告 (Battle Status Report)\n既存の内容\n"
            with open(dashboard_path, "w", encoding="utf-8") as f:
                f.write(original_content)

            with mock.patch("os.replace", side_effect=OSError("simulated replace failure")):
                with self.assertRaises(OSError):
                    cr._append_dashboard_alerts(dashboard_path, ["- アラート"])

            with open(dashboard_path, encoding="utf-8") as f:
                content_after = f.read()
            self.assertEqual(content_after, original_content)

            leftover_tmp = [n for n in os.listdir(tmpdir) if n != "dashboard.md"]
            self.assertEqual(leftover_tmp, [])
        finally:
            import shutil
            shutil.rmtree(tmpdir)


# ── cmd_934 T1: RED対照3件(queue/reports/cmd934_decompose.md
#    acceptance_criteria)。いずれも「是正前はこう壊れていた」を実行可能な
#    形で示した上で、是正後の正しい挙動を確かめる。

class Test35RedControl1QueryFuseReplacesMayQuery(unittest.TestCase):
    """RED対照1(今の詰まり): 旧may_query(一つの件につき一生に1回)は、
    query_incidentsに既存headが一度でも載れば、そのheadへは二度と
    問い合わせが出ない——headが変わらぬ限り永久に止まる
    (queue/reports/cmd933_review_next_vs_cr_retrigger.md 結論1の実況)。
    是正後のquery_fuse_ok()は、同じ件でもfuse_min分を過ぎれば再び許す。
    """

    def test_red_old_once_per_incident_rule_blocks_forever(self):
        # 旧may_queryの核(cr_retrigger.pyから削除済み)をここに再現する:
        # 「incident_keyがquery_incidentsに一度でも載れば、以後は常にFalse」。
        def old_may_query_once_per_incident(incident_key, state, now):
            return incident_key not in state.get("query_incidents", {})

        incident_key = "geolonia/geonicdb-console#1#sha1#check"
        # 10/01の実況の再現: 7時間前に一度問い合わせ済み。
        state = {"query_incidents": {incident_key: NOW - timedelta(hours=7)}}
        # 7時間経っても、headが変わらぬ限り旧ルールは永久にFalseを返す。
        self.assertFalse(old_may_query_once_per_incident(incident_key, state, NOW))
        self.assertFalse(old_may_query_once_per_incident(
            incident_key, state, NOW + timedelta(days=30)))  # 30日後でも変わらぬ

    def test_green_query_fuse_ok_allows_again_after_fuse_window(self):
        incident_key = "geolonia/geonicdb-console#1#sha1#check"
        last_queried = NOW - timedelta(minutes=61)
        state = {"query_fuse": {incident_key: last_queried}}
        # 是正後: 61分経っていればfuse_min(60分)を過ぎており再び許される。
        self.assertTrue(cr.query_fuse_ok(incident_key, state, NOW, fuse_min=60))

    def test_green_query_fuse_still_blocks_within_fuse_window(self):
        incident_key = "geolonia/geonicdb-console#1#sha1#check"
        last_queried = NOW - timedelta(minutes=30)
        state = {"query_fuse": {incident_key: last_queried}}
        self.assertFalse(cr.query_fuse_ok(incident_key, state, NOW, fuse_min=60))

    def test_green_end_to_end_second_query_for_same_incident_after_fuse_expires(self):
        """run()を通して、同一incidentへの再問い合わせが60分を過ぎれば
        実際に投じられることを固定する(query_fuse_ok単体でなく配線も含む)。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"], query_enabled=True)
        incident_key = "geolonia/geonicdb-console#1#sha1#check"
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                  "query_fuse": {incident_key: NOW - timedelta(minutes=61)}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "check", "reason": "budget unknown",
                          "command": "@coderabbitai rate limit"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_called_once_with(
            "geolonia/geonicdb-console", 1, cr.QUERY_BODY, gh_bin="gh")
        self.assertEqual(state["query_fuse"][incident_key], NOW)


class Test36RedControl2DoubleTriggerPreventedByQueueAwareDecision(unittest.TestCase):
    """RED対照2(二重の依頼・cmd934やり直し=軍師QC H1是正): 二重の依頼を
    防ぐ要は、決める部品(review-next)がcall_cr_decideから渡されるHOMEの下の
    本物のqueue(`.claude/cr-decide/queue/`)を読めることにある。queueの
    claimの有無そのものはreview-next.mjs(組織skill・改変禁止)の領分であり
    ここでは変えようがない——cr_retrigger.py側が握るのは「決める部品へ
    どのHOMEを渡すか」だけである。渡すHOMEが利用者の家(pwdの家)でなく
    親envのHOMEのままだと、queueに本物のclaimが実在してもreview-nextからは
    見えず、意味なく'review'を返し二重の依頼の種になる(=cmd934_decompose.md
    の想定どおり、二重防止の実効はHOME明示(_child_env)に懸かっている)。

    ★前回(PR#184・head 82acafd)のtest_red_queue_unaware_decision_ignores_
    fresh_claimは、自分で書いた辞書のキーを確かめるだけで本物のコードを
    一行も通していなかった(空虚なRED・軍師QC H1)。ここでは偽のnode
    (review-nextの代わり)を本物の子プロセスとして立て、本物の
    call_cr_decide()を回して証す。"""

    _FAKE_REVIEW_NEXT_JS = (
        "const fs = require('fs');\n"
        "const path = require('path');\n"
        "const args = process.argv.slice(2);\n"
        "const prNumber = args[0];\n"
        "const repoIdx = args.indexOf('--repo');\n"
        "const repo = repoIdx >= 0 ? args[repoIdx + 1] : 'unknown';\n"
        "const home = process.env.HOME || '';\n"
        "const queueName = 'queue-' + repo.toLowerCase().split('/').join('_')"
        " + '_' + prNumber + '.json';\n"
        "const queuePath = path.join(home, '.claude', 'cr-decide', 'queue', queueName);\n"
        "if (home && fs.existsSync(queuePath)) {\n"
        "  process.stdout.write(JSON.stringify({action: 'wait',"
        " reason: 'queue claim found (fake review-next)'}));\n"
        "} else {\n"
        "  process.stdout.write(JSON.stringify({action: 'review',"
        " command: '@coderabbitai review'}));\n"
        "}\n"
    )

    def setUp(self):
        self.script_dir = tempfile.mkdtemp(prefix="cr_retrigger_fake_reviewnext_")
        self.script_path = os.path.join(self.script_dir, "fake-review-next.js")
        with open(self.script_path, "w", encoding="utf-8") as f:
            f.write(self._FAKE_REVIEW_NEXT_JS)
        # 親env側のHOME(claim無し)——launchd等でHOMEが利用者の家と違う場所に
        # なりうることの再現。
        self.no_claim_home = tempfile.mkdtemp(prefix="cr_retrigger_home_noclaim_")
        # 利用者の本物の家(pwdの家)相当——本物のqueueのclaimはここにある。
        self.claim_home = tempfile.mkdtemp(prefix="cr_retrigger_home_claim_")
        queue_dir = os.path.join(self.claim_home, ".claude", "cr-decide", "queue")
        os.makedirs(queue_dir, exist_ok=True)
        with open(os.path.join(queue_dir, "queue-geolonia_geonicdb-console_1.json"),
                  "w", encoding="utf-8") as f:
            json.dump({"claimedAt": NOW.isoformat().replace("+00:00", "Z")}, f)

    def tearDown(self):
        import shutil
        shutil.rmtree(self.script_dir, ignore_errors=True)
        shutil.rmtree(self.no_claim_home, ignore_errors=True)
        shutil.rmtree(self.claim_home, ignore_errors=True)

    def test_red_env_without_home_override_misses_real_queue_and_double_reviews(self):
        """是正前相当: call_cr_decideへ渡すenvがHOMEを明示しない
        (_clean_git_env()のみ、main版call_cr_decideの実際の経路)だと、
        親のHOME(claim無しの場所)がそのまま子へ渡り、利用者の家にある
        本物のqueueが見えず'review'を返す=二重の依頼の種。"""
        with mock.patch.object(cr, "_child_env", side_effect=cr._clean_git_env), \
             mock.patch.dict(os.environ, {"HOME": self.no_claim_home}):
            decision = cr.call_cr_decide(
                "geolonia/geonicdb-console", 1, self.script_dir, self.script_path,
                node_bin="node")
        self.assertEqual(decision["action"], "review")

    def test_green_child_env_sees_real_queue_claim_and_waits(self):
        """是正後: _child_env()がpwdの家(利用者の本物の家)を明示して子へ
        渡すため、親のHOMEが別の場所を指していても、そこにある本物のqueueの
        claimが見え'wait'を返し投じない=二重の依頼を防ぐ。

        ★main版のcall_cr_decideは_clean_git_env()しか使わずpwdを一切見ない
        ため、pwdをここでmockしても親envのHOMEがそのまま子へ伝わり'review'の
        ままとなる——このtestはPRの試験一式をmain版に当てればFAIL
        (action=='review'のまま)で落ちる。"""
        with mock.patch("pwd.getpwuid",
                         return_value=mock.Mock(pw_dir=self.claim_home)), \
             mock.patch.dict(os.environ, {"HOME": self.no_claim_home}):
            decision = cr.call_cr_decide(
                "geolonia/geonicdb-console", 1, self.script_dir, self.script_path,
                node_bin="node")
        self.assertEqual(decision["action"], "wait")


class Test37RedControl3ChildEnvHasHome(unittest.TestCase):
    """RED対照3(HOME): launchdのplistはHOMEを設定せぬ。親envからHOMEが
    無くとも、子プロセス(review-next.mjs等)へは利用者の家が渡ること。
    是正前(_clean_git_env()のみ)は、親にHOMEが無ければ子にも無い
    ——review-nextのqueueが`os.homedir()`の推測(root等)に化けうる。
    是正後(_child_env())は常にpwd経由で明示する。"""

    def test_red_clean_git_env_alone_does_not_guarantee_home(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("HOME", None)
            env = cr._clean_git_env()
        self.assertNotIn("HOME", env)

    def test_green_child_env_sets_home_even_when_parent_lacks_it(self):
        import pwd
        expected_home = pwd.getpwuid(os.getuid()).pw_dir
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("HOME", None)
            env = cr._child_env()
        self.assertEqual(env["HOME"], expected_home)

    def test_green_child_env_strips_git_vars_too(self):
        # _child_env()は_clean_git_env()の上に成り立つ——GIT_*除去の回帰。
        with mock.patch.dict(os.environ, {"GIT_DIR": "/some/other/repo/.git"}):
            env = cr._child_env()
        self.assertFalse(any(k.startswith("GIT_") for k in env))

    def test_green_call_cr_decide_passes_child_env_with_home(self):
        captured = {}

        def fake_run(cmd, **kwargs):
            captured["env"] = kwargs.get("env")
            return mock.Mock(stdout=json.dumps(
                {"action": "check", "command": "@coderabbitai rate limit"}))

        import pwd
        expected_home = pwd.getpwuid(os.getuid()).pw_dir
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("HOME", None)
            with mock.patch("subprocess.run", side_effect=fake_run):
                cr.call_cr_decide(
                    "geolonia/geonicdb-console", 1, "/fake/clone",
                    "/fake/review-next.mjs")

        self.assertEqual(captured["env"]["HOME"], expected_home)

    def test_green_ensure_clone_passes_child_env_with_home(self):
        captured = {}

        def fake_run(cmd, **kwargs):
            captured["env"] = kwargs.get("env")
            return mock.Mock(returncode=0)

        import pwd
        expected_home = pwd.getpwuid(os.getuid()).pw_dir
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_ensure_clone_")
        try:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop("HOME", None)
                with mock.patch("subprocess.run", side_effect=fake_run):
                    cr._ensure_clone("geolonia/geonicdb-console", tmpdir)
            self.assertEqual(captured["env"]["HOME"], expected_home)
        finally:
            import shutil
            shutil.rmtree(tmpdir)


class Test38AssertAllowedBodyRejectsPayAndApproveBodies(unittest.TestCase):
    """cmd_934 T2 acceptance④: assert_allowed_body()は、cr-decideのpay・
    approve相当の本文(review-nextがそのまま返す文面の形)を名指しで拒む。
    Test9は汎用の自由文を拒むことしか固めていなかったため、ここで
    pay・approveそれぞれの実際の文面を明示して固定する。"""

    def test_rejects_pay_use_credits_body(self):
        with self.assertRaises(ValueError):
            cr.assert_allowed_body("[AI] @coderabbitai review --use-credits")

    def test_rejects_approve_body(self):
        with self.assertRaises(ValueError):
            cr.assert_allowed_body("[AI] @coderabbitai approve")


class Test39RedControlLoosenedAssertAllowedBodyWouldPostPay(unittest.TestCase):
    """RED対照(cmd_934 T2 acceptance⑤): assert_allowed_body()が最後の砦
    であることを、素通しにした偽版との対比で示す。

    是正前相当(素通し版に差し替えた状態): pay相当の本文でpost_comment()を
    呼ぶと、例外にならずgh呼出(subprocess.run)まで進んでしまう
    ——これは「投じてはならない本文が投じられる」事故そのものである。

    現行コード(assert_allowed_bodyを差し替えない): 同じ呼び出しが
    ValueErrorで止まり、gh呼出(subprocess.run)は一度も起きない。
    """

    PAY_BODY = "[AI] @coderabbitai review --use-credits"
    APPROVE_BODY = "[AI] @coderabbitai approve"

    @staticmethod
    def _loosened_assert_allowed_body(body):
        """素通し版(RED対照専用)。本物のALLOWED_BODIES判定を行わない。"""
        return None

    def test_red_loosened_guard_lets_pay_body_reach_gh(self):
        with mock.patch.object(cr, "assert_allowed_body",
                                side_effect=self._loosened_assert_allowed_body), \
             mock.patch("subprocess.run") as run_mock:
            cr.post_comment("geolonia/geonicdb-console", 1, self.PAY_BODY)
        run_mock.assert_called_once()

    def test_red_loosened_guard_lets_approve_body_reach_gh(self):
        with mock.patch.object(cr, "assert_allowed_body",
                                side_effect=self._loosened_assert_allowed_body), \
             mock.patch("subprocess.run") as run_mock:
            cr.post_comment("geolonia/geonicdb-console", 1, self.APPROVE_BODY)
        run_mock.assert_called_once()

    def test_green_current_guard_blocks_pay_body_before_gh(self):
        with mock.patch("subprocess.run") as run_mock:
            with self.assertRaises(ValueError):
                cr.post_comment("geolonia/geonicdb-console", 1, self.PAY_BODY)
        run_mock.assert_not_called()

    def test_green_current_guard_blocks_approve_body_before_gh(self):
        with mock.patch("subprocess.run") as run_mock:
            with self.assertRaises(ValueError):
                cr.post_comment("geolonia/geonicdb-console", 1, self.APPROVE_BODY)
        run_mock.assert_not_called()
# ── cmd_934続き(queue/reports/cmd934_trigger_per_day_judgment.md §6・案B):
#    trigger_breaker(壊れた徴で止める)の試験。Test8が「数の枷を除いた」
#    ことを固定したのに対し、ここでは「数の代わりに徴で止める」ことを固定する。

class Test40TriggerMissedDetection(unittest.TestCase):
    """投じた後の周回で、同じhead(sha不変)のCodeRabbit statusが、投じた
    時刻より後にrate limitedへ戻っていれば、「外れた依頼」としてstateに
    刻む(trigger_missedイベント・state["trigger_misses"])。"""

    def test_rate_limited_after_trigger_is_recorded_as_miss(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        last_trigger_at = NOW - timedelta(minutes=10)
        state = {
            "heads": {"geolonia/geonicdb-console#1#sha1":
                      {"attempts": 1, "last_trigger_at": last_trigger_at}},
            "sent_log": [], "query_log": [], "query_incidents": {},
        }

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "wait", "reason": "n/a",
                          "retryAt": (NOW + timedelta(minutes=5)).isoformat().replace("+00:00", "Z")}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        missed = [e for e in log_lines if e.get("event") == "trigger_missed"]
        self.assertEqual(len(missed), 1)
        self.assertEqual(missed[0]["pr"], 1)
        self.assertEqual(missed[0]["level"], "warn")
        self.assertEqual(len(state["trigger_misses"]), 1)
        self.assertEqual(state["trigger_misses"][0], NOW)

    def test_status_before_trigger_is_not_a_miss(self):
        """statusの更新時刻が投じた時刻より前(投じる前からrate limitedの
        まま)なら、外れた徴ではない。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        last_trigger_at = NOW
        state = {
            "heads": {"geolonia/geonicdb-console#1#sha1":
                      {"attempts": 1, "last_trigger_at": last_trigger_at}},
            "sent_log": [], "query_log": [], "query_incidents": {},
        }

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "wait", "reason": "n/a"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited",
                                               last_trigger_at - timedelta(minutes=1))), \
             mock.patch.object(cr, "post_comment"), \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        self.assertEqual([e for e in log_lines if e.get("event") == "trigger_missed"], [])

    def test_no_prior_trigger_is_not_a_miss(self):
        """一度も投じていないhead(last_trigger_at無し)は、rate limitedの
        ままでも外れた依頼ではない(そもそも外れる依頼が無い)。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "wait", "reason": "n/a"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        self.assertEqual([e for e in log_lines if e.get("event") == "trigger_missed"], [])

    def test_same_status_update_not_double_counted_across_cycles(self):
        """同じupdated_atのまま次周回を回しても、外れた依頼を2重に数えない
        (miss_recorded_for_trigger_atが同じ更新の再数えを防ぐ)。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        last_trigger_at = NOW - timedelta(minutes=10)
        status_updated_at = NOW
        state = {
            "heads": {"geolonia/geonicdb-console#1#sha1":
                      {"attempts": 1, "last_trigger_at": last_trigger_at}},
            "sent_log": [], "query_log": [], "query_incidents": {},
        }

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "wait", "reason": "n/a"}}

        patches1 = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", status_updated_at)), \
             mock.patch.object(cr, "post_comment"), \
             patches1[0], patches1[1], patches1[2]:
            state, log_lines1 = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)
        self.assertEqual(
            len([e for e in log_lines1 if e.get("event") == "trigger_missed"]), 1)

        now2 = NOW + timedelta(minutes=5)
        patches2 = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", status_updated_at)), \
             mock.patch.object(cr, "post_comment"), \
             patches2[0], patches2[1], patches2[2]:
            state, log_lines2 = cr.run(cfg, state, now2, "/nonexistent/.stop", dry_run=False)

        self.assertEqual([e for e in log_lines2 if e.get("event") == "trigger_missed"], [])
        self.assertEqual(len(state["trigger_misses"]), 1)

    def test_status_restamped_with_new_updated_at_still_not_double_counted(self):
        """RED→GREEN(自己レビュー是正): 是正前は「同じupdated_atか」で二重数えを
        見張っていたため、CodeRabbitが新たな投げ無しに同じrate limited状態
        を★別のupdated_atで再timestampし直すと、1回の失敗した投げを2回と
        誤って数えてしまっていた。是正後は「この投げ(last_trigger_at)単位」
        で見張るため、last_trigger_atが変わらない限りupdated_atが進んでも
        二重に数えない。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        last_trigger_at = NOW - timedelta(minutes=10)
        state = {
            "heads": {"geolonia/geonicdb-console#1#sha1":
                      {"attempts": 1, "last_trigger_at": last_trigger_at}},
            "sent_log": [], "query_log": [], "query_incidents": {},
        }

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "wait", "reason": "n/a"}}

        patches1 = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             patches1[0], patches1[1], patches1[2]:
            state, log_lines1 = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)
        self.assertEqual(
            len([e for e in log_lines1 if e.get("event") == "trigger_missed"]), 1)

        # CodeRabbitが新たな投げ無しに、同じrate limited状態を★別の
        # updated_at(NOW + 1分)で再timestampし直した想定(last_trigger_atは
        # 変わらぬまま=本当に新しい投げは一度も起きていない)。
        now2 = NOW + timedelta(minutes=5)
        restamped_updated_at = NOW + timedelta(minutes=1)
        patches2 = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", restamped_updated_at)), \
             mock.patch.object(cr, "post_comment"), \
             patches2[0], patches2[1], patches2[2]:
            state, log_lines2 = cr.run(cfg, state, now2, "/nonexistent/.stop", dry_run=False)

        self.assertEqual([e for e in log_lines2 if e.get("event") == "trigger_missed"], [])
        self.assertEqual(len(state["trigger_misses"]), 1)

    def test_dry_run_does_not_mutate_state_but_still_logs(self):
        """自己レビュー是正: dry_runの間はstate(decision台帳)を一切書き換えない
        (sent_log・attempts・query_fuse等、他の全ての台帳更新と同じ流儀)。
        観察のためのログ出力(trigger_missed・dry_run=Trueの印)は出す。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        last_trigger_at = NOW - timedelta(minutes=10)
        state = {
            "heads": {"geolonia/geonicdb-console#1#sha1":
                      {"attempts": 1, "last_trigger_at": last_trigger_at}},
            "sent_log": [], "query_log": [], "query_incidents": {},
        }

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "wait", "reason": "n/a"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        missed = [e for e in log_lines if e.get("event") == "trigger_missed"]
        self.assertEqual(len(missed), 1)
        self.assertTrue(missed[0]["dry_run"])
        # 核心: dry_runの間はtrigger_misses等の台帳が一切増えていないこと。
        self.assertNotIn("trigger_misses", state)
        self.assertEqual(
            state["heads"]["geolonia/geonicdb-console#1#sha1"].get("miss_recorded_for_trigger_at"),
            None)
        self.assertEqual(
            state["heads"]["geolonia/geonicdb-console#1#sha1"]["last_trigger_at"],
            last_trigger_at)


class Test41TriggerBreakerOpensAfterTwoMissesAndBlocksThirdAttempt(unittest.TestCase):
    """acceptance_criteria: 投じた後にrate limitedが2回続けて返ると、3回目は
    投じずtrigger_breaker_openとなり、ntfy通知の呼び出しがある
    (queue/reports/cmd934_trigger_per_day_judgment.md §6・案B)。"""

    def test_third_attempt_blocked_after_two_missed_triggers(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        # cycle1: まだ投じていない。review-nextが勧め、1回目を投じる。
        now1 = NOW
        decisions1 = {1: {"action": "review", "reason": "1 review available",
                            "command": "@coderabbitai review"}}
        patches1 = _patch_cr_decide_wiring(decisions1)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review paused", now1)), \
             mock.patch.object(cr, "post_comment") as post_mock1, \
             patches1[0], patches1[1], patches1[2]:
            state, _ = cr.run(cfg, state, now1, "/nonexistent/.stop", dry_run=False)
        post_mock1.assert_called_once_with(
            "geolonia/geonicdb-console", 1, cr.TRIGGER_BODY, gh_bin="gh")
        self.assertEqual(
            state["heads"]["geolonia/geonicdb-console#1#sha1"]["attempts"], 1)

        # cycle2(10分後): 投じた直後rate limitedへ戻る(外れた依頼その1)。
        # review-nextはなお勧めるので2回目を投じる(breakerはまだ閉じている)。
        now2 = now1 + timedelta(minutes=10)
        decisions2 = {1: {"action": "review", "reason": "1 review available",
                            "command": "@coderabbitai review"}}
        patches2 = _patch_cr_decide_wiring(decisions2)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", now2)), \
             mock.patch.object(cr, "post_comment") as post_mock2, \
             patches2[0], patches2[1], patches2[2]:
            state, log_lines2 = cr.run(cfg, state, now2, "/nonexistent/.stop", dry_run=False)
        missed2 = [e for e in log_lines2 if e.get("event") == "trigger_missed"]
        self.assertEqual(len(missed2), 1)
        post_mock2.assert_called_once_with(
            "geolonia/geonicdb-console", 1, cr.TRIGGER_BODY, gh_bin="gh")
        self.assertEqual(
            state["heads"]["geolonia/geonicdb-console#1#sha1"]["attempts"], 2)
        self.assertFalse(state.get("trigger_breaker_open", False))

        # cycle3(さらに10分後): 2度目のrate limitedへ戻り(外れた依頼その2)、
        # breakerが開く。review-nextはなお勧めるが、3回目は投じない。
        now3 = now2 + timedelta(minutes=10)
        decisions3 = {1: {"action": "review", "reason": "1 review available",
                            "command": "@coderabbitai review"}}
        patches3 = _patch_cr_decide_wiring(decisions3)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", now3)), \
             mock.patch.object(cr, "post_comment") as post_mock3, \
             mock.patch.object(cr, "_post_trigger_breaker_ntfy") as ntfy_mock, \
             patches3[0], patches3[1], patches3[2]:
            state, log_lines3 = cr.run(cfg, state, now3, "/nonexistent/.stop", dry_run=False)

        post_mock3.assert_not_called()
        self.assertTrue(state["trigger_breaker_open"])
        ntfy_mock.assert_called_once()
        opened = [e for e in log_lines3 if e.get("event") == "trigger_breaker_open"]
        self.assertEqual(len(opened), 1)
        self.assertEqual(opened[0]["level"], "warn")
        self.assertEqual(opened[0]["miss_count"], 2)
        # 3回目は投じられていないため、attemptsは2のまま(max_attemptsの
        # 枷とは別に、breakerが先に止めたことの確認)。
        self.assertEqual(
            state["heads"]["geolonia/geonicdb-console#1#sha1"]["attempts"], 2)

    def test_breaker_stays_open_without_renotifying_on_later_cycles(self):
        """一度開いたbreakerは、以後のcycleで新たな外れた依頼が無くても
        (既にopenのまま)、重ねてntfyを呼ばない。"""
        cfg = {"allowlist": [], "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                  "trigger_breaker_open": True,
                  "trigger_misses": [NOW - timedelta(hours=1), NOW - timedelta(minutes=30)]}

        with mock.patch.object(cr, "_post_trigger_breaker_ntfy") as ntfy_mock:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        ntfy_mock.assert_not_called()
        self.assertEqual(
            [e for e in log_lines if e.get("event") == "trigger_breaker_open"], [])

    def test_dry_run_does_not_open_breaker_or_notify(self):
        """自己レビュー是正: dry_runの間はtrigger_breaker_open自体も実際には
        開かず(stateは変わらず)、ntfy・dashboard追記も呼ばない。観察用の
        ログ(dry_run=Trueの印つき)だけは出す。"""
        cfg = {"allowlist": [], "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                  "trigger_misses": [NOW - timedelta(hours=1), NOW - timedelta(minutes=30)]}

        with mock.patch.object(cr, "_post_trigger_breaker_ntfy") as ntfy_mock, \
             mock.patch.object(cr, "_append_dashboard_alerts") as dashboard_mock:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        ntfy_mock.assert_not_called()
        dashboard_mock.assert_not_called()
        self.assertFalse(state.get("trigger_breaker_open", False))
        opened = [e for e in log_lines if e.get("event") == "trigger_breaker_open"]
        self.assertEqual(len(opened), 1)
        self.assertTrue(opened[0]["dry_run"])

    def test_dry_run_accurately_predicts_same_cycle_breaker_blocking_other_prs(self):
        """RED→GREEN(自己レビュー是正・4回目・最重要): 是正前は、この周回で新たに
        検知した外れをdry_runの間はstateへ積まなかったため、「この周回で
        2件めの外れに達し、同じ周回でbreakerが開いて他のPRの投げも止まる」
        はずの場面でも、--dry-runは古い(この周回より前の)件数だけで判定
        してしまい、review-nextが勧める別PRを誤って「投じる」と示していた
        ——acceptance_criteria⑨の別worktree--dry-run事前検証(merge前に
        本番相当のPRで行う)が当てにならなくなる欠陥だった。是正後は、
        この周回で新たに検知した外れを(stateへは書かずに)判定へ反映する。
        """
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        pr1_last_trigger_at = NOW - timedelta(minutes=10)
        state = {
            "heads": {"geolonia/geonicdb-console#1#sha1":
                      {"attempts": 1, "last_trigger_at": pr1_last_trigger_at}},
            "sent_log": [], "query_log": [], "query_incidents": {},
            "trigger_misses": [NOW - timedelta(hours=1)],  # 既に1件(24時間窓内)
        }

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [
                {"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None},
                {"number": 2, "headRefOid": "sha2", "isDraft": False, "createdAt": None},
            ]

        def fake_status(repo, sha, gh_bin="gh", timeout=30):
            if sha == "sha1":
                return "Review rate limited", NOW  # 今回の周回で2件めの外れになる
            return "Review paused", NOW  # PR2はcr_decideへ回る

        decisions = {
            1: {"action": "wait", "reason": "n/a"},
            2: {"action": "review", "reason": "1 review available",
                "command": "@coderabbitai review"},
        }
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status", side_effect=fake_status), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        missed = [e for e in log_lines if e.get("event") == "trigger_missed"]
        self.assertEqual(len(missed), 1)
        opened = [e for e in log_lines if e.get("event") == "trigger_breaker_open"]
        self.assertEqual(len(opened), 1)
        self.assertEqual(opened[0]["miss_count"], 2)
        self.assertTrue(opened[0]["dry_run"])
        # 核心: PR2はreview-nextがreviewを勧めているが、この周回で開く
        # (はずの)breakerにより、dry_runでも「投じる」と示してはならない。
        self.assertEqual([e for e in log_lines if e.get("event") == "triggered"], [])
        post_mock.assert_not_called()
        # stateそのものは引き続きdry_run中は変わらない(他の是正と整合)。
        self.assertFalse(state.get("trigger_breaker_open", False))
        self.assertEqual(state["trigger_misses"], [NOW - timedelta(hours=1)])

    def test_zero_threshold_config_is_clamped_to_safe_default(self):
        """RED→GREEN(自己レビュー是正・4回目): trigger_breaker_threshold: 0の
        ような壊れた設定値は、1件も外れていないのに`0 >= 0`で即座に
        breakerを開いてしまう——既定値(2)へ安全側に倒す。"""
        cfg = {"allowlist": [], "budget": {"trigger_breaker_threshold": 0}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        with mock.patch.object(cr, "_post_trigger_breaker_ntfy") as ntfy_mock:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        ntfy_mock.assert_not_called()
        self.assertFalse(state.get("trigger_breaker_open", False))
        self.assertEqual(
            [e for e in log_lines if e.get("event") == "trigger_breaker_open"], [])

    def test_negative_window_hours_config_is_clamped_to_safe_default(self):
        cfg = {"allowlist": [], "budget": {"trigger_breaker_window_hours": -5}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                  "trigger_misses": [NOW - timedelta(hours=1), NOW - timedelta(minutes=10)]}

        with mock.patch.object(cr, "_post_trigger_breaker_ntfy") as ntfy_mock:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        # 既定の24時間窓が使われ、通常どおり2件で開く(壊れた負の窓に
        # よって窓が空になり誤判定することはない)。
        ntfy_mock.assert_called_once()
        self.assertTrue(state["trigger_breaker_open"])

    def test_dashboard_alert_failure_does_not_lose_cycle_log_or_state(self):
        """RED→GREEN(自己レビュー是正・4回目): _append_dashboard_alertsの失敗を
        run()自身が無防備に伝播させると、この周回のlog_lines(今まさに
        積んだtrigger_breaker_openの記録を含む)がlog_pathへ書かれる前に
        失われ、main()のstate保存(trigger_breaker_open=True等)にも
        届かない。他のI/O呼出(ntfy・post_comment・gh取得)と同じく、
        失敗はwarnログに変えてrun()を完走させること。"""
        cfg = {"allowlist": [], "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                  "trigger_misses": [NOW - timedelta(hours=1), NOW - timedelta(minutes=10)]}

        with mock.patch.object(cr, "_post_trigger_breaker_ntfy"), \
             mock.patch.object(cr, "_append_dashboard_alerts",
                                side_effect=OSError("simulated dashboard write failure")):
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        # 核心: run()自身が例外で落ちず、この周回の記録とstate更新が残る。
        self.assertTrue(state["trigger_breaker_open"])
        opened = [e for e in log_lines if e.get("event") == "trigger_breaker_open"]
        self.assertEqual(len(opened), 1)
        failed = [e for e in log_lines
                  if e.get("event") == "trigger_breaker_dashboard_alert_failed"]
        self.assertEqual(len(failed), 1)
        self.assertEqual(failed[0]["level"], "warn")
        cycle_lines = [e for e in log_lines if e.get("event") == "cycle"]
        self.assertEqual(len(cycle_lines), 1)  # run()が最後まで完走している

    def test_bool_threshold_config_is_not_mistaken_for_valid_int(self):
        """RED→GREEN(自己レビュー是正・5回目): Pythonの`bool`は`int`の派生型
        (`isinstance(True, int)`はTrue)であるため、`isinstance(x, int)`
        だけの検証では`trigger_breaker_threshold: true`という誤記
        (config/cr_retrigger.yamlは`enabled: true`等が並び紛れやすい)が
        `1`として素通りしてしまう——1件の外れで即座にbreakerが開く事故に
        なる。boolは明示的に弾き、既定値(2)へ倒すこと。"""
        cfg = {"allowlist": [], "budget": {"trigger_breaker_threshold": True}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                  "trigger_misses": [NOW - timedelta(hours=1)]}  # 1件のみ

        with mock.patch.object(cr, "_post_trigger_breaker_ntfy") as ntfy_mock:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        # 既定値2が使われるため、1件だけでは開かない。
        ntfy_mock.assert_not_called()
        self.assertFalse(state.get("trigger_breaker_open", False))


class Test41bQueryGatedByTriggerBreaker(unittest.TestCase):
    """自己レビュー是正(5回目・最重要・実測で確認された欠陥): trigger_breaker_open
    が開いている間は、`[AI] @coderabbitai rate limit`の予備の問い合わせも
    止める。killedと同様「以後は一切投じぬ」はずが、この経路だけ漏れて
    おり、breaker open中でも実際にquery_postedが投稿されていた。"""

    def test_query_not_posted_while_breaker_is_open(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"], query_enabled=True)
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                  "trigger_breaker_open": True}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "check", "reason": "budget unknown",
                          "command": "@coderabbitai rate limit"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        not_posted = [e for e in log_lines if e.get("event") == "query_not_posted"]
        self.assertEqual(len(not_posted), 1)
        self.assertEqual(not_posted[0]["reason"], "trigger_breaker_open")
        self.assertEqual(state.get("query_fuse", {}), {})

    def test_query_posted_normally_when_breaker_closed(self):
        """回帰確認: breakerが閉じていれば、従来どおり問い合わせは投じる。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"], query_enabled=True)
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "check", "reason": "budget unknown",
                          "command": "@coderabbitai rate limit"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_called_once_with(
            "geolonia/geonicdb-console", 1, cr.QUERY_BODY, gh_bin="gh")

    def test_query_blocked_same_cycle_breaker_trips_including_for_triggering_pr_itself(self):
        """RED→GREEN(自己レビュー是正・6回目・実測で再現): is_within_project_tree
        済みのstate["trigger_breaker_open"]だけを見ると、まさにこの周回で
        2件めの外れを検知して閾値へ達した(=この周回でbreakerが開く)
        場合、その外れを起こしたPR自身や、ループ内でそれより後に処理
        される別PRの問い合わせが、同じ周回のうちに漏れて投稿されていた
        (実測で再現された欠陥)。_this_cycle_misses込みで判定すること。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"], query_enabled=True)
        pr1_last_trigger_at = NOW - timedelta(minutes=10)
        state = {
            "heads": {"geolonia/geonicdb-console#1#sha1":
                      {"attempts": 1, "last_trigger_at": pr1_last_trigger_at}},
            "sent_log": [], "query_log": [], "query_incidents": {},
            "trigger_misses": [NOW - timedelta(hours=1)],  # 既に1件(24時間窓内)
        }

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [
                {"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None},
                {"number": 2, "headRefOid": "sha2", "isDraft": False, "createdAt": None},
            ]

        def fake_status(repo, sha, gh_bin="gh", timeout=30):
            return "Review rate limited", NOW  # PR1は今回2件めの外れになる

        decisions = {
            1: {"action": "check", "reason": "budget unknown",
                "command": "@coderabbitai rate limit"},
            2: {"action": "check", "reason": "budget unknown",
                "command": "@coderabbitai rate limit"},
        }
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status", side_effect=fake_status), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        # 核心: PR1(外れを起こした当人)・PR2(ループ内でそれより後)、
        # いずれの問い合わせも同じ周回のうちに投稿されてはならない。
        post_mock.assert_not_called()
        not_posted = [e for e in log_lines if e.get("event") == "query_not_posted"]
        self.assertEqual(len(not_posted), 2)
        for e in not_posted:
            self.assertEqual(e["reason"], "trigger_breaker_open")
        self.assertTrue(state["trigger_breaker_open"])


class Test42TriggerBreakerResetFile(unittest.TestCase):
    """解除は人がstate["heads"]の印を消すか、停止fileと同じ扱いの解除file
    (trigger_breaker_reset_path)を置くことで行う。解除fileは読み捨てて
    消す(一度ぶんの合図として扱う)。★自己レビュー是正: この消費(state書換・
    file削除)自体もdry_runの間は行わない(他の全ての台帳更新と同じ
    流儀)。"""

    def test_reset_file_present_clears_breaker_and_is_consumed(self):
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_breaker_reset_")
        try:
            reset_path = os.path.join(tmpdir, "cr_retrigger.trigger_breaker_reset")
            with open(reset_path, "w", encoding="utf-8") as f:
                f.write("")

            cfg = {"allowlist": [], "budget": {}}
            state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                      "trigger_breaker_open": True,
                      "trigger_misses": [NOW - timedelta(hours=1), NOW - timedelta(minutes=10)]}

            # このtestの主眼はreset「意味論」(stateが変わる・ログが出る・
            # 消費される)であって、project tree封じ込めの可否ではない
            # ——封じ込め自体はTest45で別途固定する。tmpdirは実システムの
            # 一時dirでありproject tree外のため、ここではTrueに固定する。
            with mock.patch.object(cr, "_is_within_project_tree", return_value=True):
                state, log_lines = cr.run(
                    cfg, state, NOW, "/nonexistent/.stop", dry_run=False,
                    trigger_breaker_reset_path=reset_path)

            self.assertFalse(state["trigger_breaker_open"])
            self.assertEqual(state["trigger_misses"], [])
            reset_events = [e for e in log_lines if e.get("event") == "trigger_breaker_reset"]
            self.assertEqual(len(reset_events), 1)
            self.assertTrue(reset_events[0]["had_open_breaker"])
            self.assertEqual(reset_events[0]["cleared_miss_count"], 2)
            self.assertFalse(os.path.exists(reset_path))
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_reset_event_still_logged_when_breaker_already_closed(self):
        """breakerが元々閉じていた場合も、fileが消費された事実は常に
        ログへ残す(自己レビュー是正: 黙って消えると、積み上がりかけていた
        trigger_missesがいつ・なぜ消えたのか誰にも分からなくなる)。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_breaker_reset_noop_")
        try:
            reset_path = os.path.join(tmpdir, "cr_retrigger.trigger_breaker_reset")
            with open(reset_path, "w", encoding="utf-8") as f:
                f.write("")

            cfg = {"allowlist": [], "budget": {}}
            state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

            with mock.patch.object(cr, "_is_within_project_tree", return_value=True):
                state, log_lines = cr.run(
                    cfg, state, NOW, "/nonexistent/.stop", dry_run=False,
                    trigger_breaker_reset_path=reset_path)

            reset_events = [e for e in log_lines if e.get("event") == "trigger_breaker_reset"]
            self.assertEqual(len(reset_events), 1)
            self.assertFalse(reset_events[0]["had_open_breaker"])
            self.assertEqual(reset_events[0]["cleared_miss_count"], 0)
            self.assertFalse(os.path.exists(reset_path))
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_dry_run_does_not_consume_reset_file_or_mutate_state(self):
        """RED→GREEN(自己レビュー是正): main()はdry_runに関わらずstateを無条件で
        保存するため、本番pathを指したまま--dry-runを走らせても、人が
        置いた解除fileを消費せず・breaker/trigger_missesも変えないこと。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_breaker_reset_dryrun_")
        try:
            reset_path = os.path.join(tmpdir, "cr_retrigger.trigger_breaker_reset")
            with open(reset_path, "w", encoding="utf-8") as f:
                f.write("")

            cfg = {"allowlist": [], "budget": {}}
            original_misses = [NOW - timedelta(hours=1), NOW - timedelta(minutes=10)]
            state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                      "trigger_breaker_open": True,
                      "trigger_misses": list(original_misses)}

            with mock.patch.object(cr, "_is_within_project_tree", return_value=True):
                state, log_lines = cr.run(
                    cfg, state, NOW, "/nonexistent/.stop", dry_run=True,
                    trigger_breaker_reset_path=reset_path)

            self.assertTrue(state["trigger_breaker_open"])
            self.assertEqual(state["trigger_misses"], original_misses)
            self.assertTrue(os.path.exists(reset_path))  # 消費されず残る
            would_happen = [
                e for e in log_lines if e.get("event") == "trigger_breaker_reset_would_happen"]
            self.assertEqual(len(would_happen), 1)
            self.assertTrue(would_happen[0]["dry_run"])
            self.assertTrue(would_happen[0]["had_open_breaker"])
            self.assertEqual(
                [e for e in log_lines if e.get("event") == "trigger_breaker_reset"], [])
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_green_reset_allows_triggering_to_resume(self):
        """解除後は、review-nextがreviewを勧めていれば即座に投じを再開する
        (解除fileは恒久停止ではなく、一度ぶんの人の確認の合図であること)。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_breaker_resume_")
        try:
            reset_path = os.path.join(tmpdir, "cr_retrigger.trigger_breaker_reset")
            with open(reset_path, "w", encoding="utf-8") as f:
                f.write("")

            cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
            state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                      "trigger_breaker_open": True, "trigger_misses": [NOW, NOW]}

            def fake_open_prs(repo, gh_bin="gh", timeout=30):
                return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

            decisions = {1: {"action": "review", "reason": "1 review available",
                              "command": "@coderabbitai review"}}
            patches = _patch_cr_decide_wiring(decisions)
            with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
                 mock.patch.object(cr, "_fetch_coderabbit_status",
                                    return_value=("Review paused", NOW)), \
                 mock.patch.object(cr, "post_comment") as post_mock, \
                 mock.patch.object(cr, "_is_within_project_tree", return_value=True), \
                 patches[0], patches[1], patches[2]:
                state, log_lines = cr.run(
                    cfg, state, NOW, "/nonexistent/.stop", dry_run=False,
                    trigger_breaker_reset_path=reset_path)

            self.assertFalse(state["trigger_breaker_open"])
            post_mock.assert_called_once_with(
                "geolonia/geonicdb-console", 1, cr.TRIGGER_BODY, gh_bin="gh")
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_remove_failure_is_logged_not_silently_swallowed(self):
        """自己レビュー是正(5回目): 解除fileの消し損ね(os.remove失敗)を黙殺すると、
        次周回も同じfileが見つかり続け、まだ溜まっていない外れた依頼まで
        毎回刈り取ってbreakerが二度と閾値に達しなくなる——気づける形で
        warnログを残すこと。★さらに、削除が失敗した以上「解除された」とは
        認めず、stateは一切変えない(削除が確かに済んで初めてstateを
        書き換える設計——是正前は先にstateを書き換えてから削除を試みて
        いたため、削除が恒常的に失敗する環境では毎周回trigger_missesが
        無条件にゼロへ刈り取られ続けていた)。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_breaker_reset_removefail_")
        try:
            reset_path = os.path.join(tmpdir, "cr_retrigger.trigger_breaker_reset")
            with open(reset_path, "w", encoding="utf-8") as f:
                f.write("")

            cfg = {"allowlist": [], "budget": {}}
            original_misses = [NOW, NOW]
            state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                      "trigger_breaker_open": True, "trigger_misses": list(original_misses)}

            with mock.patch("os.remove", side_effect=OSError("simulated remove failure")), \
                 mock.patch.object(cr, "_is_within_project_tree", return_value=True):
                state, log_lines = cr.run(
                    cfg, state, NOW, "/nonexistent/.stop", dry_run=False,
                    trigger_breaker_reset_path=reset_path)

            # 核心: 削除が失敗した以上、breaker・misses双方とも変わらない。
            self.assertTrue(state["trigger_breaker_open"])
            self.assertEqual(state["trigger_misses"], original_misses)
            failed = [e for e in log_lines
                      if e.get("event") == "trigger_breaker_reset_file_remove_failed"]
            self.assertEqual(len(failed), 1)
            self.assertEqual(failed[0]["level"], "warn")
            self.assertEqual(
                [e for e in log_lines if e.get("event") == "trigger_breaker_reset"], [])
            self.assertTrue(os.path.exists(reset_path))  # 消せなかった事実のまま残る
        finally:
            import shutil
            shutil.rmtree(tmpdir)


class Test43ReviewedHeadClearsStaleTriggerBookkeeping(unittest.TestCase):
    """自己レビュー是正: headが既にreviewed済みになった後は、古いlast_trigger_at・
    miss_recorded_for_trigger_atを消す。消さずに残すと、何日も後に(人の手や別の呼び手
    による)無関係な再問い合わせが同じheadへrate limitedを返した時、
    とうに成功した古い投げを「外れた」と誤って数えてしまう。"""

    def test_reviewed_status_clears_stale_last_trigger_at(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        old_trigger_at = NOW - timedelta(days=3)
        state = {
            "heads": {"geolonia/geonicdb-console#1#sha1":
                      {"attempts": 1, "last_trigger_at": old_trigger_at,
                       "miss_recorded_for_trigger_at": old_trigger_at}},
            "sent_log": [], "query_log": [], "query_incidents": {},
        }

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review completed", NOW)):
            state, _ = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        head_state = state["heads"]["geolonia/geonicdb-console#1#sha1"]
        self.assertNotIn("last_trigger_at", head_state)
        self.assertNotIn("miss_recorded_for_trigger_at", head_state)

    def test_unrelated_later_rate_limit_on_reviewed_head_is_not_a_miss(self):
        """RED→GREEN: 是正前は、reviewed後に残った古いlast_trigger_atのせいで、
        何日も後の無関係なrate limitedが「外れた依頼」として誤カウントされて
        いた。是正後は2周回(まずreviewedで古い印を消す→次にrate limitedを
        観測)を経ても誤カウントされない。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        old_trigger_at = NOW - timedelta(days=3)
        state = {
            "heads": {"geolonia/geonicdb-console#1#sha1":
                      {"attempts": 1, "last_trigger_at": old_trigger_at,
                       "miss_recorded_for_trigger_at": old_trigger_at}},
            "sent_log": [], "query_log": [], "query_incidents": {},
        }

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        # cycle1: reviewed済みを観測 → 古いlast_trigger_at・miss_recorded_for_trigger_atを消す。
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review completed", NOW)):
            state, _ = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        # cycle2(何日か後、別の呼び手が同じheadへ無関係な再問い合わせをした想定):
        # rate limitedへ戻っても、last_trigger_atが消えているため外れた
        # 依頼としては数えない。
        now2 = NOW + timedelta(days=2)
        decisions = {1: {"action": "wait", "reason": "n/a"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", now2)), \
             mock.patch.object(cr, "post_comment"), \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, now2, "/nonexistent/.stop", dry_run=False)

        self.assertEqual([e for e in log_lines if e.get("event") == "trigger_missed"], [])

    def test_max_attempts_reached_head_also_clears_stale_bookkeeping(self):
        """自己レビュー是正(続): reviewedにならずmax_attempts(3回)へ達した
        headも、cr_retriggerはもう二度と投げ直さない——古いlast_trigger_at
        を残すと、何日も後の無関係なrate limitedを誤って「外れた依頼」と
        数えてしまう(reviewedの場合と同じ病)。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        old_trigger_at = NOW - timedelta(days=3)
        state = {
            "heads": {"geolonia/geonicdb-console#1#sha1":
                      {"attempts": cr.MAX_ATTEMPTS_PER_HEAD, "last_trigger_at": old_trigger_at}},
            "sent_log": [], "query_log": [], "query_incidents": {},
        }

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "wait", "reason": "n/a"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review paused", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             patches[0], patches[1], patches[2]:
            state, _ = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        head_state = state["heads"]["geolonia/geonicdb-console#1#sha1"]
        self.assertNotIn("last_trigger_at", head_state)

        # 何日か後、無関係なrate limitedが同じheadへ現れても数えない。
        now2 = NOW + timedelta(days=2)
        patches2 = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", now2)), \
             mock.patch.object(cr, "post_comment"), \
             patches2[0], patches2[1], patches2[2]:
            state, log_lines = cr.run(cfg, state, now2, "/nonexistent/.stop", dry_run=False)

        self.assertEqual([e for e in log_lines if e.get("event") == "trigger_missed"], [])

    def test_final_attempt_miss_is_recorded_before_stale_bookkeeping_is_cleared(self):
        """RED→GREEN(自己レビュー是正・2回目・最重要): headが既にmax_attempts
        (3回)へ達した周回で、かつ★その周回のCodeRabbit statusがまさに
        rate limitedへ戻っている(=直前に投じた3回めの結果そのもの)時、
        その外れを記録し損ねてはならない。

        ★是正前の順序(古い印消し→外れの検知)だと、この周回の時点で
        attempts_so_far が既に3であるため、古い印消しが外れの検知より
        ★先に走ってlast_trigger_atを消してしまい、最後の(最も確かめ
        たい)投げの外れが永遠に記録されない——trigger_breakerが最も
        壊れた振る舞いを示すheadほど見張れなくなるという、安全弁の趣旨
        そのものに反する欠陥だった。是正後は外れの検知を先に行う。"""
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        last_trigger_at = NOW - timedelta(minutes=10)
        state = {
            "heads": {"geolonia/geonicdb-console#1#sha1":
                      {"attempts": cr.MAX_ATTEMPTS_PER_HEAD, "last_trigger_at": last_trigger_at}},
            "sent_log": [], "query_log": [], "query_incidents": {},
        }

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "wait", "reason": "n/a"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment"), \
             patches[0], patches[1], patches[2]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        # 核心: 同じ周回で、最後の試行の外れが記録され、かつ古い印も
        # (この外れを記録した直後に)消えていること。
        missed = [e for e in log_lines if e.get("event") == "trigger_missed"]
        self.assertEqual(len(missed), 1)
        self.assertEqual(len(state["trigger_misses"]), 1)
        head_state = state["heads"]["geolonia/geonicdb-console#1#sha1"]
        self.assertNotIn("last_trigger_at", head_state)
        self.assertNotIn("miss_recorded_for_trigger_at", head_state)


class Test44StatusSummarySurfacesTriggerBreaker(unittest.TestCase):
    """自己レビュー是正: trigger_missed・trigger_breaker_openは専用欄へ出し、
    warningsの汎用抽出(repo/pr/reason)でnull埋めにして中身を失わない。
    さらに、state["trigger_breaker_open"]は24時間のログwindowを跨いで
    何日も開いたままになりうるため、呼び出し側が渡す現在のstateの値を
    ログの有無と関係なく反映する。"""

    def test_trigger_missed_and_breaker_open_events_get_dedicated_fields(self):
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_status_breaker_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            status_path = os.path.join(tmpdir, "cr_retrigger_status.yaml")
            with open(log_path, "w", encoding="utf-8") as f:
                f.write(json.dumps({
                    "ts": NOW.isoformat(), "repo": "geolonia/geonicdb-console", "pr": 246,
                    "head_sha": "sha1", "event": "trigger_missed", "level": "warn",
                    "reason": "rate_limited_after_trigger",
                }) + "\n")
                f.write(json.dumps({
                    "ts": NOW.isoformat(), "event": "trigger_breaker_open", "level": "warn",
                    "miss_count": 2,
                }) + "\n")
                f.write(json.dumps({"ts": NOW.isoformat(), "event": "cycle",
                                     "runner": "launchd", "run_id": "x", "prs_seen": 1}) + "\n")

            import yaml
            summary = cr._write_status_summary(
                status_path, log_path, NOW, trigger_breaker_open=True)

            self.assertEqual(summary["trigger_missed_count"], 1)
            self.assertEqual(summary["trigger_missed"][0]["repo"], "geolonia/geonicdb-console")
            self.assertEqual(summary["trigger_missed"][0]["pr"], 246)
            self.assertEqual(summary["trigger_breaker_opened_in_window_count"], 1)
            self.assertTrue(summary["trigger_breaker_open"])

            with open(status_path, encoding="utf-8") as f:
                loaded = yaml.safe_load(f)
            self.assertTrue(loaded["trigger_breaker_open"])
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_breaker_open_surfaced_even_when_opened_outside_log_window(self):
        """RED→GREEN: breakerが24時間より前に開いて今も閉じていない場合、
        ログwindow内にtrigger_breaker_openイベントが無くても、現在のstateを
        渡せば要約に「開いたまま」と出ること(ログwindowだけに頼ると見えなく
        なる問題の是正)。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_status_breaker_stale_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            status_path = os.path.join(tmpdir, "cr_retrigger_status.yaml")
            with open(log_path, "w", encoding="utf-8") as f:
                f.write(json.dumps({"ts": NOW.isoformat(), "event": "cycle",
                                     "runner": "launchd", "run_id": "x", "prs_seen": 0}) + "\n")

            summary = cr._write_status_summary(
                status_path, log_path, NOW, trigger_breaker_open=True)

            self.assertEqual(summary["trigger_breaker_opened_in_window_count"], 0)
            self.assertTrue(summary["trigger_breaker_open"])
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_default_trigger_breaker_open_is_false(self):
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_status_breaker_default_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            status_path = os.path.join(tmpdir, "cr_retrigger_status.yaml")
            with open(log_path, "w", encoding="utf-8") as f:
                f.write(json.dumps({"ts": NOW.isoformat(), "event": "cycle",
                                     "runner": "launchd", "run_id": "x", "prs_seen": 0}) + "\n")

            summary = cr._write_status_summary(status_path, log_path, NOW)

            self.assertFalse(summary["trigger_breaker_open"])
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_trigger_missed_and_breaker_open_are_not_double_counted_in_warnings(self):
        """RED→GREEN(自己レビュー是正・6回目): trigger_missed・trigger_breaker_open
        はどちらもlevel="warn"を持つため、専用欄を設けただけでは汎用
        warnings抽出(`level == "warn"`)にも★二重に数えられ、warning_count
        が水増しされ、warningsにnull埋めの重複(repo/pr/reason全てnull)が
        混じっていた——Karo(cmd_861の朝の巡回)が見るwarning_countを
        不正確にする欠陥だった。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_status_nodupe_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            status_path = os.path.join(tmpdir, "cr_retrigger_status.yaml")
            with open(log_path, "w", encoding="utf-8") as f:
                f.write(json.dumps({
                    "ts": NOW.isoformat(), "repo": "geolonia/geonicdb-console", "pr": 246,
                    "head_sha": "sha1", "event": "trigger_missed", "level": "warn",
                    "reason": "rate_limited_after_trigger",
                }) + "\n")
                f.write(json.dumps({
                    "ts": NOW.isoformat(), "event": "trigger_breaker_open", "level": "warn",
                    "miss_count": 2,
                }) + "\n")
                f.write(json.dumps({"ts": NOW.isoformat(), "event": "cycle",
                                     "runner": "launchd", "run_id": "x", "prs_seen": 1}) + "\n")

            summary = cr._write_status_summary(
                status_path, log_path, NOW, trigger_breaker_open=True)

            # 核心: trigger_missed・trigger_breaker_openは専用欄にだけ現れ、
            # 汎用warningsには一切現れない(二重計上されない)。
            self.assertEqual(summary["warning_count"], 0)
            self.assertEqual(summary["warnings"], [])
            self.assertEqual(summary["trigger_missed_count"], 1)
            self.assertEqual(summary["trigger_breaker_opened_in_window_count"], 1)
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_trigger_breaker_operational_failures_get_dedicated_field_not_lost(self):
        """RED→GREEN(自己レビュー是正・6回目): ntfy送信・dashboard書込み・解除
        file削除・封じ込め判定の各失敗イベントは、汎用warnings抽出からは
        除かれる(二重計上防止)が、中身(error・path)を失わない専用欄を
        持つこと。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_status_opfail_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            status_path = os.path.join(tmpdir, "cr_retrigger_status.yaml")
            with open(log_path, "w", encoding="utf-8") as f:
                f.write(json.dumps({
                    "ts": NOW.isoformat(), "event": "trigger_breaker_ntfy_failed",
                    "level": "warn", "error": "simulated ntfy failure",
                }) + "\n")
                f.write(json.dumps({
                    "ts": NOW.isoformat(),
                    "event": "trigger_breaker_reset_file_outside_project_tree",
                    "level": "warn", "path": "/tmp/outside/reset",
                }) + "\n")
                f.write(json.dumps({"ts": NOW.isoformat(), "event": "cycle",
                                     "runner": "launchd", "run_id": "x", "prs_seen": 0}) + "\n")

            summary = cr._write_status_summary(status_path, log_path, NOW)

            self.assertEqual(summary["warning_count"], 0)  # ここに二重計上されない
            self.assertEqual(summary["trigger_breaker_operational_failure_count"], 2)
            errors = {e["event"]: e for e in summary["trigger_breaker_operational_failures"]}
            self.assertEqual(
                errors["trigger_breaker_ntfy_failed"]["error"], "simulated ntfy failure")
            self.assertEqual(
                errors["trigger_breaker_reset_file_outside_project_tree"]["path"],
                "/tmp/outside/reset")
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_unrelated_warning_still_counted_normally(self):
        """回帰確認: trigger_breaker系でない通常のwarnイベント(例:
        no_status_over_2h)は、従来どおりwarningsへ数えられること。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_status_otherwarn_")
        try:
            log_path = os.path.join(tmpdir, "cr_retrigger.jsonl")
            status_path = os.path.join(tmpdir, "cr_retrigger_status.yaml")
            with open(log_path, "w", encoding="utf-8") as f:
                f.write(json.dumps({
                    "ts": NOW.isoformat(), "repo": "geolonia/geonicdb-console", "pr": 1,
                    "category": "no_status", "decision": "skip", "level": "warn",
                    "reason": "no_status_over_2h",
                }) + "\n")
                f.write(json.dumps({"ts": NOW.isoformat(), "event": "cycle",
                                     "runner": "launchd", "run_id": "x", "prs_seen": 1}) + "\n")

            summary = cr._write_status_summary(status_path, log_path, NOW)

            self.assertEqual(summary["warning_count"], 1)
            self.assertEqual(summary["warnings"][0]["reason"], "no_status_over_2h")
        finally:
            import shutil
            shutil.rmtree(tmpdir)


class Test45ResetFileDeletionStaysWithinProjectTree(unittest.TestCase):
    """自己レビュー是正: CLAUDE.md「Destructive Operation Safety」Tier3
    (rm -rf <dir> → project tree内のみ、realpathで確認してから)に倣い、
    解除fileの実削除はproject tree配下への実pathでのみ行う。"""

    def test_is_within_project_tree_accepts_real_default_path(self):
        default_path = os.path.join(
            os.path.dirname(cr.__file__), "..", "logs", "cr_retrigger.trigger_breaker_reset")
        self.assertTrue(cr._is_within_project_tree(default_path))

    def test_is_within_project_tree_rejects_outside_path(self):
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_outside_project_tree_")
        try:
            outside_path = os.path.join(tmpdir, "some_file")
            self.assertFalse(cr._is_within_project_tree(outside_path))
        finally:
            import shutil
            shutil.rmtree(tmpdir)

    def test_reset_file_outside_project_tree_touches_nothing_but_warns(self):
        """RED→GREEN(自己レビュー是正・2回目): project tree外を指す解除fileは、
        os.remove()されないだけでなく、state(trigger_breaker_open・
        trigger_misses)も一切変えない——warnログだけを周回ごとに残す。

        ★是正前の設計(封じ込め判定より先にstateを無条件で書き換えていた)
        には重い欠陥があった: fileが消せない以上、次の周回もまた同じfileが
        見つかり、毎周回stateを無条件に刈り取り続ける——「一度ぶんの合図」
        のはずの解除fileが、消せぬまま永久に効き続ける「壊れたbreakerの
        恒久無効化スイッチ」に変わってしまっていた(自己レビュー指摘)。是正後は
        封じ込め判定で外れと分かった時点で、file・stateいずれにも手を
        付けず安全側(=何もしない)へ倒す。"""
        tmpdir = tempfile.mkdtemp(prefix="cr_retrigger_breaker_reset_outside_")
        try:
            reset_path = os.path.join(tmpdir, "cr_retrigger.trigger_breaker_reset")
            with open(reset_path, "w", encoding="utf-8") as f:
                f.write("")

            cfg = {"allowlist": [], "budget": {}}
            original_misses = [NOW, NOW]
            state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {},
                      "trigger_breaker_open": True, "trigger_misses": list(original_misses)}

            state, log_lines = cr.run(
                cfg, state, NOW, "/nonexistent/.stop", dry_run=False,
                trigger_breaker_reset_path=reset_path)

            # 核心: 封じ込め判定で外れと分かった以上、stateは一切変わらない
            # (削除できぬ以上、解除の意味論そのものを実行してはならない)。
            self.assertTrue(state["trigger_breaker_open"])
            self.assertEqual(state["trigger_misses"], original_misses)
            outside_events = [
                e for e in log_lines
                if e.get("event") == "trigger_breaker_reset_file_outside_project_tree"]
            self.assertEqual(len(outside_events), 1)
            self.assertEqual(outside_events[0]["level"], "warn")
            self.assertEqual(outside_events[0]["path"], reset_path)
            self.assertEqual(
                [e for e in log_lines if e.get("event") == "trigger_breaker_reset"], [])
            self.assertTrue(os.path.exists(reset_path))  # 削除されずに残る

            # 次の周回でも同じ警告が出続ける(人が気づくまで安全側のまま)。
            now2 = NOW + timedelta(minutes=10)
            state, log_lines2 = cr.run(
                cfg, state, now2, "/nonexistent/.stop", dry_run=False,
                trigger_breaker_reset_path=reset_path)
            self.assertTrue(state["trigger_breaker_open"])
            self.assertEqual(state["trigger_misses"], original_misses)
            outside_events2 = [
                e for e in log_lines2
                if e.get("event") == "trigger_breaker_reset_file_outside_project_tree"]
            self.assertEqual(len(outside_events2), 1)
        finally:
            import shutil
            shutil.rmtree(tmpdir)


if __name__ == "__main__":
    unittest.main()
