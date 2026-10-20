#!/usr/bin/env python3
"""Hermetic tests for install-fleet-board.sh --check/--apply (tsp-mc9m.41.1030.43).

Every run points FB_LIVE_DIR and FB_UNIT_DIR at temp dirs and SYSTEMCTL at a fake that only records its argv,
so no real board, unit or systemd manager is ever touched.
Run: python3 -B gpu14/fleet-board/test_install.py
"""
import hashlib
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "install-fleet-board.sh")
UNIT_SRC = os.path.join(os.path.dirname(HERE), "systemd")   # gpu14/systemd: the one tracked copy of each unit
REPO = os.path.dirname(os.path.dirname(HERE))
SCRIPTS = ("collect.py", "render.py", "refresh.sh", "velocity.py")
UNITS = ("pf-fleet-board.service", "pf-fleet-board.timer")
# Live-only data next to the scripts: --apply must leave every one byte-identical and add nothing beside them.
DATA = ("parked.tsv", "waits.tsv", "data.json", "needs/n1.json", "window-done/w1", "lanes-added.log",
        "window-queue.tsv", "cache/run-state.json", "lane-queue/q1", "lane-queue-draft/q2", "notify-on-merge.txt",
        "close-pending.tsv", "render.py.bak-20261020T133438Z", "parked.tsv.bak", "fleet-board.html",
        "fleet-board.published.html", "velocity.json")


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def tree(root):
    out = {}
    for d, _, files in os.walk(root):
        for f in files:
            p = os.path.join(d, f)
            out[os.path.relpath(p, root)] = sha(p)
    return out


class InstallFleetBoard(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="fb-install-test-")
        self.live = os.path.join(self.tmp, "live")
        self.units = os.path.join(self.tmp, "units")
        self.log = os.path.join(self.tmp, "systemctl.log")
        os.makedirs(self.live)
        os.makedirs(self.units)
        fake = os.path.join(self.tmp, "fake-systemctl")
        with open(fake, "w") as f:   # records argv; never execs a real systemctl
            f.write('#!/bin/sh\necho "$*" >>"$FAKE_LOG"\nexit "${FAKE_RC:-0}"\n')
        os.chmod(fake, 0o755)
        self.env = {"PATH": "/usr/bin:/bin", "HOME": self.tmp, "FB_LIVE_DIR": self.live, "FB_UNIT_DIR": self.units,
                    "SYSTEMCTL": fake, "FAKE_LOG": self.log}

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_script(self, *args, **extra):
        env = dict(self.env, **extra)
        return subprocess.run(["bash", SCRIPT, *args], env=env, capture_output=True, text=True, timeout=60)

    def last(self, r):
        return r.stdout.rstrip().splitlines()[-1] if r.stdout.strip() else ""

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as f:
            return f.read().splitlines()

    def seed_live_matching(self):
        for name in SCRIPTS:
            shutil.copy2(os.path.join(HERE, name), os.path.join(self.live, name))
        for name in UNITS:
            shutil.copy2(os.path.join(UNIT_SRC, name), os.path.join(self.units, name))

    def seed_data(self):
        for rel in DATA:
            p = os.path.join(self.live, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(f"data {rel}\n")

    def test_repo_timer_rearms_after_restart(self):
        with open(os.path.join(UNIT_SRC, "pf-fleet-board.timer")) as f:
            text = f.read()
        keys = set(re.findall(r"^(On[A-Za-z]+Sec)=", text, re.M))
        self.assertIn("OnActiveSec", keys, "a timer restarted after boot needs OnActiveSec= to re-arm")
        self.assertTrue({"OnUnitInactiveSec", "OnUnitActiveSec"} & keys)

    def test_one_timer_source_and_both_installers_rearm(self):
        out = subprocess.run(["git", "-C", REPO, "ls-files", "--", "*pf-fleet-board.timer", "*pf-fleet-board.service"],
                             check=True, capture_output=True, text=True).stdout.split()
        self.assertEqual(sorted(out), ["gpu14/systemd/pf-fleet-board.service", "gpu14/systemd/pf-fleet-board.timer"])
        with open(os.path.join(UNIT_SRC, "install.sh")) as f:
            text = f.read()
        enable = re.search(r"(?m)^[^#\n]*enable --now [^\n]*pf-fleet-board\.timer", text)
        self.assertTrue(enable, "install.sh enables the timer")
        restart = re.search(r"(?m)^[^#\n]*\brestart\b[^\n]*pf-fleet-board\.timer([^\n]*)$", text[enable.end():])
        self.assertTrue(restart, "install.sh must restart the timer after enable --now so OnActiveSec= applies")
        self.assertNotIn("||", restart.group(1), "a masked restart reports success with the timer unarmed")

    def test_default_unit_dir_follows_xdg_config_home(self):
        xdg = os.path.join(self.tmp, "xdg")
        env = {k: v for k, v in self.env.items() if k != "FB_UNIT_DIR"}
        for extra, want in (({"XDG_CONFIG_HOME": xdg}, os.path.join(xdg, "systemd", "user")),
                            ({}, os.path.join(self.tmp, ".config", "systemd", "user"))):
            r = subprocess.run(["bash", SCRIPT, "--apply"], env=dict(env, **extra), capture_output=True, text=True,
                               timeout=60)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            for name in UNITS:
                self.assertEqual(sha(os.path.join(want, name)), sha(os.path.join(UNIT_SRC, name)), want)

    def test_repeated_apply_keeps_every_backup(self):
        self.seed_live_matching()
        target = os.path.join(self.live, "render.py")
        for n in range(3):
            with open(target, "w") as f:
                f.write(f"hand edit {n}\n")
            r = self.run_script("--apply")
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        baks = [os.path.join(self.live, f) for f in os.listdir(self.live) if f.startswith("render.py.bak-")]
        contents = sorted(open(b).read() for b in baks)
        self.assertEqual(contents, [f"hand edit {n}\n" for n in range(3)])

    def test_check_reports_missing_as_typed_drift(self):
        r = self.run_script("--check")
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        for name in SCRIPTS + UNITS:
            self.assertRegex(r.stdout, rf"(?m)^fleet_board_drift kind=missing file={re.escape(name)} ")
        self.assertEqual(self.last(r), "fleet_board_install=drift", r.stdout)
        self.assertEqual(self.calls(), [])

    def test_check_ok_when_live_matches(self):
        self.seed_live_matching()
        r = self.run_script("--check")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("fleet_board_drift", r.stdout)
        self.assertEqual(self.last(r), "fleet_board_install=ok", r.stdout)

    def test_check_reports_content_and_mode_drift(self):
        self.seed_live_matching()
        with open(os.path.join(self.units, "pf-fleet-board.timer"), "a") as f:
            f.write("# hand edit\n")
        os.chmod(os.path.join(self.live, "refresh.sh"), 0o644)
        r = self.run_script("--check")
        self.assertEqual(r.returncode, 1)
        self.assertRegex(r.stdout, r"(?m)^fleet_board_drift kind=content file=pf-fleet-board\.timer .*repo_sha256=\w{12}")
        self.assertRegex(r.stdout, r"(?m)^fleet_board_drift kind=not_executable file=refresh\.sh ")
        self.assertEqual(len(re.findall(r"(?m)^fleet_board_drift ", r.stdout)), 2, r.stdout)

    def test_apply_installs_backs_up_and_never_touches_data(self):
        self.seed_live_matching()
        self.seed_data()
        stale = os.path.join(self.live, "render.py")
        with open(stale, "w") as f:
            f.write("old render\n")
        os.chmod(stale, 0o664)
        with open(os.path.join(self.units, "pf-fleet-board.timer"), "w") as f:
            f.write("old timer\n")
        before = tree(self.live)
        r = self.run_script("--apply")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.last(r), "fleet_board_install=ok changed=2", r.stdout)
        after = tree(self.live)
        for rel in DATA:
            self.assertEqual(after[rel], before[rel], f"data file changed: {rel}")
        new = sorted(set(after) - set(before))
        self.assertEqual(len(new), 1, new)
        self.assertRegex(new[0], r"^render\.py\.bak-\d{8}T\d{6}Z$")
        self.assertEqual(after[new[0]], before["render.py"])
        self.assertEqual(sha(stale), sha(os.path.join(HERE, "render.py")))
        self.assertEqual(stat.S_IMODE(os.stat(stale).st_mode), 0o664, "existing mode is kept")
        unit_new = [f for f in os.listdir(self.units) if f.startswith("pf-fleet-board.timer.bak-")]
        self.assertEqual(len(unit_new), 1)
        self.assertEqual(self.calls(), ["--user daemon-reload", "--user restart pf-fleet-board.timer"])
        self.assertFalse([c for c in self.calls() if "pf-fleet-board.service" in c], "never starts the service")
        self.assertEqual(self.run_script("--check").returncode, 0)

    def test_apply_fresh_install_sets_modes(self):
        r = self.run_script("--apply")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue(os.access(os.path.join(self.live, "refresh.sh"), os.X_OK))
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.units, "pf-fleet-board.timer")).st_mode), 0o644)
        self.assertFalse([f for f in os.listdir(self.live) if ".bak-" in f], "nothing replaced, nothing backed up")

    def test_apply_noop_when_clean(self):
        self.seed_live_matching()
        before = tree(self.live)
        r = self.run_script("--apply")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("changed=0", r.stdout)
        self.assertEqual(tree(self.live), before)
        self.assertEqual(self.calls(), [])

    def test_apply_fails_closed_when_systemctl_fails(self):
        r = self.run_script("--apply", FAKE_RC="3")
        self.assertNotEqual(r.returncode, 0)
        self.assertRegex(self.last(r), r"^fleet_board_install=fail reason=systemctl_failed ", r.stdout)

    def test_usage_error(self):
        for args in ((), ("--bogus",), ("--check", "--apply")):
            r = self.run_script(*args)
            self.assertEqual(r.returncode, 2, args)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
