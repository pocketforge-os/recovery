#!/usr/bin/env python3
"""Positive/negative controls for lane_readonly_verify_allowed (lane-supervisor.py)."""
import importlib.util
s = importlib.util.spec_from_file_location("ls", "/home/matt/recovery/gpu14/lane-supervisor.py")
m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
f = m.lane_readonly_verify_allowed
REAL = '''/bin/bash -lc "set -euo pipefail
git -C /home/matt/wt/tsp-2d6d1380b71afe5cdbb3/pocketforge-automation fetch --quiet origin main
git -C /home/matt/wt/tsp-2d6d1380b71afe5cdbb3/pocketforge-automation merge-base --is-ancestor eab45b46d3c49f2bb38e6e86e7fb38190e16abf5 origin/main
git -C /home/matt/wt/tsp-2d6d1380b71afe5cdbb3/pocketforge-automation rev-parse origin/main
gh api repos/pocketforge-os/pocketforge-automation/pulls/1043 --jq '{state,merged,merged_at,merge_commit_sha,head:.head.sha,base:.base.sha}'
git -C /home/matt/wt/tsp-2d6d1380b71afe5cdbb3/pocketforge-automation status --short --branch"'''
import json
FIX = json.load(open('/home/matt/recovery/gpu14/lane_readonly_fixtures.json'))
cases = [
    ("real #1043 verification", REAL, True),
    ("gh pr view", "/bin/bash -lc 'gh pr view 10 -R pocketforge-os/qemu-tsp --json state'", True),
    ("git push", "/bin/bash -lc 'set -euo pipefail\ngit -C /home/matt/wt/x/r push origin HEAD'", False),
    ("git switch (mutating, handled elsewhere)", "/bin/bash -lc 'git -C /home/matt/wt/x/r switch -c b 3ed1ef5d'", False),
    ("gh api PATCH", "/bin/bash -lc 'gh api -X PATCH repos/pocketforge-os/image/pulls/1 -f body=x'", False),
    ("gh api method flag after path", "/bin/bash -lc 'gh api repos/pocketforge-os/image/pulls/1 --method PATCH'", False),
    ("gh api field", "/bin/bash -lc 'gh api repos/pocketforge-os/image/pulls/1 -f state=closed'", False),
    ("pipe to sh", "/bin/bash -lc 'git -C /home/matt/wt/x/r log | sh'", False),
    ("command substitution", "/bin/bash -lc 'git -C /home/matt/wt/x/r rev-parse $(whoami)'", False),
    ("redirect", "/bin/bash -lc 'git -C /home/matt/wt/x/r log > /tmp/x'", False),
    ("path outside wt", "/bin/bash -lc 'git -C /home/matt/platform fetch origin'", False),
    ("dotdot path", "/bin/bash -lc 'git -C /home/matt/wt/../platform fetch origin'", False),
    ("semicolon chain", "/bin/bash -lc 'git -C /home/matt/wt/x/r fetch; rm -rf /'", False),
    ("rm", "/bin/bash -lc 'rm -rf /home/matt/wt/x'", False),
    ("gh api non-repos path", "/bin/bash -lc 'gh api user'", False),
    ("only set", "/bin/bash -lc 'set -euo pipefail'", False),
    ("real CAP head-pinned kernel#37 check (req :128)", FIX["128"], True),
    ("real CAP head-pinned platform#209 check (req :129)", FIX["129"], True),
    ("real nested-subst check-runs (req :121) stays refused", FIX["121"], False),
    ("head assign w/o test", "/bin/bash -lc 'set -e\nhead=\"$(gh api repos/pocketforge-os/image/pulls/133 --jq .head.sha)\"\ngh pr view 133 -R pocketforge-os/image --json state'", True),
    ("test of unassigned var", "/bin/bash -lc 'set -e\ntest \"$head\" = \"0a475ab54c04101a06d0c48c95a0e3cf5d778c05\"\ngh pr view 1 -R pocketforge-os/image --json state'", False),
    ("assign runs other cmd", "/bin/bash -lc 'head=\"$(rm -rf /home/matt/wt)\"\ngh pr view 1 -R pocketforge-os/image --json state'", False),
    ("assign gh api non-pulls path", "/bin/bash -lc 'head=\"$(gh api repos/pocketforge-os/image/contents/x --jq .head.sha)\"\ngh pr view 1 -R pocketforge-os/image --json state'", False),
    ("assign with chained cmd", "/bin/bash -lc 'head=\"$(gh api repos/pocketforge-os/image/pulls/1 --jq .head.sha)\"; rm -rf x\ngh pr view 1 -R pocketforge-os/image --json state'", False),
    ("test vs non-hex", "/bin/bash -lc 'head=\"$(gh api repos/pocketforge-os/image/pulls/1 --jq .head.sha)\"\ntest \"$head\" = \"$(whoami)\"\ngh pr view 1 -R pocketforge-os/image --json state'", False),
    ("var used in later gh api path", "/bin/bash -lc 'head=\"$(gh api repos/pocketforge-os/image/pulls/1 --jq .head.sha)\"\ngh api repos/pocketforge-os/image/commits/$head/check-runs'", False),
    ("backtick", "/bin/bash -lc 'head=`gh api repos/pocketforge-os/image/pulls/1 --jq .head.sha`\ngh pr view 1 -R pocketforge-os/image --json state'", False),
]
bad = 0
for name, cmd, want in cases:
    got, why = f(cmd)
    ok = got == want
    bad += not ok
    print(("PASS" if ok else "FAIL"), name, "->", got, why)
print("RESULT", "OK" if not bad else f"{bad} FAILED")
raise SystemExit(1 if bad else 0)
