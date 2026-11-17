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
  stopped_h window hours minus the union of busy time minus runner teardown (see below). Busy = boot-open
            (request) -> window close for an opened generation, boot-open -> the failed.json write for a
            failed boot-open. A generation with neither a failure nor a terminal is treated as in flight
            for at most INFLIGHT_MAX.
Legacy queue events are skipped for any generation present in KW (the runner wrote both, so summing
would double count); legacy-only generations are added. Legacy STOP->RESUME "stopped" time is not
used: the paused queue is not DUT idleness.

Idle attribution (2026-11-16 bench-idle analysis, runs/bench-idle-analysis-20261116.md). Time outside an open window
or a boot-open is split by what the bench was doing, one cause per instant, first match wins:
  runner teardown   PowerAtClose.ClosedAt (else revoked.json At) -> terminal.json mtime: the runner closing out
                    with the place still held. NOT idle: reported on the "not idle" line, left out of stopped.
  failed boot load  boot-open request -> boot-open-<gen>.failed.json mtime: the DUT was FEL-booting and the load
                    failed (failed.json's At is the session START, so it cannot end the interval). Device busy,
                    never idle: it is part of the busy set, not of stopped.
  runner queue HALT a runner kit-queue HALT was in force while a sealed request waited for it (a HALT with
                    nothing sealed is "nothing sealed"). Read from info.log RUNNER_QUEUE_HALT_CLEARED lines and
                    events.log RUNNER_QUEUE_HALT events (watch-runs.py runner_halt_check; since= is the onset),
                    and from kit-windows/forceoff-cap-clearance-*.json (onset = the newest failed.json of its
                    Generations, end = ClearedAt) for HALTs that predate the watcher.
  runner deploy     a runner deploy in progress: from its DEPLOY_READY line (request filed) to the AppliedBy time of its
                    DEPLOY-RESULT file. A changed AutomationSHA between boot-opens is only a pin change, not a deploy.
  sealed ... BENCH  a sealed request was waiting to launch (the original "device" bucket: BENCH latency or a
                    BENCH-side refusal). Sealed = a runs/relay-sent.json window_request row (hand AND auto
                    seals; its generation names the boot-open that ends the wait), an info.log SEALED_ORDERED
                    line, or a relay.log RELAYED lane->BENCH DEVICE_REQUEST file. A relay of anything else (a
                    DIAGNOSTIC_REQUEST, a DEPLOY_REQUEST, a note) is NOT a sealed request.
  observer dry-run  an OBSERVER-DRY-RUN request was out (BENCH busy, device off), as before.
  awaiting image    BUILD_DISPATCH_RESULT .. the next IMAGE_PUBLISHED for the same requester lane, with nothing sealed.
  seal-ready unsealed  a SEAL_READY wait result .. the SEALED_ORDERED that follows it (gen= or after= matches), nothing sealed.
  nothing sealed    none of the above: no runnable request was queued.
Not separable from these records, so inside "sealed ... BENCH": a terminal that never woke BENCH, and BENCH
waiting on a gpu-16 ruling (the analysis found both only in g16-intent.log). stopped_h in velocity.tsv is now
idle time only (it was gap time, which included teardown and failed boot loads), so older rows are higher.
FB_NOW=<UTC ISO8601 Z> pins "now" (hermetic tests).
"""
import datetime as dt, json, os, re, subprocess, sys

R = os.environ.get("FB_GPU14_DIR") or "/home/matt/recovery/gpu14"   # env overrides: hermetic tests
FB = R + "/fleet-board"
hours = float(next((a for a in sys.argv[1:] if not a.startswith("-")), 24))
now = (dt.datetime.strptime(os.environ["FB_NOW"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)
       if os.environ.get("FB_NOW") else dt.datetime.now(dt.timezone.utc))
since = now - dt.timedelta(hours=hours)
ts_re = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (\S+)(.*)$")

def when(s):
    return dt.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)

# ---- kit-window runner state (live windows) ----
KW = os.environ.get("PF_KIT_WINDOWS_DIR") or "/home/matt/.local/state/pocketforge/kit-windows"
INFLIGHT_MAX = dt.timedelta(hours=3)  # cap for a generation with neither failure nor terminal
OK_REASONS = ("lane_done", "success")  # "success" is the pre-lane_done name of the same outcome
PIN_LOOKBACK = dt.timedelta(hours=12)  # boot-open requests older than the window by this much are not read for their pin

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

def mtime_or(path, default):
    try:
        return mtime(path)
    except OSError:
        return default

starts = opens = ok = fail = reuse = 0
boot_s = 0.0
busy = []  # (start, end) intervals when a boot-open was in flight or a window was open
kit_gens = set()
failed_loads = []  # (boot-open request, failed.json write): the DUT was FEL-booting and the load failed
teardowns = []     # (window close, terminal.json write): the runner closing out; the place is still held
launch_at = {}     # generation (32 hex) -> boot-open request time
occ_end = {}       # generation -> the moment the runner finished with it (failure written / terminal written)
pins = []          # (request time, generation, AutomationSHA) of recent boot-opens: a changed pin is a runner deploy
for fn in os.listdir(KW):
    m = re.fullmatch(r"boot-open-([0-9a-f]{32})\.json", fn)
    if not m:
        continue
    g = m.group(1)
    kit_gens.add(g[:8])
    t0 = mtime(f"{KW}/{fn}")
    if t0 > now:  # a request made after "now" (only when FB_NOW replays an earlier moment)
        continue
    launch_at[g] = t0
    if t0 >= since - PIN_LOOKBACK:
        pins.append((t0, g, str(jload(f"{KW}/{fn}").get("AutomationSHA") or "")))
    failed_p = f"{KW}/boot-open-{g}.failed.json"
    failed = os.path.exists(failed_p)
    if t0 >= since:
        starts += 1
        opens += 0 if failed else 1
    if failed:
        # failed.json's At is the session START (== the request), so only its write time ends the FEL load
        t1 = max(t0, mtime_or(failed_p, None) or tparse(jload(failed_p).get("At"), t0))
        busy.append((t0, t1))
        failed_loads.append((t0, t1))
        occ_end[g] = t1
        continue
    term_p = f"{KW}/{g}/terminal.json"
    term = jload(term_p)
    if term:
        term_m = mtime_or(term_p, None)
        t1 = (tparse((term.get("PowerAtClose") or {}).get("ClosedAt"), None)
              or tparse(jload(f"{KW}/{g}/revoked.json").get("At"), None) or term_m or t0)
    else:
        term_m = None
        t1 = t0 + INFLIGHT_MAX
    closed_by_now = bool(term) and t1 <= now
    t1 = max(t0, min(t1, now))
    opened_at = min(max(tparse(jload(f"{KW}/{g}/active.json").get("OpenedAt"), t0), t0), t1)
    busy.append((t0, t1))
    occ_end[g] = max(t1, term_m or t1)
    if term_m and term_m > t1:
        teardowns.append((t1, term_m))
    boot_s += clipped(opened_at, t1)
    if closed_by_now and t0 >= since:
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

# ---- idle time: the gaps between busy intervals, split by cause (see "Idle attribution" above) ----
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

RUNS = (os.environ.get("FB_GPU16_DIR") or "/home/matt/recovery/gpu16") + "/runs"
SEAL_FILE_RE = re.compile(r"DEVICE[_-]?REQUEST", re.I)       # a sealed window request, as relayed to BENCH
NOT_A_SEAL_RE = re.compile(r"DEPLOY|DIAGNOSTIC|OBSERVER", re.I)  # a relay of these is not a sealed device request
RELAYED_RE = re.compile(r"RELAYED from=(\S+) to=(\S+) file=(\S+).* at=(\S+)")
SEALED_ORDERED_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (?:EVENT run=\S+ \S+ )?SEALED_ORDERED\b(.*)$")
HALT_EVENT_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) EVENT run=\S+ \S+ RUNNER_QUEUE_HALT reason=\S+ gens=\S+ since=(\S+Z)\b")
HALT_CLEARED_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) RUNNER_QUEUE_HALT_CLEARED reason=\S+ gens=\S+ since=(\S+Z)\b")


def read_lines(path):
    try:
        with open(path, errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return None


def seal_sources():
    """Sealed device requests and observer dry-runs. Returns (sealed, observers, marks, readable): sealed and observers are
    [(start, end)] while the request waited, marks is [(sealed at, auto seal?)], readable says whether any seal record could be read.
    Seals: the relay-sent ledger's window_request rows (the generation names the boot-open that ends the wait; hand and auto
    seals alike), info.log SEALED_ORDERED lines for a generation the ledger lacks, and relay.log lane->BENCH relays of a
    DEVICE_REQUEST file (the pre-ledger record; a DIAGNOSTIC_REQUEST, DEPLOY_REQUEST or note is not a seal)."""
    launches = sorted(launch_at.values())
    def next_launch(at):
        return next((x for x in launches if x >= at), now)
    def launch_of(gen, at):
        t = launch_at.get(gen) or next((x for g, x in launch_at.items() if g.startswith(gen[:8])), None)
        return t if t and t >= at else next_launch(at)
    seals = {}  # gen8 -> (at, lane, gen)
    readable = False
    try:
        with open(RUNS + "/relay-sent.json") as f:
            rows = json.load(f)
        readable = isinstance(rows, dict)
        for row in (rows.values() if readable else ()):
            if isinstance(row, dict) and row.get("kind") == "window_request" and re.fullmatch(r"[0-9a-f]{32}", str(row.get("generation"))):
                at = tparse(row.get("at"), None)
                if at:
                    seals.setdefault(row["generation"][:8], (at, str(row.get("requester") or "-"), row["generation"]))
    except (OSError, ValueError):
        pass
    auto = set()
    info = read_lines(RUNS + "/info.log")
    for line in info or ():
        m = SEALED_ORDERED_RE.match(line)
        gen = re.search(r"\bgen=([0-9a-f]{8,32})\b", m.group(2)) if m else None
        if not gen:
            continue
        lane = re.search(r"\blane=(\S+)", m.group(2))
        if "auto seal" in m.group(2):
            auto.add(gen.group(1)[:8])
        seals.setdefault(gen.group(1)[:8], (when(m.group(1)), lane.group(1) if lane else "-", gen.group(1)))
    readable = readable or info is not None
    sealed = [(at, launch_of(gen, at)) for at, lane, gen in seals.values()]
    marks = [(at, gen[:8] in auto) for at, lane, gen in seals.values()]
    ledger_ats = [(at, lane) for at, lane, gen in seals.values()]
    relay = read_lines(RUNS + "/relay.log")
    readable = readable or relay is not None
    results, observers, relayed = [], [], []
    for line in relay or ():
        m = RELAYED_RE.match(line)
        at = tparse(m.group(4), None) if m else None
        if not at:
            continue
        base = os.path.basename(m.group(3))
        if m.group(1) == "BENCH":
            results.append((at, m.group(2)))
        elif m.group(2) == "BENCH" and "OBSERVER-DRY-RUN" in base:
            observers.append((at, m.group(1)))
        elif m.group(2) == "BENCH" and SEAL_FILE_RE.search(base) and not NOT_A_SEAL_RE.search(base):
            if not any(l == m.group(1) and abs((a - at).total_seconds()) <= 120 for a, l in ledger_ats):
                relayed.append((at, m.group(1)))
    after = lambda lane, at: [r for r, to in results if to == lane and r > at]
    sealed += [(at, min(after(lane, at) + [next_launch(at)])) for at, lane in relayed]
    marks += [(at, False) for at, lane in relayed]
    observers = [(at, min(after(lane, at) or [now])) for at, lane in observers]
    return sealed, observers, marks, readable


def halt_episodes():
    """Runner kit-queue HALT episodes [(onset, end)]: info.log RUNNER_QUEUE_HALT_CLEARED (since= .. its own time), a raised
    events.log RUNNER_QUEUE_HALT not yet cleared (since= .. now), and forceoff-cap clearance records (the newest failed.json of
    their Generations .. ClearedAt), for HALTs that predate the watcher."""
    eps, cleared, raised = [], set(), []
    for name in ("info.log", "events.log"):
        for line in read_lines(f"{RUNS}/{name}") or ():
            if "RUNNER_QUEUE_HALT" not in line:
                continue
            m = HALT_CLEARED_RE.match(line)
            if m:
                eps.append((tparse(m.group(2), None), tparse(m.group(1), None)))
                cleared.add(m.group(2))
                continue
            m = HALT_EVENT_RE.match(line)
            if m:
                raised.append(m.group(2))
    eps += [(tparse(s, None), now) for s in raised if s not in cleared]
    try:
        names = sorted(os.listdir(KW))
    except OSError:
        names = []
    for fn in names:
        if not re.fullmatch(r"forceoff-cap-clearance-[0-9-]+\.json", fn):
            continue
        rec = jload(f"{KW}/{fn}")
        failed_at = [mtime_or(f"{KW}/boot-open-{g}.failed.json", None) for g in rec.get("Generations") or ()]
        if rec.get("State") == "cleared" and all(failed_at) and failed_at:
            eps.append((max(failed_at), tparse(rec.get("ClearedAt"), None)))
    return [(a, b) for a, b in eps if a and b and b > a]


DEPLOY_READY_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (?:EVENT run=\S+ \S+ )?DEPLOY_READY\b.*?\bfile=(\S+DEPLOY-REQUEST-([^/\s]+?)\.(?:json|md))")
APPLIED_BY_RE = re.compile(r"^AppliedBy=\S+ (\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ)\b", re.M)
ISO_Z = r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"
BUILD_DISPATCH_RE = re.compile(rf"^({ISO_Z}) EVENT run=(\S+) \S+ BUILD_DISPATCH_RESULT\b")
IMAGE_PUBLISHED_RE = re.compile(rf"^(?:({ISO_Z}) )?(?:EVENT run=\S+ \S+ )?IMAGE_PUBLISHED\b(.*)$")
SEAL_READY_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) WAIT_RESULT\b.*?\btoken=SEAL_READY\b.*?\bresult=gen=([0-9a-f]{8,32})")


def log_lines():
    for name in ("info.log", "events.log"):
        yield from read_lines(f"{RUNS}/{name}") or ()


def deploy_gaps():
    """Runner deploys [(request filed, applied)]: from a DEPLOY_READY line (the deploy request filed, info.log/events.log) to the
    AppliedBy time of its DEPLOY-RESULT file (gpu16/deploys/DEPLOY-RESULT-<same name as the request>.txt). A pin change between
    two boot-opens is NOT a deploy (AutomationSHA is the clone each sealed request was pinned to); a request with no applied
    result yet books nothing."""
    out = []
    for line in log_lines():
        m = DEPLOY_READY_RE.match(line)
        if not m:
            continue
        try:
            with open(os.path.dirname(RUNS) + f"/deploys/DEPLOY-RESULT-{m.group(3)}.txt") as f:
                am = APPLIED_BY_RE.search(f.read())
        except OSError:
            continue
        a, b = tparse(m.group(1), None), tparse(am.group(1), None) if am else None
        if a and b and b > a:
            out.append((a, b))
    return out


def await_intervals():
    """([awaiting image], [seal-ready unsealed]). Awaiting image: BUILD_DISPATCH_RESULT .. the next IMAGE_PUBLISHED whose requester= is the
    dispatching lane (run=<LANE>), at its at= time when it has one. Seal-ready unsealed: a SEAL_READY wait result (result=gen=<id>) .. the first later SEALED_ORDERED
    whose gen= or after= starts with that id. Unmatched starts book nothing (a dispatch that never published is not a wait)."""
    dispatched, ready, images, seals = [], [], [], []
    for line in log_lines():
        m = BUILD_DISPATCH_RE.match(line)
        if m and tparse(m.group(1), None):
            dispatched.append((tparse(m.group(1), None), m.group(2)))
        m = IMAGE_PUBLISHED_RE.match(line)
        if m:
            rest = m.group(2)
            at = re.search(r"\bat=(" + ISO_Z + r")", rest)
            who = re.search(r"\brequester=(\S+)", rest)
            t = tparse(at.group(1), None) if at else tparse(m.group(1), None)
            if t and who:
                images.append((t, who.group(1)))
        m = SEAL_READY_RE.match(line)
        if m and tparse(m.group(1), None):
            ready.append((tparse(m.group(1), None), m.group(2)[:8]))
        m = SEALED_ORDERED_RE.match(line)
        if m:
            ids = [x[:8] for x in re.findall(r"\b(?:gen|after)=([0-9a-f]{8,32})\b", m.group(2))]
            seals.append((when(m.group(1)), ids))
    out_img, out_seal, taken = [], [], set()
    for t, lane in sorted(dispatched):
        cands = [u for u, who in images if who == lane and u > t and u not in taken]
        if cands:
            taken.add(min(cands))
            out_img.append((t, min(cands)))
    for t, gid in ready:
        end = next((u for u, ids in seals if u > t and gid in ids), None)
        if end:
            out_seal.append((t, end))
    return out_img, out_seal


def classify(gaps):
    """Seconds per cause inside GAPS; one cause per instant, first match wins (see "Idle attribution")."""
    sealed, observers, marks, readable = seal_sources()
    halts, deploys = halt_episodes(), deploy_gaps()
    images, seal_ready = await_intervals()
    near = lambda ivs: [(a, b) for a, b in ivs if b > since and a < now]  # only intervals that touch the window matter
    sealed, observers, halts, deploys = near(sealed), near(observers), near(halts), near(deploys)
    images, seal_ready = near(images), near(seal_ready)
    inside = lambda ivs, m: any(a <= m < b for a, b in ivs)
    out = {k: 0.0 for k in ("teardown", "halt", "deploy", "device", "observer", "awaiting_image", "seal_ready", "empty")}
    for ga, gb in gaps:
        cuts = {ga, gb}
        for ivs in (teardowns, halts, deploys, sealed, observers, images, seal_ready):
            cuts.update(x for iv in ivs for x in iv if ga < x < gb)
        pts = sorted(cuts)
        for p, q in zip(pts, pts[1:]):
            mid = p + (q - p) / 2
            if inside(teardowns, mid):
                k = "teardown"
            elif inside(halts, mid) and inside(sealed, mid):
                k = "halt"
            elif inside(deploys, mid):
                k = "deploy"
            elif inside(sealed, mid):
                k = "device"
            elif inside(observers, mid):
                k = "observer"
            elif inside(seal_ready, mid):
                k = "seal_ready"
            elif inside(images, mid):
                k = "awaiting_image"
            else:
                k = "empty"
            out[k] += (q - p).total_seconds()
    seen = [auto for at, auto in marks if since <= at <= now]
    return out, readable, len(seen), sum(seen)


cls, have_seal_records, n_sealed_in_window, n_auto = classify(gaps)
gap_s = sum((b - a).total_seconds() for a, b in gaps)
stopped_s = max(0.0, gap_s - cls["teardown"])  # idle time: gap time minus the runner closing out (the place is still held)
failed_s = sum(clipped(a, b) for a, b in failed_loads)
n_failed = sum(1 for a, b in failed_loads if clipped(a, b) > 0)
n_teardown = sum(1 for a, b in teardowns if clipped(a, b) > 0)
split = cls if have_seal_records else None


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
          f" | observer dry-run (device off)={split['observer']/3600:.1f}h | nothing sealed={split['empty']/3600:.1f}h"
          f" | runner queue HALT={split['halt']/3600:.1f}h | runner deploy={split['deploy']/3600:.1f}h"
          f" | awaiting image={split['awaiting_image']/3600:.1f}h | seal-ready unsealed={split['seal_ready']/3600:.1f}h")
print(f"  not idle (not in stopped): runner teardown={cls['teardown']/3600:.1f}h ({n_teardown})"
      f" | failed boot loads={failed_s/3600:.1f}h ({n_failed})")
if have_seal_records:
    print(f"  sealed requests seen in window: {n_sealed_in_window} (auto {n_auto})")
print(f"  beads closed: {beads if beads is not None else 'unknown'}")
if stops:
    print(f"  stops ({len(stops)}): " + " | ".join(stops[-4:]))
if "--record" in sys.argv:
    with open(FB + "/velocity.tsv", "a") as f:
        f.write("\t".join(map(str, [f"{now:%FT%TZ}", f"{hours:g}", working, sum(tally.values()),
                                    len(rows_moved), starts, opens, ok, fail, reuse,
                                    f"{boot_s/3600:.2f}", f"{stopped_s/3600:.2f}",
                                    beads if beads is not None else ""])) + "\n")
