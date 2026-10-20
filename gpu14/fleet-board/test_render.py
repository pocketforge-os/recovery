#!/usr/bin/env python3
"""Hermetic tests for the fleet board's runner-fleet section (tsp-73epc.2.2.2).

render.render_runner_fleet() runs pf-runner-fleet-status.py `board` on status.json. Two layers:
- StubTool (always, CI): the tool is a canned-output script written here and named by path (FB_RUNNER_FLEET_TOOL;
  never on PATH, it execs nothing). It proves the generator's own guarantees: the status path override reaches the
  tool, a tool failure renders stale, and a missing or old status.json renders stale even when the tool says ok.
- RealTool (when the installed tool is present, else skipped): ok, ALARM with each finding's level/kind/key/age,
  stale (old checked_at) and missing, end to end through the real `board` renderer.
Run: python3 -B gpu14/fleet-board/test_render.py
"""
import json
import os
import sys
import tempfile
import time
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_TMP = tempfile.mkdtemp(prefix="fb-render-test-")
os.environ["FB_BOARD_DIR"] = _TMP
os.environ["FB_RUNNER_FLEET_STATUS"] = os.path.join(_TMP, "absent-status.json")
sys.path.insert(0, _HERE)
import render  # noqa: E402

SCHEMA = "pocketforge.runner_fleet_status/v1"
REAL_TOOL = os.environ.get("FB_TEST_RUNNER_FLEET_TOOL") or os.path.expanduser(
    "~/.local/libexec/pf-runner-fleet-status/pf-runner-fleet-status.py")
ALARM_FINDING = {"level": "ALARM", "kind": "stall", "key": "build-1/ci-class-a", "age_seconds": 5400,
                 "detail": "runner slot idle with jobs queued"}


def write_status(path, age_s, fleet_status="ok", findings=(), notify="none"):
    with open(path, "w") as f:
        json.dump({"schema": SCHEMA, "checked_at": time.time() - age_s, "fleet_status": fleet_status,
                   "findings": list(findings), "hosts": {}, "notify": notify}, f)


class Base(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(dir=_TMP)
        self.status = os.path.join(self.dir, "status.json")
        self.saved = (render.RUNNER_FLEET_TOOL, render.RUNNER_FLEET_STATUS)
        render.RUNNER_FLEET_STATUS = self.status

    def tearDown(self):
        render.RUNNER_FLEET_TOOL, render.RUNNER_FLEET_STATUS = self.saved


class StubTool(Base):
    def stub(self, out, rc=0):
        """A canned-output tool: records its argv and prints `out`; it runs nothing else."""
        tool = os.path.join(self.dir, "stub-tool.py")
        self.argv_file = os.path.join(self.dir, "argv.json")
        with open(tool, "w") as f:
            f.write("import json, sys\n"
                    f"json.dump(sys.argv[1:], open({self.argv_file!r}, 'w'))\n"
                    f"sys.stdout.write({out!r})\n"
                    f"sys.exit({rc})\n")
        render.RUNNER_FLEET_TOOL = tool

    OK = json.dumps({"level": "ok", "count": 0, "note": "checked 1m ago", "body": "<p>fleet ok</p>"})

    def test_status_override_reaches_the_tool(self):
        self.stub(self.OK)
        write_status(self.status, 60)
        render.render_runner_fleet()
        with open(self.argv_file) as f:
            argv = json.load(f)
        self.assertEqual(argv[:1], ["board"])
        self.assertEqual(argv[argv.index("--status") + 1], self.status)

    def test_fresh_ok_renders_ok(self):
        self.stub(self.OK)
        write_status(self.status, 60)
        body, count, level, note = render.render_runner_fleet()
        self.assertEqual((level, count), ("ok", 0))
        self.assertIn("fleet ok", body)

    def test_alarm_passes_through(self):
        out = json.dumps({"level": "ALARM", "count": 1, "note": "checked 1m ago", "body": "<td>build-1/ci-class-a</td>"})
        self.stub(out)
        write_status(self.status, 60, "ALARM", [ALARM_FINDING])
        body, count, level, note = render.render_runner_fleet()
        self.assertEqual((level, count), ("ALARM", 1))
        self.assertIn("build-1/ci-class-a", body)

    def test_old_status_is_stale_even_if_tool_says_ok(self):
        self.stub(self.OK)
        write_status(self.status, 3 * 3600)
        body, count, level, note = render.render_runner_fleet()
        self.assertEqual(level, "stale")
        self.assertIn("stale", note)
        self.assertIn("fleet ok", body)   # the last result still shows, under a stale banner

    def test_missing_status_is_stale_even_if_tool_says_ok(self):
        self.stub(self.OK)
        body, count, level, note = render.render_runner_fleet()
        self.assertEqual(level, "stale")

    def test_unreadable_status_is_stale(self):
        self.stub(self.OK)
        with open(self.status, "w") as f:
            f.write("{not json")
        self.assertEqual(render.render_runner_fleet()[2], "stale")

    def test_tool_failure_is_stale(self):
        self.stub("garbage", rc=2)
        write_status(self.status, 60)
        body, count, level, note = render.render_runner_fleet()
        self.assertEqual(level, "stale")
        self.assertIn("unavailable", body)

    def test_nonzero_exit_with_valid_result_is_stale(self):
        for lvl in ("ok", "ALARM"):
            self.stub(json.dumps({"level": lvl, "count": 0, "note": "n", "body": "<p>b</p>"}), rc=1)
            write_status(self.status, 60)
            body, count, level, note = render.render_runner_fleet()
            self.assertEqual(level, "stale", lvl)
            self.assertIn("unavailable", body)

    def test_missing_tool_is_stale(self):
        render.RUNNER_FLEET_TOOL = os.path.join(self.dir, "no-such-tool.py")
        write_status(self.status, 60)
        self.assertEqual(render.render_runner_fleet()[2], "stale")


@unittest.skipUnless(os.path.isfile(REAL_TOOL), f"pf-runner-fleet-status.py not installed at {REAL_TOOL}")
class RealTool(Base):
    def setUp(self):
        super().setUp()
        render.RUNNER_FLEET_TOOL = REAL_TOOL

    def test_ok(self):
        write_status(self.status, 60)
        body, count, level, note = render.render_runner_fleet()
        self.assertEqual((level, count), ("ok", 0))
        self.assertIn("No findings", body)

    def test_alarm_shows_level_kind_key_age(self):
        write_status(self.status, 60, "ALARM", [ALARM_FINDING], notify="sent")
        body, count, level, note = render.render_runner_fleet()
        self.assertEqual((level, count), ("ALARM", 1))
        for cell in ("ALARM", "stall", "build-1/ci-class-a", ">1h<", "sent"):
            self.assertIn(cell, body)

    def test_old_is_stale(self):
        write_status(self.status, 5 * 3600)
        body, count, level, note = render.render_runner_fleet()
        self.assertEqual(level, "stale")
        self.assertIn("5h", note)

    def test_missing_is_stale(self):
        body, count, level, note = render.render_runner_fleet()
        self.assertEqual(level, "stale")
        self.assertIn(self.status, body)


if __name__ == "__main__":
    unittest.main(verbosity=1)
