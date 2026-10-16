"""Hermetic cases for the git merge-tree allowance in wt_git_chain_allowed (2026-09-28)."""
import importlib.util
spec = importlib.util.spec_from_file_location("ls", "/home/matt/recovery/gpu14/lane-supervisor.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
CWD = "/home/matt/wt/tsp-cfe66b99c10cfb33b816/pocketforge-automation"
def c(inner): return "/bin/bash -lc '" + inner + "'"
cases = [
    # the exact request that was refused (positive control)
    (c("git fetch origin main\ngit merge-base HEAD origin/main\ngit rev-list --left-right --count HEAD...origin/main\ngit merge-tree --write-tree origin/main HEAD"), True),
    (c("git merge-tree --write-tree --name-only origin/device/a133 HEAD"), True),
    # negatives
    (c("git merge-tree origin/main HEAD"), False),                      # legacy form, no --write-tree
    (c("git merge-tree --write-tree origin/main"), False),              # one ref
    (c("git merge-tree --write-tree origin/main HEAD extra"), False),   # three refs
    (c("git merge-tree --write-tree --stdin origin/main HEAD"), False), # unlisted flag
    (c("git merge-tree --write-tree origin/main HEAD; rm -rf x"), False),
    (c("git merge-tree --write-tree ../x HEAD"), False),                # traversal-shaped operand
]
ok = 0
for cmd, want in cases:
    got, why = m.wt_git_chain_allowed(cmd, CWD)
    flag = "ok" if got == want else "FAIL"
    ok += got == want
    print(f"{flag} want={want} got={got} why={why} :: {cmd[14:90]!r}")
print(f"{ok}/{len(cases)}")
raise SystemExit(0 if ok == len(cases) else 1)
