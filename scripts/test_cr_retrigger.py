#!/usr/bin/env python3
"""cr_retrigger.py のテスト(cmd_908 T1)。実行: python3 -m unittest scripts.test_cr_retrigger -v

設計文書§7の8項目 + 確定版の2項目、計10項目を固定する(SKIP 0)。
★cmd_908 T1やり直し(軍師QC PR#170・head d84d825 = FAIL是正): F1〜F6の
回帰試験をTest11以降に追加する。
"""
import json
import os
import stat
import sys
import tempfile
import unittest
import unittest.mock as mock
from datetime import datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(__file__))
import cr_retrigger as cr

NOW = datetime(2026, 9, 28, 12, 0, 0, tzinfo=timezone.utc)


def _write_fake_gh(script_body):
    """偽のgh実行ファイルを一時ファイルに書き出し、パスを返す(呼び出し側がcleanupする)。"""
    fd, path = tempfile.mkstemp(prefix="fake_gh_", suffix=".sh")
    with os.fdopen(fd, "w") as f:
        f.write(script_body)
    st = os.stat(path)
    os.chmod(path, st.st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return path


# F1: 実際のgh api挙動を模す偽gh。-fに--method GETを伴わずissueコメントの
# エンドポイントへ来た場合、実物同様「bodyフィールドが無い」422で落ちる
# (gunshiの実測: CalledProcessErrorでrun()ごと落ちた、と同型の再現)。
FAKE_GH_F1 = """#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"issues/"*"/comments"* ]]; then
  if [[ "$args" == *"--method GET"* ]]; then
    echo "[]"
    exit 0
  fi
  echo "gh: HTTP 422: Validation Failed (body is missing)" >&2
  exit 1
fi
echo "[]"
exit 0
"""


def make_pr(repo="geolonia/geonicdb-console", pr=1, head_sha="sha1",
            description="Review rate limited", draft=False, allowed=True,
            next_attempt_at=None):
    d = {"repo": repo, "pr": pr, "head_sha": head_sha, "description": description,
         "draft": draft, "allowed": allowed}
    if next_attempt_at is not None:
        d["next_attempt_at"] = next_attempt_at
    return d


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


class Test6UnreadableWaitFallsBackToSixtyMinutes(unittest.TestCase):
    """§7-6: 待ち時間の読めぬ通知で60分の退きに倒れる。"""

    def test_no_wait_no_recent_reviews_falls_back_to_now_plus_60(self):
        result = cr.next_attempt_at({}, NOW, mode="window")
        self.assertEqual(result, NOW + timedelta(minutes=60))

    def test_unparsable_notice_body_yields_none_then_fallback(self):
        parsed = cr.parse_wait("CodeRabbit will let you know when it's ready.")
        self.assertIsNone(parsed)
        result = cr.next_attempt_at(
            {"notice_updated_at": NOW, "notice_wait_minutes": parsed}, NOW, mode="window")
        self.assertEqual(result, NOW + timedelta(minutes=60))

    def test_window_fallback_uses_oldest_recent_review(self):
        oldest = NOW - timedelta(minutes=40)
        result = cr.next_attempt_at(
            {"recent_review_starts": [oldest, NOW - timedelta(minutes=10)]}, NOW, mode="window")
        self.assertEqual(result, oldest + timedelta(minutes=62))

    def test_readable_wait_is_used_directly(self):
        parsed = cr.parse_wait("Or wait 4 minutes for your next included review.")
        self.assertAlmostEqual(parsed, 4.0)
        result = cr.next_attempt_at(
            {"notice_updated_at": NOW, "notice_wait_minutes": parsed}, NOW, mode="window")
        self.assertEqual(result, NOW + timedelta(minutes=6))

    def test_readable_wait_with_seconds(self):
        parsed = cr.parse_wait("wait **44 minutes and 12 seconds**")
        self.assertAlmostEqual(parsed, 44 + 12 / 60)


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

        import unittest.mock as mock
        with mock.patch("subprocess.run", side_effect=fake_run):
            with self.assertRaises(ValueError):
                cr.post_comment("geolonia/geonicdb-console", 1, "こちらで直してください")
        self.assertEqual(called, [])

    def test_post_comment_accepts_trigger_body(self):
        import unittest.mock as mock
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


class Test11F1MethodGetFixed(unittest.TestCase):
    """cmd_908やり直しF1(critical): gh api呼び出し(post_comment以外)は
    全て--method GETであることを固定する。RED対照: queue/reports/
    gunshi_report_cmd908_t1.yamlのhead(d84d825)のコードは、本テストと同じ
    偽ghに対しCalledProcessErrorで落ちることを別途確認済み(是正前後の
    比較はワークツリー外の一時コピーで実施・詳細は作業ログ)。"""

    def setUp(self):
        self.fake_gh = _write_fake_gh(FAKE_GH_F1)

    def tearDown(self):
        os.remove(self.fake_gh)

    def test_fetch_latest_wait_notice_survives_real_gh_post_semantics(self):
        # 偽ghは--method GET無しの-f呼び出しを実物同様422相当で落とす。
        # 是正後は例外を投げず(None, None)を返す。
        result = cr._fetch_latest_wait_notice(
            "geolonia/geonicdb-console", 1, gh_bin=self.fake_gh)
        self.assertEqual(result, (None, None))

    def test_comments_endpoint_always_called_with_method_get(self):
        calls = []

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            result = mock.Mock()
            result.stdout = "[]"
            return result

        with mock.patch("subprocess.run", side_effect=fake_run):
            cr._fetch_latest_wait_notice("geolonia/geonicdb-console", 1)

        comment_calls = [c for c in calls if "comments" in " ".join(str(x) for x in c)]
        self.assertTrue(comment_calls, "commentsエンドポイントへの呼び出しが無い")
        for call in comment_calls:
            self.assertIn("--method", call)
            idx = call.index("--method")
            self.assertEqual(call[idx + 1], "GET")


class Test12F1PerPrFailureIsolation(unittest.TestCase):
    """cmd_908やり直しF1: PRごとの取得失敗はcatchしてlogに記し、
    次のPRへ進む(run()全体を落とさない)。"""

    def test_one_pr_status_fetch_failure_does_not_abort_other_prs(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "budget": {}, "fallback_mode": "window"}
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
             mock.patch.object(cr, "_fetch_coderabbit_status", side_effect=fake_status), \
             mock.patch.object(cr, "_fetch_recent_review_starts", return_value=[]):
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


class Test14F2StaleNoticeFiltered(unittest.TestCase):
    """cmd_908やり直しF2: 通知のコメントはstatusのupdated_at以後のものだけ使う
    (古い別件の通知を拾わない)。"""

    def test_notice_older_than_min_updated_at_is_ignored(self):
        calls = []

        def fake_run(cmd, **kwargs):
            calls.append(cmd)
            result = mock.Mock()
            old_comment = {
                "user": {"login": "coderabbitai[bot]"},
                "body": "Or wait 4 minutes for your next included review.",
                "updated_at": (NOW - timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
            result.stdout = json.dumps([old_comment])
            return result

        min_updated_at = NOW - timedelta(minutes=30)
        with mock.patch("subprocess.run", side_effect=fake_run):
            result = cr._fetch_latest_wait_notice(
                "geolonia/geonicdb-console", 1, min_updated_at=min_updated_at)
        self.assertEqual(result, (None, None))

    def test_notice_after_min_updated_at_is_used(self):
        def fake_run(cmd, **kwargs):
            result = mock.Mock()
            fresh_comment = {
                "user": {"login": "coderabbitai[bot]"},
                "body": "Or wait 4 minutes for your next included review.",
                "updated_at": NOW.strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
            result.stdout = json.dumps([fresh_comment])
            return result

        min_updated_at = NOW - timedelta(minutes=30)
        with mock.patch("subprocess.run", side_effect=fake_run):
            dt, wait = cr._fetch_latest_wait_notice(
                "geolonia/geonicdb-console", 1, min_updated_at=min_updated_at)
        self.assertAlmostEqual(wait, 4.0)
        self.assertEqual(dt, NOW)


class Test15F3LoggingAndStatusSummary(unittest.TestCase):
    """cmd_908やり直しF3: 周回ごと・PRごとのlog行とqueue/reports/
    cr_retrigger_status.yamlの出力(T2完了条件・cmd_861の朝に分かること)。"""

    def test_cycle_line_carries_runner_run_id_and_pr_count(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "budget": {}, "fallback_mode": "window"}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review completed", NOW)), \
             mock.patch.object(cr, "_fetch_recent_review_starts", return_value=[]):
            state, log_lines = cr.run(
                cfg, state, NOW, "/nonexistent/.stop", dry_run=True,
                run_id="20260928T120000Z-123", runner="launchd")

        cycle_lines = [e for e in log_lines if e.get("event") == "cycle"]
        self.assertEqual(len(cycle_lines), 1)
        self.assertEqual(cycle_lines[0]["runner"], "launchd")
        self.assertEqual(cycle_lines[0]["run_id"], "20260928T120000Z-123")
        self.assertEqual(cycle_lines[0]["prs_seen"], 1)

    def test_per_pr_decision_line_present(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "budget": {}, "fallback_mode": "window"}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review completed", NOW)), \
             mock.patch.object(cr, "_fetch_recent_review_starts", return_value=[]):
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


class Test16F4QueryAndRecentReviewStartsWired(unittest.TestCase):
    """cmd_908やり直しF4(medium・家老裁可=実装せよ): query.enabled/
    query_policy/may_query/recent_review_startsが実際にrun()から呼ばれ機能する。"""

    def test_query_posted_when_enabled_and_notice_unreadable(self):
        cfg = {
            "allowlist": ["geolonia/geonicdb-console"], "fallback_mode": "window",
            "budget": {"query_min_interval_min": 30, "query_per_day": 6},
            "query": {"enabled": True}, "query_policy": "before_computed",
        }
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "_fetch_latest_wait_notice", return_value=(None, None)), \
             mock.patch.object(cr, "_fetch_recent_review_starts", return_value=[]), \
             mock.patch.object(cr, "_fetch_commit_pushed_at", return_value=None), \
             mock.patch.object(cr, "post_comment") as post_mock:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_called_once_with(
            "geolonia/geonicdb-console", 1, cr.QUERY_BODY, gh_bin="gh")
        self.assertEqual(len(state["query_incidents"]), 1)
        query_events = [e for e in log_lines if e.get("event") == "query_posted"]
        self.assertEqual(len(query_events), 1)

    def test_query_not_posted_when_disabled(self):
        cfg = {
            "allowlist": ["geolonia/geonicdb-console"], "fallback_mode": "window",
            "budget": {"query_min_interval_min": 30, "query_per_day": 6},
            "query": {"enabled": False}, "query_policy": "before_computed",
        }
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", NOW)), \
             mock.patch.object(cr, "_fetch_latest_wait_notice", return_value=(None, None)), \
             mock.patch.object(cr, "_fetch_recent_review_starts", return_value=[]), \
             mock.patch.object(cr, "_fetch_commit_pushed_at", return_value=None), \
             mock.patch.object(cr, "post_comment") as post_mock:
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=False)

        post_mock.assert_not_called()
        self.assertEqual(state.get("query_incidents", {}), {})

    def test_recent_review_starts_fetched_and_passed_to_fallback(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "fallback_mode": "window", "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        recent = [NOW - timedelta(minutes=65)]  # oldest+62分 <= now → 候補になる
        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review rate limited", None)), \
             mock.patch.object(cr, "_fetch_latest_wait_notice", return_value=(None, None)), \
             mock.patch.object(cr, "_fetch_recent_review_starts",
                                return_value=recent) as recent_mock, \
             mock.patch.object(cr, "_fetch_commit_pushed_at", return_value=None):
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        recent_mock.assert_called_once()
        pr_line = [e for e in log_lines if e.get("pr") == 1 and "decision" in e][0]
        self.assertEqual(pr_line["decision"], "candidate")


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
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "fallback_mode": "window", "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": None}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status",
                                return_value=("Review failed", NOW)), \
             mock.patch.object(cr, "_fetch_recent_review_starts", return_value=[]):
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        warn_lines = [e for e in log_lines if e.get("level") == "warn" and e.get("pr") == 1]
        self.assertEqual(len(warn_lines), 1)
        self.assertEqual(warn_lines[0]["category"], "unknown")

    def test_no_status_over_2h_logged_as_warning(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "fallback_mode": "window", "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}
        created_at = (NOW - timedelta(hours=3)).strftime("%Y-%m-%dT%H:%M:%SZ")

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": created_at}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status", return_value=(None, None)), \
             mock.patch.object(cr, "_fetch_recent_review_starts", return_value=[]):
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        warn_lines = [e for e in log_lines if e.get("level") == "warn" and e.get("pr") == 1]
        self.assertEqual(len(warn_lines), 1)
        self.assertEqual(warn_lines[0]["reason"], "no_status_over_2h")

    def test_no_status_under_2h_not_warned(self):
        cfg = {"allowlist": ["geolonia/geonicdb-console"], "fallback_mode": "window", "budget": {}}
        state = {"heads": {}, "sent_log": [], "query_log": [], "query_incidents": {}}
        created_at = (NOW - timedelta(minutes=30)).strftime("%Y-%m-%dT%H:%M:%SZ")

        def fake_open_prs(repo, gh_bin="gh", timeout=30):
            return [{"number": 1, "headRefOid": "sha1", "isDraft": False, "createdAt": created_at}]

        with mock.patch.object(cr, "_fetch_open_prs", side_effect=fake_open_prs), \
             mock.patch.object(cr, "_fetch_coderabbit_status", return_value=(None, None)), \
             mock.patch.object(cr, "_fetch_recent_review_starts", return_value=[]):
            state, log_lines = cr.run(cfg, state, NOW, "/nonexistent/.stop", dry_run=True)

        warn_lines = [e for e in log_lines if e.get("level") == "warn"]
        self.assertEqual(warn_lines, [])


if __name__ == "__main__":
    unittest.main()
