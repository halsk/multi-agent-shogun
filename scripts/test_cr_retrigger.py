#!/usr/bin/env python3
"""cr_retrigger.py のテスト(cmd_908 T1)。実行: python3 -m unittest scripts.test_cr_retrigger -v

設計文書§7の8項目 + 確定版の2項目、計10項目を固定する(SKIP 0)。
"""
import os
import sys
import unittest
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


if __name__ == "__main__":
    unittest.main()
