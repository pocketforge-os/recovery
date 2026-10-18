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
  D. device    <G>/queue.tsv, queue.done, device-queue.txt, `ps` for the queue
               runner and a running direct-boot.sh kit.
  E. owner     /home/matt/gpu14-owner-questions.md "## Needs you" section.

data.json schema (top level):
  generated_at (ISO UTC), generated_epoch, host, runtime_s
  thresholds        {name: value} the constants below, for the page footer
  errors            [{source, error}] every source that could not be read
  summary           {needs, lanes_total, lanes_running, lanes_waiting, lanes_needs,
                     lanes_unknown, dispatchable, newly_unblocked, stale, owner_asks,
                     device:{running, pending, halted, runner_alive}}
  needs             [{rank, kind, id, lane, bead, run, pr, reason, since, age_s, next}]
                    kind in handback|merge_ready|boot_ready|blocked|stale|undriven|
                    device|dispatchable ; sorted by rank
  lanes             [{lane, token, run, run_state, run_checked_at, run_fresh, bead,
                     bead_title, model, provider, runtime, driver_alive, driver_pids,
                     last_status:{n, state, reason, kv, ts, raw}, last_event_at,
                     last_turn_end, ci_wait:{pr, head, result, ts}, pr, pr_head,
                     reconciler_alive, controller_alive, runtime_alive,
                     native_activity_age_s, worktree, blocker_error,
                     cls (needs|waiting|running|released|unknown), kind, cls_reason,
                     next, log, log_mtime, source (log|admission)}]
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
                     detail}], events:[{ts, kind, text}], last_line, log_mtime}
  stale             [{id, title, status, assignee, tier, parent, updated_at,
                     last_comment_at, comment_count, age_s}]
  long_idle         {count, ids:[...]}   in_progress in scope, untouched > STALE_LOOKBACK_H
  owner_asks        {count, items:[{num, title}], error}
  beads_index       {id: {title, status, type, priority}} for every id referenced
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
G = "/home/matt/recovery/gpu14"
SECONDARY_PR_WINDOW_H = 12  # 2026-10-12: secondary PRs named by a lane within this window are checked for RED CI
PARK_MAX_H = 12
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
OWNER_ASKS = "/home/matt/gpu14-owner-questions.md"
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


def run_cmd(cmd, timeout, cwd=None, env=None):
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
            st = {"n": n, "ts": ts, "raw": body[:400], "state": "NONE", "reason": None, "kv": {}}
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
    return dev


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
    for im in re.finditer(r"^(\d+)\.\s+\*\*(.+?)\*\*", sec, re.M):
        out["items"].append({"num": int(im.group(1)), "title": im.group(2).strip()[:200]})
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


def classify_lanes(lanes, prs, index, dev):
    """Set cls/kind/cls_reason/next on each lane; return needs items."""
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
        if pk and rs != "released" and not ln["driver_alive"] and pk_pri and pk_pri.get("state") in ("MERGED", "CLOSED"):
            need("unblocked", f"parked until {pk_pr}, which is {pk_pri.get('state')} ({pk_pri.get('merged_at') or ''}): {pk[1]}",
                 "Resume the lane on the merged change and unpark it (edit parked.tsv).")
        elif pk and rs != "released" and not ln["driver_alive"] and pk_pr and (pk_pri or {}).get("state") == "OPEN":
            wait(f"parked until {pk_pr} merges ({fmt_age(pk_age)} ago): {pk[1]}")
        elif pk and rs != "released" and not ln["driver_alive"] and pk_hold:
            wait(f"parked until {pk_bead} closes ({fmt_age(pk_age)} ago): {pk[1]}")
        elif pk and rs != "released" and not ln["driver_alive"] and pk_age is not None and pk_age < PARK_MAX_H * 3600:
            wait(f"parked {fmt_age(pk_age)} ago: {pk[1]}")
        elif pk and rs != "released" and not ln["driver_alive"]:
            need("stale", f"parked longer than {PARK_MAX_H} h: {pk[1]}", "Re-check the park reason; unpark (edit parked.tsv) or act.")
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
                    else:
                        need(kind_for_state, f"{st} {fmt_age(st_age)} ago; a driver is alive but the run is {rs}",
                             "Read the handback; run.send the next step or release and stop the driver.")
                elif st in NEEDS_STATES:
                    wait(f"{st} just now; driver winding down")
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
        if cls not in ("needs", "released") and not (pk and ((pk_age is not None and pk_age < PARK_MAX_H * 3600) or pk_hold)):
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
        if bid in lane_by_bead:
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
    return disp, stale, {"count": len(long_idle), "ids": sorted(long_idle)}, needs, lane_by_bead


# --------------------------------------------------------------------- main --
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
    needs = classify_lanes(lanes, prs, index, dev)
    needs += classify_device(dev)
    needs += classify_host()
    for q in collect_model_quota():
        needs.append({"kind": "blocked", "id": "quota:" + q["worktree"], "lane": None, "bead": q["worktree"].split("/")[0],
                      "run": None, "pr": None,
                      "reason": f"OpenCode session {q['session'][:16]} (port {q['port']}) is in a provider retry loop: {q['message'][:140]}",
                      "since": None, "age_s": None,
                      "next": "Re-route to Codex (WT_ID=<bead>-cx, fetch unpushed commits by path), then POST /session/<id>/abort "
                              "so it cannot wake and push; if the lane is another coordinator's, tell them."})
    disp, stale, long_idle, bead_needs, lane_by_bead = classify_beads(index, ready_ids, lanes, beads_box.get("comments") or {})
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
    owner = collect_owner_asks()

    shown = [l for l in lanes if l.get("cls") != "released"]
    released = [l for l in lanes if l.get("cls") == "released"]
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
    for s in stale:
        refd.add(s["id"])
        if s.get("parent"):
            refd.add(s["parent"])
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
            "cls", "kind", "cls_reason", "next", "log", "log_mtime", "source", "status_age_s", "session_id")})
    summary = {
        "needs": len(needs),
        "lanes_total": len(shown),
        "lanes_running": sum(1 for l in shown if l["cls"] == "running"),
        "lanes_waiting": sum(1 for l in shown if l["cls"] == "waiting"),
        "lanes_needs": sum(1 for l in shown if l["cls"] == "needs"),
        "lanes_unknown": sum(1 for l in shown if l["cls"] == "unknown"),
        "lanes_released_hidden": len(released),
        "dispatchable": disp["parallel_total"] + len(disp["newly_unblocked"]),
        "dispatchable_recent": disp["parallel_recent_total"] + len(disp["newly_unblocked"]),
        "lanes_unchecked": sum(1 for l in shown if (l.get("run_error") or "").startswith("not checked")),
        "stale_individual": sum(1 for n in needs if n["kind"] == "stale" and n.get("bead")),
        "newly_unblocked": len(disp["newly_unblocked"]),
        "stale": len(stale),
        "owner_asks": owner["count"],
        "device": {"running": (dev.get("running") or {}).get("name"), "pending": dev["pending_count"],
                   "halted": dev["halted"], "runner_alive": dev["runner_alive"], "kit_running": dev["kit_running"]},
        "needs_by_kind": {k: sum(1 for n in needs if n["kind"] == k) for k in KIND_RANK},
        "beads_in_scope_in_progress": sum(1 for i, b in index.items() if in_scope(i) and b["status"] == "in_progress"),
        "beads_in_scope_open": sum(1 for i, b in index.items() if in_scope(i) and b["status"] == "open"),
    }
    dev.pop("pending_all", None)
    dev.pop("done_rows", None)
    data = {
        "generated_at": iso(NOW), "generated_epoch": NOW.timestamp(), "host": socket.gethostname(),
        "runtime_s": round(time.time() - T0, 1),
        "thresholds": {k: v for k, v in globals().items() if k.isupper() and isinstance(v, (int, float, str))
                       and k not in ("G", "MC", "BOARD", "OUT", "CACHE", "OWNER_ASKS", "PFTASK_BIN", "PFTASK_HOME", "NOW", "T0")},
        "campaign_roots": CAMPAIGN_ROOTS,
        "errors": ERRORS, "summary": summary, "needs": needs, "waits": waited, "lanes": lane_rows,
        "released_runs": [{"lane": l["lane"], "run": l["run"], "bead": l.get("bead")} for l in released],
        "prs": prs, "dispatchable": disp, "device": dev, "stale": stale, "long_idle": long_idle,
        "owner_asks": owner, "beads_index": bindex,
    }
    tmp = OUT + ".new"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=False)
    os.replace(tmp, OUT)
    print(f"COLLECT ok path={OUT} runtime_s={data['runtime_s']} lanes={len(shown)} needs={len(needs)} errors={len(ERRORS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
