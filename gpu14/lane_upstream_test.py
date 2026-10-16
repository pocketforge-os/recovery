"""Hermetic cases for the coordinator upstream-repoint rule (2026-09-28)."""
import importlib.util
spec = importlib.util.spec_from_file_location("ls", "/home/matt/recovery/gpu14/lane-supervisor.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
LANE = "pft-8e0228598ac24b05d88d61dd"      # CAP g3 (coordinator)
WORKER = "pft-2fdc4d1318de2c6f0f557a23"    # a worker run
WT = "/home/matt/wt/tsp-mc9m.41.984.18/pocketforge-automation"
def c(i): return "/bin/bash -lc '" + i + "'"
cases = [
    (c("git branch --set-upstream-to=origin/main tsp-mc9m.41.984.18"), LANE, WT, True),
    (c("git branch --set-upstream-to=origin/device/a133 tsp-b4446e3ceb419c3f0d15"), LANE, WT, True),
    (c("git branch --set-upstream-to=origin/main tsp-mc9m.41.984.18"), WORKER, WT, False),           # coordinators only
    (c("git branch --set-upstream-to=origin/main tsp-mc9m.41.984.18"), LANE, "/home/matt/mission-control", False),  # not in a worktree
    (c("git branch --set-upstream-to=origin/feature-x tsp-mc9m.41.984.18"), LANE, WT, False),       # not a default branch
    (c("git branch --set-upstream-to=origin/main main"), LANE, WT, False),                          # not a bead branch
    (c("git branch -D tsp-mc9m.41.984.18"), LANE, WT, False),                                        # deletion stays manual
    (c("git branch --set-upstream-to=origin/main tsp-mc9m.41.984.18 extra"), LANE, WT, False),      # extra arg
    (c("git branch --set-upstream-to=origin/main tsp-x;rm -rf /"), LANE, WT, False),                 # metachar
]
ok = 0
for cmd, rid, cwd, want in cases:
    got, why = m.command_allowed(cmd, cwd=cwd, run_id=rid)
    ok += got == want
    print(("ok  " if got == want else "FAIL"), f"want={want} got={got} why={why[:60]} :: {cmd[14:90]!r}")
print(f"{ok}/{len(cases)}"); raise SystemExit(0 if ok == len(cases) else 1)
