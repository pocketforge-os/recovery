#!/usr/bin/env python3
"""verified_wt_rm_allowed: positive control plus negatives in ONE invocation, against real temporary git repos."""
import importlib.util, os, subprocess, sys, tempfile

# The checked-out copy beside this test, never the live deployed script, with a stub home resolver
# (the module resolves its run's control home at import time).
_stub = tempfile.mkdtemp()
_resolver = os.path.join(_stub, "pf-task-run-home")
with open(_resolver, "w") as stream:
    stream.write('#!/bin/sh\necho \'{"control_home": "/nonexistent", "pf_task": "/bin/false", "host_config": "/dev/null"}\'\n')
os.chmod(_resolver, 0o755)
os.environ["PF_TASK_RUN_HOME_RESOLVER"] = _resolver
sys.argv = [sys.argv[0], "pft-test"]
spec = importlib.util.spec_from_file_location("ls", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                 "lane-supervisor.py"))
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
make_set("tsp-kept.1"); make_set("tsp-bundle.1"); make_set("tsp-other.1")
runs = [
    {"run_id": "r1", "state": "released", "request": {"worktree": os.path.join(wt, "tsp-ok.1", "repo")}},
    {"run_id": "r2", "state": "released", "request": {"worktree": os.path.join(wt, "tsp-dirty.1", "repo")}},
    {"run_id": "r3", "state": "released", "request": {"worktree": os.path.join(wt, "tsp-unl.1", "repo")}},
    {"run_id": "r4", "state": "awaiting_release", "request": {"worktree": os.path.join(wt, "tsp-live.1", "repo")}},
    # Released, clean and landed, but the receipt kept the tree: never swept.
    {"run_id": "r5", "state": "released", "request": {"worktree": os.path.join(wt, "tsp-kept.1", "repo")},
     "release_worktree": {"retention": "kept", "kept_paths": [{"path": os.path.join(wt, "tsp-kept.1", "repo")}]}},
    {"run_id": "r6", "state": "released", "request": {"worktree": os.path.join(wt, "tsp-bundle.1", "repo")},
     "release_disposition": {"disposition": "superseded", "preservation": {"kind": "bundle", "sha256": "0" * 64}}},
    # A kept path in ANOTHER set (multi-repo keep) protects that set too.
    {"run_id": "r7", "state": "released", "request": {"worktree": os.path.join(wt, "tsp-x.1", "repo")},
     "release_worktree": {"retention": "kept", "kept_paths": [{"path": os.path.join(wt, "tsp-other.1", "repo")}]}},
    {"run_id": "r8", "state": "released", "request": {"worktree": os.path.join(wt, "tsp-other.1", "repo")}},
    # removal_permitted is an ordinary released receipt.
    {"run_id": "r9", "state": "released", "request": {"worktree": os.path.join(wt, "tsp-ok.1", "repo")},
     "release_worktree": {"retention": "removal_permitted", "kept_paths": []}},
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
    ("/bin/bash -lc 'pf-wt rm tsp-kept.1'", False, "wtrm:release_preserved:tsp-kept.1:r5"),
    ("/bin/bash -lc 'pf-wt rm tsp-bundle.1'", False, "wtrm:release_preserved:tsp-bundle.1:r6"),
    ("/bin/bash -lc 'pf-wt rm tsp-other.1'", False, "wtrm:release_preserved:tsp-other.1:r7"),
]
fail = 0
for cmd, want_ok, want_why in cases:
    ok, why = ls.verified_wt_rm_allowed(cmd, runs_loader=L, wt_root=wt)
    good = (ok == want_ok) and why.startswith(want_why)
    fail += not good
    print(("PASS" if good else "FAIL"), cmd, "->", ok, why)
print(f"{len(cases)-fail}/{len(cases)}")
sys.exit(1 if fail else 0)
