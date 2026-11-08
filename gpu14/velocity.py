#!/usr/bin/env python3
"""gpu-14 velocity meter: hardware rows, windows and beads over a trailing window.

Usage: velocity.py [hours=24] [--record]
Reads fleet-board/data.json (hardware tally), the pf-kit-window-runner state in KW (live windows,
since the legacy queue was paused 2026-10-29), fleet-board/window-queue.log (legacy window events,
counted only for generations KW does not know) and `bd list --status closed` (beads). --record
appends one TSV line to fleet-board/velocity.tsv so the trend is visible across board checks.

"rows with new evidence" = rows with a new HW_ROW comment in the window (evidence_at) plus rows with a new closed
kit-window result (window_at, window_result ok|fail) that collect.py derived from the runner's terminal.json for a window
whose bead sits under the row or declares it. A window that reached a row only through a lane cluster that lists it
(lane_window_at) is not evidence for that row: it is printed on its own "lane windows (cluster only)" line, without
an outcome.
FB_GPU14_DIR / PF_KIT_WINDOWS_DIR / FB_GPU16_DIR / FB_BD_FIXTURE_DIR redirect the inputs (hermetic tests).

Kit-window definitions (generation = 32-hex id; times are UTC):
  starts    generations whose boot-open-<gen>.json mtime is inside the window (that file carries no
            in-file time, so its mtime is the request time).
  opens     starts without boot-open-<gen>.failed.json (the window opened).
  closed_ok opened generations whose <gen>/terminal.json is State=closed with Reason lane_done (or
            the pre-lane_done name "success"); closed_fail = every other terminal. An opened
            generation with no terminal yet is still running and is in neither.
  boot_h    sum of window-open -> window-close durations (active.json OpenedAt -> terminal close;
            close = PowerAtClose.ClosedAt, else revoked.json At, else terminal.json mtime),
            clipped to the trailing window. Legacy-only generations keep start -> open.
  stopped_h window hours minus the union of busy time. Busy = boot-open (request) -> window close for
            an opened generation, boot-open -> failed.At for a failed boot-open. A generation with
            neither a failure nor a terminal is treated as in flight for at most INFLIGHT_MAX.
Legacy queue events are skipped for any generation present in KW (the runner wrote both, so summing
would double count); legacy-only generations are added. Legacy STOP->RESUME "stopped" time is not
used: the paused queue is not DUT idleness.
"""
import datetime as dt, json, os, re, subprocess, sys

R = os.environ.get("FB_GPU14_DIR") or "/home/matt/recovery/gpu14"   # env overrides: hermetic tests
FB = R + "/fleet-board"
hours = float(next((a for a in sys.argv[1:] if not a.startswith("-")), 24))
now = dt.datetime.now(dt.timezone.utc)
since = now - dt.timedelta(hours=hours)
ts_re = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (\S+)(.*)$")

def when(s):
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)

# ---- kit-window runner state (live windows) ----
KW = os.environ.get("PF_KIT_WINDOWS_DIR") or "/home/matt/.local/state/pocketforge/kit-windows"
INFLIGHT_MAX = dt.timedelta(hours=3)  # cap for a generation with neither failure nor terminal
OK_REASONS = ("lane_done", "success")  # "success" is the pre-lane_done name of the same outcome

def jload(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}

def mtime(path):
    return dt.datetime.fromtimestamp(os.stat(path).st_mtime, dt.timezone.utc)

def tparse(s, default):
    try:
        return when(s)
    except (TypeError, ValueError):
        return default

def clipped(a, b):
    """Seconds of [a, b] inside the trailing window [since, now]."""
    return max(0.0, (min(b, now) - max(a, since)).total_seconds())

starts = opens = ok = fail = reuse = 0
boot_s = 0.0
busy = []  # (start, end) intervals when a boot-open was in flight or a window was open
kit_gens = set()
for fn in os.listdir(KW):
    m = re.fullmatch(r"boot-open-([0-9a-f]{32})\.json", fn)
    if not m:
        continue
    g = m.group(1)
    kit_gens.add(g[:8])
    t0 = mtime(f"{KW}/{fn}")
    failed = os.path.exists(f"{KW}/boot-open-{g}.failed.json")
    if t0 >= since:
        starts += 1
        opens += 0 if failed else 1
    if failed:
        t1 = tparse(jload(f"{KW}/boot-open-{g}.failed.json").get("At"), t0)
        busy.append((t0, max(t0, t1)))
        continue
    term_p = f"{KW}/{g}/terminal.json"
    term = jload(term_p)
    if term:
        t1 = (tparse((term.get("PowerAtClose") or {}).get("ClosedAt"), None)
              or tparse(jload(f"{KW}/{g}/revoked.json").get("At"), None) or mtime(term_p))
    else:
        t1 = t0 + INFLIGHT_MAX
    t1 = max(t0, min(t1, now))
    opened_at = min(max(tparse(jload(f"{KW}/{g}/active.json").get("OpenedAt"), t0), t0), t1)
    busy.append((t0, t1))
    boot_s += clipped(opened_at, t1)
    if term and t0 >= since:
        if term.get("State") == "closed" and term.get("Reason") in OK_REASONS:
            ok += 1
        else:
            fail += 1

# ---- legacy queue log: only generations the runner state does not know ----
stops = []
start_at = {}
done_at = {}
for line in open(FB + "/window-queue.log", errors="replace"):
    m = ts_re.match(line)
    if not m:
        continue
    t, ev, rest = when(m.group(1)), m.group(2), m.group(3)
    g = re.search(r"gen=([0-9a-f]{8})", rest)
    g = g.group(1) if g else None
    if "LoadPath=reuse" in rest or "Decision=reuse" in rest:
        if t >= since:  # no kit equivalent (every kit boot is a fresh FEL boot), so never deduped
            reuse += 1
    if g in kit_gens:
        continue
    if ev == "CHAIN" and rest.startswith(" start") and g:
        start_at[g] = t
    elif ev == "DONE" and g:
        done_at[g] = t
    if t < since:
        continue
    if ev == "CHAIN" and rest.startswith(" start"):
        starts += 1
    elif ev == "CHAIN" and rest.startswith(" open"):
        opens += 1
        if g in start_at:
            boot_s += (t - start_at[g]).total_seconds()
    elif ev == "DONE" and "outcome=closed:success" in rest:
        ok += 1
    elif ev == "DONE":
        fail += 1
    elif ev == "STOP":
        stops.append(re.sub(r" log=.*", "", rest.strip())[:90])
for g, t in done_at.items():
    if g in start_at and t > start_at[g]:
        busy.append((start_at[g], t))

# union of busy intervals, clipped to the window; stopped = window hours minus that
busy_s = 0.0
cur_a = cur_b = None
for a, b in sorted(busy):
    if cur_b is None or a > cur_b:
        if cur_b is not None:
            busy_s += clipped(cur_a, cur_b)
        cur_a, cur_b = a, b
    else:
        cur_b = max(cur_b, b)
if cur_b is not None:
    busy_s += clipped(cur_a, cur_b)
stopped_s = max(0.0, hours * 3600 - busy_s)


def idle_split(busy, relay_log=(os.environ.get("FB_GPU16_DIR") or "/home/matt/recovery/gpu16") + "/runs/relay.log"):
    """11-02: split stopped time by what the bench waited on, from gpu-16's relay log. 'device' = a sealed
    DEVICE_REQUEST was relayed to BENCH and no boot-open or BENCH result for that lane followed yet (BENCH
    latency or a BENCH-side refusal); 'observer' = an OBSERVER-DRY-RUN was out (BENCH busy, device off);
    'empty' = nothing sealed (lanes preparing or repairing). Returns seconds per bucket inside the window."""
    P = lambda t: dt.datetime.strptime(t, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
    reqs, results = [], []
    try:
        for line in open(relay_log, errors="replace"):
            m = re.match(r"RELAYED from=(\S+) to=(\S+) file=(\S+).* at=(\S+)", line)
            if not m or re.search(r"DEPLOY", m.group(3), re.I):
                continue
            if m.group(2) == "BENCH":
                kind = "observer" if "OBSERVER-DRY-RUN" in m.group(3) else "device"
                reqs.append((P(m.group(4)), m.group(1), kind))
            elif m.group(1) == "BENCH":
                results.append((P(m.group(4)), m.group(2)))
    except OSError:
        return None
    starts = sorted(a for a, _ in busy)
    pend = {"device": [], "observer": []}
    for t, lane, kind in reqs:
        ends = [r for r, to in results if to == lane and r > t]
        if kind == "device":
            ends += [a for a in starts if a >= t]
        pend[kind].append((t, min(ends) if ends else now))
    merged = []
    for a, b in sorted(busy):
        a, b = max(a, since), min(b, now)
        if b <= a:
            continue
        if merged and a <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    gaps, t = [], since
    for a, b in merged:
        if a > t:
            gaps.append((t, a))
        t = max(t, b)
    if t < now:
        gaps.append((t, now))
    out = {"device": 0.0, "observer": 0.0, "empty": 0.0}
    step = dt.timedelta(minutes=1)
    for a, b in gaps:
        t = a
        while t < b:  # minute buckets: device beats observer beats empty
            k = next((k for k in ("device", "observer") if any(p0 <= t < p1 for p0, p1 in pend[k])), "empty")
            out[k] += min(step, b - t).total_seconds()
            t += step
    return out


split = idle_split(busy)

d = json.load(open(FB + "/data.json"))
tally = {}
for r in d.get("hardware", {}).get("rows", []):
    tally[r.get("state")] = tally.get(r.get("state"), 0) + 1
# 2026-11-05 (tsp-hqm1p.100): a row has new evidence when it has a new HW_ROW comment (evidence_at) OR a new closed
# kit-window result the collector tied to it (window_at/window_result: the window's bead is under the row or declares
# it; ok or fail, an open window is not a result). Cluster-only matches (lane_window_at) are reported apart and never
# counted. HW_ROW stays the only authority for state; the window part is evidence of a test run, never of a state change.
cut = since.strftime("%Y-%m-%dT%H:%M")
hw_rows = d.get("hardware", {}).get("rows", [])
moved_hw = [r.get("name") for r in hw_rows if r.get("evidence_at") and str(r["evidence_at"]) >= cut]
moved_win = [(r.get("name"), f'{r.get("window_result")}, {r.get("window_via") or "?"}') for r in hw_rows
             if r.get("window_at") and str(r["window_at"]) >= cut and r.get("window_result") in ("ok", "fail")]
rows_moved = list(dict.fromkeys(moved_hw + [n for n, _ in moved_win]))
moved_lane = [r.get("name") for r in hw_rows if r.get("lane_window_at") and str(r["lane_window_at"]) >= cut
              and r.get("name") not in rows_moved]

beads = None
try:
    if os.environ.get("FB_BD_FIXTURE_DIR"):
        raise RuntimeError("fixture run: bd is not executed")
    out = subprocess.run(["bd", "list", "--status", "closed", "--json", "--limit", "0",
                          "--closed-after", since.strftime("%Y-%m-%dT%H:%M:%SZ")],
                         cwd="/home/matt/mission-control", capture_output=True, text=True, timeout=60)
    beads = len(json.loads(out.stdout)) if out.returncode == 0 and out.stdout.strip() else None
except Exception:
    beads = None

span_h = hours
working = tally.get("Working", 0)
print(f"VELOCITY window={hours:g}h at={now:%FT%TZ} board={d.get('generated_at')}")
print(f"  hardware: Working={working}/{sum(tally.values())} " +
      " ".join(f"{k}={v}" for k, v in sorted(tally.items()) if k != "Working") +
      f" | rows with new evidence={len(rows_moved)}"
      + (f" (HW_ROW {len(moved_hw)}: {', '.join(moved_hw) or '-'}; window {len(moved_win)}: "
         f"{', '.join(f'{n} ({res})' for n, res in moved_win) or '-'})" if rows_moved else ""))
if moved_lane:
    print(f"  lane windows (cluster only)={len(moved_lane)}: {', '.join(moved_lane)}"
          f" (a lane that owns the row ran a window; none is tied to the row, so not row evidence)")
print(f"  windows: started={starts} opened={opens} closed_ok={ok} closed_fail={fail} reuse={reuse}"
      f" | boot={boot_s/3600:.1f}h stopped={stopped_s/3600:.1f}h of {span_h:g}h"
      f" | ok/day={ok*24/hours:.1f}")
if split:
    print(f"  stopped split: sealed device request waiting on BENCH={split['device']/3600:.1f}h"
          f" | observer dry-run (device off)={split['observer']/3600:.1f}h | nothing sealed={split['empty']/3600:.1f}h")
print(f"  beads closed: {beads if beads is not None else 'unknown'}")
if stops:
    print(f"  stops ({len(stops)}): " + " | ".join(stops[-4:]))
if "--record" in sys.argv:
    with open(FB + "/velocity.tsv", "a") as f:
        f.write("\t".join(map(str, [f"{now:%FT%TZ}", f"{hours:g}", working, sum(tally.values()),
                                    len(rows_moved), starts, opens, ok, fail, reuse,
                                    f"{boot_s/3600:.2f}", f"{stopped_s/3600:.2f}",
                                    beads if beads is not None else ""])) + "\n")
