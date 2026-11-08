#!/usr/bin/env python3
"""Hermetic tests: the fleet board's "Bench results (typed, 24 h)" section (tsp-hqm1p.181).

Since 11-03 the section read only BENCH-RESULT*.json and DEPLOY-RECEIPT*.txt and showed "No typed result in the last
24 h" while a dozen kit windows closed a day: the kit-window-runner pipeline replaced that format and nothing said so.
The section now reads the kit windows' own close records (terminal.json, a failed boot-open, a failed runner) and the
lane-written *BENCH-RESULT*.txt notes next to the old JSON/DEPLOY-RECEIPT files, and a source that yields no row while
windows closed renders a WARN instead of an empty-looking section.

Runs collect.py's collect_typed_results and render.py's render_results against a synthetic kit-windows tree and result
root. Nothing live is read: every path is under a temp dir, no bd/gh/pf-task is executed.

  python3 -I fleet-board-typed-results-test.py
  FB_COLLECT=<collect.py> FB_RENDER=<render.py> python3 -I fleet-board-typed-results-test.py

Defaults are the deployed files ../fleet-board/collect.py and ../fleet-board/render.py (the live gpu14 tree).
"""
import datetime as dt
import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
COLLECT = os.environ.get("FB_COLLECT") or os.path.join(HERE, "..", "fleet-board", "collect.py")
RENDER = os.environ.get("FB_RENDER") or os.path.join(HERE, "..", "fleet-board", "render.py")

# 32-hex generations
G = {"clean": "a1" * 16, "payfail": "b2" * 16, "dirty": "c3" * 16, "bootfail": "d4" * 16, "runfail": "e5" * 16,
     "old": "f6" * 16, "open": "17" * 16, "closefail": "28" * 16}
Z = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")


def write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(obj) if isinstance(obj, str) else json.dump(obj, f)


def touch(path, when):
    os.utime(path, (when.timestamp(), when.timestamp()))


def attempt(seq, rid, outcome="pass"):
    return {"Sequence": seq, "RequestID": rid, "Outcome": outcome}


def window(kw, gen, requested, closed=None, *, lane="gpu-cts", term=None, runner=None, failure=None, boot_failed=None,
           stdout=None, receipts=None):
    """One generation on disk: boot-open request (mtime = REQUESTED), active.json, and whichever close record applies."""
    bo = os.path.join(kw, f"boot-open-{gen}.json")
    write(bo, {"Generation": gen, "Holder": f"tsp-bead.{gen}"})
    touch(bo, requested)
    if boot_failed:
        p = os.path.join(kw, f"boot-open-{gen}.failed.json")
        write(p, boot_failed)
        touch(p, closed or requested)
        return
    gd = os.path.join(kw, gen)
    write(os.path.join(gd, "active.json"), {"Generation": gen, "Holder": f"tsp-bead.{gen}", "Lane": lane,
                                            "KitPurpose": "iteration", "OpenedAt": Z(requested)})
    write(os.path.join(gd, "runner.json"), runner or {"State": "open", "LastActivity": Z(requested)})
    if failure:
        p = os.path.join(gd, "failure.json")
        write(p, failure)
        touch(p, closed or requested)
    if term:
        t = dict({"Schema": "pocketforge.kit-window-runner-terminal/v1", "Generation": gen, "KitPurpose": "iteration",
                  "PowerAtClose": {"ClosedAt": Z(closed)}}, **term)
        p = os.path.join(gd, "terminal.json")
        write(p, t)
        touch(p, closed)
    for seq, text in (stdout or {}).items():
        write(os.path.join(gd, f"revision-input-{seq:06d}", f"push-exec-{seq}.stdout"), text)
    for seq, doc in (receipts or {}).items():
        write(os.path.join(gd, "receipts", f"receipt-{seq:06d}-x.json"), doc)


def load(t):
    """(collect module, render module, kit-windows dir, result root) with every path under the temp dir T."""
    kw, root = os.path.join(t, "kit-windows"), os.path.join(t, "recovery")
    os.makedirs(os.path.join(t, "fleet-board", "cache"))
    os.makedirs(kw)
    os.makedirs(root)
    os.environ.update({"FB_BOARD_DIR": os.path.join(t, "fleet-board"), "FB_GPU14_DIR": t, "FB_GPU16_DIR": os.path.join(t, "g16"),
                       "FB_HW_ROWS": os.path.join(t, "hardware-rows.json"), "PF_KIT_WINDOWS_DIR": kw,
                       "FB_TYPED_RESULTS_ROOT": root, "FB_BD_FIXTURE_DIR": os.path.join(t, "bdfix")})
    c, r = (importlib.util.module_from_spec(importlib.util.spec_from_file_location(n, f)) for n, f in
            (("collect_under_test", COLLECT), ("render_under_test", RENDER)))
    c.__spec__.loader.exec_module(c)
    r.__spec__.loader.exec_module(r)
    return c, r, kw, root


class CurrentFormatsOnly(unittest.TestCase):
    """The 11-08 blind spot, minimal: a kit-windows dir and a lane's BENCH-RESULT .txt, none of the retired JSON/DEPLOY-RECEIPT files.
    Before tsp-hqm1p.181 this produced 0 rows and the board said "No typed result in the last 24 h"."""

    def test_kit_window_and_txt_result_give_grouped_rows_and_no_warn(self):
        with tempfile.TemporaryDirectory() as t:
            c, r, kw, root = load(t)
            now = c.NOW
            window(kw, G["clean"], now - dt.timedelta(hours=3), now - dt.timedelta(hours=2),
                   term={"State": "closed", "Reason": "lane_done", "End": "CLEAN", "Attempts": [attempt(0, G["clean"])]})
            write(os.path.join(root, "gfx5", "GFX5-X-BENCH-RESULT.txt"), "GFX5-X\nOutcome: PASS terminal. Cold boot-open PASS.\n")
            res = c.collect_typed_results({})
            self.assertEqual(res["total"], 2)
            self.assertEqual({(g["kind"], g["state"]) for g in res["groups"]}, {("kit-window", "CLEAN"), ("bench-result-txt", "PASS")})
            self.assertEqual(res["warns"], [])
            self.assertNotIn("No typed result", r.render_results({"device": {"results": res}}))


class TypedResults(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.c, cls.r, cls.kw, cls.root = load(cls.tmp.name)
        now = cls.now = cls.c.NOW
        h, m = dt.timedelta(hours=1), dt.timedelta(minutes=1)
        # clean: runner-level clean, every step passed
        window(cls.kw, G["clean"], now - 3 * h, now - 2 * h,
               term={"State": "closed", "Reason": "lane_done", "End": "CLEAN", "LaneReason": "mmc0_sat_complete",
                     "Attempts": [attempt(0, G["clean"]), attempt(1, "silent-speaker-70e5a59cc17e")]})
        # payload fail: the runner says clean and every receipt passed, the f-app-proof helper printed result=FAIL (PREF2)
        window(cls.kw, G["payfail"], now - 4 * h, now - 3 * h,
               term={"State": "closed", "Reason": "lane_done", "End": "CLEAN", "LaneReason": "mmc0_fpre_complete",
                     "Attempts": [attempt(0, G["payfail"]), attempt(1, "f-app-proof-70e5a59cc17e")]},
               stdout={1: "PF_R26 teardown_start=clear\nPF_R26 mode=app-proof result=FAIL reason=app_start_failed\n"})
        # dirty: a step failed and the window ended dirty; the receipt envelope carries the typed error
        window(cls.kw, G["dirty"], now - 6 * h, now - 5 * h, lane="gpu-power",
               term={"State": "failed", "Reason": "failure", "End": "DIRTY",
                     "Attempts": [attempt(0, G["dirty"]), attempt(1, "proof-first-boot-70e5a59cc17e", "fail")]},
               receipts={1: {"Error": "step_timeout"}})
        # the boot never opened a window
        window(cls.kw, G["bootfail"], now - 2 * h, now - 90 * m, boot_failed={"Reason": "boot_open_failed", "At": Z(now - 90 * m)})
        # R51 shape: the runner failed after the window opened and wrote no terminal.json
        window(cls.kw, G["runfail"], now - 20 * m, now - 5 * m, runner={"State": "failed", "LastActivity": Z(now - 5 * m)},
               failure={"At": Z(now - 5 * m), "Generation": G["runfail"], "Reason": "post_open_ops_pending"})
        # R51 on 11-08: closed with the generic Reason `failure`, no Attempt at all; only the runner's failure.json says why
        window(cls.kw, G["closefail"], now - 90 * m, now - 80 * m,
               term={"State": "closed", "Reason": "failure", "End": "CLEAN", "Attempts": []},
               failure={"At": Z(now - 85 * m), "Generation": G["closefail"], "Reason": "post_open_ops_pending"})
        # closed 30 h ago: out of the 24 h window. still open: not a result.
        window(cls.kw, G["old"], now - 31 * h, now - 30 * h,
               term={"State": "closed", "Reason": "lane_done", "End": "CLEAN", "Attempts": [attempt(0, G["old"])]})
        window(cls.kw, G["open"], now - 10 * m)
        write(os.path.join(cls.kw, f"declarations-{G['clean']}.json"), {})   # other files are not generations
        # result files: the lane-written notes, the deploy note, a v1 JSON, a DEPLOY-RECEIPT, one too old
        cls.pref2 = os.path.join(cls.root, "gfx5", "mmc0-exp", "GFX5-PREF2-BENCH-RESULT.txt")
        write(cls.pref2, "GFX5-PREF2-BENCH-RESULT (req-pref2, gen 827cf6a1)\nImage F raw sha256 a1fc\n"
                         "Outcome: RUNNER-LEVEL CLEAN, PAYLOAD FAIL on f-app-proof. Boot-open PASS (unit ended 11:39:52Z).\n")
        write(os.path.join(cls.root, "gfx5", "mmc0-exp", "GFX5-E1W1-BENCH-RESULT.txt"),
              "GFX5-E1W1\nOutcome: NOT A PASS. Boot-open PASS; step 1 silent-speaker REFUSED.\n")
        write(os.path.join(cls.root, "gfx5", "mmc0-exp", "GFX5-SAT3H-BENCH-RESULT.txt"),
              "GFX5-SAT3H\nOUTCOME: boot-open FAILED, no window opened. Runner refused: reason=boot_open_failed -> "
              "PF_KIT_RESUME_REFUSED reason=BASE_BOOT_FAILED failure_reason=fel_bulk_in_timeout\n")
        write(os.path.join(cls.root, "gpu16", "tnf-x-deploy", "BENCH-RESULT-deploy-r2-rerun.txt"),
              "BENCH-RESULT deploy r2 re-run (request f12a)\nOutcome: PASS. One --check (rc=0), then one --deploy (rc=0).\n")
        write(os.path.join(cls.root, "gpu16", "tnf-x-deploy", "BENCH-RESULT-deploy-r2.txt"),
              "BENCH-RESULT deploy r2\nOutcome: REFUSED at --check; deploy NOT run. Nothing mutated.\n")
        write(os.path.join(cls.root, "gfx5", "GFX5-SAT3B-BENCH-RESULT.txt"), "GFX5-SAT3B\nno outcome line, just prose\n")
        write(os.path.join(cls.root, "lane", "BENCH-RESULT-v1.json"),
              {"Schema": "pocketforge.bench-result/v1", "Outcome": "FAIL", "Reason": "fel", "Failure": {"Error": "FelBoot stall"},
               "ObservedAtUTC": Z(now - h)})
        write(os.path.join(cls.root, "lane", "DEPLOY-RECEIPT-x.txt"), "DEPLOY_RECEIPT state=PASS reason=installed\nmore\n")
        old = os.path.join(cls.root, "gfx5", "GFX5-OLD-BENCH-RESULT.txt")
        write(old, "GFX5-OLD\nOutcome: PASS.\n")
        touch(old, now - dt.timedelta(days=3))
        touch(cls.pref2, now - 3 * h)
        cls.sent = {"GFX5 deadbeef": {"from": "BENCH", "file": cls.pref2, "at": Z(now - 3 * h)}}
        cls.res = cls.c.collect_typed_results(cls.sent)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def kit(self, name):
        it = next((i for i in self.res["items"] if i["kind"] == "kit-window" and i.get("gen") == G[name]), None)
        self.assertIsNotNone(it, f"no kit-window row for the {name} window; rows: {[(i['kind'], i['file']) for i in self.res['items']]}")
        return it

    def txt(self, name):
        it = next((i for i in self.res["items"] if i["file"] == name), None)
        self.assertIsNotNone(it, f"no row for {name}; rows: {[(i['kind'], i['file']) for i in self.res['items']]}")
        return it

    # ---- kit windows ----
    def test_clean_window_is_a_good_row_with_its_lane_and_reason(self):
        it = self.kit("clean")
        self.assertEqual((it["state"], it["reason"], it["typed_cause"]), ("CLEAN", "lane_done", None))
        self.assertEqual((it["lane_hint"], it["lane_reason"]), ("gpu-cts", "mmc0_sat_complete"))
        self.assertEqual(it["at"], Z(self.now - dt.timedelta(hours=2)))           # PowerAtClose.ClosedAt
        self.assertEqual(it["path"], os.path.join(self.kw, G["clean"], "terminal.json"))

    def test_payload_fail_under_a_clean_runner_is_a_failed_row_naming_the_step(self):
        it = self.kit("payfail")
        self.assertEqual((it["state"], it["typed_cause"]), ("FAILED", "f-app-proof:app_start_failed"))

    def test_dirty_failed_window_names_the_failing_step_and_its_receipt_error(self):
        it = self.kit("dirty")
        self.assertEqual((it["state"], it["reason"], it["typed_cause"]), ("FAILED_DIRTY", "failure", "proof-first-boot:step_timeout"))

    def test_generic_failure_close_names_the_runner_failure_reason(self):
        it = self.kit("closefail")
        self.assertEqual((it["state"], it["reason"], it["typed_cause"]), ("FAILED", "failure", "window:post_open_ops_pending"))

    def test_boot_open_failure_and_a_failed_runner_without_terminal_are_rows(self):
        b = self.kit("bootfail")
        self.assertEqual((b["state"], b["reason"]), ("BOOT_OPEN_FAILED", "boot_open_failed"))
        r = self.kit("runfail")        # the R51 shape
        self.assertEqual((r["state"], r["reason"]), ("RUNNER_FAILED", "post_open_ops_pending"))

    def test_old_and_open_windows_are_not_results(self):
        gens = {i.get("gen") for i in self.res["items"]}
        self.assertNotIn(G["old"], gens)
        self.assertNotIn(G["open"], gens)

    # ---- lane-written notes, deploy results, old formats ----
    def test_bench_result_txt_outcome_line_gives_state_reason_and_cause(self):
        self.assertEqual(self.txt("GFX5-PREF2-BENCH-RESULT.txt")["state"], "FAIL")      # "RUNNER-LEVEL CLEAN, PAYLOAD FAIL"
        self.assertEqual(self.txt("GFX5-E1W1-BENCH-RESULT.txt")["state"], "FAIL")       # "NOT A PASS"
        h = self.txt("GFX5-SAT3H-BENCH-RESULT.txt")
        self.assertEqual((h["state"], h["reason"], h["typed_cause"]), ("FAIL", "boot_open_failed", "fel_bulk_in_timeout"))
        self.assertEqual(self.txt("GFX5-SAT3B-BENCH-RESULT.txt")["state"], "UNCLASSIFIED")
        self.assertNotIn("GFX5-OLD-BENCH-RESULT.txt", {i["file"] for i in self.res["items"]})

    def test_deploy_results_have_their_own_kind(self):
        ok, no = self.txt("BENCH-RESULT-deploy-r2-rerun.txt"), self.txt("BENCH-RESULT-deploy-r2.txt")
        self.assertEqual((ok["kind"], ok["state"]), ("deploy-result", "PASS"))
        self.assertEqual((no["kind"], no["state"]), ("deploy-result", "REFUSED"))
        self.assertEqual(self.txt("DEPLOY-RECEIPT-x.txt")["state"], "PASS")

    def test_v1_json_still_read(self):
        v = self.txt("BENCH-RESULT-v1.json")
        self.assertEqual((v["kind"], v["state"], v["reason"], v["typed_cause"]), ("bench-result", "FAIL", "fel", "FelBoot stall"))

    def test_lane_is_the_one_bench_relayed_the_file_to(self):
        self.assertEqual(self.txt("GFX5-PREF2-BENCH-RESULT.txt")["lane"], "GFX5")

    # ---- grouping and totals ----
    def test_groups_by_kind_state_reason_typed_cause(self):
        g = {(x["kind"], x["state"], x["reason"], x["typed_cause"]): x for x in self.res["groups"]}
        self.assertEqual(g[("kit-window", "CLEAN", "lane_done", "-")]["count"], 1)     # keys render "-" for none, as before
        self.assertEqual(g[("kit-window", "FAILED", "lane_done", "f-app-proof:app_start_failed")]["sev"], "crit")
        self.assertEqual(g[("kit-window", "CLEAN", "lane_done", "-")]["sev"], "good")
        self.assertEqual(g[("deploy-result", "PASS", "-", "-")]["count"], 1)
        self.assertEqual(self.res["by_kind"]["kit-window"], 6)
        self.assertEqual(self.res["total"], 6 + 6 + 2)    # 5 window rows; 6 txt notes (4 bench-result-txt, 2 deploy-result); v1 JSON + DEPLOY-RECEIPT
        self.assertEqual(self.res["warns"], [])
        self.assertEqual(self.res["windows_closed"], 4)   # terminal.json files modified in the last 24 h: clean, payfail, dirty, closefail

    # ---- the WARN: a source that yields 0 rows while windows closed ----
    def test_file_source_empty_but_windows_closed_warns(self):
        empty = os.path.join(self.tmp.name, "empty-root")
        os.makedirs(empty)
        old, self.c.TYPED_RESULTS_ROOT = self.c.TYPED_RESULTS_ROOT, empty
        try:
            res = self.c.collect_typed_results({})
        finally:
            self.c.TYPED_RESULTS_ROOT = old
        self.assertEqual([w["source"] for w in res["warns"]], ["files"])
        self.assertEqual(res["warns"][0]["windows_closed"], 4)
        self.assertEqual(res["by_kind"].get("kit-window"), 6)        # the window rows are still there

    def test_window_source_empty_but_windows_closed_warns(self):
        old, self.c.collect_windows = self.c.collect_windows, lambda *a, **k: []
        try:
            res = self.c.collect_typed_results(self.sent)
        finally:
            self.c.collect_windows = old
        self.assertEqual([w["source"] for w in res["warns"]], ["kit-window"])
        self.assertEqual(res["warns"][0]["windows_closed"], 4)

    def test_nothing_closed_and_nothing_found_is_no_warn(self):
        empty_kw, empty_root = (os.path.join(self.tmp.name, n) for n in ("kw-none", "root-none"))
        os.makedirs(empty_kw)
        os.makedirs(empty_root)
        saved = (self.c.KIT_WINDOWS, self.c.TYPED_RESULTS_ROOT)
        self.c.KIT_WINDOWS, self.c.TYPED_RESULTS_ROOT = empty_kw, empty_root
        try:
            res = self.c.collect_typed_results({})
        finally:
            self.c.KIT_WINDOWS, self.c.TYPED_RESULTS_ROOT = saved
        self.assertEqual((res["total"], res["warns"], res["windows_closed"]), (0, [], 0))

    # ---- render ----
    def test_render_shows_groups_rows_and_windows(self):
        html = self.r.render_results({"device": {"results": self.res}})
        self.assertNotIn("No typed result", html)
        self.assertNotIn("banner-warn", html)
        for want in ("kit-window", "FAILED_DIRTY", "proof-first-boot:step_timeout", "RUNNER_FAILED", "post_open_ops_pending",
                     "BOOT_OPEN_FAILED", "deploy-result", "a1a1a1a1"):
            self.assertIn(want, html)

    def test_render_warn_is_visible_and_replaces_the_empty_message(self):
        res = {"window_h": 24, "root": "/r", "depth": 4, "items": [], "groups": [], "total": 0, "error": None, "by_kind": {},
               "windows_closed": 4, "warns": [{"source": "files", "windows_closed": 4, "text": "files yielded 0 rows"}]}
        html = self.r.render_results({"device": {"results": res}})
        self.assertIn("banner-warn", html)
        self.assertIn("Result source empty but 4 windows closed", html)
        self.assertNotIn("No typed result in the last", html)

    def test_render_with_no_warn_and_no_rows_keeps_the_empty_message(self):
        res = {"window_h": 24, "root": "/r", "depth": 4, "items": [], "groups": [], "total": 0, "error": None, "by_kind": {},
               "windows_closed": 0, "warns": []}
        html = self.r.render_results({"device": {"results": res}})
        self.assertIn("No typed result in the last 24 h", html)
        self.assertNotIn("banner-warn", html)

    def test_tile_detail_counts_the_warning(self):
        sev, _v, detail = self.r.device_tile({"pending": 0, "queue_total": 0, "results_24h": 0, "results_warn": 2})
        self.assertEqual(sev, "warn")
        self.assertIn("2 result source", detail)


if __name__ == "__main__":
    unittest.main(verbosity=1)
