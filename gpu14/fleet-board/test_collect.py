#!/usr/bin/env python3
"""Hermetic tests for the live fleet board's collect.py and render.py (the 11-02 gpu-16 board, tsp-mc9m.60.29.84.14).

No network, no bd/gh/pf-task/systemctl: the module is imported against an empty fixture tree under a temp dir.
gpu-16's watch-runs.py is replaced by an in-memory stub module (active_runs, pft, text); bead data comes from
FB_BD_FIXTURE_DIR; kit windows, typed result files, the shared-refresh status file and the owner intake are fixtures.
2026-11-08 (tsp-6ae92df428b96774b063): the gpu-14 drive-log lanes, the lane classifier and the window queue are retired
on the live board; their cases are gone. The typed wake conditions they used live on in park_condition/wait_condition
and are tested there directly.
Run: python3 -B gpu14/fleet-board/test_collect.py
"""
import datetime as dt
import json
import os
import re
import stat
import sys
import tempfile
import types
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_TMP = tempfile.mkdtemp(prefix="fb-collect-test-")
for _d in ("fleet-board/cache", "g16/runs", "kit-windows", "results"):
    os.makedirs(os.path.join(_TMP, _d), exist_ok=True)
os.environ["FB_GPU14_DIR"] = _TMP
os.environ["FB_BOARD_DIR"] = os.path.join(_TMP, "fleet-board")
os.environ["FB_GPU16_DIR"] = os.path.join(_TMP, "g16")
os.environ["PF_KIT_WINDOWS_DIR"] = os.path.join(_TMP, "kit-windows")
os.environ["FB_TYPED_RESULTS_ROOT"] = os.path.join(_TMP, "results")
os.environ["FB_SHARED_REFRESH_STATUS"] = os.path.join(_TMP, "shared-refresh.json")
os.environ["FB_SHARED_REFRESH_ALLOW"] = os.path.join(_TMP, "shared-refresh-allow.json")
os.environ["FB_OWNER_INTAKE"] = os.path.join(_TMP, "intake.sh")
os.environ["FB_OWNER_INTAKE_IDS"] = "gpu-16"
os.environ["FB_BD_FIXTURE_DIR"] = os.path.join(_TMP, "no-bd")   # any stray bd call is a source error, never a bd exec
sys.path.insert(0, _HERE)
import collect  # noqa: E402
import render  # noqa: E402

NOW = collect.NOW
OLD_PARK = NOW - dt.timedelta(hours=collect.PARK_MAX_H + 8)
RUN = "pft-" + "a" * 24
RUN_B = "pft-" + "b" * 24


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(obj) if isinstance(obj, str) else json.dump(obj, f)


def touch(path, when):
    os.utime(path, (when.timestamp(), when.timestamp()))


def bead(bid, status="in_progress", assignee="t", updated=None, typ="task"):
    return {"id": bid, "title": f"title {bid}", "status": status, "priority": 2, "type": typ, "assignee": assignee,
            "parent": None, "tier": "exec", "updated_at": iso(updated or NOW - dt.timedelta(hours=10)),
            "created_at": iso(NOW - dt.timedelta(days=3)), "closed_at": None, "started_at": None,
            "comment_count": 0, "deps": []}


def lane(name, run, st=None, st_ts=None, rs="idle"):
    """A lanes_by_name entry as park_condition reads it (run_info.state, last_status, statuses)."""
    ls = None
    if st:
        ls = {"ts": iso(st_ts or NOW), "raw": f"X_STATUS state={st}", "state": st, "reason": "", "kv": {}}
    return {"lane": name, "run": run, "run_info": {"state": rs}, "last_status": ls}


OWNER = {"count": 2, "error": None,
         "items": [{"num": 59, "title": "Q59 RESOLVED 2026-10-20 14:46Z (no action needed):"},
                   {"num": 57, "title": "Q57 (2026-10-19T04:34Z): Argo CD read-only credential"}]}
OWNER_UNREADABLE = {"count": 0, "items": [], "error": "[Errno 2] No such file"}


class ParkTokens(unittest.TestCase):
    """Typed wake tokens (parked.tsv / waits.tsv reasons) -> hold | fire | evidence | fallback. Ported from the retired
    classify_lanes cases: the same reasons and fixtures, asserted on park_condition, which the live board still uses
    through wait_condition. Every unreadable or malformed condition is a fallback, never a hold."""

    def cond(self, reason, since=OLD_PARK, index=None, owner=OWNER, lanes=()):
        return collect.park_condition(reason, iso(since), index if index is not None else {}, owner,
                                      {ln["lane"]: ln for ln in lanes})

    def assertState(self, state, reason, **kw):
        c = self.cond(reason, **kw)
        self.assertIsNotNone(c, reason)
        self.assertEqual(c["state"], state, c["text"])
        return c

    # until_date
    def test_until_date_holds_before_the_date(self):
        self.assertState("hold", f"quota out; until_date={iso(NOW + dt.timedelta(days=2))}")

    def test_until_date_date_only_holds(self):
        self.assertState("hold", f"until_date={(NOW + dt.timedelta(days=3)).date().isoformat()}.")

    def test_until_date_fires_after_the_date(self):
        c = self.assertState("fire", f"until_date={iso(NOW - dt.timedelta(hours=1))} resume then")
        self.assertIn("until_date", c["text"])

    def test_until_date_malformed_falls_back(self):
        c = self.assertState("fallback", "until_date=next-tuesday")
        self.assertIn("until_date", c["text"])

    # until_owner
    def test_until_owner_holds_while_ask_open(self):
        self.assertState("hold", "WAIT_OWNER until_owner=Q57")

    def test_until_owner_fires_when_resolved(self):
        self.assertState("fire", "until_owner=Q59")

    def test_until_owner_fires_when_ask_gone(self):
        self.assertState("fire", "until_owner=Q41")

    def test_until_owner_unreadable_source_falls_back(self):
        self.assertState("fallback", "until_owner=Q57", owner=OWNER_UNREADABLE)

    def test_until_owner_no_source_falls_back(self):
        self.assertState("fallback", "until_owner=Q57", owner=None)

    def test_until_owner_malformed_falls_back(self):
        self.assertState("fallback", "until_owner=fiftyseven")

    # until_event=gen:<lane>
    def test_gen_holds_while_named_lane_has_no_new_verdict(self):
        other = lane("drc-g3", RUN_B, st="CI_WAIT", st_ts=NOW - dt.timedelta(hours=1))
        self.assertState("hold", "until_event=gen:drc-g3", lanes=[other])

    def test_gen_holds_on_verdict_older_than_park(self):
        other = lane("drc-g3", RUN_B, st="HANDBACK", st_ts=OLD_PARK - dt.timedelta(hours=1))
        self.assertState("hold", "until_event=gen:drc-g3", lanes=[other])

    def test_gen_fires_on_new_verdict(self):
        other = lane("drc-g3", RUN_B, st="HANDBACK", st_ts=NOW - dt.timedelta(hours=1))
        c = self.assertState("fire", "until_event=gen:drc-g3", lanes=[other])
        self.assertIn("drc-g3", c["text"])

    def test_gen_fires_on_verdict_followed_by_continue(self):
        other = lane("drc-g3", RUN_B, st="CONTINUE", st_ts=NOW - dt.timedelta(minutes=30))
        verdict = dict(other["last_status"], ts=iso(NOW - dt.timedelta(hours=2)), state="HANDBACK")
        older = dict(other["last_status"], ts=iso(OLD_PARK - dt.timedelta(hours=1)), state="BLOCKED")
        other["statuses"] = [older, verdict, other["last_status"]]
        c = self.assertState("fire", "until_event=gen:drc-g3", lanes=[other])
        self.assertIn("HANDBACK", c["text"])

    def test_gen_holds_when_only_old_verdicts_in_history(self):
        other = lane("drc-g3", RUN_B, st="CONTINUE", st_ts=NOW - dt.timedelta(minutes=30))
        other["statuses"] = [dict(other["last_status"], ts=iso(OLD_PARK - dt.timedelta(hours=1)), state="HANDBACK"),
                             other["last_status"]]
        self.assertState("hold", "until_event=gen:drc-g3", lanes=[other])

    def test_gen_fires_when_named_lane_released(self):
        other = lane("drc-g3", RUN_B, st="CI_WAIT", st_ts=NOW - dt.timedelta(hours=1), rs="released")
        self.assertState("fire", "until_event=gen:drc-g3", lanes=[other])

    def test_gen_unknown_lane_falls_back(self):
        self.assertState("fallback", "until_event=gen:nosuchlane")

    def test_event_unknown_kind_falls_back(self):
        self.assertState("fallback", "until_event=window:2ae0453e")

    # until_event=ticket:<id>
    def test_ticket_holds_until_changed(self):
        idx = {"tsp-tk.1": bead("tsp-tk.1", status="open", updated=OLD_PARK - dt.timedelta(hours=1))}
        self.assertState("hold", "until_event=ticket:tsp-tk.1", index=idx)

    def test_ticket_fires_on_change(self):
        idx = {"tsp-tk.1": bead("tsp-tk.1", status="in_progress", updated=NOW - dt.timedelta(hours=1))}
        self.assertState("fire", "until_event=ticket:tsp-tk.1", index=idx)

    def test_ticket_unknown_falls_back(self):
        self.assertState("fallback", "until_event=ticket:tsp-tk.9", index={"tsp-x": bead("tsp-x")})

    def test_ticket_unreadable_index_falls_back(self):
        self.assertState("fallback", "until_event=ticket:tsp-tk.1", index={})

    # until_pr
    def test_until_pr_holds_while_open_fires_when_merged(self):
        r = "until_pr=pocketforge-os/recovery#31"
        self.assertEqual(collect.park_condition(r, iso(OLD_PARK), {}, OWNER, {},
                                                {"pocketforge-os/recovery#31": {"state": "OPEN"}})["state"], "hold")
        self.assertEqual(collect.park_condition(r, iso(OLD_PARK), {}, OWNER, {},
                                                {"pocketforge-os/recovery#31": {"state": "MERGED"}})["state"], "fire")
        self.assertEqual(collect.park_condition(r, iso(OLD_PARK), {}, OWNER, {}, {})["state"], "fallback")
        self.assertEqual(self.cond("until_pr=recovery-31")["state"], "fallback")

    # mixed and legacy
    def test_one_malformed_token_poisons_the_hold(self):
        self.assertState("fallback", f"until_date={iso(NOW + dt.timedelta(days=2))} until_owner=Qx")

    def test_any_fired_condition_fires(self):
        self.assertState("fire", f"until_date={iso(NOW + dt.timedelta(days=2))} until_owner=Q59")

    def test_untyped_reason_has_no_condition(self):
        self.assertIsNone(self.cond("waiting on something"))

    def test_until_bead_holds_until_closed(self):
        c = self.assertState("hold", "until_bead=tsp-blk.1", index={"tsp-blk.1": bead("tsp-blk.1", status="open")})
        self.assertIn("until tsp-blk.1 closes", c["text"])
        self.assertState("fire", "until_bead=tsp-blk.1", index={"tsp-blk.1": bead("tsp-blk.1", status="closed")})


class EvidenceTokens(unittest.TestCase):
    """evidence_for=<who>[:<bead>]: an evidence keep, released when the named bead closes (ported from EvidenceRows)."""

    def cond(self, reason, index):
        return collect.park_condition(reason, iso(OLD_PARK), index, OWNER, {})

    def test_evidence_row_is_not_a_need(self):
        c = self.cond("superseded; evidence_for=proc-coord:tsp-ev.53", {"tsp-ev.53": bead("tsp-ev.53")})
        self.assertEqual(c["state"], "evidence")
        self.assertEqual(c["evidence"], {"who": "proc-coord", "bead": "tsp-ev.53"})
        self.assertFalse(c["release"])

    def test_evidence_released_when_bead_closes(self):
        c = self.cond("evidence_for=proc-coord:tsp-ev.53", {"tsp-ev.53": bead("tsp-ev.53", status="closed")})
        self.assertEqual((c["state"], c["release"]), ("fire", True))

    def test_evidence_unknown_bead_falls_back(self):
        self.assertEqual(self.cond("evidence_for=proc-coord:tsp-ev.99", {"tsp-x": bead("tsp-x")})["state"], "fallback")

    def test_evidence_without_bead_is_kept(self):
        c = self.cond("evidence_for=proc-coord", {"tsp-x": bead("tsp-x")})
        self.assertEqual((c["state"], c["evidence"]), ("evidence", {"who": "proc-coord", "bead": None}))

    def test_evidence_malformed_falls_back(self):
        self.assertEqual(self.cond("evidence_for=:tsp-ev.53", {"tsp-ev.53": bead("tsp-ev.53")})["state"], "fallback")


class WaitConditions(unittest.TestCase):
    """waits.tsv rows: typed rows follow their condition at any age; untyped rows hold for WAIT_MAX_H only."""

    def setUp(self):
        collect.WAITS.clear()

    def tearDown(self):
        collect.WAITS.clear()

    def test_no_row_is_none(self):
        self.assertIsNone(collect.wait_condition("tsp-w.1", {}, OWNER, {}, {}))

    def test_untyped_row_holds_then_fires_after_wait_max(self):
        collect.WAITS["tsp-w.1"] = (iso(NOW - dt.timedelta(hours=1)), "waiting on the owner")
        w = collect.wait_condition("tsp-w.1", {}, OWNER, {}, {})
        self.assertEqual((w["state"], w["typed"]), ("hold", False))
        collect.WAITS["tsp-w.1"] = (iso(NOW - dt.timedelta(hours=collect.WAIT_MAX_H + 1)), "waiting on the owner")
        self.assertEqual(collect.wait_condition("tsp-w.1", {}, OWNER, {}, {})["state"], "fire")

    def test_typed_row_follows_its_condition_at_any_age(self):
        collect.WAITS["tsp-w.1"] = (iso(NOW - dt.timedelta(hours=collect.WAIT_MAX_H + 30)), "until_owner=Q57")
        w = collect.wait_condition("tsp-w.1", {}, OWNER, {}, {})
        self.assertEqual((w["state"], w["typed"]), ("hold", True))

    def test_epic_wildcard_row_covers_descendants(self):
        collect.WAITS["tsp-ep.*"] = (iso(NOW - dt.timedelta(hours=1)), "epic paused by owner")
        self.assertEqual(collect.wait_condition("tsp-ep.4.2", {}, OWNER, {}, {})["state"], "hold")
        self.assertIsNone(collect.wait_condition("tsp-other.1", {}, OWNER, {}, {}))


class OwnerAttribution(unittest.TestCase):
    def setUp(self):
        collect.WAITS.clear()

    def run_beads(self, index):
        comments = {b: None for b in index}
        return collect.classify_beads(index, [], [], comments)

    def fixture(self, assignee):
        return {
            "tsp-mc9m.41.1030.28": bead("tsp-mc9m.41.1030.28", assignee=assignee, updated=NOW - dt.timedelta(hours=16)),
            "tsp-mc9m.41.1030.31": bead("tsp-mc9m.41.1030.31", assignee=assignee, updated=NOW - dt.timedelta(hours=12)),
            "tsp-mc9m.41.1030.9": bead("tsp-mc9m.41.1030.9", assignee=assignee, updated=NOW - dt.timedelta(hours=40)),
            "tsp-mc9m.41.1030.10": bead("tsp-mc9m.41.1030.10", assignee=assignee, updated=NOW - dt.timedelta(hours=1)),
            "tsp-mc9m.41.700.1": bead("tsp-mc9m.41.700.1", assignee="t", updated=NOW - dt.timedelta(hours=8)),
            "tsp-mc9m.41.700.2": bead("tsp-mc9m.41.700.2", assignee="someone-else", updated=NOW - dt.timedelta(hours=8)),
        }

    def test_proc_coord_beads_leave_needs_and_stale(self):
        disp, stale, long_idle, needs, lbb, owned = self.run_beads(self.fixture("proc-coord"))
        ids = {s["id"] for s in stale}
        self.assertEqual(ids, {"tsp-mc9m.41.700.1", "tsp-mc9m.41.700.2"})
        self.assertEqual({n["id"] for n in needs}, {"tsp-mc9m.41.700.1", "tsp-mc9m.41.700.2"})
        self.assertEqual(sorted(o["id"] for o in owned),
                         sorted(["tsp-mc9m.41.1030.28", "tsp-mc9m.41.1030.31", "tsp-mc9m.41.1030.9", "tsp-mc9m.41.1030.10"]))
        self.assertTrue(all(o["assignee"] == "proc-coord" for o in owned))
        age = {o["id"]: o["age_s"] for o in owned}
        self.assertAlmostEqual(age["tsp-mc9m.41.1030.28"], 16 * 3600, delta=120)

    def test_needs_drop_by_exactly_the_reattributed_rows(self):
        before = self.run_beads(self.fixture("t"))[3]
        after = self.run_beads(self.fixture("proc-coord"))[3]
        # before: 4 individual stale (16 h, 12 h, 8 h, 8 h) + 1 aggregate (the 40 h bead); after: the two 8 h rows
        self.assertEqual(len(before), 5)
        self.assertEqual(len(after), 2)
        moved = {n["id"] for n in before} - {n["id"] for n in after}
        self.assertEqual(moved, {"tsp-mc9m.41.1030.28", "tsp-mc9m.41.1030.31", "stale-beads"})

    def test_other_assignees_keep_todays_behavior(self):
        res = self.run_beads(self.fixture("t"))
        self.assertEqual(res[5], [])


class BdFixtureOverride(unittest.TestCase):
    """FB_BD_FIXTURE_DIR serves bead JSON from files and never executes bd (no PATH stubs: tsp-mc9m.41.1030.58)."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="fb-bd-fixture-", dir=_TMP)
        os.makedirs(os.path.join(self.dir, "comments"))
        rows = [{"id": "tsp-mc9m.41.1030.28", "title": "x", "status": "in_progress", "assignee": "proc-coord",
                 "issue_type": "task", "updated_at": iso(NOW)}]
        with open(os.path.join(self.dir, "list.json"), "w") as f:
            json.dump(rows, f)
        with open(os.path.join(self.dir, "ready.json"), "w") as f:
            json.dump([], f)
        with open(os.path.join(self.dir, "comments", "tsp-mc9m.41.1030.28.json"), "w") as f:
            json.dump([{"created_at": "2026-10-20T01:02:03Z"}], f)
        self.saved = collect.BD_FIXTURE
        collect.BD_FIXTURE = self.dir

    def tearDown(self):
        collect.BD_FIXTURE = self.saved

    def test_beads_and_comments_come_from_files(self):
        index, ready = collect.collect_beads()
        self.assertEqual(index["tsp-mc9m.41.1030.28"]["assignee"], "proc-coord")
        self.assertEqual(ready, [])
        bid, info, errtxt = collect.fetch_comments("tsp-mc9m.41.1030.28")
        # 11-02 board: fetch_comments also keeps the newest comment bodies (bounded) for ruling attribution
        self.assertEqual((info, errtxt), ({"count": 1, "last": "2026-10-20T01:02:03Z",
                                           "comments": [{"created_at": "2026-10-20T01:02:03Z", "body": ""}]}, None))

    def test_missing_fixture_is_an_error_not_a_bd_call(self):
        rc, out, errtxt = collect.run_cmd(["bd", "comments", "tsp-none", "--json"], 5)
        self.assertEqual(rc, 127)
        self.assertIn("FB_BD_FIXTURE_DIR", errtxt)
        rc, _, errtxt = collect.run_cmd(["bd", "show", "x"], 5)
        self.assertEqual(rc, 127)




# ---------------------------------------------------------------------- gpu-16 lanes (collect_g16_lanes) --
def g16_stub(rows, status):
    """An in-memory watch-runs.py: active_runs() rows, pft() answers by run id (an Exception instance is raised)."""
    m = types.ModuleType("g16_watch_runs_stub")
    m.calls = []
    m.active_runs = lambda: list(rows)

    def pft(op, args, home=None):
        m.calls.append((op, args, home))
        ans = status[args["run_id"]]
        if isinstance(ans, Exception):
            raise ans
        return ans
    m.pft = pft
    m.text = lambda f: f.get("text", "") if isinstance(f, dict) else (f or "")
    m.BENCH_REQUEST_FILE_RE = re.compile(r"BENCH-REQUEST")
    return m


def receipts(name, recs):
    """runs/receipts-<NAME>.jsonl, oldest first: (receipt id, run id, final text)."""
    with open(os.path.join(collect.G16_RUNS, f"receipts-{name}.jsonl"), "w") as f:
        for rid, run, final in recs:
            f.write(json.dumps({"receipt": rid, "evidence": {"run_id": run, "receipt": rid}, "final_text": final}) + "\n")


class G16Lanes(unittest.TestCase):
    """The lanes table: one row per runs/active.tsv lane, its pf-task run.status and newest G16 status line."""
    TURN = NOW.timestamp() - 600

    def setUp(self):
        self.saved = collect._G16W
        collect.ERRORS[:] = []

    def tearDown(self):
        collect._G16W = self.saved
        for n in os.listdir(collect.G16_RUNS):
            os.remove(os.path.join(collect.G16_RUNS, n))

    def lanes(self, rows, status, index=None):
        collect._G16W = g16_stub(rows, status)
        return {ln["lane"]: ln for ln in collect.collect_g16_lanes(index)}

    def st(self, state, **kw):
        d = {"state": state, "task": "tsp-ln.1", "controller_alive": True, "reconciler_alive": True,
             "provenance": {"runtime": "codex", "model": {"modelID": "gpt-x", "providerID": "openai"}},
             "messages": {"pending": 0, "total": 3}, "receipts": {"total": 2, "unacknowledged": 0},
             "last_turn": {"ended_at": self.TURN, "receipt": "r2", "reason": "completed"}}
        d.update(kw)
        return d

    def test_busy_run_is_running_and_reads_its_own_home(self):
        ls = self.lanes([("KIT1", RUN, "v10")], {RUN: self.st("busy", native_activity_age_seconds=42)},
                        index={"tsp-ln.1": bead("tsp-ln.1")})
        ln = ls["KIT1"]
        self.assertEqual((ln["state"], ln["cls"], ln["bead"], ln["bead_title"]), ("working", "running", "tsp-ln.1", "title tsp-ln.1"))
        self.assertIn("turn in progress", ln["cls_reason"])
        self.assertEqual((ln["model"], ln["provider"], ln["runtime"]), ("gpt-x", "openai", "codex"))
        self.assertTrue(ln["driver_alive"])
        self.assertEqual(collect._G16W.calls, [("run.status", {"run_id": RUN}, "v10")])

    def test_unacknowledged_handback_needs_gpu16_and_takes_the_turn_end_time(self):
        receipts("KIT1", [("r1", RUN, "G16_KIT_STATUS: WORKING x"),
                          ("r2", RUN, "done\nG16_KIT_STATUS: HANDBACK reason=REVIEW_READY pr=o/r#3")])
        ls = self.lanes([("KIT1", RUN, None)],
                        {RUN: self.st("awaiting_release", receipts={"total": 2, "unacknowledged": 1})})
        ln = ls["KIT1"]
        self.assertEqual((ln["state"], ln["cls"], ln["token"]), ("idle", "needs", "G16_KIT_STATUS"))
        self.assertEqual(ln["last_status"]["verdict"], "HANDBACK")
        self.assertEqual(ln["last_status"]["kv"], {"reason": "REVIEW_READY", "pr": "o/r#3"})
        self.assertEqual((ln["last_status"]["receipt"], ln["last_status"]["age_src"]), ("r2", "turn end"))
        self.assertIn("not yet acknowledged", ln["cls_reason"])

    def test_acknowledged_handback_is_waiting(self):
        receipts("KIT1", [("r2", RUN, "G16_KIT_STATUS: HANDBACK reason=REVIEW_READY")])
        ln = self.lanes([("KIT1", RUN, None)], {RUN: self.st("awaiting_release")})["KIT1"]
        self.assertEqual(ln["cls"], "waiting")
        self.assertIn("acknowledged by gpu-16", ln["cls_reason"])

    def test_another_runs_receipts_are_not_this_lanes_status(self):
        receipts("KIT1", [("r9", RUN_B, "G16_KIT_STATUS: BLOCKED reason=x")])
        ln = self.lanes([("KIT1", RUN, None)], {RUN: self.st("awaiting_release")})["KIT1"]
        self.assertIsNone(ln["last_status"])
        self.assertIn("no G16 status line", ln["cls_reason"])

    def test_blocked_run_needs_and_names_the_blocker(self):
        ln = self.lanes([("KIT1", RUN, None)],
                        {RUN: self.st("blocked", blocker={"blocker": {"text": "permission denied: push"}})})["KIT1"]
        self.assertEqual((ln["state"], ln["cls"]), ("blocked", "needs"))
        self.assertIn("permission denied: push", ln["cls_reason"])
        self.assertFalse(ln["stale_quota"])

    def test_kept_quota_text_after_a_newer_turn_is_stale_quota_not_blocked(self):
        nr = {"retryable": {"first_at": self.TURN - 3600, "last_at": self.TURN - 1800}}
        ln = self.lanes([("KIT1", RUN, None)],
                        {RUN: self.st("blocked", blocker={"blocker": "usage_limit_exceeded: try later"},
                                      native_recovery=nr)})["KIT1"]
        self.assertTrue(ln["stale_quota"])
        self.assertEqual((ln["state"], ln["cls"]), ("idle", "waiting"))

    def test_quota_text_with_no_later_turn_stays_blocked(self):
        nr = {"retryable": {"first_at": self.TURN + 60}}
        ln = self.lanes([("KIT1", RUN, None)],
                        {RUN: self.st("blocked", blocker={"blocker": "usage_limit_exceeded: try later"},
                                      native_recovery=nr)})["KIT1"]
        self.assertFalse(ln["stale_quota"])
        self.assertEqual(ln["cls"], "needs")

    def test_unreadable_run_status_is_unknown_and_a_source_error(self):
        ls = self.lanes([("KIT1", RUN, None), ("KIT2", RUN_B, None)],
                        {RUN: RuntimeError("pf-task timed out"), RUN_B: {"error": "unknown run"}})
        self.assertEqual((ls["KIT1"]["cls"], ls["KIT2"]["cls"]), ("unknown", "unknown"))
        self.assertIn("pf-task timed out", ls["KIT1"]["run_error"])
        self.assertEqual(ls["KIT2"]["run_error"], "unknown run")
        self.assertEqual(sorted(e["source"] for e in collect.ERRORS), ["run.status KIT1", "run.status KIT2"])

    def test_released_run_and_released_rows(self):
        ln = self.lanes([("KIT1", RUN, None)], {RUN: self.st("released")})["KIT1"]
        self.assertEqual(ln["cls"], "released")
        write(os.path.join(collect.G16_RUNS, "active.tsv"), f"KIT1\t{RUN}\n#RELEASED BDLOCK\t{RUN_B}\n")
        self.assertEqual(collect.g16_released_rows(), [{"lane": "BDLOCK", "run": RUN_B}])

    def test_active_runs_failure_is_an_error_not_an_empty_fleet_silently(self):
        m = g16_stub([], {})
        m.active_runs = lambda: (_ for _ in ()).throw(OSError("active.tsv unreadable"))
        collect._G16W = m
        self.assertEqual(collect.collect_g16_lanes(), [])
        self.assertEqual([e["source"] for e in collect.ERRORS], ["active.tsv"])


# --------------------------------------------- device: kit windows, typed results (#30), BENCH (collect_bench) --
GEN_CLEAN, GEN_BOOTFAIL, GEN_OPEN = "a1" * 16, "d4" * 16, "17" * 16


def kit_window(gen, requested, closed=None, term=None, boot_failed=None, lane_="gpu-cts"):
    kw = collect.KIT_WINDOWS
    bo = os.path.join(kw, f"boot-open-{gen}.json")
    write(bo, {"Generation": gen})
    touch(bo, requested)
    if boot_failed:
        p = os.path.join(kw, f"boot-open-{gen}.failed.json")
        write(p, boot_failed)
        touch(p, closed)
        return
    gd = os.path.join(kw, gen)
    write(os.path.join(gd, "active.json"), {"Generation": gen, "Lane": lane_, "KitPurpose": "iteration", "OpenedAt": iso(requested)})
    write(os.path.join(gd, "runner.json"), {"State": "open", "LastActivity": iso(requested)})
    if term:
        p = os.path.join(gd, "terminal.json")
        write(p, dict({"Generation": gen, "KitPurpose": "iteration", "PowerAtClose": {"ClosedAt": iso(closed)}}, **term))
        touch(p, closed)


def clear_tree(root):
    for dp, dns, fns in os.walk(root, topdown=False):
        for n in fns:
            os.remove(os.path.join(dp, n))
        for n in dns:
            os.rmdir(os.path.join(dp, n))


class TypedResultsAndBench(unittest.TestCase):
    """The device section: kit windows (collect_windows), typed results from the windows' own close records and the
    lane-written BENCH-RESULT notes (collect_typed_results, tsp-hqm1p.181 / recovery#30), and collect_bench."""
    H = dt.timedelta(hours=1)

    def setUp(self):
        collect.ERRORS[:] = []
        self.saved_w, self.saved_runner = collect._G16W, collect.collect_runner
        for d in (collect.KIT_WINDOWS, collect.TYPED_RESULTS_ROOT, collect.G16_RUNS):
            clear_tree(d)

    def tearDown(self):
        collect._G16W, collect.collect_runner = self.saved_w, self.saved_runner
        for d in (collect.KIT_WINDOWS, collect.TYPED_RESULTS_ROOT, collect.G16_RUNS):
            clear_tree(d)

    def seed(self):
        kit_window(GEN_CLEAN, NOW - 3 * self.H, NOW - 2 * self.H,
                   term={"State": "closed", "Reason": "lane_done", "End": "CLEAN", "LaneReason": "sat_complete",
                         "Attempts": [{"Sequence": 0, "RequestID": GEN_CLEAN, "Outcome": "pass"}]})
        kit_window(GEN_BOOTFAIL, NOW - 2 * self.H, NOW - 90 * dt.timedelta(minutes=1),
                   boot_failed={"Reason": "boot_open_failed", "At": iso(NOW - 90 * dt.timedelta(minutes=1))})
        kit_window(GEN_OPEN, NOW - 10 * dt.timedelta(minutes=1))
        self.note = os.path.join(collect.TYPED_RESULTS_ROOT, "gfx5", "GFX5-X-BENCH-RESULT.txt")
        write(self.note, "GFX5-X\nOutcome: NOT A PASS. step 1 REFUSED reason=anchor_mismatch failure_reason=fel_bulk_in_timeout\n")

    def test_windows_newest_first_with_open_and_close_state(self):
        self.seed()
        wins = collect.collect_windows()
        self.assertEqual([w["gen"] for w in wins], [GEN_OPEN, GEN_BOOTFAIL, GEN_CLEAN])
        by = {w["gen"]: w for w in wins}
        self.assertTrue(by[GEN_OPEN]["open"])
        self.assertEqual((by[GEN_CLEAN]["state"], by[GEN_CLEAN]["outcome"], by[GEN_CLEAN]["lane"]), ("closed", "CLEAN lane_done", "gpu-cts"))
        self.assertEqual(by[GEN_BOOTFAIL]["state"], "boot-open failed")

    def test_typed_results_read_close_records_and_notes(self):
        self.seed()
        res = collect.collect_typed_results({})
        rows = {(i["kind"], i.get("gen") or i["file"]): i for i in res["items"]}
        self.assertEqual(res["total"], 3)   # the open window is not a result
        clean = rows[("kit-window", GEN_CLEAN)]
        self.assertEqual((clean["state"], clean["reason"], clean["lane_reason"], clean["lane_hint"]),
                         ("CLEAN", "lane_done", "sat_complete", "gpu-cts"))
        self.assertEqual(rows[("kit-window", GEN_BOOTFAIL)]["state"], "BOOT_OPEN_FAILED")
        note = rows[("bench-result-txt", "GFX5-X-BENCH-RESULT.txt")]
        self.assertEqual((note["state"], note["reason"], note["typed_cause"]), ("FAIL", "anchor_mismatch", "fel_bulk_in_timeout"))
        self.assertEqual(res["warns"], [])
        self.assertEqual(res["windows_closed"], 1)

    def test_closed_windows_with_no_note_rows_warn(self):
        self.seed()
        os.remove(self.note)
        res = collect.collect_typed_results({})
        self.assertEqual([w["source"] for w in res["warns"]], ["files"])
        html = render.render_results({"device": {"results": res}})
        self.assertIn("yielded 0 rows", html)

    def test_relay_names_the_lane_a_result_went_to(self):
        self.seed()
        res = collect.collect_typed_results({"GFX5 deadbeef": {"from": "BENCH", "file": self.note, "at": iso(NOW)}})
        note = next(i for i in res["items"] if i["kind"] == "bench-result-txt")
        self.assertEqual(note["lane"], "GFX5")

    def test_collect_bench_assembles_the_device_section(self):
        self.seed()
        collect.collect_runner = lambda: {"unit": collect.RUNNER_UNIT, "active": "active", "sub": "running", "pid": 7,
                                          "since": None, "deployed": "pa-1234", "error": None}
        collect._G16W = g16_stub([], {})
        receipts("BENCH1", [("b1", RUN, "G16_BENCH_STATUS: WORKING runner=pa-1234 dut=on"),
                            ("b2", RUN, "G16_BENCH_STATUS: WAITING place=tsp-a133")])
        req = os.path.join(_TMP, "GFX5-BENCH-REQUEST-r1.md")
        write(req, "x")
        write(os.path.join(collect.G16_RUNS, "relay-sent.json"),
              {"BENCH1 abc": {"from": "GFX51", "file": req, "at": iso(NOW - self.H)},
               "GFX51 def": {"from": "BENCH1", "file": self.note, "at": iso(NOW - 0.5 * self.H)}})
        bench = {"lane": "BENCH1", "run": RUN, "state": "idle", "cls": "waiting", "last_status": None}
        dev = collect.collect_bench([bench, {"lane": "GFX51", "run": RUN_B}])
        self.assertEqual(dev["bench"]["lane"], "BENCH1")
        self.assertEqual({k: v["value"] for k, v in dev["reported"].items()},
                         {"runner": "pa-1234", "dut": "on", "place": "tsp-a133"})
        self.assertEqual([w["gen"] for w in dev["windows_open"]], [GEN_OPEN])
        self.assertEqual(len(dev["queue"]), 1)
        q = dev["queue"][0]
        self.assertEqual((q["cluster"], q["lane"], q["answered"]), ("GFX", "GFX51", True))
        self.assertEqual((q["answer"]["state"], q["answer"]["reason"]), ("FAIL", "anchor_mismatch"))
        self.assertEqual(dev["results"]["total"], 3)
        self.assertIsNone(dev["sent_error"])

    def test_unreadable_relay_file_is_an_error_and_an_empty_queue(self):
        collect.collect_runner = lambda: {"active": "inactive", "error": None}
        collect._G16W = g16_stub([], {})
        dev = collect.collect_bench([])
        self.assertEqual(dev["queue"], [])
        self.assertIsNotNone(dev["sent_error"])
        self.assertIn("relay-sent.json", [e["source"] for e in collect.ERRORS])


class DeviceTile(unittest.TestCase):
    """render.device_tile on the 11-02 summary: runner down is crit, an open window good, unanswered requests warn,
    and a typed-result source that went blank while windows closed turns an idle tile into a warning (#30)."""
    BASE = {"halted": False, "kit_running": False, "running": None, "pending": 0, "queue_total": 0,
            "bench_state": "idle", "bench_verdict": None, "results_24h": 0, "results_warn": 0}

    def tile(self, **kw):
        return render.device_tile(dict(self.BASE, **kw))

    def test_runner_down_is_crit(self):
        self.assertEqual(self.tile(halted=True, kit_running=True)[:2], ("crit", "RUNNER DOWN"))

    def test_open_window_is_good(self):
        sev, v, _ = self.tile(kit_running=True, running="iteration a1a1a1a1")
        self.assertEqual((sev, v), ("good", "window iteration a1a1a1a1"))

    def test_pending_requests_warn_idle_is_info(self):
        self.assertEqual(self.tile(pending=2, queue_total=3)[0], "warn")
        sev, v, detail = self.tile()
        self.assertEqual((sev, v), ("info", "idle"))
        self.assertIn("0 of 0 requests without a result", detail)

    def test_blank_result_source_warns_on_the_tile(self):
        sev, _, detail = self.tile(results_warn=1)
        self.assertEqual(sev, "warn")
        self.assertIn("1 result source empty while windows closed", detail)
        self.assertEqual(self.tile(results_warn=1, halted=True)[0], "crit")


# ------------------------------------------------------------------------ shared checkouts --
class SharedRefresh(unittest.TestCase):
    """pf-shared-refresh status -> host needs (tsp-mc9m.60.29.84.24); exceptions only from the committed allowlist."""

    def setUp(self):
        collect.ERRORS[:] = []
        for p in (collect.SHARED_REFRESH_STATUS, collect.SHARED_REFRESH_ALLOW):
            if os.path.exists(p):
                os.remove(p)

    def status(self, rows, gen=None):
        write(collect.SHARED_REFRESH_STATUS, {"generated_at": iso(gen or NOW - dt.timedelta(minutes=2)), "complete": True,
                                              "checkouts": rows})

    def row(self, path, state, skipped_h=None, **kw):
        r = {"path": path, "branch": "main", "state": state, "checked_at": iso(NOW - dt.timedelta(minutes=2))}
        if skipped_h is not None:
            r["first_skipped_at"] = iso(NOW - dt.timedelta(hours=skipped_h))
        r.update(kw)
        return r

    def test_missing_status_is_one_unknown_need(self):
        needs, summary = collect.classify_shared_refresh()
        self.assertEqual([n["id"] for n in needs], ["shared-refresh-status"])
        self.assertIn("missing", summary["error"])

    def test_long_skip_alarms_short_skip_and_ok_do_not(self):
        self.status([self.row("/r/ok", "ok"), self.row("/r/short", "dirty", 0.5),
                     self.row("/r/long", "ff_refused", 3, detail="untracked gpu14/x would be overwritten")])
        needs, summary = collect.classify_shared_refresh()
        self.assertEqual([n["id"] for n in needs], ["shared-refresh:/r/long"])
        self.assertIn("ff_refused", needs[0]["reason"])
        self.assertIn("untracked gpu14/x", needs[0]["reason"])
        self.assertTrue(needs[0]["next"].startswith("gpu-16 ops: "))
        self.assertEqual([c["alarm"] for c in summary["checkouts"]], [False, False, True])

    def test_unknown_skip_start_fails_closed(self):
        self.status([self.row("/r/x", "diverged")])
        self.assertEqual(len(collect.classify_shared_refresh()[0]), 1)

    def test_allowlisted_state_is_quiet_other_states_still_alarm(self):
        write(collect.SHARED_REFRESH_ALLOW, [{"path": "/r/long", "states": ["ff_refused"], "reason": "by design", "bead": "tsp-x.1"}])
        self.status([self.row("/r/long", "ff_refused", 3)])
        needs, summary = collect.classify_shared_refresh()
        self.assertEqual((needs, summary["checkouts"][0]["allowlisted"]), ([], "by design"))
        self.status([self.row("/r/long", "dirty", 3)])
        self.assertEqual(len(collect.classify_shared_refresh()[0]), 1)

    def test_malformed_allowlist_voids_every_exception(self):
        write(collect.SHARED_REFRESH_ALLOW, [{"path": "/r/long", "states": ["ff_refused"], "reason": "by design", "bead": "tsp-x.1"},
                                             {"path": "/r/y", "states": ["nonsense"], "reason": "r", "bead": "b"}])
        self.assertEqual(collect.load_shared_refresh_allow(), {})
        self.assertIn("shared refresh allowlist", [e["source"] for e in collect.ERRORS])
        self.status([self.row("/r/long", "ff_refused", 3)])
        self.assertEqual(len(collect.classify_shared_refresh()[0]), 1)

    def test_stale_status_is_one_unknown_need_and_rows_never_alarm(self):
        self.status([self.row("/r/long", "ff_refused", 3)], gen=NOW - dt.timedelta(hours=2))
        needs, summary = collect.classify_shared_refresh()
        self.assertEqual([n["id"] for n in needs], ["shared-refresh-status"])
        self.assertFalse(summary["checkouts"][0]["alarm"])

    def test_malformed_row_adds_one_unknown_beside_valid_alarms(self):
        self.status([self.row("/r/long", "dirty", 3), {"state": "dirty"}])
        self.assertEqual(sorted(n["id"] for n in collect.classify_shared_refresh()[0]),
                         ["shared-refresh-status", "shared-refresh:/r/long"])


# ---------------------------------------------------------------------------- owner asks --
class OwnerIntake(unittest.TestCase):
    """Owner asks = the owner intake's tickets that are not resolved (pf-owner-intake.sh list --id <id>)."""

    def intake(self, body, rc=0):
        p = collect.OWNER_INTAKE
        write(p, f"#!/bin/sh\necho \"$*\" >> {_TMP}/intake.calls\ncat <<'X'\n{body}\nX\nexit {rc}\n")
        os.chmod(p, os.stat(p).st_mode | stat.S_IXUSR)

    def setUp(self):
        collect.ERRORS[:] = []
        if os.path.exists(f"{_TMP}/intake.calls"):
            os.remove(f"{_TMP}/intake.calls")

    def test_open_tickets_are_asks_resolved_are_counted_only(self):
        self.intake("own-1\tstatus=open\tround=2\tbead=tsp-o.1\nown-2\tstatus=resolved\tround=1\tbead=\n"
                    "pf-ask-owner: no tickets for x")
        out = collect.collect_owner_asks({"tsp-o.1": bead("tsp-o.1")})
        self.assertEqual((out["count"], out["listed"], out["resolved"], out["error"]), (1, 2, 1, None))
        self.assertEqual(out["items"][0], {"num": None, "ticket": "own-1", "status": "open", "round": "2",
                                           "bead": "tsp-o.1", "id": "gpu-16", "title": "title tsp-o.1"})
        with open(f"{_TMP}/intake.calls") as f:
            self.assertEqual(f.read(), "list --id gpu-16\n")

    def test_intake_failure_is_an_error(self):
        self.intake("", rc=3)
        out = collect.collect_owner_asks()
        self.assertEqual(out["count"], 0)
        self.assertIn("gpu-16: rc=3", out["error"])
        self.assertIn("owner intake", [e["source"] for e in collect.ERRORS])


class RenderOwned(unittest.TestCase):
    D = {"owned": [{"id": "tsp-mc9m.41.1030.28", "title": "t28", "status": "in_progress", "assignee": "proc-coord",
                    "tier": "exec", "parent": "tsp-mc9m.41.1030", "updated_at": "2026-10-20T00:00:00Z", "age_s": 57600}]}

    def test_owned_group_renders(self):
        html_ = render.render_owned(self.D, "proc-coord")
        self.assertIn("tsp-mc9m.41.1030.28", html_)
        self.assertIn(">16h00<", html_)

    def test_empty_groups_render(self):
        self.assertIn("empty", render.render_owned({"owned": []}, "proc-coord"))


if __name__ == "__main__":
    unittest.main(verbosity=1)
