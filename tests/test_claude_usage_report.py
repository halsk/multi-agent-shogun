#!/usr/bin/env python3
"""claude_usage_report.py のテスト。実行: python3 -m unittest tests.test_claude_usage_report -v"""
import io, json, os, sys, tempfile, unittest
from contextlib import redirect_stdout

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
import claude_usage_report as cur


def rec(req_id, usage=None, sidechain=False, model="claude-sonnet-5",
        session="s1", cwd="/repo/a", branch="main", effort="high", content="hello"):
    u = {"input_tokens": 10, "output_tokens": 20,
         "cache_read_input_tokens": 900, "cache_creation_input_tokens": 100,
         "cache_creation": {"ephemeral_1h_input_tokens": 96, "ephemeral_5m_input_tokens": 4},
         "server_tool_use": {"web_search_requests": 1, "web_fetch_requests": 0},
         "speed": "standard", "service_tier": "standard"}
    if usage is not None:
        u.update(usage)
    return json.dumps({
        "requestId": req_id, "sessionId": session, "isSidechain": sidechain,
        "cwd": cwd, "gitBranch": branch, "effort": effort,
        "timestamp": "2026-08-24T00:00:00.000Z",
        "message": {"role": "assistant", "model": model, "usage": u,
                    "content": [{"type": "text", "text": content}]},
    })


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = os.path.join(self.tmp.name, "projects", "p1")
        os.makedirs(self.dir)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, lines):
        with open(os.path.join(self.dir, name), "w", encoding="utf-8") as f:
            f.write("\n".join(lines) + "\n")

    def run_main(self, *extra):
        json_path = os.path.join(self.tmp.name, "out.json")
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cur.main(["--dir", self.tmp.name, "--json", json_path, *extra])
        data = None
        if os.path.exists(json_path):
            with open(json_path, encoding="utf-8") as f:
                data = json.load(f)
        return rc, buf.getvalue(), data


class TestAggregation(Base):
    def test_minimal_expected_counts(self):
        self.write("a.jsonl", [rec("r1"), rec("r2", session="s2")])
        rc, out, data = self.run_main()
        self.assertEqual(rc, 0)
        self.assertEqual(data["requests"], 2)
        self.assertEqual(data["sessions"], 2)
        self.assertEqual(data["totals"]["input_tokens"], 20)
        self.assertEqual(data["totals"]["output_tokens"], 40)
        self.assertEqual(data["totals"]["cache_read_input_tokens"], 1800)
        self.assertEqual(data["totals"]["cache_1h"], 192)
        self.assertEqual(data["totals"]["cache_5m"], 8)
        self.assertEqual(data["totals"]["web_search"], 2)
        self.assertEqual(data["by_model"]["claude-sonnet-5"]["requests"], 2)
        self.assertEqual(data["by_repo"]["/repo/a"]["branches"]["main"]["requests"], 2)
        self.assertAlmostEqual(data["rates"]["cache_read_rate"], 0.9, places=3)

    def test_broken_lines_do_not_crash(self):
        self.write("a.jsonl", ["{not json", rec("r1"), '"just a string"', "{\"半端"])
        rc, out, data = self.run_main()
        self.assertEqual(rc, 0)
        self.assertEqual(data["requests"], 1)
        self.assertGreaterEqual(data["parse_errors"], 2)

    def test_rows_without_usage_ignored(self):
        user_row = json.dumps({"type": "user", "sessionId": "s1",
                               "message": {"role": "user", "content": "question"}})
        self.write("a.jsonl", [user_row, rec("r1")])
        rc, out, data = self.run_main()
        self.assertEqual(data["requests"], 1)

    def test_sidechain_separation(self):
        self.write("a.jsonl", [rec("r1"), rec("r2", sidechain=True), rec("r3", sidechain=True)])
        rc, out, data = self.run_main()
        self.assertEqual(data["sidechain"]["main"]["requests"], 1)
        self.assertEqual(data["sidechain"]["sidechain"]["requests"], 2)

    def test_duplicate_request_rows_counted_once(self):
        self.write("a.jsonl", [rec("r1"), rec("r1"), rec("r1"), rec("r2")])
        rc, out, data = self.run_main()
        self.assertEqual(data["requests"], 2)
        self.assertEqual(data["duplicate_rows_skipped"], 2)
        self.assertEqual(data["totals"]["output_tokens"], 40)
        rc, out, raw = self.run_main("--raw")
        self.assertEqual(raw["requests"], 4)
        self.assertEqual(raw["totals"]["output_tokens"], 80)

    def test_missing_dir_exits_cleanly(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = cur.main(["--dir", os.path.join(self.tmp.name, "nope"), "--json", "-"])
        self.assertEqual(rc, 0)


class TestPrivacy(Base):
    def test_conversation_text_never_appears_in_output(self):
        secret = "SECRET_PROMPT_TEXT_do_not_leak"
        self.write("a.jsonl", [rec("r1", content=secret)])
        rc, out, data = self.run_main()
        combined = out + json.dumps(data, ensure_ascii=False)
        self.assertNotIn(secret, combined)

    def test_extract_reads_only_allowed_fields(self):
        row = cur.extract(json.loads(rec("r1", content="conversation body")))
        self.assertNotIn("content", json.dumps(row))
        self.assertEqual(set(row) & {"content", "toolUseResult", "lastPrompt"}, set())


class TestWarnings(Base):
    def test_low_cache_read_rate_warns(self):
        self.write("a.jsonl", [rec("r1", usage={"cache_read_input_tokens": 100,
                                                "cache_creation_input_tokens": 900})])
        rc, out, data = self.run_main()
        self.assertIn("low_cache_read_rate", [w["code"] for w in data["warnings"]])

    def test_fast_mode_share_warns(self):
        self.write("a.jsonl", [rec("r1", usage={"speed": "fast"})])
        rc, out, data = self.run_main()
        self.assertIn("high_fast_mode_share", [w["code"] for w in data["warnings"]])

    def test_5m_ttl_share_warns(self):
        self.write("a.jsonl", [rec("r1", usage={"cache_creation": {
            "ephemeral_1h_input_tokens": 10, "ephemeral_5m_input_tokens": 90}})])
        rc, out, data = self.run_main()
        self.assertIn("high_5m_ttl_share", [w["code"] for w in data["warnings"]])

    def test_efficient_usage_no_warnings(self):
        self.write("a.jsonl", [rec("r1")])
        rc, out, data = self.run_main()
        self.assertEqual(data["warnings"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
