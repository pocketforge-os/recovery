#!/usr/bin/env python3
"""Hermetic tests for fleet-board collect.py classification and render.py groups (tsp-mc9m.41.1030.55).

No network, no bd/gh/pf-task: the module is imported against an empty fixture gpu14 dir and every input
(parked rows, waits, bead index, lanes, owner asks) is a fixture built here relative to collect.NOW.
Run: python3 -B gpu14/fleet-board/test_collect.py
"""
import datetime as dt
import os
import sys
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_TMP = tempfile.mkdtemp(prefix="fb-collect-test-")
os.makedirs(os.path.join(_TMP, "fleet-board"), exist_ok=True)
os.environ["FB_GPU14_DIR"] = _TMP
os.environ["FB_BOARD_DIR"] = os.path.join(_TMP, "fleet-board")
os.environ["FB_OWNER_ASKS"] = os.path.join(_TMP, "owner-questions.md")
sys.path.insert(0, _HERE)
import collect  # noqa: E402
import render  # noqa: E402

NOW = collect.NOW
OLD_PARK = NOW - dt.timedelta(hours=collect.PARK_MAX_H + 8)   # past PARK_MAX_H: today a stale need
YOUNG_PARK = NOW - dt.timedelta(hours=1)


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def bead(bid, status="in_progress", assignee="t", updated=None, typ="task"):
    return {"id": bid, "title": f"title {bid}", "status": status, "priority": 2, "type": typ, "assignee": assignee,
            "parent": None, "tier": "exec", "updated_at": iso(updated or NOW - dt.timedelta(hours=10)),
            "created_at": iso(NOW - dt.timedelta(days=3)), "closed_at": None, "started_at": None,
            "comment_count": 0, "deps": []}


def lane(name, run, st=None, st_ts=None, rs="idle", driver=False, task=None):
    ls = None
    if st:
        ls = {"n": 1, "ts": iso(st_ts or NOW), "raw": f"X_STATUS state={st}", "state": st, "reason": "",
              "kv": {}, "gen": None}
    return {"lane": name, "run": run, "run_info": {"state": rs, "task": task}, "last_status": ls,
            "last_event_at": iso(st_ts or NOW), "pr": None, "adm": None, "ci_waits": [], "driver_alive": driver,
            "driver_starts": [], "secondary_prs": []}


OWNER = {"count": 2, "error": None,
         "items": [{"num": 59, "title": "Q59 RESOLVED 2026-10-20 14:46Z (no action needed):"},
                   {"num": 57, "title": "Q57 (2026-10-19T04:34Z): Argo CD read-only credential"}]}
OWNER_UNREADABLE = {"count": 0, "items": [], "error": "[Errno 2] No such file"}

RUN = "pft-" + "a" * 24


class ParkTokens(unittest.TestCase):
    """Typed wake conditions on parked.tsv reasons; every unreadable/malformed condition keeps PARK_MAX_H."""

    def classify(self, reason, since=OLD_PARK, index=None, owner=OWNER, extra=()):
        collect.PARKED.clear()
        collect.PARKED[RUN] = (iso(since), reason)
        ln = lane("parked", RUN, st="HANDBACK", st_ts=since - dt.timedelta(minutes=5))
        lanes = [ln] + list(extra)
        needs = collect.classify_lanes(lanes, {}, index if index is not None else {}, {}, owner=owner)
        mine = [n for n in needs if n["lane"] == "parked"]
        return ln, mine

    def assertHold(self, reason, **kw):
        ln, mine = self.classify(reason, **kw)
        self.assertEqual(mine, [], ln["cls_reason"])
        self.assertEqual(ln["cls"], "waiting", ln["cls_reason"])
        return ln

    def assertFire(self, reason, **kw):
        ln, mine = self.classify(reason, **kw)
        self.assertEqual(len(mine), 1, ln["cls_reason"])
        self.assertEqual(mine[0]["kind"], "unblocked", mine[0]["reason"])
        return mine[0]

    def assertFallback(self, reason, **kw):
        ln, mine = self.classify(reason, **kw)
        self.assertEqual(len(mine), 1, ln["cls_reason"])
        self.assertEqual(mine[0]["kind"], "stale")
        self.assertIn(f"parked longer than {collect.PARK_MAX_H} h", mine[0]["reason"])
        return mine[0]

    # until_date
    def test_until_date_holds_before_the_date(self):
        self.assertHold(f"quota out; until_date={iso(NOW + dt.timedelta(days=2))}")

    def test_until_date_date_only_holds(self):
        self.assertHold(f"until_date={(NOW + dt.timedelta(days=3)).date().isoformat()}.")

    def test_until_date_fires_after_the_date(self):
        n = self.assertFire(f"until_date={iso(NOW - dt.timedelta(hours=1))} resume then")
        self.assertIn("until_date", n["reason"])

    def test_until_date_malformed_falls_back(self):
        n = self.assertFallback("until_date=next-tuesday")
        self.assertIn("until_date", n["reason"])

    def test_malformed_young_park_still_waits(self):
        ln, mine = self.classify("until_date=soon", since=YOUNG_PARK)
        self.assertEqual(mine, [])
        self.assertEqual(ln["cls"], "waiting")

    # until_owner
    def test_until_owner_holds_while_ask_open(self):
        self.assertHold("WAIT_OWNER until_owner=Q57")

    def test_until_owner_fires_when_resolved(self):
        self.assertFire("until_owner=Q59")

    def test_until_owner_fires_when_ask_gone(self):
        self.assertFire("until_owner=Q41")

    def test_until_owner_unreadable_source_falls_back(self):
        self.assertFallback("until_owner=Q57", owner=OWNER_UNREADABLE)

    def test_until_owner_no_source_falls_back(self):
        self.assertFallback("until_owner=Q57", owner=None)

    def test_until_owner_malformed_falls_back(self):
        self.assertFallback("until_owner=fiftyseven")

    # until_event=gen:<lane>
    def test_gen_holds_while_named_lane_has_no_new_verdict(self):
        other = lane("drc-g3", "pft-" + "b" * 24, st="CI_WAIT", st_ts=NOW - dt.timedelta(hours=1), driver=True)
        self.assertHold("until_event=gen:drc-g3", extra=[other])

    def test_gen_holds_on_verdict_older_than_park(self):
        other = lane("drc-g3", "pft-" + "b" * 24, st="HANDBACK", st_ts=OLD_PARK - dt.timedelta(hours=1))
        self.assertHold("until_event=gen:drc-g3", extra=[other])

    def test_gen_fires_on_new_verdict(self):
        other = lane("drc-g3", "pft-" + "b" * 24, st="HANDBACK", st_ts=NOW - dt.timedelta(hours=1))
        n = self.assertFire("until_event=gen:drc-g3", extra=[other])
        self.assertIn("drc-g3", n["reason"])

    def test_gen_fires_when_named_lane_released(self):
        other = lane("drc-g3", "pft-" + "b" * 24, st="CI_WAIT", st_ts=NOW - dt.timedelta(hours=1), rs="released")
        self.assertFire("until_event=gen:drc-g3", extra=[other])

    def test_gen_unknown_lane_falls_back(self):
        self.assertFallback("until_event=gen:nosuchlane")

    def test_event_unknown_kind_falls_back(self):
        self.assertFallback("until_event=window:2ae0453e")

    # until_event=ticket:<id>
    def test_ticket_holds_until_changed(self):
        idx = {"tsp-tk.1": bead("tsp-tk.1", status="open", updated=OLD_PARK - dt.timedelta(hours=1))}
        self.assertHold("until_event=ticket:tsp-tk.1", index=idx)

    def test_ticket_fires_on_change(self):
        idx = {"tsp-tk.1": bead("tsp-tk.1", status="in_progress", updated=NOW - dt.timedelta(hours=1))}
        self.assertFire("until_event=ticket:tsp-tk.1", index=idx)

    def test_ticket_unknown_falls_back(self):
        self.assertFallback("until_event=ticket:tsp-tk.9", index={"tsp-x": bead("tsp-x")})

    def test_ticket_unreadable_index_falls_back(self):
        self.assertFallback("until_event=ticket:tsp-tk.1", index={})

    # mixed and legacy
    def test_one_malformed_token_poisons_the_hold(self):
        self.assertFallback(f"until_date={iso(NOW + dt.timedelta(days=2))} until_owner=Qx")

    def test_any_fired_condition_fires(self):
        self.assertFire(f"until_date={iso(NOW + dt.timedelta(days=2))} until_owner=Q59")

    def test_untyped_old_park_unchanged(self):
        self.assertFallback("waiting on something")

    def test_until_bead_unchanged(self):
        idx = {"tsp-blk.1": bead("tsp-blk.1", status="open")}
        ln = self.assertHold("until_bead=tsp-blk.1", index=idx)
        self.assertIn("until tsp-blk.1 closes", ln["cls_reason"])


class EvidenceRows(unittest.TestCase):
    def classify(self, reason, index, since=OLD_PARK):
        collect.PARKED.clear()
        collect.PARKED[RUN] = (iso(since), reason)
        ln = lane("kleaf1-g3", RUN, st="HANDBACK", st_ts=since - dt.timedelta(minutes=5))
        needs = collect.classify_lanes([ln], {}, index, {}, owner=OWNER)
        return ln, needs

    def test_evidence_row_is_not_a_need(self):
        idx = {"tsp-ev.53": bead("tsp-ev.53", status="in_progress")}
        ln, needs = self.classify("superseded; evidence_for=proc-coord:tsp-ev.53", idx)
        self.assertEqual(needs, [])
        self.assertEqual(ln["cls"], "evidence")
        self.assertEqual(ln["evidence"], {"who": "proc-coord", "bead": "tsp-ev.53"})

    def test_evidence_returns_as_need_when_bead_closes(self):
        idx = {"tsp-ev.53": bead("tsp-ev.53", status="closed")}
        ln, needs = self.classify("evidence_for=proc-coord:tsp-ev.53", idx)
        self.assertEqual([n["kind"] for n in needs], ["unblocked"])
        self.assertIn("release", needs[0]["next"].lower())

    def test_evidence_unknown_bead_falls_back(self):
        ln, needs = self.classify("evidence_for=proc-coord:tsp-ev.99", {"tsp-x": bead("tsp-x")})
        self.assertEqual([n["kind"] for n in needs], ["stale"])

    def test_evidence_without_bead_expires_after_park_max(self):
        ln, needs = self.classify("evidence_for=proc-coord", {"tsp-x": bead("tsp-x")}, since=YOUNG_PARK)
        self.assertEqual((needs, ln["cls"]), ([], "evidence"))
        ln, needs = self.classify("evidence_for=proc-coord", {"tsp-x": bead("tsp-x")})
        self.assertEqual([n["kind"] for n in needs], ["stale"])

    def test_evidence_malformed_falls_back(self):
        ln, needs = self.classify("evidence_for=:tsp-ev.53", {"tsp-ev.53": bead("tsp-ev.53")})
        self.assertEqual([n["kind"] for n in needs], ["stale"])


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


class RenderGroups(unittest.TestCase):
    D = {"owned": [{"id": "tsp-mc9m.41.1030.28", "title": "t28", "status": "in_progress", "assignee": "proc-coord",
                    "tier": "exec", "parent": "tsp-mc9m.41.1030", "updated_at": "2026-10-20T00:00:00Z", "age_s": 57600}],
         "evidence": [{"lane": "kleaf1-g3", "run": RUN, "bead": "tsp-mc9m.60.29.35", "who": "proc-coord",
                       "keeper_bead": "tsp-mc9m.41.1030.53", "reason": "superseded", "since": "2026-10-19T12:52:01Z",
                       "age_s": 90000}]}

    def test_owned_group_renders(self):
        html_ = render.render_owned(self.D, "proc-coord")
        self.assertIn("tsp-mc9m.41.1030.28", html_)
        self.assertIn(">16h00<", html_)

    def test_evidence_group_renders(self):
        html_ = render.render_evidence(self.D)
        self.assertIn("kleaf1-g3", html_)
        self.assertIn("proc-coord", html_)
        self.assertIn("tsp-mc9m.41.1030.53", html_)

    def test_empty_groups_render(self):
        self.assertIn("empty", render.render_owned({"owned": []}, "proc-coord"))
        self.assertIn("empty", render.render_evidence({}))


if __name__ == "__main__":
    unittest.main(verbosity=1)
