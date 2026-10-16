"""lane-supervisor exits 10 DEAD_CONTROLLER on two controller_alive=false readings, never approving."""
import importlib.util, sys, tempfile
spec = importlib.util.spec_from_file_location("ls", "/home/matt/recovery/gpu14/lane-supervisor.py")
ls = importlib.util.module_from_spec(spec); spec.loader.exec_module(ls)
ls.time.sleep = lambda *_: None
ok = 0


def run(alive_seq):
    calls = []
    seq = list(alive_seq)

    def pf(op, payload, *a):
        calls.append(op)
        if op == "work.wait":
            return {"state": "permission_blocked"}
        if op == "run.status":
            alive = seq.pop(0) if seq else True
            return {"state": "permission_blocked", "controller_alive": alive, "permissions": []}
        return {}
    ls.pf = pf
    log = tempfile.NamedTemporaryFile(delete=False).name
    sys.argv = ["x", "pft-test", "gen", log, "0.0005", "5"]
    rc = ls.main()
    return rc, calls


def check(name, cond):
    global ok
    print(("PASS " if cond else "FAIL ") + name); ok += bool(cond)


rc, calls = run([False, False])
check("two dead readings -> exit 10", rc == 10)
check("no run.permission issued while dead", "run.permission" not in calls)
rc, calls = run([False, True, True])
check("one transient dead reading does not exit 10", rc != 10)
rc, calls = run([True, True])
check("positive control: live controller never exits 10", rc != 10)
print(f"{ok}/4"); sys.exit(0 if ok == 4 else 1)
