import importlib.util, sys
spec = importlib.util.spec_from_file_location("ls", "/home/matt/recovery/gpu14/lane-supervisor.py")
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cases = [
  ("/bin/bash -lc 'bash tests/test-session-authority-systemd.sh'", False),
  ("/bin/bash -lc 'cd /home/matt/wt/x/image && ./tests/test-session-authority-systemd.sh --keep'", False),
  ("/bin/bash -lc 'docker run --rm --privileged --cgroupns private debian:12 /sbin/init'", False),
  ("/bin/bash -lc 'git status --short'", None),   # unaffected: falls through to normal rules
]
fails = 0
for cmd, want in cases:
    ok, why = m.command_allowed(cmd, "/home/matt/wt/x/image", None)
    if want is False:
        good = (ok is False and why == "denied:session-authority-harness-incident")
    else:
        good = (why != "denied:session-authority-harness-incident")
    print(("ok  " if good else "FAIL"), cmd[:80], "->", ok, why)
    fails += not good
print("PASS" if not fails else f"FAIL {fails}"); sys.exit(1 if fails else 0)
