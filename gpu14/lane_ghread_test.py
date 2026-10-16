"""Hermetic cases for lane_gh_read_allowed (2026-09-28). Commands 390/397 are the real refused requests."""
import importlib.util
spec = importlib.util.spec_from_file_location("ls", "/home/matt/recovery/gpu14/lane-supervisor.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
q390 = '''/bin/bash -lc "gh api graphql -f query='query { repository(owner:\\"pocketforge-os\\", name:\\"pocketforge-automation\\") { pullRequest(number:1048) { reviewThreads(first:100) { nodes { id isResolved comments(first:20) { nodes { url body author { login } } } } } } } }' --jq '.data.repository.pullRequest.reviewThreads.nodes[] | {id,isResolved,comments:[.comments.nodes[]|{url,author:.author.login,body}]}'"'''
c397 = "/bin/bash -lc 'gh run view 36403723394 --repo pocketforge-os/pocketforge-automation --job 108867365166 --log-failed'"
m393 = '''/bin/bash -lc "gh api graphql -f query='mutation { addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:\\"X\\",body:\\"y\\"}){comment{url}} }'"'''
cases = [
    (q390, True), (c397, True),
    ("/bin/bash -lc 'gh pr view 1048 --repo pocketforge-os/pocketforge-automation --json headRefOid,state'", True),
    ("/bin/bash -lc 'gh pr checks 36 --repo pocketforge-os/kernel-sunxi-7.x'", True),
    (m393, False),                                                                   # mutation
    ("/bin/bash -lc 'gh run view 1 --repo evil/repo --log'", False),                 # foreign repo
    ("/bin/bash -lc 'gh run view 1 --log'", False),                                  # no --repo
    ("/bin/bash -lc 'gh run view 1 --repo pocketforge-os/x --log | tee /tmp/x'", False),  # unquoted pipe
    ("/bin/bash -lc 'gh run rerun 1 --repo pocketforge-os/x'", False),               # mutating subcommand
    ("/bin/bash -lc 'gh pr merge 1 --repo pocketforge-os/x'", False),
    ("/bin/bash -lc 'gh api repos/pocketforge-os/x/pulls/1 -X PATCH -f body=x'", False),
    ('''/bin/bash -lc "gh api graphql -f query='query { repository(owner:\\"someone-else\\", name:\\"x\\") { id } }'"''', False),  # other owner
    ("/bin/bash -lc 'gh run view 1 --repo pocketforge-os/x --log; rm -rf /tmp/x'", False),
]
ok = 0
for cmd, want in cases:
    got, why = m.lane_gh_read_allowed(cmd)
    ok += got == want
    print(("ok  " if got == want else "FAIL"), f"want={want} got={got} why={why} :: {cmd[14:80]!r}")
print(f"{ok}/{len(cases)}"); raise SystemExit(0 if ok == len(cases) else 1)
