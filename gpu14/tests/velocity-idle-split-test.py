#!/usr/bin/env python3
"""velocity.py idle attribution (runs/bench-idle-analysis-20261116.md): the stopped split names real causes.

The fixture (fixtures/velocity-idle-20261116.json) is the 11-16 shape frozen from live records: kit-window boot-open/failed/terminal
records, the forceoff-cap clearance, relay.log, info.log and the relay-sent ledger, with "now" pinned to the analysis time. The
first class reproduces the analyst's table; the others pin each defect on a small synthetic bench. Run:
  python3 gpu14/tests/velocity-idle-split-test.py            (the script next to this tree)
  FB_VELOCITY=/path/to/velocity.py python3 ...               (any other copy, e.g. the pre-fix one, to see it fail)
"""
import contextlib, datetime as dt, io, json, os, runpy, subprocess, sys, tempfile, unittest, warnings

HERE = os.path.dirname(os.path.abspath(__file__))
VELOCITY = os.environ.get("FB_VELOCITY") or os.path.join(HERE, "..", "velocity.py")
FIXTURE = os.path.join(HERE, "fixtures", "velocity-idle-20261116.json")
U = dt.timezone.utc

# runs/bench-idle-analysis-20261116.md, "Where the 11.47 h went" (hours). The analyst's lost-wake (0.60), BENCH-turn (0.59) and
# gpu-16-ruling (0.21) rows are not separable in the machine records, so they are one bucket here.
# The analyst's 11-16 table booked every pin change as a deploy (1.64 h). tsp-hqm1p.182.394: the fixture has no DEPLOY_READY/DEPLOY-RESULT
# records, so that 1.64 h is now split between "nothing sealed" and the sealed-waiting bucket by what was actually queued.
ANALYST = {"halt": 5.54, "deploy": 0.0, "empty": 2.24, "teardown": 1.00, "failed": 0.82, "bench": 1.76, "total": 11.47}


def ts(s):
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S.%fZ" if "." in s else "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=U)


def Z(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def put(path, body, mtime=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(body if isinstance(body, str) else json.dumps(body))
    if mtime is not None:
        t = mtime.timestamp()
        os.utime(path, (t, t))


class Bench:
    """A scratch gpu14 + kit-windows + gpu16 tree for one velocity.py run."""

    def __init__(self, root, now):
        self.root, self.now = root, now
        self.kw, self.runs = f"{root}/kw", f"{root}/gpu16/runs"
        put(f"{root}/fleet-board/data.json", {"generated_at": Z(now), "hardware": {"rows": []}})
        put(f"{root}/fleet-board/window-queue.log", "")
        os.makedirs(self.kw, exist_ok=True)
        os.makedirs(self.runs, exist_ok=True)
        self.relay, self.info, self.events, self.ledger = [], [], [], {}
        self.hours = 24

    def boot_open(self, gen, request, sha="a" * 12, failed=None, failed_start=None, closed=None, terminal=None, state="closed",
                  reason="lane_done", revoked=None, opened=None):
        put(f"{self.kw}/boot-open-{gen}.json", {"AutomationSHA": sha}, request)
        if failed is not None:  # failed.At is the session START; its write time is the failure
            put(f"{self.kw}/boot-open-{gen}.failed.json", {"At": Z(failed_start or request)}, failed)
        elif terminal is not None:
            put(f"{self.kw}/{gen}/terminal.json", {"State": state, "Reason": reason,
                                                   "PowerAtClose": {"ClosedAt": Z(closed)} if closed else {}}, terminal)
            put(f"{self.kw}/{gen}/active.json", {"OpenedAt": Z(opened or request)})
            if revoked:
                put(f"{self.kw}/{gen}/revoked.json", {"At": Z(revoked)})

    def write(self):
        put(f"{self.runs}/relay.log", "".join(l + "\n" for l in self.relay))
        put(f"{self.runs}/info.log", "".join(l + "\n" for l in self.info))
        put(f"{self.runs}/events.log", "".join(l + "\n" for l in self.events))
        put(f"{self.runs}/relay-sent.json", self.ledger)

    def env(self):
        return dict(os.environ, FB_GPU14_DIR=self.root, PF_KIT_WINDOWS_DIR=self.kw, FB_GPU16_DIR=f"{self.root}/gpu16",
                    FB_BD_FIXTURE_DIR=self.root, FB_NOW=Z(self.now))

    def run(self, *args):
        self.write()
        p = subprocess.run([sys.executable, "-B", VELOCITY, str(self.hours), *args], env=self.env(), capture_output=True, text=True, timeout=60)
        assert p.returncode == 0, p.stderr
        return p.stdout.splitlines()

    def table(self):
        """The exact attribution (hours), read from the script's own variables, not its one-decimal printout."""
        self.write()
        saved, saved_argv = dict(os.environ), sys.argv
        os.environ.update(self.env())
        sys.argv = [VELOCITY, str(self.hours)]
        try:
            with contextlib.redirect_stdout(io.StringIO()), warnings.catch_warnings():
                warnings.simplefilter("ignore", ResourceWarning)  # velocity.py leaves its input files to the interpreter, as it always did
                g = runpy.run_path(VELOCITY)
        finally:
            os.environ.clear()
            os.environ.update(saved)
            sys.argv = saved_argv
        assert "cls" in g, "velocity.py does not attribute idle time by cause (no cls)"
        h = lambda s: s / 3600
        c = g["cls"]
        return {"halt": h(c["halt"]), "deploy": h(c["deploy"]), "empty": h(c["empty"]), "teardown": h(c["teardown"]),
                "failed": h(g["failed_s"]), "awaiting_image": h(c.get("awaiting_image", 0)), "seal_ready": h(c.get("seal_ready", 0)), "bench": h(c["device"] + c["observer"]), "stopped": h(g["stopped_s"]),
                "total": h(c["teardown"] + g["failed_s"] + g["stopped_s"]), "n_failed": g["n_failed"], "n_teardown": g["n_teardown"]}


def bench_from_fixture(root):
    with open(FIXTURE) as f:
        fx = json.load(f)
    b = Bench(root, ts(fx["now"]))
    for r in fx["boot_opens"]:
        if "failed" in r:
            b.boot_open(r["gen"], ts(r["request_at"]), r["sha"], failed=ts(r["failed"]["mtime"]), failed_start=ts(r["failed"]["at"]))
        elif "terminal" in r:
            t = r["terminal"]
            b.boot_open(r["gen"], ts(r["request_at"]), r["sha"], closed=ts(t["closed_at"]) if t["closed_at"] else None,
                        terminal=ts(t["mtime"]), state=t["state"], reason=t["reason"],
                        revoked=ts(r["revoked_at"]) if r.get("revoked_at") else None, opened=ts(r["opened_at"]) if r.get("opened_at") else None)
        else:
            b.boot_open(r["gen"], ts(r["request_at"]), r["sha"])
    for name, rec in fx["clearance"].items():
        put(f"{b.kw}/{name}", rec)
    b.relay, b.info, b.ledger = list(fx["relay_log"]), list(fx["info_log"]), dict(fx["relay_sent"])
    return b


class Idle1116(unittest.TestCase):
    """The analyst's 24 h table at 2026-11-16T16:06:08Z, recomputed by velocity.py."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.bench = bench_from_fixture(cls.tmp.name)
        cls.lines = cls.bench.run()
        cls.t = cls.bench.table()

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_each_cause_matches_the_analysis(self):
        t = self.t
        for k in ("halt", "deploy", "empty", "failed"):
            self.assertAlmostEqual(t[k], ANALYST[k], delta=0.05, msg=f"{k}: {t[k]:.3f} h vs the analysis {ANALYST[k]} h")
        # The analyst's slices gave an explicit-cause interval precedence over teardown, so two revoked-window teardowns sit in his
        # lost-wake and ruling rows; the pair (teardown + BENCH bucket) is the like-for-like comparison.
        self.assertAlmostEqual(t["teardown"], ANALYST["teardown"], delta=0.1)
        self.assertAlmostEqual(t["bench"], ANALYST["bench"], delta=0.1)
        self.assertAlmostEqual(t["teardown"] + t["bench"], ANALYST["teardown"] + ANALYST["bench"], delta=0.1)
        self.assertAlmostEqual(t["total"], ANALYST["total"], delta=0.01, msg="every second of the 24 h is in exactly one cause")

    def test_the_diagnostic_relay_is_not_6_3_hours_of_sealed_request(self):
        self.assertLess(self.t["bench"], 2.0)          # was 6.3 h from the one GFX7 DIAGNOSTIC_REQUEST relay at 04:57Z
        self.assertAlmostEqual(self.t["empty"], 2.24, delta=0.05)   # was 1.06 h while pin changes counted as deploys

    def test_idle_excludes_teardown_and_failed_loads(self):
        self.assertAlmostEqual(self.t["stopped"], 9.65, delta=0.15)  # "Real idle was about 9.65 h"
        self.assertEqual(self.t["n_failed"], 3)
        self.assertGreaterEqual(self.t["n_teardown"], 21)

    def test_printed_lines(self):
        out = "\n".join(self.lines)
        self.assertRegex(out, r"windows: started=\d+ opened=\d+ closed_ok=\d+ closed_fail=\d+ reuse=\d+ \| boot=[\d.]+h stopped=9\.[67]h of 24h")
        self.assertRegex(out, r"stopped split: sealed device request waiting on BENCH=1\.8h \| observer dry-run \(device off\)=0\.0h"
                              r" \| nothing sealed=2\.2h \| runner queue HALT=5\.5h \| runner deploy=0\.0h"
                              r" \| awaiting image=0\.0h \| seal-ready unsealed=0\.0h")
        self.assertRegex(out, r"not idle \(not in stopped\): runner teardown=1\.\dh \(\d+\) \| failed boot loads=0\.8h \(3\)")
        self.assertRegex(out, r"sealed requests seen in window: \d+ \(auto \d+\)")


class Defects(unittest.TestCase):
    """Small benches, 6 h window ending 12:00: window A 07:00-07:30, window B 10:00-10:20 (each closes 165 s before its terminal.json)."""
    HOURS = 6
    NOW = dt.datetime(2026, 11, 16, 12, 0, 0, tzinfo=U)
    TD = dt.timedelta(seconds=165)
    A, B = "a" * 32, "b" * 32

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.b = Bench(self.tmp.name, self.NOW)
        self.b.hours = self.HOURS

    def at(self, hhmm):
        h, m = map(int, hhmm.split(":"))
        return dt.datetime(2026, 11, 16, h, m, 0, tzinfo=U)

    def hrs(self, a, b):
        return (b - a).total_seconds() / 3600

    def window(self, gen, request, close, **kw):
        self.b.boot_open(gen, request, closed=close, terminal=close + self.TD, opened=request + dt.timedelta(minutes=10), **kw)

    def two_windows(self, sha_a="1" * 12, sha_b="1" * 12):
        self.window(self.A, self.at("07:00"), self.at("07:30"), sha=sha_a)
        self.window(self.B, self.at("10:00"), self.at("10:20"), sha=sha_b)
        # idle-or-explained gaps: before A, between A's terminal and B's request, after B's terminal
        self.pre, self.mid = self.hrs(self.at("06:00"), self.at("07:00")), self.hrs(self.at("07:30") + self.TD, self.at("10:00"))
        self.post = self.hrs(self.at("10:20") + self.TD, self.NOW)

    def seal(self, key, at, gen, lane="R22F"):
        self.b.ledger[key] = {"kind": "window_request", "at": Z(at), "generation": gen, "requester": lane}

    def test_diagnostic_relay_to_bench_is_not_a_sealed_request(self):
        self.two_windows()
        self.b.relay.append("RELAYED from=GFX7 to=BENCH file=/runs/DIAGNOSTIC_REQUEST-GFX7-r6-boot0-medium.md at=2026-11-16T08:00:00Z")
        t = self.b.table()
        self.assertAlmostEqual(t["bench"], 0.0, places=3)
        self.assertAlmostEqual(t["empty"], self.pre + self.mid + self.post, places=3)

    def test_device_request_relay_still_counts_until_the_next_boot_open(self):
        self.two_windows()
        self.b.relay.append("RELAYED from=GFX7 to=BENCH file=/runs/DEVICE_REQUEST-GFX7-r7.md at=2026-11-16T08:00:00Z")
        t = self.b.table()
        self.assertAlmostEqual(t["bench"], 2.0, places=3)                                       # 08:00 -> B's boot-open at 10:00
        self.assertAlmostEqual(t["empty"], self.pre + self.hrs(self.at("07:30") + self.TD, self.at("08:00")) + self.post, places=3)

    def test_runner_teardown_is_not_idle(self):
        self.window(self.A, self.at("07:00"), self.at("07:30"))
        t = self.b.table()
        self.assertAlmostEqual(t["teardown"], 165 / 3600, places=4)
        self.assertEqual(t["n_teardown"], 1)
        self.assertAlmostEqual(t["stopped"], self.HOURS - 0.5 - 165 / 3600, places=4)           # the window and its teardown are not idle
        self.assertTrue(any("not idle (not in stopped): runner teardown=0.0h (1)" in l for l in self.b.run()))

    def test_failed_boot_load_is_busy_until_the_failure_is_written(self):
        # failed.json's At is the session start (== the request); only its write time ends the FEL load
        self.b.boot_open("c" * 32, self.at("10:00"), failed=self.at("10:00") + dt.timedelta(minutes=16, seconds=30))
        t = self.b.table()
        self.assertAlmostEqual(t["failed"], 16.5 / 60, places=4)
        self.assertEqual(t["n_failed"], 1)
        self.assertAlmostEqual(t["stopped"], self.HOURS - 16.5 / 60, places=4)                  # nothing but the load is taken out
        self.assertTrue(any("failed boot loads=0.3h (1)" in l for l in self.b.run()))

    def test_auto_sealed_request_is_visible_without_a_relay_line(self):
        self.two_windows()
        self.seal("DISP1 k1", self.at("08:00"), self.B, "DISP1")
        self.b.info.append("2026-11-16T08:00:00Z SEALED_ORDERED lane=DISP1 run=pft-x gen=bbbbbbbb after=aaaaaaaa sha256=0123456789ab"
                           " (auto seal; gpu-16 not woken)")
        self.assertAlmostEqual(self.b.table()["bench"], 2.0, places=3)                          # sealed 08:00, launched 10:00
        self.assertIn("sealed requests seen in window: 1 (auto 1)", "\n".join(self.b.run()))

    def test_nothing_sealed_is_stated(self):
        self.two_windows()
        out = "\n".join(self.b.run())
        self.assertIn("sealed requests seen in window: 0 (auto 0)", out)
        self.assertAlmostEqual(self.b.table()["bench"], 0.0, places=3)

    def test_halt_with_a_sealed_request_pending_is_its_own_cause(self):
        self.two_windows()
        self.seal("R k1", self.at("08:30"), self.B)
        self.b.info.append("2026-11-16T09:40:00Z RUNNER_QUEUE_HALT_CLEARED reason=forceoff_daily_cap gens=a1b2c3d4 since=2026-11-16T08:15:00Z"
                           " held_min=85 raised=yes verdict=WAIT")
        t = self.b.table()
        self.assertAlmostEqual(t["halt"], self.hrs(self.at("08:30"), self.at("09:40")), places=3)     # sealed .. cleared
        self.assertAlmostEqual(t["bench"], self.hrs(self.at("09:40"), self.at("10:00")), places=3)    # the rest of the wait
        self.assertTrue(any("runner queue HALT=1.2h" in l for l in self.b.run()))

    def test_halt_with_nothing_sealed_is_nothing_sealed(self):
        self.two_windows()
        self.b.info.append("2026-11-16T09:40:00Z RUNNER_QUEUE_HALT_CLEARED reason=forceoff_daily_cap gens=a1b2c3d4 since=2026-11-16T08:15:00Z"
                           " held_min=85 raised=yes verdict=WAIT")
        t = self.b.table()
        self.assertAlmostEqual(t["halt"], 0.0, places=3)
        self.assertAlmostEqual(t["empty"], self.pre + self.mid + self.post, places=3)

    def test_halt_raised_and_not_yet_cleared_runs_to_now(self):
        self.two_windows()
        self.seal("R k1", self.at("11:00"), "d" * 32)                                       # never launched
        self.b.events.append("2026-11-16T11:30:00Z EVENT run=G16FIX - RUNNER_QUEUE_HALT reason=forceoff_daily_cap gens=a1b2c3d4"
                             " since=2026-11-16T10:30:00Z held_min=60 forceoff_day=2026-11-16:2")
        self.assertAlmostEqual(self.b.table()["halt"], self.hrs(self.at("11:00"), self.NOW), places=3)

    def test_halt_before_the_watcher_comes_from_the_clearance_record(self):
        self.two_windows()
        self.b.boot_open("f" * 32, self.at("08:00"), failed=self.at("08:15"))                       # the failed load that tripped the cap
        # the failed load (08:00-08:15) is busy, so it splits the idle time between A and B
        put(f"{self.b.kw}/forceoff-cap-clearance-2026-11-16-01.json",
            {"State": "cleared", "ClearedAt": "2026-11-16T09:40:00Z", "Generations": ["f" * 32], "HaltReason": "forceoff_daily_cap"})
        self.seal("R k1", self.at("08:30"), self.B)
        self.assertAlmostEqual(self.b.table()["halt"], self.hrs(self.at("08:30"), self.at("09:40")), places=3)

    def deploy(self, ready, applied, sha="c" * 40, name=None):
        """A runner-clone deploy: the DEPLOY_READY event (request filed) and the DEPLOY-RESULT file whose AppliedBy carries the apply time."""
        name = name or f"runner-clone-{sha[:8]}"
        self.b.info.append(f"{Z(ready)} EVENT run=G16FIX - DEPLOY_READY request=05e3c648 target=runner-clone sha={sha} lane=INFRA1 "
                           f"which=gen=002e7d40 file={self.tmp.name}/gpu16/deploys/DEPLOY-REQUEST-{name}.json (preconditions met)")
        put(f"{self.tmp.name}/gpu16/deploys/DEPLOY-RESULT-{name}.txt",
            f"Outcome=PASS\nTarget=runner-clone\nSHA={sha}\nAppliedBy=gpu-16 {Z(applied)}: apply PASS, verify PASS\n")

    def test_pin_change_alone_is_not_a_deploy(self):
        self.two_windows(sha_a="1" * 12, sha_b="2" * 12)                                       # the pin moved, nothing was deployed in the gap
        t = self.b.table()
        self.assertAlmostEqual(t["deploy"], 0.0, places=3)
        self.assertAlmostEqual(t["empty"], self.pre + self.mid + self.post, places=3)

    def test_deploy_runs_from_the_request_to_its_applied_time_not_the_whole_pin_gap(self):
        self.two_windows(sha_a="1" * 12, sha_b="2" * 12)                                       # two pins 2 h+ apart ...
        self.deploy(self.at("08:30"), self.at("08:31"))                                        # ... and a 1-minute deploy
        t = self.b.table()
        self.assertAlmostEqual(t["deploy"] * 3600, 60, places=3)
        self.assertAlmostEqual(t["empty"], self.pre + self.mid + self.post - 60 / 3600, places=3)

    def test_deploy_outside_the_window_or_unapplied_counts_nothing(self):
        self.two_windows()
        self.b.info.append(f"{Z(self.at('08:30'))} EVENT run=G16FIX - DEPLOY_READY request=1 target=runner-clone sha={'d' * 40} lane=X "
                           f"which=g file=/x/DEPLOY-REQUEST-runner-clone-dddddddd.json (preconditions met)")   # no DEPLOY-RESULT yet
        self.assertAlmostEqual(self.b.table()["deploy"], 0.0, places=3)

    def test_awaiting_image_is_build_dispatch_to_image_published(self):
        self.two_windows()
        sha = "f" * 40
        self.b.events.append(f"{Z(self.at('08:00'))} EVENT run=GFX5 pft-x BUILD_DISPATCH_RESULT run=1 url=u profile=p variant=dev platform_sha={sha} cache=-")
        self.b.info.append(f"{Z(self.at('09:00'))} EVENT run=GFX5 pft-x IMAGE_PUBLISHED platform_sha={sha} image=img")
        t = self.b.table()
        self.assertAlmostEqual(t["awaiting_image"], 1.0, places=3)
        self.assertAlmostEqual(t["empty"], self.pre + self.mid + self.post - 1.0, places=3)
        out = "\n".join(self.b.run())
        self.assertIn("awaiting image=1.0h", out)

    def test_seal_ready_unsealed_is_the_receipt_to_sealed_ordered(self):
        self.two_windows()
        self.b.info.append(f"{Z(self.at('08:00'))} WAIT_RESULT run=POWER8 pft-y receipt=receipt-e1 status=WAITING token=SEAL_READY result=gen={self.A}"
                           " detail='reason=SEAL_READY R22d'")
        self.b.info.append(f"{Z(self.at('09:00'))} EVENT run=POWER8 pft-y SEALED_ORDERED result=PASS reason=ordered gen={self.B} after={self.A[:8]} lane=R22F")
        t = self.b.table()
        self.assertAlmostEqual(t["seal_ready"], 1.0, places=3)                                  # 08:00 -> 09:00
        self.assertAlmostEqual(t["bench"], 1.0, places=3)                                       # sealed 09:00, launched 10:00
        self.assertIn("seal-ready unsealed=1.0h", "\n".join(self.b.run()))

    def test_same_pin_is_no_deploy(self):
        self.two_windows()
        self.assertAlmostEqual(self.b.table()["deploy"], 0.0, places=3)

    def test_old_fields_and_tsv_columns_are_unchanged(self):
        self.two_windows()
        lines = self.b.run("--record")
        self.assertTrue(lines[0].startswith("VELOCITY window=6h at=2026-11-16T12:00:00Z"), lines[0])
        for field in ("hardware: Working=", "windows: started=2 opened=2 closed_ok=2 closed_fail=0 reuse=0 | boot=", "ok/day=",
                      "stopped split: sealed device request waiting on BENCH=", "observer dry-run (device off)=", "nothing sealed=",
                      "beads closed:"):
            self.assertTrue(any(field in l for l in lines), f"missing {field!r} in {lines}")
        with open(f"{self.b.root}/fleet-board/velocity.tsv") as f:
            row = f.read().rstrip("\n").split("\t")
        self.assertEqual(len(row), 13)
        self.assertEqual(row[0], "2026-11-16T12:00:00Z")
        self.assertEqual((row[5], row[6], row[7], row[8], row[9]), ("2", "2", "2", "0", "0"))   # started opened ok fail reuse
        self.assertAlmostEqual(float(row[11]), self.b.table()["stopped"], delta=0.006)           # stopped_h is idle only


if __name__ == "__main__":
    unittest.main(verbosity=2)
