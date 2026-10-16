#!/usr/bin/env python3
"""verified_wt_rm_allowed: positive control plus negatives in ONE invocation, against real temporary git repos."""
import importlib.util, os, subprocess, sys, tempfile

spec = importlib.util.spec_from_file_location("ls", "/home/matt/recovery/gpu14/lane-supervisor.py")
ls = importlib.util.module_from_spec(spec); spec.loader.exec_module(ls)

def sh(*a, cwd=None):
    subprocess.run(a, cwd=cwd, check=True, capture_output=True)

tmp = tempfile.mkdtemp()
origin = os.path.join(tmp, "origin.git"); sh("git", "init", "-q", "--bare", "-b", "main", origin)
seed = os.path.join(tmp, "seed"); sh("git", "clone", "-q", origin, seed)
sh("git", "-C", seed, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base")
sh("git", "-C", seed, "push", "-q", "origin", "HEAD:main")
wt = os.path.join(tmp, "wt")

def make_set(bead, landed=True, dirty=False):
    repo = os.path.join(wt, bead, "repo"); os.makedirs(os.path.dirname(repo))
    sh("git", "clone", "-q", origin, repo)
    sh("git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", bead)
    if landed:
        sh("git", "-C", repo, "push", "-q", "origin", "HEAD:main")
        sh("git", "-C", seed, "pull", "-q", "origin", "main")
    if dirty:
        open(os.path.join(repo, "x"), "w").write("x")
    return repo

make_set("tsp-ok.1"); make_set("tsp-dirty.1", dirty=True); make_set("tsp-unl.1", landed=False); make_set("tsp-live.1")
runs = [
    {"run_id": "r1", "state": "released", "request": {"worktree": os.path.join(wt, "tsp-ok.1", "repo")}},
    {"run_id": "r2", "state": "released", "request": {"worktree": os.path.join(wt, "tsp-dirty.1", "repo")}},
    {"run_id": "r3", "state": "released", "request": {"worktree": os.path.join(wt, "tsp-unl.1", "repo")}},
    {"run_id": "r4", "state": "awaiting_release", "request": {"worktree": os.path.join(wt, "tsp-live.1", "repo")}},
]
L = lambda: runs
cases = [
    ("/bin/bash -lc 'pf-wt rm tsp-ok.1'", True, "verified_wt_rm"),            # positive control
    ("/bin/bash -lc 'pf-wt rm tsp-dirty.1'", False, "wtrm:dirty"),
    ("/bin/bash -lc 'pf-wt rm tsp-unl.1'", False, "wtrm:head_not_in_origin/main"),
    ("/bin/bash -lc 'pf-wt rm tsp-live.1'", False, "wtrm:unreleased"),
    ("/bin/bash -lc 'pf-wt rm tsp-none.1'", False, "wtrm:no_run_owns"),
    ("/bin/bash -lc 'pf-wt rm tsp-ok.1 && pf-wt rm tsp-live.1'", False, "wtrm:unreleased"),
    ("/bin/bash -lc 'pf-wt rm tsp-ok.1; rm -rf /'", False, "wtrm:not_pure"),
    ("/bin/bash -lc 'pf-wt rm ../etc'", False, "wtrm:not_pure"),
]
fail = 0
for cmd, want_ok, want_why in cases:
    ok, why = ls.verified_wt_rm_allowed(cmd, runs_loader=L, wt_root=wt)
    good = (ok == want_ok) and why.startswith(want_why)
    fail += not good
    print(("PASS" if good else "FAIL"), cmd, "->", ok, why)
print(f"{len(cases)-fail}/{len(cases)}")
sys.exit(1 if fail else 0)
