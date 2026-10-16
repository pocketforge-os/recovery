"""Hermetic cases for the lane pf-pr-drive/pf-pr-merge gate rules (2026-09-28)."""
import importlib.util
spec = importlib.util.spec_from_file_location("ls", "/home/matt/recovery/gpu14/lane-supervisor.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
LANE = "pft-8e0228598ac24b05d88d61dd"      # CAP g3 (coordinator)
WORKER = "pft-2fdc4d1318de2c6f0f557a23"    # a worker run
def c(i): return "/bin/bash -lc '" + i + "'"
cases = [
    (c("pf-automation-tool pf-pr-drive.sh --help"), LANE, True),
    (c("pf-automation-tool pf-pr-drive.sh pocketforge-os/pocketforge-automation#1048"), LANE, True),
    (c("pf-automation-tool pf-pr-drive.sh --timeout 900 pocketforge-os/pocketforge-automation#1048"), LANE, True),
    (c("pf-automation-tool pf-pr-merge.sh pocketforge-os/pocketforge-automation#1048"), LANE, True),
    (c("pf-automation-tool pf-pr-drive.sh pocketforge-os/runtime#100"), LANE, True),         # window CLOSED 2026-09-28
    (c("pf-automation-tool pf-pr-merge.sh pocketforge-os/launcher#145"), LANE, True),        # window CLOSED 2026-09-28
    (c("pf-automation-tool pf-pr-drive.sh --resolve-thread X:/tmp/f pocketforge-os/pocketforge-automation#1048"), LANE, False),
    (c("pf-automation-tool pf-pr-drive.sh evil/repo#1"), LANE, False),
    (c("pf-automation-tool pf-pr-drive.sh pocketforge-os/pocketforge-automation#1048 pocketforge-os/x#2"), LANE, False),
    (c("pf-automation-tool pf-pr-drive.sh pocketforge-os/pocketforge-automation#1048"), WORKER, False),  # workers never merge
]
ok = 0
for cmd, rid, want in cases:
    got, why = m.command_allowed(cmd, cwd="/home/matt/wt", run_id=rid)
    ok += got == want
    print(("ok  " if got == want else "FAIL"), f"want={want} got={got} why={why[:60]} :: {cmd[14:100]!r}")
print(f"{ok}/{len(cases)}"); raise SystemExit(0 if ok == len(cases) else 1)
