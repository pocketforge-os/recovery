#!/usr/bin/env python3
"""collect.py -- gather live fleet state for gpu-14 into data.json (read-only).

Everything comes from live sources on every run; nothing is remembered between
runs except cache/run-state.json (pf-task run.status answers, so a `released`
run is never queried again and lanes outside the per-run pf-task time budget
still show their last known run state with its age).

Sources (all read-only):
  A. beads     `bd list --all --json --flat -n 0` (one call, every status) and
               `bd ready --json -n 0`; `bd comments <id> --json` only for stale
               candidates (bounded, see COMMENTS_MAX).
  B. lanes     <G>/<lane>-drive.log modified in the last LANE_LOG_WINDOW_H hours,
               `ps` for live lane-drive.sh drivers, <G>/admission-*.json for
               run->bead/model, and pf-task run.status (single-run primary-key
               lookups, sequential, each under PFTASK_TIMEOUT_S, total budget
               PFTASK_BUDGET_S). Never the pf-task journal/DB.
  C. PRs       `gh pr view` for PRs named in lane status lines (cached per run).
  D. device    the live window queue (fleet-board/window-queue.tsv, .done.tsv,
               .failed.tsv, .active, .pause, window-done/, /proc/locks for its run
               lock), the legacy <G>/queue.tsv, queue.done, device-queue.txt, `ps`
               for the queue runner and a running direct-boot.sh kit.
  E. owner     /home/matt/gpu14-owner-questions.md "## Needs you" section.

data.json schema (top level):
  generated_at (ISO UTC), generated_epoch, host, runtime_s
  thresholds        {name: value} the constants below, for the page footer
  errors            [{source, error}] every source that could not be read
  summary           {needs, lanes_total, lanes_running, lanes_waiting, lanes_needs,
                     lanes_unknown, dispatchable, newly_unblocked, stale, owner_asks,
                     device:{running, pending, halted, runner_alive, kit_running, wq_depth,
                     wq_held, wq_active, wq_active_phase, wq_paused, wq_running}}
  needs             [{rank, kind, id, lane, bead, run, pr, reason, since, age_s, next}]
                    kind in handback|merge_ready|boot_ready|blocked|stale|undriven|
                    device|dispatchable ; sorted by rank
  lanes             [{lane, token, run, run_state, run_checked_at, run_fresh, bead,
                     bead_title, model, provider, runtime, driver_alive, driver_pids,
                     last_status:{n, state, reason, kv, ts, raw}, last_event_at,
                     last_turn_end, ci_wait:{pr, head, result, ts}, pr, pr_head,
                     reconciler_alive, controller_alive, runtime_alive,
                     native_activity_age_s, worktree, blocker_error,
                     cls (needs|waiting|running|released|unknown|evidence), kind, cls_reason,
                     next, log, log_mtime, source (log|admission), evidence:{who, bead}|null}]
                    (cls evidence: a parked run kept as evidence_for=<who>[:<bead>], see park_condition)
  prs               {"owner/repo#N": {state, merged_at, head, review, draft, title,
                     url, checks:{total, success, pending, failed, failed_names},
                     ci_green, merge_ready, fetched_at, error}}
  dispatchable      {parallel:[bead], newly_unblocked:[bead], chains:[{blocker:bead,
                     dependents:[bead]}], backlog_count, parallel_shown, chains_total}
                    bead = {id, title, status, priority, type, tier, parent,
                            parent_title, updated_at, created_at, blockers:[{id,
                            status, closed_at, title}], lane}
  device            {runner_alive, kit_running, kit_proc, halted, halt_line,
                     running:{name, started_at, elapsed_s, receipt}|null,
                     next:[{name, type, path, sha, args, position}], pending_count,
                     held_count, done_count, results:[{ts, name, verdict, cls,
                     detail}], events:[{ts, kind, text}], last_line, log_mtime,
                     window_queue:{running, running_via, paused, pause_line, pause_at, depth,
                     held_count, withdrawn_count, active:{gen, lane, owner, label, phase,
                     since, pkg}|null, pending:[row+position], held:[row+hold, held_at,
                     reason], done_count, failed_count, recent:[{ts, gen, lane, label,
                     outcome, src}]}}
                    (lanes[].window_queue = {gen, state, text, position} for a BOOT_READY lane)
  stale             [{id, title, status, assignee, tier, parent, updated_at,
                     last_comment_at, comment_count, age_s}]
  long_idle         {count, ids:[...]}   in_progress in scope, untouched > STALE_LOOKBACK_H
  owner_asks        {count, items:[{num, title}], error}
  owned             [{id, title, status, assignee, tier, parent, updated_at, age_s, priority}] beads with no lane
                    assigned to another coordinator (COORD_OWNERS); never needs or stale rows
  evidence          [{lane, run, bead, who, keeper_bead, reason, since, age_s}] parked runs kept as evidence
  beads_index       {id: {title, status, type, priority}} for every id referenced
  hardware          {rows:[hwrow], tally:{state: n}, flags:{unowned, evidence_old, anchor_closed, no_anchor},
                     source, comments_fetched, error}   one row per hardware block (hardware-rows.json)
  priorities        {goals:[{id, tier, name, why, anchor, anchor_status, open_count, lanes, tally, rows:[hwrow]}]}
                    hwrow = {id, name, subsystem|area, scope, driver, driver_source, anchor:[id], anchor_status:
                             [{id, status}], open_count, open_top:[{id, title, status, priority}], last_activity,
                             last_activity_age_s, lanes:[lane], queued:[{lane, bead}], state, state_source
                             (hw_row|seed), build, evidence, evidence_at, evidence_by, evidence_age_s,
                             flags:[unowned|evidence_old|anchor_closed|no_anchor]}
                    state = the latest `HW_ROW state=<S> build=<N> evidence=<text>` comment on an anchor bead
                    (optional row=<id> limits it to one row), else the seed (seed_state, seed_at)
  backlog           {open_total, p0, p1, older_14d, buckets:[label], totals:[n], areas:[{area, total, p0, p1,
                     counts:[n]}], other:{areas, total, p0, p1, counts}, areas_total, batches:[{batch, total,
                     open, in_progress, blocked, closed, top:[{id, title, status, priority}]}]}
                    every bead with status open (all scopes), age from created_at, area = id to two segments
"""
import struct
import collections
import concurrent.futures as cf
import datetime as dt
import glob
import json
import os
import re
import socket
import subprocess
import sys
import time

# ---------------------------------------------------------------- constants --
# 2026-10-20 (tsp-mc9m.41.1030.55): FB_GPU14_DIR points the run at a copy of the gpu14 inputs (hermetic tests,
# before/after dry runs against a snapshot); unset, it is the live dir.
G = os.environ.get("FB_GPU14_DIR") or "/home/matt/recovery/gpu14"
SECONDARY_PR_WINDOW_H = 12  # 2026-10-12: secondary PRs named by a lane within this window are checked for RED CI
PARK_MAX_H = 12
# 2026-10-20 (tsp-mc9m.41.1030.55): ~20 rows sat on "Needs gpu-14" for 10+ h and only 2 were gpu-14's. Beads assigned
# to another coordinator identity are that coordinator's (proc-coord drives its beads through its own subagents, not
# pf-task lanes): they leave gpu-14's needs and stale rows and show in an "Owned by <who>" group. Any other assignee
# keeps today's behavior.
COORD_OWNERS = ("proc-coord",)
PARKED = {}
RUN_BOUNDS = {}
try:
    for _l in open(f"{G}/run-bounds.tsv"):
        _f = _l.rstrip("\n").split("\t")
        if len(_f) >= 2 and _f[1].isdigit():
            RUN_BOUNDS[_f[0]] = int(_f[1])
except OSError:
    pass
try:
    with open(os.path.join(G, "fleet-board", "parked.tsv")) as _f:
        for _l in _f:
            _c = _l.rstrip("\n").split("\t")
            if len(_c) >= 3 and _c[0].startswith("pft-"):
                PARKED[_c[0]] = (_c[1], _c[2])
except FileNotFoundError:
    pass
# 2026-10-11: a dispatchable or stale bead that is not gpu-14's to dispatch (another coordinator's epic) or that
# waits on a named dependency nagged every tick. waits.tsv (bead_id<TAB>since_iso<TAB>reason) records why it
# waits; such a bead drops out of NEEDS for WAIT_MAX_H, then comes back so a stale wait cannot hide work.
WAIT_MAX_H = 24
# 2026-10-13 (b8p #1427): class-a-shard sat queued 90 min while pf-runner-pool looped one slot on
# guest_preflight_failed; the lane read "CI running" every tick. A CI_WAIT still pending past this is a pool stall.
CI_STALL_MIN = 60
WAITS = {}
try:
    with open(os.path.join(G, "fleet-board", "waits.tsv")) as _f:
        for _l in _f:
            _c = _l.rstrip("\n").split("\t")
            if len(_c) >= 3 and _c[0].startswith("tsp-"):
                WAITS[_c[0]] = (_c[1], _c[2])
except FileNotFoundError:
    pass


# 2026-10-12: an owner-paused epic (tsp-ihne1.*, input-coord) re-flagged one bead per day. A waits.tsv id ending in
# ".*" covers every descendant. Same 24 h expiry, so one row is refreshed daily.
def wait_for(bid):
    # The freshest matching row wins (an expired exact row must not mask a fresh epic-wide one).
    cands = [v for k, v in WAITS.items() if k == bid or (k.endswith(".*") and bid.startswith(k[:-1]))]
    return max(cands, key=lambda v: v[0]) if cands else None


MC = "/home/matt/mission-control"
BOARD = os.environ.get("FB_BOARD_DIR") or "/home/matt/recovery/gpu14/fleet-board"
OUT = os.path.join(BOARD, "data.json")
CACHE = os.path.join(BOARD, "cache", "run-state.json")
OWNER_ASKS = os.environ.get("FB_OWNER_ASKS") or "/home/matt/gpu14-owner-questions.md"
RUN_HOME_RESOLVER = "/home/matt/recovery/gpu14/pf-task-run-home"

# Campaign roots: a bead is in scope when its id equals a root or starts with "<root>.".
CAMPAIGN_ROOTS = [
    "tsp-mc9m.41",                  # A133/GPU epic (+ .995 tooling, .996 security, .1002 cloud-init, .1017 Build 7)
    "tsp-98733d6399be82e4f00c",     # GLES / imageStore
    "tsp-op5a.440",                 # gamescope
    "tsp-f3fm",                     # Poolsuite
    "tsp-ihne1",                    # input epic
    "tsp-h5ed.46",                  # pfvd simulator
    "tsp-wc8xc", "tsp-ds77e", "tsp-jfwnq", "tsp-z8vav",
]

LANE_LOG_WINDOW_H = int(os.environ.get("FB_LANE_LOG_WINDOW_H", 72))  # lane logs older than this are not lanes any more
ADMISSION_WINDOW_H = 72         # admission files this recent count as lanes even with no log
PFTASK_TIMEOUT_S = 60           # per run.status call
PFTASK_BUDGET_S = int(os.environ.get("FB_PFTASK_BUDGET_S", 150))  # total wall time for run.status calls per refresh
                                # (FB_PFTASK_BUDGET_S=400 once warms cache/run-state.json for every lane)
BUSY_IDLE_ALARM_MIN = 45        # busy run with no native activity for this long -> stale
BUSY_NO_SIGNAL_ALARM_MIN = 75   # busy run with no activity signal at all, started this long ago -> stale
HANDBACK_WITH_DRIVER_GRACE_MIN = 10  # HANDBACK while a driver is still alive: alarm after this
KIT_STUCK_H = 3                 # device step running this long without a result -> stale
STALE_BEAD_H = 6                # in_progress, no lane, no update/comment for this long -> stale
STALE_LOOKBACK_H = 168          # older untouched in_progress beads are "long idle", not alarms
STALE_INDIVIDUAL_H = 24         # stale beads idle longer than this are one aggregated needs item, not one each
RECENT_DAYS = 14                # dispatchable beads touched within this are "recent"; the rest is backlog
NEWLY_UNBLOCKED_H = 72          # a blocker closed within this window makes a ready bead "newly unblocked"
RESULTS_SHOW = 10               # device results listed
RESULTS_WINDOW_H = 24           # ... within this window (falls back to the last RESULTS_SHOW)
NEXT_SHOW = 5                   # pending device steps listed
PARALLEL_SHOW = 40              # dispatchable beads listed in full
CHAINS_SHOW = 30
GH_TIMEOUT_S = 40
GH_PARALLEL = 4
BD_TIMEOUT_S = 180
COMMENTS_PARALLEL = 4
COMMENTS_MAX = 150
COMMENTS_TIMEOUT_S = 30
# 2026-10-20 (gpu-14): hardware & driver rows and the open backlog. Rows live in hardware-rows.json beside this file;
# their live state is the latest HW_ROW comment on an anchor bead (README "Hardware rows"). Anchor comments are fetched
# only when the bead's comment_count moved since cache/hw-comments.json (bd comments per id is ~0.3 s; the bulk
# `bd show --include-comments` took 32 s for the same ids).
HW_ROWS_FILE = os.environ.get("FB_HW_ROWS") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "hardware-rows.json")
HW_COMMENTS_CACHE = os.path.join(BOARD, "cache", "hw-comments.json")
LANE_QUEUE_DIR = os.path.join(G, "fleet-board", "lane-queue")
HW_EVIDENCE_OLD_D = 7           # a row's evidence older than this is flagged "evidence old"
HW_TOP_OPEN = 3                 # open descendant beads listed per row (by priority)
HW_COMMENTS_BUDGET_S = 45       # wall time for re-reading anchor comments per refresh (runs beside the pf-task lookups)
HW_STATES = ("Working", "Partial", "Detected", "Broken", "Untested", "Parked", "HW-limit", "Deferred")
HW_OWNED_STATES = {"Working", "HW-limit", "Parked", "Deferred"}   # never flagged unowned (parked/deferred by owner ruling)
HW_KITS_CACHE = os.path.join(BOARD, "cache", "hw-kits.json")
HW_KITS_BUDGET_S = 5            # wall time for reading queued window-queue kit packages for bead ids (cached by mtimes)
HW_KIT_FILES_MAX = 64           # files read per kit package (OPERATOR.md, PREFLIGHT, requests-sealed/*.json, seed-kit/*)
HW_KIT_READ_MAX = 1 << 20       # bytes read per kit file
HW_REFS_MAX = 400               # kit paths / generations remembered per anchor from its own comments
BACKLOG_AREAS_SHOW = 15         # areas listed in the open-backlog table; the rest is one "other" row
BACKLOG_BUCKETS = (("<1 d", 1), ("1–3 d", 3), ("3–7 d", 7), ("7–14 d", 14), (">14 d", None))

NEEDS_STATES = {"HANDBACK", "BOOT_READY", "BLOCKED", "IDLE", "QUESTION", "MERGE_READY",
                "DESIGN_READY", "PARTIAL", "DIAG_ONLY"}
WAIT_STATES = {"CI_WAIT", "WAITING", "CONTINUE"}
NON_DISPATCH_TYPES = {"epic", "gate", "molecule", "convoy"}

KIND_RANK = {"merge_ready": 0, "handback": 1, "boot_ready": 2, "budget": 3, "device": 3, "blocked": 4,
             "stale": 5, "undriven": 6, "dispatchable": 7}

NOW = dt.datetime.now(dt.timezone.utc)
T0 = time.time()
ERRORS = []


def err(source, e):
    ERRORS.append({"source": source, "error": str(e)[:600]})


def iso(d):
    if d is None:
        return None
    if isinstance(d, (int, float)):
        d = dt.datetime.fromtimestamp(d, dt.timezone.utc)
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_ts(s):
    if not s:
        return None
    try:
        s = s.strip()
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        d = dt.datetime.fromisoformat(s)
        if d.tzinfo is None:
            d = d.replace(tzinfo=dt.timezone.utc)
        return d
    except Exception:
        return None


def age_s(d):
    if d is None:
        return None
    return max(0.0, (NOW - d).total_seconds())


# 2026-10-20 (tsp-mc9m.41.1030.55/.58): a dry run once fed fixture bead data through a `bd` stub on PATH; the stub fell
# through to the installed bd shim, which took the stub for the real bd, and the pair forked 114k processes. Fixture
# bead data comes in through this override instead: FB_BD_FIXTURE_DIR holds list.json (`bd list --all --json`),
# ready.json (`bd ready --json`) and comments/<id>.json (`bd comments <id> --json`). With it set, no bd is executed;
# a missing file is a source error.
BD_FIXTURE = os.environ.get("FB_BD_FIXTURE_DIR")


def bd_fixture(cmd):
    rel = {"list": "list.json", "ready": "ready.json"}.get(cmd[1] if len(cmd) > 1 else "")
    if len(cmd) > 2 and cmd[1] == "comments" and re.fullmatch(r"[A-Za-z0-9._-]+", cmd[2]):
        rel = os.path.join("comments", cmd[2] + ".json")
    if not rel:
        return 127, "", f"FB_BD_FIXTURE_DIR: no fixture for {' '.join(cmd[:3])}"
    try:
        with open(os.path.join(BD_FIXTURE, rel)) as f:
            return 0, f.read(), ""
    except OSError as ex:
        return 127, "", f"FB_BD_FIXTURE_DIR: {ex}"


def run_cmd(cmd, timeout, cwd=None, env=None):
    if BD_FIXTURE and cmd and cmd[0] == "bd":
        return bd_fixture(cmd)
    e = dict(os.environ)
    if env:
        e.update(env)
    try:
        p = subprocess.run(cmd, cwd=cwd, env=e, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s"
    except Exception as ex:  # binary missing etc.
        return 127, "", str(ex)


def in_scope(bid):
    return any(bid == r or bid.startswith(r + ".") for r in CAMPAIGN_ROOTS)


# -------------------------------------------------------------------- beads --
def collect_beads():
    """Return (index, ready_ids). index: id -> slim bead record for every bead."""
    index, ready = {}, []
    rc, out, errtxt = run_cmd(["bd", "list", "--all", "--json", "--flat", "-n", "0"], BD_TIMEOUT_S, cwd=MC)
    if rc != 0 or not out.strip():
        err("bd list --all", f"rc={rc} {errtxt.strip()[:300]}")
        return index, ready
    try:
        rows = json.loads(out)
    except Exception as ex:
        err("bd list --all (json)", ex)
        return index, ready
    for r in rows:
        md = r.get("metadata") or {}
        deps = [{"id": d.get("depends_on_id"), "type": d.get("type")}
                for d in (r.get("dependencies") or []) if d.get("depends_on_id")]
        index[r["id"]] = {
            "id": r["id"], "title": r.get("title") or "", "status": r.get("status"),
            "priority": r.get("priority"), "type": r.get("issue_type"),
            "assignee": r.get("assignee"), "parent": r.get("parent"),
            "tier": md.get("worker_tier") if isinstance(md, dict) else None,
            "updated_at": r.get("updated_at"), "created_at": r.get("created_at"),
            "closed_at": r.get("closed_at"), "started_at": r.get("started_at"),
            "comment_count": r.get("comment_count"), "deps": deps,
            "labels": [x for x in (r.get("labels") or []) if isinstance(x, str)],
        }
    rc, out, errtxt = run_cmd(["bd", "ready", "--json", "-n", "0"], BD_TIMEOUT_S, cwd=MC)
    if rc != 0 or not out.strip():
        err("bd ready", f"rc={rc} {errtxt.strip()[:300]}")
    else:
        try:
            ready = [r["id"] for r in json.loads(out)]
        except Exception as ex:
            err("bd ready (json)", ex)
    return index, ready


def fetch_comments(bid):
    rc, out, errtxt = run_cmd(["bd", "comments", bid, "--json"], COMMENTS_TIMEOUT_S, cwd=MC)
    if rc != 0:
        return bid, None, f"rc={rc} {errtxt.strip()[:200]}"
    try:
        rows = json.loads(out) if out.strip() else []
        last = max((c.get("created_at") or "" for c in rows), default=None)
        return bid, {"count": len(rows), "last": last or None}, None
    except Exception as ex:
        return bid, None, str(ex)


# -------------------------------------------------------------------- lanes --
TS_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (.*)$")
STATUS_RE = re.compile(r"^status\(result#(\d+)\):\s*(.*)$")
TOKEN_RE = re.compile(r"^([A-Z0-9_]+_STATUS)\s+state=([A-Za-z_]+)\s*(.*)$")
KV_RE = re.compile(r"(\w+)=(\S+)")
RUN_RE = re.compile(r"driver start run=(pft-[0-9a-f]{24})")
PR_RE = re.compile(r"^([\w.-]+/[\w.-]+)#(\d+)$")
HEX64_RE = re.compile(r"[0-9a-f]{64}")
# window-queue.sh field(): the FIRST whitespace-delimited gen= value, trailing `*,; stripped, must be 32 hex.
STATUS_GEN_RE = re.compile(r"(?:^|\s)gen=(\S+)")
BEAD_RE = re.compile(r"(tsp-[a-z0-9]+(?:\.[0-9]+)*)")


def parse_lane_log(path):
    lane = {"lane": os.path.basename(path)[:-len("-drive.log")], "log": path,
            "log_mtime": iso(os.path.getmtime(path)), "runs": [], "statuses": [],
            "ci_waits": [], "turn_ends": [], "driver_starts": [], "last_event_at": None,
            "last_line": None, "token": None}
    try:
        with open(path, errors="replace") as f:
            lines = f.read().splitlines()
    except Exception as ex:
        err(f"lane log {path}", ex)
        return lane
    for ln in lines:
        m = TS_RE.match(ln)
        if not m:
            continue
        ts, rest = m.group(1), m.group(2)
        lane["last_event_at"] = ts
        lane["last_line"] = ln[:300]
        rm = RUN_RE.search(rest)
        if rm:
            lane["runs"].append(rm.group(1))
            lane["driver_starts"].append(ts)
            continue
        sm = STATUS_RE.match(rest)
        if sm:
            n, body = int(sm.group(1)), sm.group(2).strip()
            st = {"n": n, "ts": ts, "raw": body[:400], "state": "NONE", "reason": None, "kv": {}, "gen": None}
            # 2026-10-19: the window-queue generation, read from the whole line (raw is clipped at 400 chars)
            gm = STATUS_GEN_RE.search(body)
            gv = re.sub(r"[`*,;]+$", "", gm.group(1)) if gm else ""
            st["gen"] = gv if re.fullmatch(r"[0-9a-f]{32}", gv) else None
            tm = TOKEN_RE.match(body)
            if tm:
                lane["token"] = tm.group(1)
                st["state"] = tm.group(2).upper()
                kv = dict(KV_RE.findall(tm.group(3)))
                st["kv"] = kv
                st["reason"] = kv.get("reason")
            lane["statuses"].append(st)
            continue
        if rest.startswith("CI_WAIT "):
            kv = dict(KV_RE.findall(rest))
            lane["ci_waits"].append({"ts": ts, "pr": kv.get("pr"), "head": kv.get("head"), "result": None,
                                     "result_ts": None, "pass": None, "fail": None})
            continue
        if rest.startswith("CIW result="):
            kv = dict(KV_RE.findall(rest))
            if lane["ci_waits"]:
                cw = lane["ci_waits"][-1]
                cw.update({"result": kv.get("result"), "result_ts": ts,
                           "pass": kv.get("pass"), "fail": kv.get("fail"), "now": kv.get("now")})
            continue
        if "TURN_END" in rest:
            kv = dict(KV_RE.findall(rest))
            lane["turn_ends"].append({"ts": ts, "state": kv.get("state"), "wake_reason": kv.get("wake_reason")})
    return lane


def live_drivers():
    """run_id -> {pids:[], lane, token} for every live lane-drive.sh."""
    out = {}
    rc, txt, e = run_cmd(["ps", "-eo", "pid,etimes,args"], 20)
    if rc != 0:
        err("ps", e)
        return out
    rx = re.compile(r"^\s*(\d+)\s+(\d+)\s+(?:/bin/)?bash\s+\S*lane-drive\.sh\s+(pft-[0-9a-f]{24})\s+(\S+)\s+(\S+)\s+(\S+)")
    for ln in txt.splitlines():
        m = rx.match(ln)
        if m:
            d = out.setdefault(m.group(3), {"pids": [], "lane": m.group(6), "token": m.group(4), "etimes": 0})
            d["pids"].append(int(m.group(1)))
            d["etimes"] = max(d["etimes"], int(m.group(2)))
    return out


def admission_map():
    """run_id -> {task, model, provider, runtime, file, mtime}"""
    out = {}
    for f in glob.glob(os.path.join(G, "admission-*.json")):
        try:
            d = json.load(open(f))
            rid = d.get("run_id")
            if not rid:
                continue
            prov = d.get("provenance") or {}
            model = ((prov.get("model") or {}).get("modelID") or {}).get("text")
            provider = ((prov.get("model") or {}).get("providerID") or {}).get("text")
            out[rid] = {"task": d.get("task"), "model": model, "provider": provider,
                        "runtime": prov.get("runtime"), "file": os.path.basename(f),
                        "mtime": os.path.getmtime(f)}
        except Exception as ex:
            err(f"admission {os.path.basename(f)}", ex)
    return out


def load_cache():
    try:
        return json.load(open(CACHE))
    except Exception:
        return {}


def save_cache(c):
    try:
        os.makedirs(os.path.dirname(CACHE), exist_ok=True)
        tmp = CACHE + ".new"
        json.dump(c, open(tmp, "w"), indent=0, sort_keys=True)
        os.replace(tmp, CACHE)
    except Exception as ex:
        err("cache write", ex)


def resolve_run_home(run_id):
    rc, out, error = run_cmd(
        [RUN_HOME_RESOLVER, "lookup", run_id], PFTASK_TIMEOUT_S)
    try:
        value = json.loads(out)
    except Exception:
        return None, f"run home unresolved: rc={rc} {error[:120]}"
    if rc or not isinstance(value, dict):
        return None, f"run home unresolved: rc={rc} {error[:120]}"
    return value, None


def pftask_status(run_id, home=None):
    """One primary-key run.status lookup. Returns slim dict or {'error': ...}."""
    if home is None:
        home, error = resolve_run_home(run_id)
        if error:
            return {"error": error}
    cmd = [home["pf_task"], "--home", home["control_home"], "--role", "coordinator", "run.status",
           json.dumps({"run_id": run_id})]
    rc, out, e = run_cmd(cmd, PFTASK_TIMEOUT_S,
                         env={"PF_TASK_HOST_CONFIG": home["host_config"]})
    try:
        d = json.loads(out) if out.strip() else {}
    except Exception:
        return {"error": f"rc={rc} non-json: {out[:120]} {e[:120]}"}
    if not d:
        return {"error": f"rc={rc} {e.strip()[:200] or 'empty output'}"}
    if d.get("status") == "refused" or "state" not in d:
        return {"error": f"refused: {d.get('reason') or json.dumps(d)[:160]}"}
    prov = d.get("provenance") or {}
    model = ((prov.get("model") or {}).get("modelID") or {}).get("text")
    provider = ((prov.get("model") or {}).get("providerID") or {}).get("text")
    runtime = prov.get("runtime")
    sid = d.get("session_id")
    if not runtime:
        runtime = "opencode" if (sid or "").startswith("ses_") else ("codex" if sid else None)
    lt = d.get("last_turn") or {}
    blk = d.get("blocker") or {}
    return {
        "state": d.get("state"), "task": d.get("task"), "session_id": sid,
        "reconciler_alive": d.get("reconciler_alive"), "controller_alive": d.get("controller_alive"),
        "runtime_alive": d.get("runtime_alive"),
        "native_activity_age_s": d.get("native_activity_age_seconds"),
        "messages_total": ((d.get("messages") or {}).get("total")
                           if home["control_home"] == "/home/matt/.pf-task-v2" else None),
        "last_turn_end": iso(lt.get("ended_at")) if isinstance(lt.get("ended_at"), (int, float)) else None,
        "last_turn_reason": lt.get("reason"),
        "worktree": (d.get("worktree") or {}).get("text") if isinstance(d.get("worktree"), dict) else d.get("worktree"),
        "blocker_state": blk.get("state"),
        "blocker_error": ((blk.get("error") or {}).get("text") or "")[:300],
        "runtime_parked": (d.get("runtime_parked") or {}).get("phase") if d.get("runtime_parked") else None,
        "model": model, "provider": provider, "runtime": runtime,
        "run_home": home["control_home"], "run_home_revision": home["revision"],
    }


def collect_lanes(drivers, adm, cache):
    lanes = []
    cutoff = time.time() - LANE_LOG_WINDOW_H * 3600
    for path in sorted(glob.glob(os.path.join(G, "*-drive.log"))):
        try:
            if os.path.getmtime(path) < cutoff:
                continue
        except OSError:
            continue
        ln = parse_lane_log(path)
        ln["source"] = "log"
        ln["run"] = ln["runs"][-1] if ln["runs"] else None
        lanes.append(ln)
    # 2026-10-19: a re-driven run can leave an older drive log under another lane name (payloadfix-r3 ->
    # payloadfix, same pft-b51a3e09). The run-matched driver made the stale log look alive and resurfaced its
    # old HANDBACK as Needs gpu-14. Only the most recently active log for a run counts.
    newest = {}
    for ln in lanes:
        if ln["run"] and (ln["run"] not in newest or (ln["last_event_at"] or "") > (newest[ln["run"]]["last_event_at"] or "")):
            newest[ln["run"]] = ln
    lanes = [ln for ln in lanes if not ln["run"] or newest[ln["run"]] is ln]
    # admitted runs (recent admission file) with no lane log at all: nothing wakes gpu-14 for them
    logged_runs = {l["run"] for l in lanes if l["run"]}
    for rid, a in adm.items():
        if rid in logged_runs or a["mtime"] < time.time() - ADMISSION_WINDOW_H * 3600:
            continue
        lanes.append({"lane": a["file"].replace("admission-", "").replace(".json", ""), "log": None,
                      "log_mtime": iso(a["mtime"]), "runs": [rid], "run": rid, "statuses": [], "ci_waits": [],
                      "turn_ends": [], "driver_starts": [iso(a["mtime"])], "last_event_at": iso(a["mtime"]),
                      "last_line": f"admission {a['file']} (no lane log)", "token": None, "source": "admission"})
    for ln in lanes:
        d = drivers.get(ln["run"]) if ln["run"] else None
        if not d:  # a driver may also be matched by lane name (same lane, re-driven run)
            d = next((v for v in drivers.values() if v["lane"] == ln["lane"]), None)
        ln["driver_alive"] = bool(d)
        ln["driver_pids"] = d["pids"] if d else []
        ln["driver_etimes"] = d["etimes"] if d else None
        if d and not ln["token"]:
            ln["token"] = d["token"]
        ls = ln["statuses"][-1] if ln["statuses"] else None
        ln["last_status"] = ls
        a = adm.get(ln["run"]) if ln["run"] else None
        ln["adm"] = a
    # pf-task run.status: sequential, bounded, released runs cached forever
    def prio(ln):
        c = cache.get(ln["run"] or "", {})
        checked = parse_ts(c.get("checked_at"))
        ls = ln["last_status"]
        last = parse_ts(ls["ts"]) if ls else parse_ts(ln["last_event_at"])
        return (1 if ln["driver_alive"] else 0, checked.timestamp() if checked else 0,
                -(last.timestamp() if last else 0))
    budget_end = time.time() + PFTASK_BUDGET_S
    done_runs = {}
    for ln in sorted(lanes, key=prio):
        rid = ln["run"]
        if not rid:
            ln["run_info"] = None
            ln["run_fresh"] = False
            continue
        if rid in done_runs:
            ln["run_info"], ln["run_fresh"], ln["run_checked_at"] = done_runs[rid]
            continue
        home, home_error = resolve_run_home(rid)
        c = cache.get(rid)
        cache_matches = bool(c and home and (
            (c.get("run_home") == home["control_home"]
             and c.get("run_home_revision") == home["revision"])
            or (not c.get("run_home") and not c.get("run_home_revision")
                and home["control_home"] == "/home/matt/.pf-task-v2")))
        if home_error:
            info, fresh, at = {"error": home_error}, True, iso(NOW)
        elif cache_matches and c.get("state") == "released":
            info, fresh, at = {k: v for k, v in c.items() if k != "checked_at"}, False, c.get("checked_at")
        elif time.time() + 5 > budget_end:
            info = ({k: v for k, v in c.items() if k != "checked_at"}
                    if cache_matches else None)
            fresh, at = False, (c or {}).get("checked_at") if cache_matches else None
            if info is None:
                info = {"error": "not checked: pf-task time budget exhausted this refresh"}
        else:
            info = pftask_status(rid, home)
            fresh, at = True, iso(NOW)
            if "error" not in info:
                cache[rid] = dict(info, checked_at=at)
            elif cache_matches:
                info = dict({k: v for k, v in c.items() if k != "checked_at"}, error=info["error"])
                fresh, at = False, c.get("checked_at")
        done_runs[rid] = (info, fresh, at)
        ln["run_info"], ln["run_fresh"], ln["run_checked_at"] = info, fresh, at
    return lanes


# ---------------------------------------------------------------------- PRs --
def pr_refs_from_lanes(lanes):
    refs = {}
    for ln in lanes:
        ls = ln["last_status"]
        cands = []
        if ls and ls["kv"].get("pr"):
            cands.append((ls["kv"]["pr"], ls["kv"].get("head")))
        if ln["ci_waits"]:
            cw = ln["ci_waits"][-1]
            cands.append((cw.get("pr"), cw.get("head")))
        for pr, head in cands:
            if pr and PR_RE.match(pr):
                refs.setdefault(pr, head)
                ln["pr"] = ln.get("pr") or pr
                ln["pr_head"] = ln.get("pr_head") or head
        # 2026-10-12 (lin pft-fe54e79f): a lane juggling two PRs (automation#1401 + platform#329) ended each turn on
        # #1401, so its driver watched only that one; #329 went RED and sat ~45 min unseen. Track every other PR the
        # lane named in a status line within SECONDARY_PR_WINDOW_H as a secondary, so a RED one becomes a need.
        sec = []
        cutoff = NOW.timestamp() - SECONDARY_PR_WINDOW_H * 3600
        for st in ln["statuses"]:
            spr = st["kv"].get("pr")
            sts = parse_ts(st["ts"])
            if spr and PR_RE.match(spr) and spr != ln.get("pr") and spr not in sec and sts and sts.timestamp() >= cutoff:
                sec.append(spr)
                refs.setdefault(spr, None)
        ln["secondary_prs"] = sec
    return refs


def fetch_pr(ref):
    m = PR_RE.match(ref)
    repo, num = m.group(1), m.group(2)
    rc, out, e = run_cmd(["gh", "pr", "view", num, "-R", repo, "--json",
                          "state,mergedAt,headRefOid,statusCheckRollup,reviewDecision,isDraft,title,url"],
                         GH_TIMEOUT_S)
    if rc != 0:
        return ref, {"error": f"rc={rc} {e.strip()[:200]}", "fetched_at": iso(NOW)}
    try:
        d = json.loads(out)
    except Exception as ex:
        return ref, {"error": f"json: {ex}", "fetched_at": iso(NOW)}
    tot = succ = pend = fail = 0
    failed = []
    for c in d.get("statusCheckRollup") or []:
        tot += 1
        if c.get("__typename") == "StatusContext":
            s = (c.get("state") or "").upper()
            if s in ("SUCCESS",):
                succ += 1
            elif s in ("PENDING", "EXPECTED", ""):
                pend += 1
            else:
                fail += 1
                failed.append(c.get("context") or "status")
        else:
            st = (c.get("status") or "").upper()
            con = (c.get("conclusion") or "").upper()
            if st != "COMPLETED":
                pend += 1
            elif con in ("SUCCESS", "NEUTRAL", "SKIPPED"):
                succ += 1
            else:
                fail += 1
                failed.append(c.get("name") or "check")
    state = d.get("state")
    ci_green = tot > 0 and pend == 0 and fail == 0
    return ref, {
        "state": state, "merged_at": d.get("mergedAt"), "head": d.get("headRefOid"),
        "review": d.get("reviewDecision") or "", "draft": d.get("isDraft"), "title": d.get("title"),
        "url": d.get("url"),
        "checks": {"total": tot, "success": succ, "pending": pend, "failed": fail, "failed_names": failed[:6]},
        "ci_green": ci_green,
        "merge_ready": state == "OPEN" and not d.get("isDraft") and ci_green and d.get("reviewDecision") == "APPROVED",
        "fetched_at": iso(NOW),
    }


def collect_prs(refs):
    prs = {}
    if not refs:
        return prs
    with cf.ThreadPoolExecutor(GH_PARALLEL) as ex:
        for ref, info in ex.map(fetch_pr, sorted(refs)):
            prs[ref] = info
            if info.get("error"):
                err(f"gh pr view {ref}", info["error"])
    return prs


# ------------------------------------------------------------------- device --
DQ_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) (.*)$")


def collect_device():
    dev = {"runner_alive": False, "kit_running": False, "kit_proc": None, "halted": False, "halt_line": None,
           "running": None, "next": [], "pending_count": 0, "held_count": 0, "done_count": 0,
           "results": [], "events": [], "last_line": None, "log_mtime": None}
    rc, txt, e = run_cmd(["ps", "-eo", "pid,etimes,args"], 20)
    if rc == 0:
        for ln in txt.splitlines():
            if re.search(r"\sbash\s+\S*queue-runner\.sh(\s|$)", ln) and "grep" not in ln:
                dev["runner_alive"] = True
            m = re.search(r"\sbash\s+(?:/home/matt/recovery/\S*/kits/\S*/|\./)direct-boot\.sh\s+(\S+)(.*)$", ln)
            if m and "--offline-only" not in ln and " --check" not in ln:
                dev["kit_running"] = True
                dev["kit_proc"] = (m.group(1) + m.group(2))[:200]
    done = set()
    try:
        with open(os.path.join(G, "queue.done")) as f:
            done = {l.strip() for l in f if l.strip()}
    except Exception as ex:
        err("queue.done", ex)
    dev["done_count"] = len(done)
    try:
        pos = 0
        with open(os.path.join(G, "queue.tsv")) as f:
            for raw in f:
                line = raw.rstrip("\n")
                if not line.strip():
                    continue
                cols = line.split("\t")
                if line.startswith("#"):
                    if len(cols) >= 6:
                        dev["held_count"] += 1
                        # 2026-10-11: a retired/failed row's kit is consumed, not BOOT_READY (wavea/reseal sat 18-50 h as boot_ready)
                        if cols[3] not in ("", "-"):
                            dev.setdefault("done_rows", {}).setdefault(cols[3], cols[0].lstrip("#"))
                    continue
                if len(cols) < 6:
                    continue
                name, typ, path, sha, mf, prefix = cols[:6]
                args = cols[6] if len(cols) > 6 else ""
                if name in done:
                    if sha not in ("", "-"):
                        dev.setdefault("done_rows", {})[sha] = name
                    continue
                pos += 1
                dev["pending_count"] = pos
                if len(dev["next"]) < NEXT_SHOW:
                    dev["next"].append({"name": name, "type": typ, "path": path, "sha": sha, "manifest": mf,
                                        "args": args, "position": pos})
                dev.setdefault("pending_all", []).append({"name": name, "type": typ, "sha": sha, "path": path})
    except Exception as ex:
        err("queue.tsv", ex)
    events = []
    try:
        p = os.path.join(G, "device-queue.txt")
        dev["log_mtime"] = iso(os.path.getmtime(p))
        with open(p, errors="replace") as f:
            lines = f.read().splitlines()
        dev["last_line"] = lines[-1][:300] if lines else None
        for ln in lines:
            m = DQ_RE.match(ln)
            if not m:
                continue
            ts, rest = m.group(1), m.group(2)
            ev = {"ts": ts, "text": rest[:400]}
            if rest.startswith("QUEUE empty"):
                ev.update(kind="empty")
            elif rest.startswith("HALT "):
                ev.update(kind="halt")
                m2 = re.match(r"HALT (?:after|before) (\S+?):?\s", rest)
                ev["name"] = m2.group(1) if m2 else None
            elif rest.startswith("SKIP "):
                ev.update(kind="skip")
                m2 = re.match(r"SKIP (\S+?):", rest)
                ev["name"] = m2.group(1) if m2 else None
            elif rest.startswith("CHAIN_WARN "):
                ev.update(kind="chain_warn")
                m2 = re.search(r"name=(\S+)", rest)
                ev["name"] = m2.group(1) if m2 else None
            else:
                m2 = re.match(r"(\S+) (START|RESULT|rc=|result\.json|no run\.log|\d{4}-\d\d-\d\dT\S+ RESULT)(.*)$", rest)
                if not m2:
                    ev.update(kind="note")
                    events.append(ev)
                    continue
                name, what, tail = m2.group(1), m2.group(2), m2.group(3)
                ev["name"] = name
                if what == "START":
                    ev.update(kind="start")
                    r = re.search(r"R=(\S+)", tail) or re.search(r"log=(\S+)", tail)
                    ev["receipt"] = r.group(1) if r else None
                else:
                    ev.update(kind="result")
                    body = (what + tail)
                    v = re.search(r"verdict=(\S+)", body)
                    rcm = re.match(r"rc=(\d+)", body)
                    om = re.search(r'"Outcome":"(\w+)"', body) or re.search(r'"Error":"(\w+)"', body)
                    stg = re.search(r"stage=(\S+)", body)
                    rsn = re.search(r"reason=(\S+)", body)
                    if v:
                        ev["verdict"] = v.group(1)
                    elif rcm:
                        ev["verdict"] = "rc=" + rcm.group(1)
                    elif om:
                        ev["verdict"] = om.group(1)
                    elif "no run.log" in body:
                        ev["verdict"] = "no-result"
                    else:
                        ev["verdict"] = "?"
                    ev["stage"] = stg.group(1) if stg else None
                    ev["detail"] = (("reason=" + rsn.group(1) + " ") if rsn else "") + body[:200]
                    vv = ev["verdict"].lower()
                    if vv in ("pass", "rc=0") or vv.endswith("-collected") or vv == "ok":
                        ev["cls"] = "good"
                    elif vv in ("na", "n/a", "no-result", "?"):
                        ev["cls"] = "neutral"
                    elif vv in ("stop", "blocked") or vv.startswith("rc="):
                        ev["cls"] = "warning"
                    else:
                        ev["cls"] = "critical"
            events.append(ev)
    except Exception as ex:
        err("device-queue.txt", ex)
    dev["events"] = events[-40:]
    # running now = last START with no later terminal/skip event for the same name
    last_start = None
    for i in range(len(events) - 1, -1, -1):
        if events[i]["kind"] == "start":
            last_start = (i, events[i])
            break
    if last_start:
        i, s = last_start
        finished = any(e.get("name") == s["name"] and e["kind"] in ("result", "skip", "halt") for e in events[i + 1:])
        if not finished:
            st = parse_ts(s["ts"])
            dev["running"] = {"name": s["name"], "started_at": s["ts"], "elapsed_s": age_s(st),
                              "receipt": s.get("receipt")}
    # 2026-10-13: a kit-resume series holds the DUT between rows but logs no START line, so the board said
    # device_running=- during Build 9 acceptance. kit-resume.active is the runner's own marker for an open series.
    if not dev.get("running"):
        try:
            with open(os.path.join(G, "kit-resume.active")) as f:
                active = json.load(f)
            anchor = active.get("Anchor") or ""
            series = os.path.basename(os.path.dirname(os.path.dirname(anchor))) or "kit-resume series"
            st_m = os.path.getmtime(os.path.join(G, "kit-resume.active"))
            dev["running"] = {"name": f"kit-resume {series}", "started_at": iso(st_m),
                              "elapsed_s": NOW.timestamp() - st_m, "receipt": os.path.dirname(anchor) or None}
        except FileNotFoundError:
            pass
        except Exception as ex:  # a malformed marker is itself worth surfacing
            err("kit-resume.active", ex)
    # 2026-10-13: the first live window (glcrash) booted with the board saying device_running=-. A live window lives in
    # the pf-kit-window-runner root: boot-open-<gen>.json while activating, <gen>/runner.json once open.
    if not dev.get("running"):
        wroot = os.path.expanduser("~/.local/state/pocketforge/kit-windows")
        try:
            for name in sorted(os.listdir(wroot)):
                m = re.fullmatch(r"boot-open-([0-9a-f]{32})\.json", name)
                if not m:
                    continue
                gen = m.group(1)
                rj = os.path.join(wroot, gen, "runner.json")
                state = "activating"
                if os.path.exists(rj):
                    with open(rj) as f:
                        state = str(json.load(f).get("State") or "unknown")
                if state in ("closed", "revoked"):
                    continue
                # 2026-10-13 18:06Z: a FAILED boot-open (boot-open-<gen>.failed.json, no runner.json) showed as
                # "activating" forever, and because the loop runs in name order it hid the real open window (4182dcde
                # sorted after 27b50af6). A failed boot-open is not running; an open window wins over anything else.
                if state == "activating" and os.path.exists(os.path.join(wroot, f"boot-open-{gen}.failed.json")):
                    continue
                if dev.get("running") and "(open)" in dev["running"]["name"] and state != "open":
                    continue
                # 2026-10-13: gen 38f5cccd's session closed (terminal.json CLOSED) but the runner never finalized and
                # runner.json still said open; show that instead of a live window.
                try:
                    with open(os.path.join(wroot, gen, "active.json")) as f:
                        anc = json.load(f).get("AnchorPath") or ""
                    if anc and os.path.exists(os.path.join(os.path.dirname(anc), "terminal.json")):
                        state = "session CLOSED, runner not finalized: disposition WAIT"
                except FileNotFoundError:
                    pass
                st_m = os.path.getmtime(os.path.join(wroot, name))
                dev["running"] = {"name": f"live window {gen[:8]} ({state})", "started_at": iso(st_m),
                                  "elapsed_s": NOW.timestamp() - st_m, "receipt": os.path.join(wroot, gen)}
        except FileNotFoundError:
            pass
        except Exception as ex:
            err("kit-windows", ex)
    # halted = a HALT with no later START or QUEUE empty. 2026-10-13: after a verified bench, the restarted runner
    # printed "QUEUE empty" on an empty queue, but the board kept saying HALTED (no START ever follows on an empty queue).
    last_halt = max((i for i, e in enumerate(events) if e["kind"] == "halt"), default=None)
    if last_halt is not None:
        later_start = any(e["kind"] in ("start", "empty") for e in events[last_halt + 1:])
        if not later_start and not dev["runner_alive"]:
            dev["halted"] = True
            dev["halt_line"] = events[last_halt]["text"]
            dev["halt_at"] = events[last_halt]["ts"]
    cutoff = NOW - dt.timedelta(hours=RESULTS_WINDOW_H)
    res = [e for e in events if e["kind"] in ("result", "halt", "skip")]
    recent = [e for e in res if (parse_ts(e["ts"]) or NOW) >= cutoff]
    dev["results"] = (recent if len(recent) >= RESULTS_SHOW else res)[-RESULTS_SHOW:][::-1]
    dev["window_queue"], dev["wq_by_gen"] = collect_window_queue()
    return dev


# ------------------------------------------------------------- window queue --
# 2026-10-19: since 10-16 (D4a) the live bench queue is window-queue.sh over fleet-board/window-queue.tsv, but the board
# read only the retired kits queue (queue.tsv): the bench tile said "0 queued" with rows queued, and lanes whose kit was
# queued, HELD or already consumed were flagged boot_ready. Formats are window-queue.sh's own (Q, ACTIVE, DONE, FAILED,
# PAUSE, MARK, RL there):
#   window-queue.tsv        ts lane owner TOKEN pkg gen steps label note; first non-comment row is next. '#' rows are
#                           comments; gpu-14 holds a row as `# HELD <why>` (or `# PARKED <why>`) + the original columns,
#                           and withdraws one as `#withdrawn-<who>-<ts> <why>` + the original columns.
#   window-queue.done.tsv   ts gen owner lane label outcome pkg (finish)
#   window-queue.failed.tsv ts kind reason + the popped 9-column row, so gen is column 9 (fail_row)
#   window-queue.active     key=value lines: gen owner lane token pkg label phase since
#   window-queue.pause      present = paused (the STOP line)
#   window-done/<gen>       success|failure<TAB>ts<TAB>source (the --done marker)
#   .window-queue.run.lock  flock held by the running loop for its whole life (running())
WQ_BOARD = os.environ.get("WQ_BOARD") or BOARD
KIT_WINDOWS = os.environ.get("PF_KIT_WINDOWS_DIR") or os.path.expanduser("~/.local/state/pocketforge/kit-windows")
WQ_SHOW = 15                    # pending / held window-queue rows listed
WQ_RECENT_SHOW = 8              # done / failed window-queue rows listed
WQ_GEN_RE = re.compile(r"^[0-9a-f]{32}$")
WQ_HOLD_RE = re.compile(r"^#\s*(HELD|PARKED)\b[\s:]*(.*)$")
WQ_WITHDRAWN_RE = re.compile(r"^#\s*withdrawn-(\S+)\s*(.*)$", re.I)
WQ_TAIL_TS_RE = re.compile(r"[\s:#]*\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\s*$")   # the row's own ts, kept after the prefix
WQ_LEAD_TS_RE = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d)?Z)\s*")


def wq_running(lock_path):
    """window-queue.sh running(): the loop holds an flock on .window-queue.run.lock, so `flock -n` fails while it runs.
    Answer the same question by reading /proc/locks for a granted FLOCK on that inode: a pure read that never takes the
    lock, so a refresh can never make a starting loop exit already_running. Without /proc/locks, fall back to the
    same non-blocking probe --status uses. Returns (running, method)."""
    try:
        s = os.stat(lock_path)
    except FileNotFoundError:
        return False, "no_lock_file"
    want = (os.major(s.st_dev), os.minor(s.st_dev), s.st_ino)
    try:
        with open("/proc/locks") as f:
            for ln in f:
                p = ln.split()
                if len(p) < 6 or p[1] != "FLOCK":   # "N: -> FLOCK ..." is a blocked waiter, not a holder
                    continue
                mm = p[5].split(":")
                try:
                    if (int(mm[0], 16), int(mm[1], 16), int(mm[2])) == want:
                        return True, "proc_locks"
                except (ValueError, IndexError):
                    continue
        return False, "proc_locks"
    except OSError:
        pass
    import fcntl
    fd = os.open(lock_path, os.O_WRONLY | os.O_APPEND)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True, "flock_probe"
    finally:
        os.close(fd)   # closing the only fd releases a probe lock we did take
    return False, "flock_probe"


def collect_window_queue():
    """Return (window_queue summary for data.json, {gen: disposition}). A disposition is
    {state: active|pending|held|consumed, text, ...}; precedence active > pending > held > done/failed/marker > withdrawn."""
    fb = WQ_BOARD
    wq = {"path": os.path.join(fb, "window-queue.tsv"), "running": None, "running_via": None, "paused": False,
          "pause_line": None, "pause_at": None, "depth": 0, "held_count": 0, "withdrawn_count": 0, "active": None,
          "pending": [], "held": [], "done_count": 0, "failed_count": 0, "recent": []}
    by_gen = {}
    try:
        wq["running"], wq["running_via"] = wq_running(os.path.join(fb, ".window-queue.run.lock"))
    except Exception as ex:
        err("window-queue run lock", ex)
    pp = os.path.join(fb, "window-queue.pause")
    if os.path.isfile(pp):
        wq["paused"] = True
        try:
            wq["pause_at"] = iso(os.path.getmtime(pp))
            with open(pp, errors="replace") as f:
                wq["pause_line"] = f.read(200).strip()
        except OSError as ex:
            err("window-queue.pause", ex)
    try:
        kv = {}
        with open(os.path.join(fb, "window-queue.active"), errors="replace") as f:
            for l in f:
                k, sep, v = l.rstrip("\n").partition("=")
                if sep and k not in kv:
                    kv[k] = v
        if kv.get("gen"):   # --status: sed -n 's/^gen=//p' | head -1
            wq["active"] = {k: kv.get(k) for k in ("gen", "lane", "owner", "label", "phase", "since", "pkg")}
    except FileNotFoundError:
        pass
    except Exception as ex:
        err("window-queue.active", ex)
    # done / failed / markers: every outcome a generation has had, oldest first
    outcomes = collections.defaultdict(list)
    recent = []
    for fn, src in (("window-queue.done.tsv", "done"), ("window-queue.failed.tsv", "failed")):
        try:
            with open(os.path.join(fb, fn), errors="replace") as f:
                for raw in f:
                    line = raw.rstrip("\n")
                    if not line:
                        continue
                    wq[src + "_count"] += 1          # --status counts failed rows with grep -c .
                    c = line.split("\t")
                    if src == "done" and len(c) >= 6:
                        g, oc, lane, label = c[1], c[5], c[3], c[4]
                    elif src == "failed" and len(c) >= 9:
                        g, oc = c[8], f"failed {c[1]}" + (f" {c[2]}" if c[2] else "")
                        lane, label = c[4], (c[10] if len(c) > 10 else "")
                    else:
                        continue
                    oc = re.sub(r"\s*gen=[0-9a-f]{32}", "", oc)
                    outcomes[g].append((c[0], oc[:160]))
                    recent.append({"ts": c[0], "gen": g, "lane": lane, "label": label, "outcome": oc[:200], "src": src})
        except FileNotFoundError:
            pass
        except Exception as ex:
            err(fn, ex)
    wq["recent"] = sorted(recent, key=lambda r: r["ts"], reverse=True)[:WQ_RECENT_SHOW]
    for g, ocs in outcomes.items():
        if WQ_GEN_RE.match(g):
            by_gen[g] = {"state": "consumed", "outcome": "; ".join(o for _t, o in sorted(ocs)[-3:]), "src": "window-queue"}
    try:
        md = os.path.join(fb, "window-done")
        for g in os.listdir(md):
            if WQ_GEN_RE.match(g) and g not in by_gen:
                with open(os.path.join(md, g), errors="replace") as f:
                    m = f.readline().split("\t")
                by_gen[g] = {"state": "consumed", "outcome": f"window-done marker {m[0].strip() or '?'}"
                             + (f" ({m[2].strip()})" if len(m) > 2 and m[2].strip() else ""), "src": "window-done"}
    except FileNotFoundError:
        pass
    except Exception as ex:
        err("window-done markers", ex)
    # the queue file: pending rows (position = order among non-comment rows, as head_row/--status count them)
    held_gens = {}
    try:
        with open(wq["path"], errors="replace") as f:
            for raw in f:
                line = raw.rstrip("\n")
                if not line.strip():
                    continue
                c = line.split("\t")
                row = {"ts": c[0], "lane": c[1] if len(c) > 1 else "", "run": c[2] if len(c) > 2 else "",
                       "token": c[3] if len(c) > 3 else "", "pkg": c[4] if len(c) > 4 else "",
                       "gen": c[5] if len(c) > 5 else "", "steps": c[6] if len(c) > 6 else "",
                       "label": c[7] if len(c) > 7 else "", "note": (c[8] if len(c) > 8 else "")[:200]}
                if line.lstrip().startswith("#"):
                    if not WQ_GEN_RE.match(row["gen"]):
                        continue                     # header or a free comment
                    head = c[0].strip()
                    mh, mw = WQ_HOLD_RE.match(head), WQ_WITHDRAWN_RE.match(head)
                    if mw:
                        why = WQ_TAIL_TS_RE.sub("", mw.group(2)).strip() or "withdrawn"
                        wq["withdrawn_count"] += 1
                        by_gen.setdefault(row["gen"], {"state": "consumed", "outcome": f"withdrawn ({mw.group(1)}): {why[:120]}",
                                                       "src": "window-queue"})
                        continue
                    why = WQ_TAIL_TS_RE.sub("", mh.group(2) if mh else head.lstrip("#")).strip()
                    lm = WQ_LEAD_TS_RE.match(why)
                    row.update(ts=None, hold=(mh.group(1) if mh else "commented"), held_at=lm.group(1) if lm else None,
                               reason=((why[lm.end():] if lm else why).strip() or (mh.group(1) if mh else "commented"))[:300])
                    tm = WQ_TAIL_TS_RE.search(head)
                    row["ts"] = tm.group(0).strip(" :#") if tm else None
                    wq["held_count"] += 1
                    if len(wq["held"]) < WQ_SHOW:
                        wq["held"].append(row)
                    held_gens[row["gen"]] = row
                    continue
                wq["depth"] += 1
                row["position"] = wq["depth"]
                if len(wq["pending"]) < WQ_SHOW:
                    wq["pending"].append(row)
                if WQ_GEN_RE.match(row["gen"]):
                    by_gen[row["gen"]] = {"state": "pending", "position": row["position"], "label": row["label"],
                                          "src": "window-queue"}
    except FileNotFoundError:
        pass
    except Exception as ex:
        err("window-queue.tsv", ex)
    for g, row in held_gens.items():
        if (by_gen.get(g) or {}).get("state") != "pending":
            by_gen[g] = {"state": "held", "hold": row["hold"], "reason": row["reason"], "held_at": row["held_at"],
                         "src": "window-queue"}
    a = wq["active"]
    if a and WQ_GEN_RE.match(a["gen"] or ""):
        by_gen[a["gen"]] = {"state": "active", "phase": a.get("phase"), "since": a.get("since"), "src": "window-queue"}
    # display text, once the depth and the loop state are known
    loop = " (queue PAUSED)" if wq["paused"] else (" (queue loop NOT running)" if wq["running"] is False else "")
    for g, d in by_gen.items():
        if d["state"] == "pending":
            d["text"] = f"queued #{d['position']} of {wq['depth']} in the window queue (gen {g[:8]}){loop}"
        elif d["state"] == "held":
            d["text"] = f"{'held' if d['hold'] == 'HELD' else d['hold'].lower()}: {d['reason'][:180]}"
        elif d["state"] == "active":
            d["text"] = f"window-queue active item: gen {g[:8]} phase={d.get('phase') or '?'} since {d.get('since') or '?'}"
        else:
            d["text"] = f"consumed: {d['outcome'][:200]}"
    return wq, by_gen


def kit_window_disposition(gen):
    """A gen the window queue never saw but pf-kit-window-runner did: consumed (window-queue.sh --add refuses it as
    generation_consumed). None when the runner has no trace of it."""
    try:
        rj = os.path.join(KIT_WINDOWS, gen, "runner.json")
        if os.path.exists(rj):
            with open(rj) as f:
                state = str(json.load(f).get("State") or "unknown")
        elif os.path.exists(os.path.join(KIT_WINDOWS, f"boot-open-{gen}.failed.json")):
            state = "boot-open failed"
        elif os.path.exists(os.path.join(KIT_WINDOWS, f"boot-open-{gen}.json")) or os.path.isdir(os.path.join(KIT_WINDOWS, gen)):
            state = "boot-open started"
        else:
            return None
    except Exception as ex:
        err(f"kit-windows {gen[:8]}", ex)
        return None
    return {"state": "consumed", "outcome": f"kit window {state} (outside the window queue)", "src": "kit-windows",
            "text": f"consumed: kit window {state} (outside the window queue)"}


# --------------------------------------------------------------- owner asks --
def collect_owner_asks():
    out = {"count": 0, "items": [], "error": None}
    try:
        txt = open(OWNER_ASKS, errors="replace").read()
    except Exception as ex:
        out["error"] = str(ex)
        err("owner questions", ex)
        return out
    m = re.search(r"^## Needs you\s*$(.*?)(?=^## |\Z)", txt, re.S | re.M)
    sec = m.group(1) if m else ""
    # 2026-10-19 (gpu-14): the file lists asks as "- **Q57 (...): title**" bullets as well as
    # "1. **title**" numbered lines; matching only the numbered form showed 0 live asks while Q53-Q57 were open.
    for n, im in enumerate(re.finditer(r"^(?:(\d+)\.|-)\s+\*\*(.+?)\*\*", sec, re.M), 1):
        q = re.match(r"Q(\d+)\b", im.group(2))
        num = int(im.group(1) or (q.group(1) if q else n))
        out["items"].append({"num": num, "title": im.group(2).strip()[:200]})
    out["count"] = len(out["items"])
    return out


# ------------------------------------------------------------ classification --
def fmt_age(s):
    if s is None:
        return "?"
    s = int(s)
    if s < 3600:
        return f"{s // 60} min"
    if s < 86400:
        return f"{s / 3600:.1f} h"
    return f"{s / 86400:.1f} d"


# 2026-10-20 (tsp-mc9m.41.1030.55): parks that wait on a date, an owner answer or another lane's verdict resurfaced
# every PARK_MAX_H, and superseded runs kept only as evidence sat in needs for a day. Typed tokens in the park reason:
#   until_date=<UTC ISO>              holds until that time
#   until_owner=Q<n>                  holds while Q<n> is a live item in the owner-asks "## Needs you" section
#   until_event=gen:<lane>            holds until that lane posts a NEEDS_STATES status after the park, or is released
#   until_event=ticket:<bead>         holds until that bead changes (updated or closed after the park)
#   evidence_for=<who>[:<bead>]       an "Evidence kept" row, not a need, until <bead> closes (no bead: PARK_MAX_H)
# A malformed token, or one whose source cannot be read, keeps PARK_MAX_H resurfacing: a bad park never hides a stall.
PARK_TOKEN_RE = re.compile(r"(?<![\w-])(until_date|until_owner|until_event|evidence_for)=(\S*)")
OWNER_DONE_RE = re.compile(r"\b(RESOLVED|ANSWERED)\b")
PARK_ID_RE = r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?"


def park_condition(reason, since, index, owner, lanes_by_name):
    """Typed wake tokens in a parked.tsv reason -> None (no typed token) or
    {"state": hold|fire|evidence|fallback, "text": why, "evidence": {who, bead}|None}."""
    toks = PARK_TOKEN_RE.findall(reason or "")
    if not toks:
        return None
    since_d = parse_ts(since)
    holds, fires, bad, ev, release = [], [], [], None, False
    for key, raw in toks:
        val = raw.rstrip(".,;:)")
        tok = f"{key}={val}"
        if key == "until_date":
            d = parse_ts(val) if re.match(r"\d{4}-\d\d-\d\d", val) else None
            if d is None:
                bad.append(f"{tok} is not a UTC ISO time")
            elif NOW >= d:
                fires.append(f"{tok} has passed")
            else:
                holds.append(f"until {iso(d)}")
        elif key == "until_owner":
            m = re.fullmatch(r"Q(\d+)", val)
            if not m:
                bad.append(f"{tok} is not Q<n>")
            elif not owner or owner.get("error"):
                bad.append(f"{tok}: owner asks unreadable ({((owner or {}).get('error') or 'no source')[:80]})")
            else:
                live = [i for i in owner.get("items") or [] if i.get("num") == int(m.group(1))
                        and not OWNER_DONE_RE.search(i.get("title") or "")]
                if live:
                    holds.append(f"while owner ask {val} is open")
                else:
                    fires.append(f"owner ask {val} is answered (not a live Needs-you item)")
        elif key == "until_event":
            m = re.fullmatch(r"(gen|ticket):(" + PARK_ID_RE + ")", val)
            if not m:
                bad.append(f"{tok} is not gen:<lane> or ticket:<id>")
            elif since_d is None:
                bad.append(f"{tok}: park time unreadable")
            elif m.group(1) == "gen":
                ol = lanes_by_name.get(m.group(2))
                # any NEEDS_STATES status since the park counts, even if a later CONTINUE/CI_WAIT followed it (review
                # 5588845556): the whole lane status history, not only the last line
                hist = ((ol or {}).get("statuses") or [(ol or {}).get("last_status") or {}])
                verdict = next((x for x in hist if x.get("state") in NEEDS_STATES
                                and (parse_ts(x.get("ts")) or since_d) > since_d), None)
                if ol is None:
                    bad.append(f"{tok}: lane {m.group(2)} is not on the board")
                elif ((ol.get("run_info") or {}).get("state")) == "released":
                    fires.append(f"lane {m.group(2)} is released")
                elif verdict:
                    fires.append(f"lane {m.group(2)} posted {verdict['state']} at {verdict['ts']}")
                else:
                    holds.append(f"until lane {m.group(2)} posts a verdict")
            else:
                tb = index.get(m.group(2)) if index else None
                tb_upd = parse_ts((tb or {}).get("updated_at"))
                if tb is None:
                    bad.append(f"{tok}: {'bead index unreadable' if not index else 'unknown bead'}")
                elif tb.get("status") == "closed" or (tb_upd and tb_upd > since_d):
                    fires.append(f"{m.group(2)} changed ({tb.get('status')}, updated {iso(tb_upd)})")
                else:
                    holds.append(f"until {m.group(2)} changes ({tb.get('status')})")
        else:   # evidence_for
            m = re.fullmatch(r"(" + PARK_ID_RE + r")(?::(" + PARK_ID_RE + r"))?", val)
            if not m:
                bad.append(f"{tok} is not <who>[:<bead>]")
                continue
            ev = {"who": m.group(1), "bead": m.group(2)}
            if not m.group(2):
                continue    # no release bead: an evidence row while young, then PARK_MAX_H (caller)
            eb = index.get(m.group(2)) if index else None
            if eb is None:
                bad.append(f"{tok}: {'bead index unreadable' if not index else 'unknown bead'}")
            elif eb.get("status") == "closed":
                release = True
                fires.append(f"evidence kept for {m.group(1)} until {m.group(2)}, which is closed")
    if bad:
        return {"state": "fallback", "text": "; ".join(bad), "evidence": ev, "release": False}
    if fires:
        return {"state": "fire", "text": "; ".join(fires), "evidence": ev, "release": release}
    if ev:
        return {"state": "evidence", "text": f"evidence kept for {ev['who']}"
                + (f" until {ev['bead']} closes" if ev["bead"] else ""), "evidence": ev, "release": False}
    return {"state": "hold", "text": "; ".join(holds), "evidence": None, "release": False}


def classify_lanes(lanes, prs, index, dev, owner=None):
    """Set cls/kind/cls_reason/next on each lane; return needs items. owner: collect_owner_asks() (until_owner=)."""
    lanes_by_name = {ln["lane"]: ln for ln in lanes}
    needs = []
    pending_by_sha = {}
    for p in dev.get("pending_all") or []:
        pending_by_sha[p["sha"]] = p
    results_by_name = {}
    for e in dev.get("events") or []:
        if e["kind"] == "result":
            results_by_name[e.get("name")] = e
    running_name = (dev.get("running") or {}).get("name")

    done_rows = dev.get("done_rows") or {}
    wq_by_gen = dev.get("wq_by_gen") or {}

    def wq_disposition(gen):
        """2026-10-19: a BOOT_READY gen -> its window-queue disposition (collect_window_queue), else a kit-window
        trace, else None (nothing knows the kit: today's boot_ready need stands)."""
        if not gen:
            return None
        return wq_by_gen.get(gen) or kit_window_disposition(gen)

    def kit_match(text):
        """A BOOT_READY/HANDBACK reason naming a kit manifest sha -> queue disposition.
        ('pending', name, position) | ('running', name, None) | ('done', name, verdict) | None"""
        # 2026-10-11: also accept unique >=8-hex prefixes (reasons often cite `manifest_1f466de1`)
        cands = list(HEX64_RE.findall(text or ""))
        known = list(pending_by_sha) + list(done_rows)
        for tok in re.findall(r"(?<![0-9a-f])[0-9a-f]{8,63}(?![0-9a-f])", text or ""):
            hits = {k for k in known if k.startswith(tok)}
            if len(hits) == 1:
                cands.append(hits.pop())
        for h in cands:
            if h in pending_by_sha:
                p = pending_by_sha[h]
                pos = next((i + 1 for i, q in enumerate(dev["pending_all"]) if q is p), None)
                return ("pending", p["name"], pos)
            if h in done_rows:
                name = done_rows[h]
                if name == running_name:
                    return ("running", name, None)
                ev = results_by_name.get(name)
                return ("done", name, (ev or {}).get("verdict"))
        return None

    for ln in lanes:
        ri = ln.get("run_info") or {}
        rs = ri.get("state") if "error" not in ri else None
        ls = ln["last_status"]
        st = ls["state"] if ls else None
        reason = (ls or {}).get("reason") or ""
        # display text: everything after "state=X" on the status line (reason= tokens are often clipped words)
        shown = re.sub(r"^[A-Z0-9_]+_STATUS\s+state=\S+\s*", "", (ls or {}).get("raw") or "")[:160]
        st_ts = parse_ts(ls["ts"]) if ls else parse_ts(ln["last_event_at"])
        st_age = age_s(st_ts)
        # 2026-10-19: a BOOT_READY handback names its kit generation; the window queue says whether it is queued,
        # HELD, active or already consumed, so only a kit nothing knows about stays a boot_ready need.
        boot_ready_st = st == "BOOT_READY" or (st == "HANDBACK" and reason.upper().startswith("BOOT_READY"))
        st_gen = (ls or {}).get("gen") if boot_ready_st else None
        wqd = wq_disposition(st_gen) if st_gen else None
        ln["window_queue"] = dict({k: wqd.get(k) for k in ("state", "text", "position")}, gen=st_gen) if wqd else None
        pr = ln.get("pr")
        pi = prs.get(pr) if pr else None
        pi = pi if pi and not pi.get("error") else None
        ln["bead"] = ri.get("task") or (ln.get("adm") or {}).get("task")
        ln["bead_title"] = (index.get(ln["bead"]) or {}).get("title") if ln["bead"] else None
        ln["model"] = ri.get("model") or (ln.get("adm") or {}).get("model")
        ln["provider"] = ri.get("provider") or (ln.get("adm") or {}).get("provider")
        ln["runtime"] = ri.get("runtime") or (ln.get("adm") or {}).get("runtime")
        ln["run_state"] = rs or ("?" if "error" in ri or not ri else None)
        ln["run_error"] = ri.get("error")
        for k in ("reconciler_alive", "controller_alive", "runtime_alive", "native_activity_age_s",
                  "messages_total", "worktree", "blocker_error", "last_turn_end", "runtime_parked", "session_id"):
            ln[k] = ri.get(k)
        ln["ci_wait"] = ln["ci_waits"][-1] if ln["ci_waits"] else None
        ln["status_age_s"] = st_age
        cls, kind, why, nxt = "unknown", None, "", ""

        def need(k, w, n):
            nonlocal cls, kind, why, nxt
            cls, kind, why, nxt = "needs", k, w, n

        def wait(w):
            nonlocal cls, kind, why, nxt
            cls, kind, why, nxt = "waiting", None, w, ""

        pr_txt = f"{pr}" if pr else ""
        # 2026-10-11: lanes deliberately waiting on a named event (held kit, dead run superseded by a new one,
        # an upstream merge) are listed in parked.tsv (run_id<TAB>since_iso<TAB>reason) by gpu-14. A parked lane
        # shows as waiting; after PARK_MAX_H it comes back as a need so a forgotten park cannot hide a stall.
        pk = PARKED.get(ln["run"] or "")
        pk_age = age_s(parse_ts(pk[0])) if pk else None
        # 2026-10-12: ten Qwen-stuck runs re-surfaced every 12 h although each can only be released once
        # tsp-mc9m.41.984.49.19 lands. A park reason carrying `until_bead=<id>` holds while that bead is open.
        pk_bead = re.search(r"until_bead=([A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9])", pk[1]).group(1) if pk and re.search(r"until_bead=([A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9])", pk[1]) else None
        pk_hold = bool(pk_bead) and (index.get(pk_bead) or {}).get("status") not in (None, "closed")
        # 2026-10-12: pftfix sat parked 11 h after the PR it waited on (automation#1402) merged; nothing watched it.
        # A park reason carrying `until_pr=<owner/repo#N>` holds while that PR is open and becomes a need once it merges.
        pk_pr = re.search(r"until_pr=([\w.-]+/[\w.-]+#\d+)", pk[1]).group(1) if pk and re.search(r"until_pr=([\w.-]+/[\w.-]+#\d+)", pk[1]) else None
        pk_pri = prs.get(pk_pr) if pk_pr else None
        pk_cond = park_condition(pk[1], pk[0], index, owner, lanes_by_name) if pk else None
        pk_bad = f" (wake condition unreadable: {pk_cond['text']})" if pk_cond and pk_cond["state"] == "fallback" else ""
        if pk and rs != "released" and not ln["driver_alive"] and pk_pri and pk_pri.get("state") in ("MERGED", "CLOSED"):
            need("unblocked", f"parked until {pk_pr}, which is {pk_pri.get('state')} ({pk_pri.get('merged_at') or ''}): {pk[1]}",
                 "Resume the lane on the merged change and unpark it (edit parked.tsv).")
        elif pk and rs != "released" and not ln["driver_alive"] and pk_pr and (pk_pri or {}).get("state") == "OPEN":
            wait(f"parked until {pk_pr} merges ({fmt_age(pk_age)} ago): {pk[1]}")
        elif pk and rs != "released" and not ln["driver_alive"] and pk_hold:
            wait(f"parked until {pk_bead} closes ({fmt_age(pk_age)} ago): {pk[1]}")
        elif pk and rs != "released" and not ln["driver_alive"] and pk_cond and pk_cond["state"] == "fire":
            need("unblocked", f"parked ({fmt_age(pk_age)} ago); its wake condition fired: {pk_cond['text']}: {pk[1]}",
                 "The evidence is no longer needed: release the run (release-run.sh) and drop its parked.tsv row."
                 if pk_cond["release"] else "Act on the event, then resume the lane or re-park it with a new condition (edit parked.tsv).")
        elif pk and rs != "released" and not ln["driver_alive"] and pk_cond and pk_cond["state"] == "evidence" \
                and (pk_cond["evidence"]["bead"] or (pk_age is not None and pk_age < PARK_MAX_H * 3600)):
            cls, kind, why, nxt = "evidence", None, f"{pk_cond['text']} (parked {fmt_age(pk_age)} ago): {pk[1]}", ""
            ln["evidence"] = dict(pk_cond["evidence"])
        elif pk and rs != "released" and not ln["driver_alive"] and pk_cond and pk_cond["state"] == "hold":
            wait(f"parked {pk_cond['text']} ({fmt_age(pk_age)} ago): {pk[1]}")
        elif pk and rs != "released" and not ln["driver_alive"] and pk_age is not None and pk_age < PARK_MAX_H * 3600:
            wait(f"parked {fmt_age(pk_age)} ago{pk_bad}: {pk[1]}")
        elif pk and rs != "released" and not ln["driver_alive"]:
            need("stale", f"parked longer than {PARK_MAX_H} h{pk_bad}: {pk[1]}", "Re-check the park reason; unpark (edit parked.tsv) or act.")
        elif rs == "released":
            cls, why = "released", "run released"
        elif rs == "busy":
            na = ri.get("native_activity_age_s")
            # 2026-10-14: pf-task's native activity follows the Codex rollout file only. OpenCode turns write
            # opencode.db instead, so na kept growing from admission (route showed "4.2 h idle" mid-turn, db written
            # seconds earlier). OpenCode retry stalls are caught by the opencode-quota probe instead.
            if (ri.get("runtime") or ln.get("runtime")) == "opencode":
                na = None
            started = parse_ts(ln["driver_starts"][-1]) if ln["driver_starts"] else None
            if ri.get("reconciler_alive") is False:
                need("stale", "run busy but reconciler dead", "Check run.status; restart the reconciler or rotate the lane.")
            elif na is not None and na > BUSY_IDLE_ALARM_MIN * 60:
                need("stale", f"run busy, no native activity for {fmt_age(na)}",
                     "Check the worker (tmux/session); nudge with run.send or rotate the lane.")
            elif na is None and ri.get("last_turn_end") is None and started and age_s(started) > BUSY_NO_SIGNAL_ALARM_MIN * 60:
                need("stale", f"run busy with no activity signal, admitted {fmt_age(age_s(started))} ago",
                     "Confirm the first turn actually started (models.get, runtime log); re-admit if refused.")
            else:
                cls, why = "running", f"turn in progress" + (f" ({fmt_age(na)} since activity)" if na is not None else "") \
                    + (f"; last status {st}" if st else "; first turn")
        else:
            merged = pi and pi["state"] == "MERGED"
            kind_for_state = {"HANDBACK": "handback", "BOOT_READY": "boot_ready", "BLOCKED": "blocked",
                              "MERGE_READY": "merge_ready"}.get(st or "", "handback")
            km = kit_match(reason + " " + ((ls or {}).get("raw") or "")) if st in ("BOOT_READY", "HANDBACK") else None
            blocker = None
            if st == "BLOCKED":
                for cand in BEAD_RE.findall((ls or {}).get("raw") or ""):
                    if cand != ln["bead"] and cand in index:
                        blocker = index[cand]
                        break
            if not ln["driver_alive"]:
                if st in NEEDS_STATES or st in (None, "NONE"):
                    if st == "BLOCKED" and blocker and blocker["status"] not in ("closed",):
                        wait(f"BLOCKED on {blocker['id']} ({blocker['status']}): {reason[:120]}")
                    elif st == "BLOCKED" and blocker and blocker["status"] == "closed":
                        need("blocked", f"blocker {blocker['id']} is now closed; lane still BLOCKED, no driver",
                             "run.send the lane: its blocker landed; restart lane-drive.sh.")
                    elif wqd and wqd["state"] != "consumed":
                        wait(wqd["text"])
                    elif wqd:
                        need("handback", f"{wqd['text']}; lane still {st} BOOT_READY on gen {st_gen[:8]} with no live driver",
                             "Read the window's receipt / close outcome, post the result to the lane (run.send) and drive "
                             "it on (a retry is a new package + generation).")
                    elif km and km[0] == "pending":
                        wait(f"kit queued on the bench as {km[1]} (position {km[2]} of {dev['pending_count']})")
                    elif km and km[0] == "running":
                        wait(f"its kit {km[1]} is running on the bench now")
                    elif km and km[0] == "done":
                        need("handback", f"{st}: its kit ran as {km[1]} (verdict {km[2] or '?'}); lane idle, no driver",
                             "Read the receipt, post the result to the lane (run.send) and drive it on.")
                    elif pi and pi["merge_ready"]:
                        need("merge_ready", f"PR {pr_txt} is merge-ready (CI green, approved); lane {st}, no driver",
                             "Merge with pf-pr-merge.sh, then continue or release the run.")
                    elif merged and st in ("HANDBACK", "MERGE_READY"):
                        need("handback", f"PR {pr_txt} merged; lane {st} with no driver",
                             "Verify the merge on origin/main, update/close the bead, release the run.")
                    elif st == "HANDBACK" and reason.upper().startswith("BOOT_READY"):
                        need("boot_ready", f"HANDBACK: {shown}", "Seal check, add the kit to queue.tsv (.new + mv) or read its receipt.")
                    elif st in (None, "NONE"):
                        need("undriven", "no parseable status line yet and no live driver",
                             "Read the run's last message; nudge for a status line or restart the driver.")
                    else:
                        extra = f": {shown}" if shown else ""
                        nx = {"boot_ready": "Queue the kit (queue.tsv .new + mv) or read its result, then continue the lane.",
                              "blocked": "Resolve or re-route the blocker; continue the lane.",
                              "merge_ready": "Merge with pf-pr-merge.sh, then release the run.",
                              }.get(kind_for_state, "Read the last result, verify, then run.send the next step or release the run.")
                        if pi and pi["state"] == "OPEN" and pi["ci_green"] and pi["review"] != "APPROVED":
                            extra += f" (CI green {pi['checks']['success']}/{pi['checks']['total']}, review {pi['review'] or 'none'})"
                        unchecked = "; run state unchecked this refresh" if ri.get("error", "").startswith("not checked") else ""
                        need(kind_for_state, f"{st}{extra}; no live driver{unchecked}", nx)
                elif st in WAIT_STATES:
                    if merged:
                        need("handback", f"PR {pr_txt} merged while the lane sat in {st} with no driver",
                             "Verify origin/main, close the bead, release the run.")
                    elif pi and pi["merge_ready"]:
                        need("merge_ready", f"PR {pr_txt} merge-ready; lane {st}, no driver",
                             "Merge with pf-pr-merge.sh, then continue or release the run.")
                    elif pi and pi["state"] == "OPEN" and pi["checks"]["failed"]:
                        need("undriven", f"CI RED on {pr_txt} ({', '.join(pi['checks']['failed_names'][:3])}); lane {st}, no driver",
                             "Restart lane-drive.sh so the lane gets the CI result, or run.send it yourself.")
                    else:
                        need("undriven", f"lane in {st} with no live driver" + (f" ({pr_txt})" if pr else ""),
                             "Restart lane-drive.sh for this run (or release it if finished).")
                else:
                    need("undriven", f"lane state {st} with no live driver", "Restart the driver or release the run.")
            else:  # driver alive
                if st == "CI_WAIT":
                    cw = ln["ci_wait"] or {}
                    if pi and pi["state"] == "MERGED":
                        wait(f"PR {pr_txt} merged; driver will continue the lane")
                    elif pi and pi["state"] == "OPEN":
                        c = pi["checks"]
                        if pi["merge_ready"]:
                            wait(f"CI green + approved on {pr_txt}; driver continues the lane")
                        elif c["failed"]:
                            wait(f"CI RED on {pr_txt} ({c['failed']} failed); driver continues the lane")
                        elif c["pending"] and st_age is not None and st_age > CI_STALL_MIN * 60 \
                                and not (pk and pk_age is not None and pk_age < PARK_MAX_H * 3600
                                         and re.search(r"(?i)stall|pool|stuck", pk[1] or "")):
                            need("ci_stall", f"CI still pending on {pr_txt} {fmt_age(st_age)} after CI_WAIT "
                                 f"({c['success']}/{c['total']} done)",
                                 "Check the pending job's runner (queued with no runner = pool stall: "
                                 "pf-runner-pool journal on mm); fix or reroute, never raise a timeout.")
                        elif c["pending"]:
                            wait(f"CI running on {pr_txt}: {c['success']}/{c['total']} done")
                        else:
                            wait(f"CI green on {pr_txt}; review {pi['review'] or 'pending'}; driver continues")
                    elif cw.get("result"):
                        wait(f"CI {cw['result']} on {cw.get('pr')}; driver continuing")
                    else:
                        wait(f"CI_WAIT on {pr_txt or '?'}; driver watching")
                elif st in WAIT_STATES:
                    wait(f"{st}: {reason[:120] or 'driver watching'}")
                elif st in NEEDS_STATES and st_age is not None and st_age > HANDBACK_WITH_DRIVER_GRACE_MIN * 60 \
                        and rs not in (None,):
                    if km and km[0] == "pending":
                        wait(f"kit queued on the bench as {km[1]} (position {km[2]})")
                    elif wqd:   # queued / held / active / consumed: the live driver carries the lane on
                        wait(f"{wqd['text']}; driver alive, run {rs}")
                    else:
                        need(kind_for_state, f"{st} {fmt_age(st_age)} ago; a driver is alive but the run is {rs}",
                             "Read the handback; run.send the next step or release and stop the driver.")
                elif st in NEEDS_STATES:
                    wait(f"{wqd['text']}; driver alive" if wqd else f"{st} just now; driver winding down")
                elif st in (None, "NONE"):
                    if rs in ("admitted", None) and "error" in ri:
                        cls, why = "unknown", f"run state unknown ({ri.get('error', '')[:80]})"
                    else:
                        wait(f"driver watching; run {rs or '?'}; no status line yet")
                else:
                    wait(f"{st}; driver alive, run {rs}")
        if "error" in ri and cls in ("unknown",):
            cls, why = "unknown", f"run.status unavailable: {ri['error'][:100]}; last lane status {st}"
            if not ln["driver_alive"] and st in NEEDS_STATES:
                need(kind_for_state, f"{st} ({reason[:100]}); no driver; run state unknown", "Check run.status by hand; act on the handback.")
        bnd = RUN_BOUNDS.get(ln["run"] or "")
        mt = ln.get("messages_total")
        budget_ack = bool(pk) and pk_age is not None and pk_age < PARK_MAX_H * 3600 \
            and re.search(r"(?i)budget|rotat", pk[1] or "") is not None
        if ri.get("run_home") == "/home/matt/.pf-task-v2" and bnd and isinstance(mt, int) \
                and mt >= bnd - 4 and rs not in ("released", None) and not budget_ack:
            need("budget", f"messages {mt}/{bnd}: the next sends hit session_message_budget_exhausted",
                 "Rotate now: ask for a pushed-head handoff on the bead, then dispatch the next generation.")
        pk_typed_hold = cls in ("waiting", "evidence") and bool(pk_cond) and pk_cond["state"] in ("hold", "evidence")
        if cls not in ("needs", "released") and not (pk and ((pk_age is not None and pk_age < PARK_MAX_H * 3600) or pk_hold
                                                             or pk_typed_hold)):
            for spr in ln.get("secondary_prs") or []:
                spi = prs.get(spr)
                if spi and not spi.get("error") and spi.get("state") == "OPEN" and spi["checks"]["failed"] \
                        and not spi["checks"]["pending"]:
                    need("secondary_red", f"CI RED on {spr} ({', '.join(spi['checks']['failed_names'][:3])}); "
                         f"the lane's driver watches only {pr_txt or 'its latest PR'}",
                         f"run.send the lane the failing lines for {spr} (or restart its driver on that PR).")
                    break
        ln.update(cls=cls, kind=kind, cls_reason=why, next=nxt)
        if cls == "needs":
            needs.append({"kind": kind, "id": ln["lane"], "lane": ln["lane"], "bead": ln["bead"], "run": ln["run"],
                          "pr": pr, "reason": why, "since": iso(st_ts), "age_s": st_age, "next": nxt,
                          "bead_title": ln["bead_title"]})
    return needs


def collect_model_quota():
    """2026-10-11: the bailian token-plan quota ran out and 13 OpenCode sessions sat in a silent retry loop for hours
    while pf-task reported them busy. Ask every local `opencode serve` for /session/status; type=retry whose message
    names a quota/rate limit is a stalled lane."""
    import urllib.request
    out, seen = [], set()
    try:
        pids = subprocess.run(["pgrep", "-f", "opencode serve"], capture_output=True, text=True, timeout=10).stdout.split()
    except Exception as ex:
        err("opencode quota", ex)
        return out
    for pid in pids:
        try:
            cmd = open(f"/proc/{pid}/cmdline").read().replace("\0", " ")
            cwd = os.readlink(f"/proc/{pid}/cwd")
        except OSError:
            continue
        m = re.search(r"--port (\d+)", cmd)
        if not m or m.group(1) in seen:
            continue
        seen.add(m.group(1))
        try:
            st = json.load(urllib.request.urlopen(f"http://127.0.0.1:{m.group(1)}/session/status", timeout=4))
        except Exception:
            continue
        for sid, v in (st or {}).items():
            msg = (v or {}).get("message") or ""
            if (v or {}).get("type") == "retry" and re.search(r"quota|Too Many Requests|rate.?limit", msg, re.I):
                out.append({"pid": pid, "port": m.group(1), "session": sid, "worktree": cwd.replace("/home/matt/wt/", ""),
                            "message": msg[:200]})
    return out


def classify_device(dev):
    needs = []
    if dev.get("halted"):
        needs.append({"kind": "device", "id": "device-queue", "lane": None, "bead": None, "run": None, "pr": None,
                      "reason": f"device queue HALTED: {dev['halt_line'][:160]}; {dev['pending_count']} steps pending",
                      "since": dev.get("halt_at"), "age_s": age_s(parse_ts(dev.get("halt_at"))),
                      "next": "Verify the bench (pf-device.sh status, relays, PSU), then restart queue-runner.sh."})
    elif not dev["runner_alive"] and dev["pending_count"] > 0 and not dev["kit_running"] and not dev["running"]:
        needs.append({"kind": "device", "id": "device-queue", "lane": None, "bead": None, "run": None, "pr": None,
                      "reason": f"queue-runner.sh not running with {dev['pending_count']} steps pending; bench idle",
                      "since": dev.get("log_mtime"), "age_s": age_s(parse_ts(dev.get("log_mtime"))),
                      "next": "Start queue-runner.sh (run_in_background) after a device_idle check."})
    # 2026-10-19: lanes whose kit is queued in the window queue now wait instead of nagging boot_ready, so a stopped
    # queue must surface on its own or those lanes would wait on nothing.
    wq = dev.get("window_queue") or {}
    # 2026-10-20 (tsp-mc9m.41.1030.55.1, review 5588845556): window-queue.sh keeps .active and writes .pause when it
    # stops after popping its only row, so depth is 0 while a window is unresolved; an active item alerts too.
    wq_act = wq.get("active") or None
    if (wq.get("depth") or wq_act) and (wq.get("paused") or wq.get("running") is False):
        why = f"PAUSED ({wq.get('pause_line') or 'pause file'})" if wq.get("paused") else "not running"
        nxt = ("Diagnose the STOP (needs/window-queue-stop-*.txt), then window-queue.sh --resume complete|incomplete "
               "and restart it (run_in_background)." if wq.get("paused") else
               "Start window-queue.sh (run_in_background); check window-queue.sh --status first.")
        since = wq.get("pause_at") if wq.get("paused") else None
        needs.append({"kind": "device", "id": "window-queue", "lane": None, "bead": None, "run": None, "pr": None,
                      "reason": f"window queue {why[:160]} with {wq.get('depth') or 0} rows pending"
                                + (f" and active item gen {(wq_act.get('gen') or '?')[:8]} (phase {wq_act.get('phase') or '?'}, "
                                   f"lane {wq_act.get('lane') or '?'}) unresolved" if wq_act else ""), "since": since,
                      "age_s": age_s(parse_ts(since)), "next": nxt})
    r = dev.get("running")
    if r and r["elapsed_s"] and r["elapsed_s"] > KIT_STUCK_H * 3600:
        needs.append({"kind": "stale", "id": r["name"], "lane": None, "bead": None, "run": None, "pr": None,
                      "reason": f"device step {r['name']} running {fmt_age(r['elapsed_s'])} without a result",
                      "since": r["started_at"], "age_s": r["elapsed_s"],
                      "next": "Read its receipt/log; if wedged, recover the bench and let the runner continue."})
    return needs


# 2026-10-12 owner: "the laptop has been busy for days". Found: 14.7k zombies under the ChatGPT app, a pf-task
# controller respawning a dead runtime every 1-2 s for 7 days (wtmp 499 MB -> accounts-daemon 100% CPU, 1.4 GB),
# 25 orphaned test stubs busy-waiting, and a 13-day ps-app. Nothing on the board showed any of it.
HOST_ZOMBIES_MAX = 500
HOST_WTMP_MAX_BYTES = 100 * 1024 * 1024
HOST_WTMP_RECORDS_5MIN_MAX = 60
HOST_ORPHAN_MIN_AGE_S = 86400
HOST_ORPHAN_MIN_PCPU = 2.0
HOST_ORPHAN_ALLOW = re.compile(r"gnome|gvfs|xdg-|dbus|pipewire|wireplumber|evolution|tracker|goa-|at-spi|ibus|gsd-|"
                               r"snapd?|mutter|chrome|claude|tmux |pf-task-host|next-server|tcgerrors|nautilus|"
                               r"seahorse|dconf|gpg-agent|update-manager|flatpak|ssh: .*\[mux\]|accounts-daemon")


def classify_host():
    try:
        ps = subprocess.run(["ps", "-eo", "pid=,ppid=,etimes=,pcpu=,stat=,comm=,args="], capture_output=True,
                            text=True, timeout=30).stdout.splitlines()
    except Exception as e:
        err("host ps", e)
        return []
    rows = []
    for line in ps:
        f = line.split(None, 6)
        if len(f) < 6:
            continue
        rows.append({"pid": f[0], "ppid": f[1], "et": int(f[2]), "cpu": float(f[3]), "stat": f[4], "comm": f[5],
                     "args": f[6] if len(f) > 6 else f[5]})
    comm_by_pid = {r["pid"]: r["comm"] for r in rows}
    zombies = [r for r in rows if r["stat"].startswith("Z")]
    zpar = collections.Counter(comm_by_pid.get(r["ppid"], r["ppid"]) for r in zombies)
    user_mgr = {r["pid"] for r in rows if r["args"].startswith("/usr/lib/systemd/systemd --user")
                or r["args"].startswith("/lib/systemd/systemd --user")}
    orphans = [r for r in rows if r["ppid"] in user_mgr and r["et"] > HOST_ORPHAN_MIN_AGE_S
               and r["cpu"] >= HOST_ORPHAN_MIN_PCPU and not HOST_ORPHAN_ALLOW.search(r["args"])]
    try:
        wtmp = os.path.getsize("/var/log/wtmp")
    except OSError:
        wtmp = 0
    # 2026-10-16: `last -s -5min` reported 0 while a controller respawn loop wrote ~110 records/min (pft-6e74e4c8, 786k
    # tmux panes), and an exception also read as 0. Count records straight from the wtmp tail instead (glibc x86_64
    # struct utmp = 384 bytes, ut_tv.tv_sec int32 at offset 340; validated 224 == utmpdump for 10:40-10:42Z), and
    # report an unreadable count as unknown, never as 0.
    try:
        rec, tail = 384, 4 * 1024 * 1024
        start = max(0, wtmp - tail)
        start -= start % rec
        cutoff = time.time() - 300
        with open("/var/log/wtmp", "rb") as wf:
            wf.seek(start)
            wd = wf.read()
        wtmp_5m = sum(1 for o in range(0, len(wd) - rec + 1, rec) if struct.unpack_from("<i", wd, o + 340)[0] >= cutoff)
    except Exception as e:
        err("host wtmp", e)
        wtmp_5m = None
    problems = []
    if len(zombies) > HOST_ZOMBIES_MAX:
        problems.append(f"{len(zombies)} zombies (top parent {zpar.most_common(1)[0][0]})")
    if wtmp > HOST_WTMP_MAX_BYTES or wtmp_5m is None or wtmp_5m > HOST_WTMP_RECORDS_5MIN_MAX:
        problems.append(f"wtmp {wtmp // (1024 * 1024)} MB, {'unknown' if wtmp_5m is None else wtmp_5m} login records "
                        f"in 5 min (a respawn loop? find churning children of the tmux server: ps --ppid <tmux pid>)")
    if orphans:
        top = sorted(orphans, key=lambda r: -r["cpu"])[:3]
        problems.append(f"{len(orphans)} orphans >24 h using CPU: " +
                        "; ".join(f"pid {r['pid']} {r['cpu']:.0f}% {fmt_age(r['et'])} {r['args'][:50]}" for r in top))
    if not problems:
        return []
    return [{"kind": "host", "id": "host-hygiene", "lane": None, "bead": None, "run": None, "pr": None,
             "reason": "laptop hygiene: " + " | ".join(problems), "since": iso(NOW), "age_s": 0,
             "next": "Find the producer of each item (parent, cwd, cgroup); kill stale leftovers by exact PID; "
                     "file a producer-side fix."}]


def slim_bead(b, index, lane_by_bead):
    par = index.get(b.get("parent") or "") or {}
    blockers = []
    for d in b["deps"]:
        if d["type"] == "blocks":
            t = index.get(d["id"]) or {}
            blockers.append({"id": d["id"], "status": t.get("status", "?"), "closed_at": t.get("closed_at"),
                             "title": t.get("title", "")[:120]})
    return {"id": b["id"], "title": b["title"][:160], "status": b["status"], "priority": b["priority"],
            "type": b["type"], "tier": b["tier"], "parent": b.get("parent"), "parent_title": par.get("title", "")[:100],
            "updated_at": b["updated_at"], "created_at": b["created_at"], "blockers": blockers,
            "lane": lane_by_bead.get(b["id"])}


def stale_candidates(index, lane_by_bead):
    """in_progress, in scope, no lane, idle between STALE_BEAD_H and STALE_LOOKBACK_H -> (candidates, long_idle_ids)"""
    cands, long_idle = [], []
    for bid, b in index.items():
        if not in_scope(bid) or b["status"] != "in_progress" or b["type"] in NON_DISPATCH_TYPES:
            continue
        if bid in lane_by_bead or b.get("assignee") in COORD_OWNERS:   # another coordinator's: owned_beads()
            continue
        a = age_s(parse_ts(b["updated_at"]))
        if a is None:
            continue
        if a > STALE_LOOKBACK_H * 3600:
            long_idle.append(bid)
        elif a > STALE_BEAD_H * 3600:
            cands.append(b)
    cands.sort(key=lambda b: b["updated_at"])
    return cands, long_idle


def owned_beads(index, lane_by_bead):
    """2026-10-20 (tsp-mc9m.41.1030.55): in-scope, not-closed beads with no lane whose assignee is another coordinator
    (COORD_OWNERS). They are that coordinator's to drive, so they are listed with their age instead of being needs."""
    out = []
    for bid, b in index.items():
        if not in_scope(bid) or b.get("assignee") not in COORD_OWNERS or b["status"] not in ("in_progress", "open") \
                or b["type"] in NON_DISPATCH_TYPES or bid in lane_by_bead:
            continue
        out.append({"id": bid, "title": b["title"][:160], "status": b["status"], "assignee": b["assignee"],
                    "tier": b["tier"], "parent": b.get("parent"), "updated_at": b["updated_at"],
                    "age_s": age_s(parse_ts(b["updated_at"])), "priority": b["priority"]})
    out.sort(key=lambda o: (o["assignee"], 0 if o["status"] == "in_progress" else 1, -(o["age_s"] or 0)))
    return out


def fetch_comments_for(ids):
    out = {}
    with cf.ThreadPoolExecutor(COMMENTS_PARALLEL) as ex:
        for bid, info, e in ex.map(fetch_comments, ids[:COMMENTS_MAX]):
            if e:
                err(f"bd comments {bid}", e)
            out[bid] = info
    return out


def classify_beads(index, ready_ids, lanes, comments):
    lane_by_bead = {}
    for ln in lanes:
        if ln.get("bead") and ln.get("cls") != "released":
            lane_by_bead.setdefault(ln["bead"], ln["lane"])
    ready = set(ready_ids)
    cutoff_new = NOW - dt.timedelta(hours=NEWLY_UNBLOCKED_H)
    parallel, newly = [], []
    excluded = 0
    for bid in sorted(ready):
        b = index.get(bid)
        if not b or not in_scope(bid) or b["status"] != "open":
            continue
        if b["type"] in NON_DISPATCH_TYPES:
            excluded += 1
            continue
        if bid in lane_by_bead:
            continue
        if b.get("assignee") in COORD_OWNERS:   # another coordinator's to dispatch: owned_beads()
            continue
        sb = slim_bead(b, index, lane_by_bead)
        sb["recent"] = (age_s(parse_ts(b["updated_at"])) or 1e12) < RECENT_DAYS * 86400 or \
                       (age_s(parse_ts(b["created_at"])) or 1e12) < RECENT_DAYS * 86400
        recent_close = [x for x in sb["blockers"] if x["status"] == "closed" and (parse_ts(x["closed_at"]) or dt.datetime.min.replace(tzinfo=dt.timezone.utc)) >= cutoff_new]
        if recent_close:
            sb["unblocked_by"] = [x["id"] for x in recent_close]
            sb["unblocked_at"] = max(x["closed_at"] for x in recent_close)
            newly.append(sb)
        else:
            parallel.append(sb)

    def pkey(s):
        return (s["priority"] if s["priority"] is not None else 9, -(parse_ts(s["updated_at"]) or NOW).timestamp())
    parallel.sort(key=lambda s: (0 if s.get("recent") else 1,) + pkey(s))
    newly.sort(key=lambda s: s.get("unblocked_at") or "", reverse=True)
    # chains: open blockers -> what they unblock (in scope, not closed)
    groups = {}
    for bid, b in index.items():
        if not in_scope(bid) or b["status"] in ("closed",):
            continue
        for d in b["deps"]:
            if d["type"] != "blocks":
                continue
            t = index.get(d["id"])
            if not t or t["status"] == "closed":
                continue
            groups.setdefault(d["id"], []).append(bid)
    chains = []
    for blk, deps in groups.items():
        t = index[blk]
        chains.append({"blocker": slim_bead(t, index, lane_by_bead),
                       "dependents": [slim_bead(index[x], index, lane_by_bead) for x in sorted(deps) if x in index]})
    chains.sort(key=lambda c: (-len(c["dependents"]), 0 if c["blocker"]["status"] == "in_progress" else 1, c["blocker"]["id"]))
    disp = {"parallel": parallel[:PARALLEL_SHOW], "parallel_total": len(parallel), "parallel_shown": min(len(parallel), PARALLEL_SHOW),
            "parallel_recent_total": sum(1 for p in parallel if p.get("recent")),
            "parallel_rest_ids": [p["id"] for p in parallel[PARALLEL_SHOW:]],
            "newly_unblocked": newly, "chains": chains[:CHAINS_SHOW], "chains_total": len(chains),
            "excluded_container_types": excluded}
    # stale candidates (comments were prefetched in the beads thread; fetch any the final lane set adds)
    cands, long_idle = stale_candidates(index, lane_by_bead)
    missing = [c["id"] for c in cands[:COMMENTS_MAX] if c["id"] not in comments]
    if missing:
        comments.update(fetch_comments_for(missing))
    stale = []
    if True:
        for b in cands[:COMMENTS_MAX]:
            bid = b["id"]
            info = comments.get(bid)
            last = (info or {}).get("last")
            last_d = parse_ts(last)
            upd_d = parse_ts(b["updated_at"])
            newest = max([d for d in (last_d, upd_d) if d], default=None)
            a = age_s(newest)
            if a is not None and a > STALE_BEAD_H * 3600:
                stale.append({"id": bid, "title": b["title"][:160], "status": b["status"], "assignee": b["assignee"],
                              "tier": b["tier"], "parent": b.get("parent"), "updated_at": b["updated_at"],
                              "last_comment_at": last, "comment_count": (info or {}).get("count", b.get("comment_count")),
                              "age_s": a, "priority": b["priority"]})
    stale.sort(key=lambda s: -s["age_s"])
    if len(cands) > COMMENTS_MAX:
        err("stale scan", f"{len(cands) - COMMENTS_MAX} candidates beyond COMMENTS_MAX={COMMENTS_MAX} not checked")
    needs = []
    older = []
    for s in stale:
        # waits.tsv (fresh entries) records why a bead waits; keep it out of both the individual and the aggregate need.
        _w = wait_for(s["id"])
        _wa = age_s(parse_ts(_w[0])) if _w else None
        if _w and _wa is not None and _wa < WAIT_MAX_H * 3600:
            continue
        if s["age_s"] > STALE_INDIVIDUAL_H * 3600:
            older.append(s)
            continue
        needs.append({"kind": "stale", "id": s["id"], "lane": None, "bead": s["id"], "run": None, "pr": None,
                      "reason": f"in_progress with no lane; untouched {fmt_age(s['age_s'])} (tier {s['tier'] or '?'})",
                      "since": iso(NOW - dt.timedelta(seconds=s["age_s"])), "age_s": s["age_s"],
                      "next": "Find its worker or release the claim; re-dispatch or set it back to open.",
                      "bead_title": s["title"]})
    if older:
        oldest = max(older, key=lambda s: s["age_s"])
        needs.append({"kind": "stale", "id": "stale-beads", "lane": None, "bead": None, "run": None, "pr": None,
                      "reason": f"{len(older)} in_progress beads in scope have had no lane, update or comment for "
                                f"{STALE_INDIVIDUAL_H} h to {STALE_LOOKBACK_H // 24} days (oldest {oldest['id']}, {fmt_age(oldest['age_s'])}); see Stale beads",
                      "since": iso(NOW - dt.timedelta(seconds=oldest["age_s"])), "age_s": oldest["age_s"],
                      "next": "Sweep the Stale beads table: release abandoned claims (status back to open) or re-dispatch.",
                      "bead_title": None, "count": len(older)})
    for nb in newly:
        needs.append({"kind": "dispatchable", "id": nb["id"], "lane": None, "bead": nb["id"], "run": None, "pr": None,
                      "reason": f"newly unblocked by {', '.join(nb['unblocked_by'])} (closed {nb['unblocked_at']}); open, no lane",
                      "since": nb["unblocked_at"], "age_s": age_s(parse_ts(nb["unblocked_at"])),
                      "next": "Dispatch a worker (kickoff) or record why it waits.", "bead_title": nb["title"]})
    return disp, stale, {"count": len(long_idle), "ids": sorted(long_idle)}, needs, lane_by_bead, \
        owned_beads(index, lane_by_bead)


# --------------------------------------------------------------------- main --
# ------------------------------------------------------- hardware & drivers --
# 2026-10-20 (gpu-14): one row per hardware block and per tier-priority item (hardware-rows.json). A lane posts row
# evidence as a bd comment on the row's anchor bead whose line reads
#   HW_ROW state=<Working|Partial|Detected|Broken|Untested|Parked|HW-limit|Deferred> build=<N> evidence=<text>
# (optional row=<row id> before evidence= when one bead anchors several rows). The latest valid line wins; a row with
# none shows its seed (seed_state, seed_at). Nothing here writes to beads.
HW_ROW_RE = re.compile(r"^\s*HW_ROW\s+(.*)$")
HW_KV_RE = re.compile(r"(?:^|\s)(row|state|build)=(\S+)")
HW_EV_RE = re.compile(r"(?:^|\s)evidence=")
HW_STATE_CANON = {s.lower(): s for s in HW_STATES}
HW_STATE_CANON.update({"hw_limit": "HW-limit", "hwlimit": "HW-limit", "hw-limited": "HW-limit"})
LANE_SUFFIX_RE = re.compile(r"-(?:g|r)\d+$")
KIT_REV_RE = re.compile(r"-(?:r|g|v)\d+$")                  # kit revision suffix: ...-M8-r8 is the M8 family
KIT_PATH_RE = re.compile(r"(?:/home/matt|~)/recovery/[A-Za-z0-9._+/-]+")
GEN32_RE = re.compile(r"(?<![0-9a-f])[0-9a-f]{32}(?![0-9a-f])")
PATHISH_RE = re.compile(r"[^\s\"'=]*/[^\s\"']*")         # a kit's paths name tools/images, not its subject beads


def comment_refs(comments):
    """Kit package paths and 32-hex generations a bead's own comments name, newest first, capped at HW_REFS_MAX each."""
    paths, gens = [], []
    for c in sorted(comments or [], key=lambda c: c.get("created_at") or "", reverse=True):
        t = c.get("text") or ""
        for p in KIT_PATH_RE.findall(t):
            p = "/home/matt" + p[1:] if p.startswith("~") else p
            p = p.rstrip("./,:;-")
            if p not in paths and len(paths) < HW_REFS_MAX:
                paths.append(p)
        for g in GEN32_RE.findall(t):
            if g not in gens and len(gens) < HW_REFS_MAX:
                gens.append(g)
    return {"paths": paths, "gens": gens}


def parse_hw_rows(comments):
    """bd comments rows -> [{at, by, row, state, build, evidence}] for every valid HW_ROW line, oldest first."""
    out = []
    for c in comments or []:
        for line in (c.get("text") or "").splitlines():
            m = HW_ROW_RE.match(line)
            if not m:
                continue
            body, ev = m.group(1), ""
            em = HW_EV_RE.search(body)
            if em:
                body, ev = body[:em.start()], body[em.end():].strip()
            kv = dict(HW_KV_RE.findall(body))
            st = HW_STATE_CANON.get((kv.get("state") or "").strip(",;").lower())
            if not st:
                continue
            out.append({"at": c.get("created_at"), "by": c.get("author"), "row": kv.get("row"), "state": st,
                        "build": kv.get("build"), "evidence": ev[:600]})
    out.sort(key=lambda x: x["at"] or "")
    return out


def fetch_comment_rows(bid):
    rc, out, errtxt = run_cmd(["bd", "comments", bid, "--json"], COMMENTS_TIMEOUT_S, cwd=MC)
    if rc != 0:
        return bid, None, f"rc={rc} {errtxt.strip()[:200]}"
    try:
        return bid, (json.loads(out) if out.strip() else []), None
    except Exception as ex:
        return bid, None, str(ex)


def load_hw_doc():
    with open(HW_ROWS_FILE) as f:
        doc = json.load(f)
    if not isinstance(doc.get("rows"), list):
        raise ValueError(f"{HW_ROWS_FILE}: no rows list")
    return doc


def hw_anchor_ids(doc):
    ids = []
    for r in (doc.get("rows") or []) + (doc.get("priorities") or []):
        for a in r.get("anchor") or []:
            if a and a not in ids:
                ids.append(a)
    return ids


def collect_hw_comments(index, ids):
    """anchor id -> {count, last, hw:[HW_ROW lines], refs:{paths, gens}}; a bead is re-read only when bd list's
    comment_count moved (or its cache entry predates refs)."""
    try:
        with open(HW_COMMENTS_CACHE) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    want = [i for i in ids if i in index]
    # never-read beads first, then the rest; whatever misses HW_COMMENTS_BUDGET_S keeps its cached entry for next time
    todo = sorted((i for i in want if i not in cache or cache[i].get("count") != index[i].get("comment_count")
                   or "refs" not in cache[i]),
                  key=lambda i: i in cache)
    done = 0
    if todo:
        ex = cf.ThreadPoolExecutor(COMMENTS_PARALLEL)
        futs = [ex.submit(fetch_comment_rows, i) for i in todo]
        try:
            for fut in cf.as_completed(futs, timeout=HW_COMMENTS_BUDGET_S):
                bid, rows, e = fut.result()
                if e:
                    err(f"bd comments {bid} (hardware rows)", e)
                    continue
                done += 1
                cache[bid] = {"count": index[bid].get("comment_count"),
                              "last": max((c.get("created_at") or "" for c in rows), default="") or None,
                              "hw": parse_hw_rows(rows), "refs": comment_refs(rows)}
        except cf.TimeoutError:
            err("bd comments (hardware rows)", f"budget {HW_COMMENTS_BUDGET_S}s spent: {len(todo) - done} of {len(todo)} "
                                               "anchor comment lists left for the next refresh")
        finally:
            ex.shutdown(wait=False, cancel_futures=True)
    cache = {i: cache[i] for i in want if i in cache}
    try:
        tmp = HW_COMMENTS_CACHE + ".new"
        with open(tmp, "w") as f:
            json.dump(cache, f, indent=0, sort_keys=True)
        os.replace(tmp, HW_COMMENTS_CACHE)
    except OSError as ex:
        err("hw comments cache", ex)
    return cache, done


def lane_coverage(lanes):
    """-> (driving {bead: [lane]}, queued {bead: [lane-queue name]}). Driving: a live (not released, not evidence)
    lane's admitted bead plus its latest assign-next pop (lane-queue/*.done rows for the lane's run). Queued: the
    non-comment lines of lane-queue/<lane>.txt (assign-next.sh pops the first)."""
    driving, queued = {}, {}
    live = [l for l in lanes if l.get("cls") not in ("released", "evidence")]
    runs = {l["run"]: l["lane"] for l in live if l.get("run")}
    for l in live:
        if l.get("bead"):
            driving.setdefault(l["bead"], set()).add(l["lane"])
    last_pop = {}
    for path in glob.glob(os.path.join(LANE_QUEUE_DIR, "*.done")):
        try:
            with open(path, errors="replace") as f:
                for line in f:
                    c = line.rstrip("\n").split("\t")
                    if len(c) < 3 or c[1] not in runs or not c[2].split():
                        continue
                    m = BEAD_RE.fullmatch(c[2].split()[0])
                    if m and (c[1] not in last_pop or c[0] >= last_pop[c[1]][0]):
                        last_pop[c[1]] = (c[0], m.group(1))
        except OSError as ex:
            err("lane-queue", ex)
    for run, (_ts, bead) in last_pop.items():
        driving.setdefault(bead, set()).add(runs[run])
    for path in glob.glob(os.path.join(LANE_QUEUE_DIR, "*.txt")):
        name = os.path.basename(path)[:-4]
        try:
            with open(path, errors="replace") as f:
                for line in f:
                    s = line.strip()
                    if not s or s.startswith("#"):
                        continue
                    m = BEAD_RE.fullmatch(s.split()[0])
                    if m:
                        queued.setdefault(m.group(1), set()).add(name)
        except OSError as ex:
            err("lane-queue", ex)
    return driving, queued


def queued_kits(wq, lanes):
    """The window-queue kits waiting for or holding the device: every non-comment window-queue.tsv row (position =
    order among them, 1 = next) plus window-queue.active. -> [{lane, run, gen, label, pkg, position, active}]; lane is
    the live lane whose run owns the row, else the row's lane family."""
    by_run = {}
    for l in lanes:
        if l.get("run") and (l["run"] not in by_run or l.get("cls") not in ("released", "evidence")):
            by_run[l["run"]] = l["lane"]
    kits, pos = [], 0
    try:
        with open(wq.get("path") or os.path.join(WQ_BOARD, "window-queue.tsv"), errors="replace") as f:
            for raw in f:
                line = raw.rstrip("\n")
                if not line.strip() or line.lstrip().startswith("#"):
                    continue
                pos += 1
                c = line.split("\t")
                if len(c) > 5 and c[4].startswith("/"):
                    kits.append({"lane": by_run.get(c[2]) or c[1], "run": c[2], "gen": c[5], "label": c[7] if len(c) > 7 else "",
                                 "pkg": c[4].rstrip("/"), "position": pos, "active": False})
    except OSError as ex:
        err("window-queue (hardware kits)", ex)
    a = wq.get("active") or {}
    if a.get("pkg", "").startswith("/"):
        kits.insert(0, {"lane": by_run.get(a.get("owner")) or a.get("lane") or "?", "run": a.get("owner"), "gen": a.get("gen") or "",
                        "label": a.get("label") or "", "pkg": a["pkg"].rstrip("/"), "position": None, "active": True})
    return kits


def kit_files(pkg):
    fs = [os.path.join(pkg, "OPERATOR.md"), os.path.join(pkg, "PREFLIGHT")]
    fs += sorted(glob.glob(os.path.join(pkg, "requests-sealed", "*.json")))
    sk = os.path.join(pkg, "seed-kit")
    if os.path.isdir(sk):
        for root, dirs, files in os.walk(sk):
            dirs.sort()
            fs += [os.path.join(root, x) for x in sorted(files)]
            if len(fs) > HW_KIT_FILES_MAX:
                break
    else:
        fs.append(sk)
    return fs[:HW_KIT_FILES_MAX]


def kit_sig(pkg):
    out = []
    for p in (pkg, os.path.join(pkg, "OPERATOR.md"), os.path.join(pkg, "PREFLIGHT"), os.path.join(pkg, "requests-sealed"),
              os.path.join(pkg, "seed-kit")):
        try:
            out.append(os.stat(p).st_mtime_ns)
        except OSError:
            out.append(None)
    return out


def kit_bead_ids(kits):
    """pkg -> sorted bead ids the package names: its own path (…/recovery/<bead>/…) and the bare ids (not inside a
    path such as ~/wt/<bead>/… or another bead's image) in OPERATOR.md, PREFLIGHT, requests-sealed/*.json and
    seed-kit/*. Cached in
    HW_KITS_CACHE by the package dir's (and those entries') mtimes; HW_KITS_BUDGET_S caps the reads per refresh."""
    try:
        with open(HW_KITS_CACHE) as f:
            cache = json.load(f)
    except (OSError, ValueError):
        cache = {}
    t0, out, left = time.monotonic(), {}, 0
    for k in kits:
        pkg = k["pkg"]
        if pkg in out:
            continue
        sig = kit_sig(pkg)
        ent = cache.get(pkg)
        if ent and ent.get("sig") == sig:
            out[pkg] = ent["ids"]
            continue
        if time.monotonic() - t0 > HW_KITS_BUDGET_S:
            left += 1
            if ent:
                out[pkg] = ent["ids"]
            continue
        ids = set(BEAD_RE.findall(pkg))
        for fp in kit_files(pkg):
            try:
                with open(fp, "rb") as f:
                    b = f.read(HW_KIT_READ_MAX)
            except OSError:
                continue
            if b"\0" in b[:4096]:
                continue
            ids.update(BEAD_RE.findall(PATHISH_RE.sub(" ", b.decode("utf-8", "replace"))))
        out[pkg] = sorted(ids)
        cache[pkg] = {"sig": sig, "ids": out[pkg]}
    if left:
        err("hardware kits", f"budget {HW_KITS_BUDGET_S}s spent: {left} kit package(s) not re-read this refresh")
    try:
        tmp = HW_KITS_CACHE + ".new"
        with open(tmp, "w") as f:
            json.dump({p: cache[p] for p in out if p in cache}, f, indent=0, sort_keys=True)
        os.replace(tmp, HW_KITS_CACHE)
    except OSError as ex:
        err("hw kits cache", ex)
    return out


def kit_family_match(path, pkg):
    """A comment path names kit pkg when it is pkg (or under it) or the same family: same parent dir, basename equal
    once a -rN/-gN/-vN revision suffix is dropped (…/peripherals-first-functional-M8-r5 ~ …-M8-r8)."""
    pc, cc = pkg.split("/"), path.split("/")
    n = len(pc)
    if n < 6 or len(cc) < n or cc[:n - 1] != pc[:n - 1]:   # /home/matt/recovery/<bead>/<kit> at least
        return False
    return cc[n - 1] == pc[n - 1] or KIT_REV_RE.sub("", cc[n - 1]) == KIT_REV_RE.sub("", pc[n - 1])


def kit_cover(kits, kit_ids, index, comments, driving):
    """-> (named {bead: [kit]}, by_anchor_refs(anchor) -> [kit], batches {label: [member bead]}).
    named: the bead ids a queued kit's package names (rule b). by_anchor_refs: kits an anchor's own comments name by
    package path/family or generation (rule b, read from the bead side). batches: batch:<slug> label -> members (rule c)."""
    named = {}
    for k in kits:
        for i in kit_ids.get(k["pkg"]) or []:
            named.setdefault(i, []).append(k)

    def by_refs(anchor):
        refs = (comments.get(anchor) or {}).get("refs") or {}
        gens, paths = set(refs.get("gens") or []), refs.get("paths") or []
        return [k for k in kits if (k["gen"] and k["gen"] in gens) or any(kit_family_match(p, k["pkg"]) for p in paths)]

    batches = {}
    for bid, b in index.items():
        for lab in b.get("labels") or []:
            if lab.startswith("batch:"):
                batches.setdefault(lab, []).append(bid)
    return named, by_refs, batches


def child_map(index):
    """parent -> children, from the parent field and from the dotted id (tsp-x.1.2 is under tsp-x.1)."""
    kids = collections.defaultdict(set)
    for bid, b in index.items():
        if b.get("parent"):
            kids[b["parent"]].add(bid)
        if "." in bid:
            up = bid.rsplit(".", 1)[0]
            if up in index:
                kids[up].add(bid)
    return kids


def descendants(roots, kids):
    seen, todo = set(), list(roots)
    while todo:
        for c in kids.get(todo.pop(), ()):
            if c not in seen and c not in roots:
                seen.add(c)
                todo.append(c)
    return seen


def latest_ts(ts_list):
    best, best_d = None, None
    for t in ts_list:
        d = parse_ts(t)
        if d is not None and (best_d is None or d > best_d):
            best, best_d = t, d
    return best


def open_sorted(beads):
    """not-closed beads, best first: priority, in_progress before others, most recently updated."""
    xs = [b for b in beads if b["status"] not in ("closed", "tombstone")]
    xs.sort(key=lambda b: b.get("updated_at") or "", reverse=True)
    xs.sort(key=lambda b: (b["priority"] if isinstance(b.get("priority"), int) else 9, 0 if b["status"] == "in_progress" else 1))
    return xs


def row_kits(anchors, cover, index, driving, kc):
    """Coverage beyond a lane driving the row's own beads: queued/active window-queue kits (rule b, from the package or
    from the anchor's comments) and batch:<slug> propagation (rule c). -> (kits [{lane, gen, label, position, active,
    pkg, bead, via}], batch_lanes [{lane, bead, via}])."""
    named, by_refs, batches = kc
    kits, seen, blanes = [], set(), []

    def add(k, bead, via):
        key = (k["gen"], k["pkg"])
        if key not in seen:
            seen.add(key)
            kits.append({"lane": k["lane"], "gen": k["gen"], "label": k["label"], "position": k["position"],
                         "active": k["active"], "pkg": k["pkg"], "bead": bead, "via": via})

    for i in sorted(cover):
        for k in named.get(i, ()):
            add(k, i, "package")
    for a in anchors:
        for k in by_refs(a):
            add(k, a, "comment")
    for a in anchors:
        for lab in sorted(l for l in (index.get(a) or {}).get("labels") or [] if l.startswith("batch:")):
            for m in sorted(batches.get(lab, ())):
                if m in cover:
                    continue
                for ln in sorted(driving.get(m, ())):
                    if all(x["lane"] != ln for x in blanes):
                        blanes.append({"lane": ln, "bead": m, "via": lab})
                for k in named.get(m, ()):
                    add(k, m, lab)
    kits.sort(key=lambda k: (not k["active"], k["position"] or 0))
    return kits, blanes


def hw_row_live(r, index, kids, comments, driving, queued, kc=None):
    anchors = [a for a in (r.get("anchor") or []) if a]
    roots = set(anchors)
    desc = descendants(roots, kids)
    a_status = [{"id": a, "status": (index.get(a) or {}).get("status") or "missing"} for a in anchors]
    opens = open_sorted([index[i] for i in desc if i in index])
    times = [(comments.get(a) or {}).get("last") for a in anchors]
    for i in roots | desc:
        b = index.get(i)
        if b:
            times += [b.get("updated_at"), b.get("closed_at")]
    last = latest_ts(times)
    cover = roots | desc
    lanes = sorted({l for i in cover for l in driving.get(i, ())})
    queue = sorted({(l, i) for i in cover for l in queued.get(i, ())})
    kits, blanes = row_kits(anchors, cover, index, driving, kc) if kc else ([], [])
    hws = sorted((dict(h, bead=a) for a in anchors for h in (comments.get(a) or {}).get("hw") or []
                  if h.get("row") in (None, "", r["id"])), key=lambda h: h.get("at") or "")
    if hws:
        h = hws[-1]
        st = {"state": h["state"], "state_source": "hw_row", "build": h.get("build"), "evidence": h.get("evidence"),
              "evidence_at": h.get("at"), "evidence_by": h.get("by"), "evidence_bead": h["bead"]}
    else:
        st = {"state": r.get("seed_state") or "Untested", "state_source": "seed", "build": None,
              "evidence": r.get("seed_evidence") or "", "evidence_at": (r["seed_at"] + "T00:00:00Z") if r.get("seed_at") else None,
              "evidence_by": None, "evidence_bead": None}
    ev_age = age_s(parse_ts(st["evidence_at"]))
    flags = []
    if not anchors:
        flags.append("no_anchor")
    if st["state"] not in HW_OWNED_STATES and not lanes and not queue and not kits and not blanes:
        flags.append("unowned")
    if ev_age is not None and ev_age > HW_EVIDENCE_OLD_D * 86400:
        flags.append("evidence_old")
    if anchors and st["state"] not in HW_OWNED_STATES and all(s["status"] == "closed" for s in a_status):
        flags.append("anchor_closed")
    out = {k: r.get(k) for k in ("id", "name", "subsystem", "area", "goal", "scope", "driver", "driver_source") if k in r}
    out.update({"anchor": anchors, "anchor_status": a_status, "open_count": len(opens),
                "open_top": [{"id": b["id"], "title": b["title"][:120], "status": b["status"], "priority": b["priority"]}
                             for b in opens[:HW_TOP_OPEN]],
                "last_activity": last, "last_activity_age_s": age_s(parse_ts(last)), "lanes": lanes,
                "queued": [{"lane": l, "bead": i} for l, i in queue], "kits": kits, "batch_lanes": blanes,
                "evidence_age_s": ev_age, "flags": flags,
                "seed_state": r.get("seed_state"), "seed_at": r.get("seed_at")})
    out.update(st)
    return out


def build_hardware(index, lanes, comments, doc, wq=None):
    kids = child_map(index)
    driving, queued = lane_coverage(lanes)
    kits = queued_kits(wq or {}, lanes)
    kc = kit_cover(kits, kit_bead_ids(kits), index, comments, driving)
    flag_names = ("unowned", "evidence_old", "anchor_closed", "no_anchor")

    def tally(rows):
        t = {s: sum(1 for x in rows if x["state"] == s) for s in HW_STATES}
        for x in rows:
            if x["state"] not in t:
                t[x["state"]] = t.get(x["state"], 0) + 1
        return t

    rows = [hw_row_live(r, index, kids, comments, driving, queued, kc) for r in doc.get("rows") or []]
    hardware = {"rows": rows, "tally": tally(rows), "flags": {f: sum(1 for x in rows if f in x["flags"]) for f in flag_names},
                "source": HW_ROWS_FILE, "evidence_old_d": HW_EVIDENCE_OLD_D, "kits_scanned": len(kits)}
    prows = [hw_row_live(p, index, kids, comments, driving, queued, kc) for p in doc.get("priorities") or []]
    goals, placed = [], set()
    for g in doc.get("goals") or []:
        anchors = [a for a in (g.get("anchor") or []) if a]
        desc = descendants(set(anchors), kids)
        cover = set(anchors) | desc
        mem = [p for p in prows if p.get("goal") == g.get("id")]
        placed.update(id(p) for p in mem)
        goals.append({"id": g.get("id"), "tier": g.get("tier"), "name": g.get("name"), "why": g.get("why"),
                      "anchor": anchors,
                      "anchor_status": [{"id": a, "status": (index.get(a) or {}).get("status") or "missing"} for a in anchors],
                      "open_count": len(open_sorted([index[i] for i in desc if i in index])),
                      "lanes": sorted({l for i in cover for l in driving.get(i, ())}),
                      "tally": {k: v for k, v in tally(mem).items() if v}, "rows": mem})
    rest = [p for p in prows if id(p) not in placed]
    if rest:
        goals.append({"id": "unassigned", "tier": None, "name": "No goal", "why": "goal id not in hardware-rows.json goals",
                      "anchor": [], "anchor_status": [], "open_count": 0, "lanes": [],
                      "tally": {k: v for k, v in tally(rest).items() if v}, "rows": rest})
    priorities = {"goals": goals, "tally": tally(prows),
                  "flags": {f: sum(1 for x in prows if f in x["flags"]) for f in flag_names}}
    return hardware, priorities


def collect_backlog(index):
    """Every bead with status open (all scopes): age bucket (created_at) x area (id to two segments), P0/P1, batches."""
    nb = len(BACKLOG_BUCKETS)

    def bucket(b):
        a = age_s(parse_ts(b.get("created_at")))
        if a is None:
            return nb - 1
        for i, (_label, lim) in enumerate(BACKLOG_BUCKETS):
            if lim is None or a < lim * 86400:
                return i
        return nb - 1

    opens = [b for b in index.values() if b["status"] == "open"]
    areas, totals = {}, [0] * nb
    for b in opens:
        area = ".".join(b["id"].split(".")[:2])
        k = bucket(b)
        a = areas.setdefault(area, {"area": area, "total": 0, "p0": 0, "p1": 0, "counts": [0] * nb})
        a["total"] += 1
        a["counts"][k] += 1
        totals[k] += 1
        if b.get("priority") == 0:
            a["p0"] += 1
        elif b.get("priority") == 1:
            a["p1"] += 1
    ranked = sorted(areas.values(), key=lambda a: (-a["total"], a["area"]))
    shown, rest = ranked[:BACKLOG_AREAS_SHOW], ranked[BACKLOG_AREAS_SHOW:]
    other = {"areas": len(rest), "total": sum(a["total"] for a in rest), "p0": sum(a["p0"] for a in rest),
             "p1": sum(a["p1"] for a in rest), "counts": [sum(a["counts"][i] for a in rest) for i in range(nb)]}
    batches = {}
    for b in index.values():
        for lab in b.get("labels") or []:
            if not lab.startswith("batch:") or len(lab) <= 6:
                continue
            g = batches.setdefault(lab[6:], {"batch": lab[6:], "total": 0, "open": 0, "in_progress": 0, "blocked": 0,
                                             "closed": 0, "other": 0, "_beads": []})
            g["total"] += 1
            g[b["status"] if b["status"] in ("open", "in_progress", "blocked", "closed") else "other"] += 1
            g["_beads"].append(b)
    out_b = []
    for g in sorted(batches.values(), key=lambda g: (-(g["total"] - g["closed"]), g["batch"])):
        g["top"] = [{"id": b["id"], "title": b["title"][:120], "status": b["status"], "priority": b["priority"]}
                    for b in open_sorted(g.pop("_beads"))[:HW_TOP_OPEN]]
        out_b.append(g)
    return {"open_total": len(opens), "p0": sum(1 for b in opens if b.get("priority") == 0),
            "p1": sum(1 for b in opens if b.get("priority") == 1), "older_14d": totals[-1],
            "buckets": [label for label, _ in BACKLOG_BUCKETS], "totals": totals, "areas": shown, "other": other,
            "areas_total": len(areas), "batches": out_b}


def main():
    drivers = live_drivers()
    adm = admission_map()
    cache = load_cache()
    beads_box = {}

    # preliminary lane->bead map (admission files + cached run.status) so the stale scan can run alongside pf-task
    prelim_lanes = set()
    cutoff = time.time() - LANE_LOG_WINDOW_H * 3600
    for path in glob.glob(os.path.join(G, "*-drive.log")):
        try:
            if os.path.getmtime(path) < cutoff:
                continue
            txt = open(path, errors="replace").read()
        except OSError:
            continue
        runs = RUN_RE.findall(txt)
        if runs:
            rid = runs[-1]
            t = (adm.get(rid) or {}).get("task") or (cache.get(rid) or {}).get("task")
            if t:
                prelim_lanes.add(t)
    for rid, a in adm.items():
        if a["mtime"] >= time.time() - ADMISSION_WINDOW_H * 3600 and a.get("task"):
            prelim_lanes.add(a["task"])

    def beads_job():
        try:
            beads_box["index"], beads_box["ready"] = collect_beads()
        except Exception as ex:
            err("beads", ex)
            beads_box["index"], beads_box["ready"] = {}, []
        try:
            cands, _ = stale_candidates(beads_box["index"], {b: 1 for b in prelim_lanes})
            beads_box["comments"] = fetch_comments_for([c["id"] for c in cands])
        except Exception as ex:
            err("comments prefetch", ex)
            beads_box["comments"] = {}
        # 2026-10-20: hardware rows' anchor comments (HW_ROW tokens), cached by comment_count
        try:
            beads_box["hw_doc"] = load_hw_doc()
            beads_box["hw_comments"], beads_box["hw_fetched"] = collect_hw_comments(
                beads_box["index"], hw_anchor_ids(beads_box["hw_doc"]))
        except Exception as ex:
            err("hardware rows", ex)
            beads_box["hw_comments"], beads_box["hw_fetched"] = {}, 0

    with cf.ThreadPoolExecutor(2) as ex:
        fut_beads = ex.submit(beads_job)
        lanes = collect_lanes(drivers, adm, cache)      # sequential pf-task lookups, main thread
        save_cache(cache)
        refs = pr_refs_from_lanes(lanes)
        # until_pr=<owner/repo#N> park holds need that PR's state too.
        for _since, _why in PARKED.values():
            for _m in re.finditer(r"until_pr=([\w.-]+/[\w.-]+#\d+)", _why):
                if PR_RE.match(_m.group(1)):
                    refs.setdefault(_m.group(1), None)
        fut_prs = ex.submit(collect_prs, refs)
        fut_beads.result()
        prs = fut_prs.result()
    index, ready_ids = beads_box["index"], beads_box["ready"]
    dev = collect_device()
    wq = dev["window_queue"]
    owner = collect_owner_asks()
    needs = classify_lanes(lanes, prs, index, dev, owner=owner)
    needs += classify_device(dev)
    needs += classify_host()
    for q in collect_model_quota():
        needs.append({"kind": "blocked", "id": "quota:" + q["worktree"], "lane": None, "bead": q["worktree"].split("/")[0],
                      "run": None, "pr": None,
                      "reason": f"OpenCode session {q['session'][:16]} (port {q['port']}) is in a provider retry loop: {q['message'][:140]}",
                      "since": None, "age_s": None,
                      "next": "Re-route to Codex (WT_ID=<bead>-cx, fetch unpushed commits by path), then POST /session/<id>/abort "
                              "so it cannot wake and push; if the lane is another coordinator's, tell them."})
    disp, stale, long_idle, bead_needs, lane_by_bead, owned = classify_beads(index, ready_ids, lanes, beads_box.get("comments") or {})
    # 2026-10-20: hardware & driver rows, tier priorities, open backlog. Display only: never needs items.
    hardware, priorities, backlog = {"rows": [], "error": None}, {"goals": []}, None
    if beads_box.get("hw_doc") is not None and index:
        try:
            hardware, priorities = build_hardware(index, lanes, beads_box.get("hw_comments") or {}, beads_box["hw_doc"], wq)
            hardware["comments_fetched"] = beads_box.get("hw_fetched", 0)
        except Exception as ex:
            err("hardware", ex)
            hardware["error"] = str(ex)[:300]
    if index:
        try:
            backlog = collect_backlog(index)
        except Exception as ex:
            err("backlog", ex)
    waited = []
    for n in bead_needs:
        w = wait_for(n.get("bead") or "")
        w_age = age_s(parse_ts(w[0])) if w else None
        if w and w_age is not None and w_age < WAIT_MAX_H * 3600:
            waited.append({"bead": n["bead"], "kind": n["kind"], "since": w[0], "reason": w[1]})
            continue
        if w:
            n["reason"] = f"wait recorded longer than {WAIT_MAX_H} h ({w[1][:120]}); " + n["reason"]
        needs.append(n)
    # 2026-10-13: glcrash sat WINDOW_READY on a recorded wait (transport fix deploy) and re-flagged "undriven" every
    # tick. A fresh waits.tsv row for the lane's bead covers an undriven lane need too; handbacks and merges still show.
    kept = []
    for n in needs:
        if n.get("kind") == "undriven" and n.get("bead"):
            w = wait_for(n["bead"])
            w_age = age_s(parse_ts(w[0])) if w else None
            if w and w_age is not None and w_age < WAIT_MAX_H * 3600:
                waited.append({"bead": n["bead"], "kind": n["kind"], "since": w[0], "reason": w[1]})
                continue
        kept.append(n)
    needs[:] = kept
    for n in needs:
        n["rank"] = KIND_RANK.get(n["kind"], 9)
    needs.sort(key=lambda n: (n["rank"], -(n["age_s"] or 0)))

    shown = [l for l in lanes if l.get("cls") != "released"]
    released = [l for l in lanes if l.get("cls") == "released"]
    evidence = [{"lane": l["lane"], "run": l["run"], "bead": l.get("bead"), "who": l["evidence"]["who"],
                 "keeper_bead": l["evidence"]["bead"], "reason": (PARKED.get(l["run"] or "") or ("", ""))[1][:300],
                 "since": (PARKED.get(l["run"] or "") or (None,))[0],
                 "age_s": age_s(parse_ts((PARKED.get(l["run"] or "") or (None,))[0]))}
                for l in shown if l.get("cls") == "evidence"]
    refd = set()
    for ln in shown:
        if ln.get("bead"):
            refd.add(ln["bead"])
    for n in needs:
        if n.get("bead"):
            refd.add(n["bead"])
    for c in disp["chains"]:
        refd.add(c["blocker"]["id"])
        refd.update(d["id"] for d in c["dependents"])
    for p in disp["parallel"] + disp["newly_unblocked"]:
        refd.add(p["id"])
        if p.get("parent"):
            refd.add(p["parent"])
        refd.update(x["id"] for x in p["blockers"])
    for s in stale + owned:
        refd.add(s["id"])
        if s.get("parent"):
            refd.add(s["parent"])
    for x in evidence:
        refd.update(i for i in (x["bead"], x["keeper_bead"]) if i)
    bindex = {i: {"title": index[i]["title"][:160], "status": index[i]["status"], "type": index[i]["type"],
                  "priority": index[i]["priority"]} for i in refd if i in index}

    lane_rows = []
    for ln in sorted(shown, key=lambda l: ({"needs": 0, "unknown": 1, "waiting": 2, "running": 3}.get(l["cls"], 4),
                                           -(l.get("status_age_s") or 0))):
        lane_rows.append({k: ln.get(k) for k in (
            "lane", "token", "run", "run_state", "run_checked_at", "run_fresh", "run_error", "bead", "bead_title",
            "model", "provider", "runtime", "driver_alive", "driver_pids", "driver_etimes", "last_status",
            "last_event_at", "last_turn_end", "ci_wait", "pr", "pr_head", "reconciler_alive", "controller_alive",
            "runtime_alive", "native_activity_age_s", "messages_total", "worktree", "blocker_error", "runtime_parked",
            "cls", "kind", "cls_reason", "next", "log", "log_mtime", "source", "status_age_s", "session_id",
            "window_queue", "evidence")})
    summary = {
        "needs": len(needs),
        "lanes_total": len(shown),
        "lanes_running": sum(1 for l in shown if l["cls"] == "running"),
        "lanes_waiting": sum(1 for l in shown if l["cls"] == "waiting"),
        "lanes_needs": sum(1 for l in shown if l["cls"] == "needs"),
        "lanes_unknown": sum(1 for l in shown if l["cls"] == "unknown"),
        "lanes_evidence": len(evidence),
        "owned": {w: sum(1 for o in owned if o["assignee"] == w) for w in COORD_OWNERS},
        "lanes_released_hidden": len(released),
        "dispatchable": disp["parallel_total"] + len(disp["newly_unblocked"]),
        "dispatchable_recent": disp["parallel_recent_total"] + len(disp["newly_unblocked"]),
        "lanes_unchecked": sum(1 for l in shown if (l.get("run_error") or "").startswith("not checked")),
        "stale_individual": sum(1 for n in needs if n["kind"] == "stale" and n.get("bead")),
        "newly_unblocked": len(disp["newly_unblocked"]),
        "stale": len(stale),
        "owner_asks": owner["count"],
        "device": {"running": (dev.get("running") or {}).get("name"), "pending": dev["pending_count"],
                   "halted": dev["halted"], "runner_alive": dev["runner_alive"], "kit_running": dev["kit_running"],
                   # 2026-10-19: the live queue (window-queue.sh); "pending" above stays the retired queue.tsv count
                   "wq_depth": wq["depth"], "wq_held": wq["held_count"], "wq_active": (wq["active"] or {}).get("gen"),
                   "wq_active_phase": (wq["active"] or {}).get("phase"), "wq_paused": wq["paused"],
                   "wq_running": wq["running"]},
        "needs_by_kind": {k: sum(1 for n in needs if n["kind"] == k) for k in KIND_RANK},
        "beads_in_scope_in_progress": sum(1 for i, b in index.items() if in_scope(i) and b["status"] == "in_progress"),
        "beads_in_scope_open": sum(1 for i, b in index.items() if in_scope(i) and b["status"] == "open"),
        "hardware": {"rows": len(hardware.get("rows") or []), "tally": hardware.get("tally") or {},
                     "flags": hardware.get("flags") or {}},
        "backlog_open": (backlog or {}).get("open_total"),
    }
    dev.pop("pending_all", None)
    dev.pop("done_rows", None)
    dev.pop("wq_by_gen", None)
    data = {
        "generated_at": iso(NOW), "generated_epoch": NOW.timestamp(), "host": socket.gethostname(),
        "runtime_s": round(time.time() - T0, 1),
        "thresholds": {k: v for k, v in globals().items() if k.isupper() and isinstance(v, (int, float, str))
                       and k not in ("G", "MC", "BOARD", "OUT", "CACHE", "OWNER_ASKS", "PFTASK_BIN", "PFTASK_HOME", "NOW", "T0",
                                     "WQ_BOARD", "KIT_WINDOWS", "HW_ROWS_FILE", "HW_COMMENTS_CACHE", "HW_KITS_CACHE",
                                     "LANE_QUEUE_DIR")},
        "campaign_roots": CAMPAIGN_ROOTS,
        "errors": ERRORS, "summary": summary, "needs": needs, "waits": waited, "lanes": lane_rows,
        "released_runs": [{"lane": l["lane"], "run": l["run"], "bead": l.get("bead")} for l in released],
        "prs": prs, "dispatchable": disp, "device": dev, "stale": stale, "long_idle": long_idle,
        "owner_asks": owner, "beads_index": bindex, "owned": owned, "evidence": evidence,
        "hardware": hardware, "priorities": priorities, "backlog": backlog,
    }
    tmp = OUT + ".new"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=False)
    os.replace(tmp, OUT)
    print(f"COLLECT ok path={OUT} runtime_s={data['runtime_s']} lanes={len(shown)} needs={len(needs)} errors={len(ERRORS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
