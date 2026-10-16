import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", "/home/matt/recovery/gpu14/lane-supervisor.py")
m = importlib.util.module_from_spec(spec); sys.argv = ["x"]; spec.loader.exec_module(m)
wt = "/home/matt/wt/tsp-b4446e3ceb419c3f0d15/kernel-sunxi-7.x"
ok = [
    "/bin/bash -lc 'docker image ls --digests --no-trunc 10.0.32.86:5555/pocketforge/build'",
    "/bin/bash -lc 'docker image ls --all --no-trunc'",
    "/bin/bash -lc 'docker image ls --all --filter ancestor=sha256:98fe2402e4eafaae6cfc92ded82b7a9345ed525805519cb2e439fdda93a60b76 --no-trunc'",
    "/bin/bash -lc 'docker images'",
    "/bin/bash -lc 'docker image inspect 10.0.32.86:5555/pocketforge/build'",
]
bad = [
    "/bin/bash -lc 'docker image rm foo'",
    "/bin/bash -lc 'docker image prune -a'",
    "/bin/bash -lc 'docker run --rm foo'",
    "/bin/bash -lc 'docker image ls --format {{.ID}}'",
    "/bin/bash -lc 'docker image ls; docker run foo'",
    "/bin/bash -lc 'docker pull foo'",
]
fails = 0
for c in ok:
    r = m.command_allowed(c, wt)
    if not r[0]: print("FAIL expected allow:", c, r); fails += 1
for c in bad:
    r = m.command_allowed(c, wt)
    if r[0]: print("FAIL expected deny:", c, r); fails += 1
r = m.command_allowed(ok[0], "/tmp")
if r[0]: print("FAIL outside wt allowed", r); fails += 1
print("dockerread test", "PASS" if fails == 0 else f"FAIL {fails}")
