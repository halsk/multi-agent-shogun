#!/usr/bin/env python3
"""cr_retrigger.py のテスト(cmd_908 T1 + cmd_913)。
実行: python3 -m unittest scripts.test_cr_retrigger -v

設計文書§7の8項目 + 確定版の2項目、計10項目を固定する(SKIP 0)。
★cmd_908 T1やり直し(軍師QC PR#170・head d84d825 = FAIL是正): F1〜F6の
回帰試験をTest11以降に追加する。
★cmd_913: 「決める」部分をcr-decideへ寄せた統合の試験をTest18以降に追加する
(queue/reports/cmd913_crdecide_integration.md §5の5項目・RED→GREEN)。
parse_wait/next_attempt_at/_fetch_latest_wait_notice/_fetch_recent_review_starts
はcr_retrigger.pyから削除したため、これらを直接叩いていた旧試験は削除・
cr-decide経由の等価な試験へ置き換えた。
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
            next_attempt_at=None):
    d = {"repo": repo, "pr": pr, "head_sha": head_sha, "description": description,
         "draft": draft, "allowed": allowed}
    if next_attempt_at is not None:
        d["next_attempt_at"] = next_attempt_at
    return d


def _cr_decide_cfg(allowlist, query_enabled=False, cr_decide_enabled=True):
    return {
        "allowlist": allowlist,
        "budget": {"trigger_per_hour": 10, "trigger_per_day": 10,
                    "query_min_interval_min": 30, "query_per_day": 6},
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
    """§7-3: skippedを投げぬ。"""

    def test_skipped_excluded(self):
        prs = [make_pr(description="Review skipped: draft"),
               make_pr(pr=2, head_sha="sha2", description="Review skipped: WIP title")]
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
    """§7-7: 未知のdescriptionで投げぬ。"""

    def test_unknown_description_classified_and_excluded(self):
        self.assertEqual(cr.classify("Review failed"), "unknown")
        prs = [make_pr(description="Review failed")]
        state = {"heads": {}, "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, prs, budget, NOW)
        self.assertEqual(targets, [])

    def test_empty_description_is_no_status_and_excluded(self):
        self.assertEqual(cr.classify(""), "no_status")
        self.assertEqual(cr.classify(None), "no_status")


class Test8HourlyAndDailyBudgetEnforced(unittest.TestCase):
    """§7-8: 毎時・毎日の予算を超えぬ。"""

    def test_hourly_budget_blocks_second_trigger_within_hour(self):
        prs = [make_pr(), make_pr(pr=2, head_sha="sha2")]
        state = {"heads": {}, "sent_log": [NOW - timedelta(minutes=10)]}
        budget = {"trigger_per_hour": 1, "trigger_per_day": 8}
        targets = cr.select_targets(state, prs, budget, NOW)
        self.assertEqual(targets, [])

    def test_daily_budget_blocks_despite_hourly_room(self):
        prs = [make_pr()]
        sent_log = [NOW - timedelta(hours=h, minutes=1) for h in range(1, 9)]
        state = {"heads": {}, "sent_log": sent_log}
        budget = {"trigger_per_hour": 5, "trigger_per_day": 8}
        targets = cr.select_targets(state, prs, budget, NOW)
        self.assertEqual(targets, [])

    def test_within_budget_allows_trigger(self):
        prs = [make_pr()]
        state = {"heads": {}, "sent_log": []}
        budget = {"trigger_per_hour": 1, "trigger_per_day": 8}
        targets = cr.select_targets(state, prs, budget, NOW)
        self.assertEqual(len(targets), 1)


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


class Test10QueryRespectsRateLimits(unittest.TestCase):
    """確定版§9.2: 問い合わせが「一つの件につき1回だけ」
    「全体30分に1回・1日6回まで」の下限を守る。"""

    def test_first_query_for_incident_allowed(self):
        state = {"query_log": [], "query_incidents": {}}
        cfg = {"query_min_interval_min": 30, "query_per_day": 6}
        self.assertTrue(cr.may_query("incident-1", state, NOW, cfg))

    def test_same_incident_not_queried_twice(self):
        state = {"query_log": [NOW - timedelta(minutes=45)],
                 "query_incidents": {"incident-1": NOW - timedelta(minutes=45)}}
        cfg = {"query_min_interval_min": 30, "query_per_day": 6}
        self.assertFalse(cr.may_query("incident-1", state, NOW, cfg))

    def test_global_thirty_minute_interval_enforced(self):
        state = {"query_log": [NOW - timedelta(minutes=10)], "query_incidents": {}}
        cfg = {"query_min_interval_min": 30, "query_per_day": 6}
        self.assertFalse(cr.may_query("incident-2", state, NOW, cfg))

    def test_thirty_minutes_elapsed_allows_new_incident(self):
        state = {"query_log": [NOW - timedelta(minutes=31)], "query_incidents": {}}
        cfg = {"query_min_interval_min": 30, "query_per_day": 6}
        self.assertTrue(cr.may_query("incident-2", state, NOW, cfg))

    def test_daily_cap_of_six_enforced(self):
        query_log = [NOW - timedelta(hours=h) for h in range(1, 7)]
        state = {"query_log": query_log, "query_incidents": {}}
        cfg = {"query_min_interval_min": 30, "query_per_day": 6}
        self.assertFalse(cr.may_query("incident-new", state, NOW, cfg))


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


class Test13F2ReselectRequiresFreshRateLimit(unittest.TestCase):
    """cmd_908やり直しF2(high): 同じheadへの再投げは、前回の投げの後に
    CodeRabbitが改めてrate limitedを返した時だけ許される。"""

    def test_no_reselect_when_status_unchanged_since_last_trigger(self):
        # 軍師の実測条件の再現: attempts=1・61分前に投げた・statusはそのまま。
        last_trigger_at = NOW - timedelta(minutes=61)
        pr = make_pr(next_attempt_at=NOW - timedelta(minutes=1))
        pr["status_updated_at"] = last_trigger_at - timedelta(minutes=5)
        state = {"heads": {"geolonia/geonicdb-console#1#sha1":
                            {"attempts": 1, "last_trigger_at": last_trigger_at}},
                 "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, [pr], budget, NOW)
        self.assertEqual(targets, [])

    def test_reselect_allowed_when_status_updated_after_trigger(self):
        last_trigger_at = NOW - timedelta(minutes=61)
        pr = make_pr(next_attempt_at=NOW - timedelta(minutes=1))
        pr["status_updated_at"] = last_trigger_at + timedelta(minutes=5)
        state = {"heads": {"geolonia/geonicdb-console#1#sha1":
                            {"attempts": 1, "last_trigger_at": last_trigger_at}},
                 "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, [pr], budget, NOW)
        self.assertEqual(len(targets), 1)

    def test_legacy_state_without_last_trigger_at_is_permissive(self):
        # last_trigger_atを持たぬ旧stateは、既存の3回未満チェックのみで判定する
        # (Test2の既存回帰と整合させる・移行時に壊さない)。
        pr = make_pr()
        state = {"heads": {"geolonia/geonicdb-console#1#sha1": {"attempts": 1}}, "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, [pr], budget, NOW)
        self.assertEqual(len(targets), 1)


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


class Test17F6HeadRecentPushAndWarnings(unittest.TestCase):
    """cmd_908やり直しF6(low): §3.3のheadが変わったPRは待つ・未知description・
    2時間status無しの警告。"""

    def test_head_pushed_within_10min_is_not_reselected(self):
        pr = make_pr()
        pr["head_pushed_at"] = NOW - timedelta(minutes=3)
        state = {"heads": {}, "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, [pr], budget, NOW)
        self.assertEqual(targets, [])
        self.assertEqual(cr._decision_reason(pr, state, NOW), "head_recent_push")

    def test_head_pushed_over_10min_ago_is_eligible(self):
        pr = make_pr()
        pr["head_pushed_at"] = NOW - timedelta(minutes=15)
        state = {"heads": {}, "sent_log": []}
        budget = {"trigger_per_hour": 10, "trigger_per_day": 10}
        targets = cr.select_targets(state, [pr], budget, NOW)
        self.assertEqual(len(targets), 1)

    def test_unknown_description_logged_as_warning(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review failed", NOW)):
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
        mock.patch.object(cr, "_fetch_commit_pushed_at", return_value=None),
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
             patches[0], patches[1], patches[2], patches[3]:
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
             patches[0], patches[1], patches[2], patches[3]:
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
             patches[0], patches[1], patches[2], patches[3]:
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
             patches[0], patches[1], patches[2], patches[3]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        observed = [e for e in log_lines if e.get("event") == "cr_decide_observed_not_posted"]
        self.assertEqual(len(observed), 1)
        self.assertEqual(observed[0]["command"], "@coderabbitai review --use-credits")


class Test22CrDecideCheckThrottledByLedger(unittest.TestCase):
    """RED→GREEN①: cr-decideの答えがcheckでも、台帳(may_query・30分に1回)が
    抑える(cr-decide自身は走りごとの記憶を持たないため)。"""

    def test_second_check_within_30min_is_not_posted(self):
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
             patches[0], patches[1], patches[2], patches[3]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        # 台帳の30分に1回の下限により、2件目は投じられない(1件目のみ)。
        self.assertEqual(post_mock.call_count, 1)
        post_mock.assert_called_once_with(
            "geolonia/geonicdb-console", 1, cr.QUERY_BODY, gh_bin="gh")
        not_posted = [e for e in log_lines if e.get("event") == "query_not_posted"]
        self.assertEqual(len(not_posted), 1)
        self.assertEqual(not_posted[0]["pr"], 2)

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
             patches[0], patches[1], patches[2], patches[3]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        self.assertEqual(state.get("query_incidents", {}), {})


class Test23CrDecidePausedVsSkippedRouting(unittest.TestCase):
    """RED→GREEN⑤: 「見つける」でcr-decideへ渡すのはrate_limited・pausedのみ。
    skipped(意図したskip)は渡さない(既存動作を変えない)。"""

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
             patches[0], patches[1] as ensure_clone_mock, patches[2] as call_mock, patches[3]:
            cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        call_mock.assert_called_once()
        ensure_clone_mock.assert_called()

    def test_skipped_never_calls_cr_decide(self):
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"])
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        patches = _patch_cr_decide_wiring({})
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review skipped: draft", NOW)), \
             patches[0] as tool_mock, patches[1] as ensure_clone_mock, \
             patches[2] as call_mock, patches[3]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        call_mock.assert_not_called()
        ensure_clone_mock.assert_not_called()
        tool_mock.assert_not_called()
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
             mock.patch.object(cr, "_fetch_commit_pushed_at", return_value=None), \
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
             patches1[0], patches1[1], patches1[2], patches1[3]:
            state, log_lines1 = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock1.assert_called_once_with(
            "geolonia/geonicdb-console", 1, cr.QUERY_BODY, gh_bin="gh")
        self.assertIn("geolonia/geonicdb-console#1#sha1#check", state["query_incidents"])

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
             patches2[0], patches2[1], patches2[2], patches2[3]:
            state, log_lines2 = cr.run(cfg, state, now2, "/nonexistent/.stop", dry_run=False)

        post_mock2.assert_called_once_with(
            "geolonia/geonicdb-console", 1, cr.TRIGGER_BODY, gh_bin="gh")

    def test_second_incident_query_within_30min_stays_throttled_by_ledger(self):
        # X1の下限(design §9.2)がquery.enabled=true下でも守られることの回帰
        # (Test22と同型だが、query_enabled=trueが既定になった後の固定として
        # ここにも残す)。
        cfg = _cr_decide_cfg(["geolonia/geonicdb-console"], query_enabled=True)
        state = {"heads": {}, "sent_log": [], "query_log": [NOW - timedelta(minutes=5)],
                  "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        decisions = {1: {"action": "check", "reason": "budget unknown",
                          "command": "@coderabbitai rate limit"}}
        patches = _patch_cr_decide_wiring(decisions)
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "post_comment") as post_mock, \
             patches[0], patches[1], patches[2], patches[3]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        not_posted = [e for e in log_lines if e.get("event") == "query_not_posted"]
        self.assertEqual(len(not_posted), 1)


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
             patches[0], patches[1], patches[2], patches[3]:
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
             patches[0], patches[1], patches[2], patches[3]:
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
             patches[0], patches[1], patches[2], patches[3]:
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
             patches1[0], patches1[1], patches1[2], patches1[3]:
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
             patches2[0], patches2[1], patches2[2], patches2[3]:
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
             patches[0], patches[1], patches[2], patches[3]:
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
             patches[0], patches[1], patches[2], patches[3]:
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

    def test_main_ci_status_reads_state_field(self):
        with mock.patch.object(cr, "_gh_json", return_value={"state": "failure"}):
            self.assertEqual(cr._fetch_main_ci_status("geolonia/geonicdb-console"), "failure")

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
             patches[0], patches[1], patches[2], patches[3]:
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
             patches1[0], patches1[1], patches1[2], patches1[3]:
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
             patches2[0], patches2[1], patches2[2], patches2[3]:
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
             patches[0], patches[1], patches[2], patches[3]:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        body = ntfy_mock.call_args.args[0]
        self.assertIn("[P1]", body)
        self.assertIn("[P2]", body)
        self.assertIn("はい P1", body)
        self.assertIn("いいえ", body)

        sent_lines = [e for e in log_lines if e.get("event") == "pay_ntfy_sent"]
        self.assertEqual(len(sent_lines), 1)
        self.assertEqual(sent_lines[0]["labels"]["P1"],
                          {"repo": "geolonia/geonicdb-console", "pr": 1, "head_sha": "sha1"})
        self.assertEqual(sent_lines[0]["labels"]["P2"],
                          {"repo": "geolonia/geonicdb-console", "pr": 2, "head_sha": "sha2"})
        self.assertEqual(state["pay_ntfy_labels"]["P1"]["pr"], 1)
        self.assertEqual(state["pay_ntfy_labels"]["P2"]["pr"], 2)

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
             patches[0], patches[1], patches[2], patches[3]:
            cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        body = ntfy_mock.call_args.args[0]
        self.assertIn("[P1]", body)
        self.assertIn("全て払うなら「はい」", body)


if __name__ == "__main__":
    unittest.main()
