#!/usr/bin/env python3
"""collect.py -- gather live fleet state for gpu-16 into data.json (read-only).

Everything comes from live sources on every run; nothing is remembered between
runs except the hardware-row comment/kit caches under cache/.
2026-11-02 (tsp-mc9m.60.29.84.14): lanes are gpu-16's managed runs (runs/active.tsv),
the device section is BENCH + pf-kit-window-runner, owner asks come from the owner
intake. The gpu-14 drive-log lanes and the window queue are retired and not read.

Sources (all read-only):
  A. beads     `bd list --all --json --flat -n 0` (one call, every status) and
               `bd ready --json -n 0`; `bd comments <id> --json` only for stale
               candidates (bounded, see COMMENTS_MAX).
  B. lanes     <G16>/runs/active.tsv (NAME, run_id, pf-task home; '#' rows released),
               pf-task run.status per run on its own home (watch-runs.py pft(): read-only,
               sequential) and the newest G16_<CLUSTER>_STATUS line in that run's
               receipts (<G16>/runs/receipts-<NAME>.jsonl, appended by watch-runs.py).
               A `blocked` run whose blocker is kept usage-limit text from a quota episode
               it has since completed a turn after is stale quota (.84.11): idle/working.
  C. PRs       `gh pr view` for PRs named in lane status lines.
  D. device    BENCH's newest status line (+ the newest runner=/dut=/place= it reported),
               `systemctl --user show pf-kit-window-runner.service`, the kit windows
               (~/.local/state/pocketforge/kit-windows), <G16>/runs/relay-sent.json for the
               BENCH queue, and typed results of the last TYPED_RESULTS_WINDOW_H hours: the kit
               windows' own close records (terminal.json, a failed boot-open, a failed runner:
               collect_windows) and the files under TYPED_RESULTS_ROOT (BENCH-RESULT*.json v1,
               lane-written *BENCH-RESULT*.txt, DEPLOY-RECEIPT*.txt).
               2026-11-08 (tsp-hqm1p.181): a result source that yields no row while kit windows closed
               is a WARN (results.warns), never a quiet "no typed result".
               2026-11-05 (tsp-hqm1p.100): the same kit windows give each hardware row its device evidence
               (collect_hw_windows / window_links): window_at, window_result ok|fail, window_generation,
               window_bead, window_via bead|named|cluster, window_source, window_ok_n/window_fail_n, windows[],
               and an open window as a kit. hardware.kits_scanned counts the requests read. Display only: the
               row state and evidence_at stay the latest HW_ROW comment.
  E. owner     `pf-owner-intake.sh list --id <id>` for each OWNER_INTAKE_IDS id; only
               tickets that are not resolved are owner asks.
  F. checkouts ~/.local/state/pocketforge/shared-refresh.json (pf-shared-refresh status) and
               shared-refresh-allow.json beside this file.

data.json schema (top level):
  generated_at (ISO UTC), generated_epoch, host, runtime_s
  thresholds        {name: value} the constants below, for the page footer
  errors            [{source, error}] every source that could not be read
  summary           {needs, lanes_total, lanes_running, lanes_waiting, lanes_needs,
                     lanes_unknown, lanes_stale_quota, dispatchable, newly_unblocked, stale,
                     owner_asks, device:{running (open window "<purpose> <gen8>"), pending (unanswered
                     BENCH queue rows), halted (runner unit not active), runner_alive, kit_running,
                     windows_open, bench_state, bench_verdict, queue_total, results_24h}}
  needs             [{rank, kind, id, lane, bead, run, pr, reason, since, age_s, next}]
                    kind in handback|merge_ready|boot_ready|blocked|stale|undriven|
                    device|host|dispatchable ; sorted by rank
  lanes             [{lane, token, run, home, run_state (pf-task), state (working|idle|blocked|...|
                     unknown), stale_quota, run_checked_at, run_fresh, run_error, bead, bead_title,
                     model, provider, runtime, driver_alive (controller and reconciler alive),
                     last_status:{cluster, verdict, state, reason, kv, detail, raw, receipt, ts,
                     age_src (turn end|receipt log), newest}, status_age_s, last_turn_end,
                     last_turn_reason, pr, reconciler_alive, controller_alive, runtime_alive,
                     native_activity_age_s, messages_pending, messages_total, receipts_total,
                     receipts_unacked, worktree, blocker_error, cls (needs|waiting|running|unknown),
                     kind, cls_reason, next, source, session_id}]
  released_runs     [{lane, run, bead}]   '#' rows of active.tsv and released runs
  prs               {"owner/repo#N": {state, merged_at, head, review, draft, title,
                     url, checks:{total, success, pending, failed, failed_names},
                     ci_green, merge_ready, fetched_at, error}}
  dispatchable      {parallel:[bead], newly_unblocked:[bead], chains:[{blocker:bead,
                     dependents:[bead]}], backlog_count, parallel_shown, chains_total}
                    bead = {id, title, status, priority, type, tier, parent,
                            parent_title, updated_at, created_at, blockers:[{id,
                            status, closed_at, title}], lane}
  device            {bench:{lane, run, home, bead, run_state, state, cls, cls_reason, last_status,
                     status_age_s, messages_pending, messages_total, native_activity_age_s,
                     stale_quota, blocker_error}|null,
                     runner:{unit, active, sub, pid, since, deployed, error},
                     reported:{runner|dut|place: {value, receipt, receipts_back}} (BENCH status lines),
                     boundary:{dut, place, at, file}|null (newest typed result that carries one),
                     windows:[{gen, requested_at, state, outcome, open, lane, purpose, opened_at,
                     deadline, last_activity}] (WINDOWS_SHOW newest), windows_open, windows_total,
                     queue:[{cluster, lane, from, request, request_file, request_sha256, relayed_at,
                     age_s, answered, answers_after, answer:{to, file, at, state, reason,
                     typed_cause}|null}], sent_error,
                     results:{window_h, root, depth, total, error, windows_root, windows_closed,
                     by_kind:{kind: n}, warns:[{source kit-window|files, windows_closed, text}],
                     groups:[{kind, state, reason, typed_cause, count, latest_at, lanes, sev}],
                     items:[{kind kit-window|bench-result|bench-result-txt|deploy-result|deploy-receipt,
                     file, path, at, state, reason, typed_cause, lane, lane_hint, boundary,
                     (kit-window) gen, lane_reason, purpose}]}}
  stale             [{id, title, status, assignee, tier, parent, updated_at,
                     last_comment_at, comment_count, age_s}]
  long_idle         {count, ids:[...]}   in_progress in scope, untouched > STALE_LOOKBACK_H
  owner_asks        {count, items:[{ticket, status, round, bead, id, title}], error, source, ids,
                     listed, resolved}   (open = intake status other than resolved)
  owned             [{id, title, status, assignee, tier, parent, updated_at, age_s, priority}] beads with no lane
                    assigned to another coordinator (COORD_OWNERS); never needs or stale rows
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
  shared_refresh    {status_path, generated_at, complete, error, checkouts:[{path, branch, state, ahead, behind,
                     first_skipped_at, last_ok_at, checked_at, skipped_s, alarm, allowlisted}]}
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
# waits; untyped rows drop out of NEEDS for WAIT_MAX_H, then come back so stale
# bookkeeping cannot hide work. Typed rows are governed by their condition.
WAIT_MAX_H = 24
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
# ".*" covers every descendant. Typed rows share the parked.tsv condition
# grammar; only legacy untyped rows retain the 24 h expiry.
def wait_for(bid):
    # The freshest matching row wins (an expired exact row must not mask a fresh epic-wide one).
    cands = [v for k, v in WAITS.items() if k == bid or (k.endswith(".*") and bid.startswith(k[:-1]))]
    return max(cands, key=lambda v: v[0]) if cands else None


MC = "/home/matt/mission-control"
BOARD = os.environ.get("FB_BOARD_DIR") or "/home/matt/recovery/gpu14/fleet-board"
PRESERVED_RUNS_FILE = os.environ.get("FB_PRESERVED_RUNS_FILE") or os.path.join(BOARD, "preserved-runs.json")
COORD_NEEDS_FILE = os.environ.get("FB_COORD_NEEDS_FILE") or os.path.join(BOARD, "coord-needs.json")
OUT = os.path.join(BOARD, "data.json")

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

STALE_BEAD_H = 6                # in_progress, no lane, no update/comment for this long -> stale
STALE_LOOKBACK_H = 168          # older untouched in_progress beads are "long idle", not alarms
STALE_INDIVIDUAL_H = 24         # stale beads idle longer than this are one aggregated needs item, not one each
RECENT_DAYS = 14                # dispatchable beads touched within this are "recent"; the rest is backlog
NEWLY_UNBLOCKED_H = 72          # a blocker closed within this window makes a ready bead "newly unblocked"
PARALLEL_SHOW = 40              # dispatchable beads listed in full
CHAINS_SHOW = 30
GH_TIMEOUT_S = 40
GH_PARALLEL = 4
BD_TIMEOUT_S = 180
COMMENTS_PARALLEL = 4
COMMENTS_MAX = 150
COMMENTS_TIMEOUT_S = 30
RULING_COMMENTS_MAX = 20        # newest comments retained in memory for board waiting/ruling attribution
RULING_COMMENT_BYTES = 4096     # per-comment bound; no comment bodies are emitted into data.json
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
# 2026-11-05 (tsp-hqm1p.100): device evidence per row is derived from the kit-window runner's own results (the window
# queue is retired, so queued kits are always empty). Display only: HW_ROW comments stay the only authority for a row's
# state, and a derived window result never changes state, state_source, evidence_at or the HW_ROW fields.
HW_WINDOWS_LOOKBACK_H = 168     # kit windows (boot-open requests) read for row evidence
HW_WINDOW_INFLIGHT_H = 3        # a request with no terminal.json older than this is stale: neither a result nor a kit
HW_WINDOW_OK_REASONS = ("lane_done", "success")   # terminal State=closed with one of these = ok (velocity.py's rule)
HW_WINDOWS_ROW_SHOW = 3         # recent windows listed per row
HW_MENTION_TEXT_MAX = 8000      # chars of a bead's description scanned for the bead ids it names
BACKLOG_AREAS_SHOW = 15         # areas listed in the open-backlog table; the rest is one "other" row
BACKLOG_BUCKETS = (("<1 d", 1), ("1–3 d", 3), ("3–7 d", 7), ("7–14 d", 14), (">14 d", None))

NEEDS_STATES = {"HANDBACK", "BOOT_READY", "BLOCKED", "IDLE", "QUESTION", "MERGE_READY",
                "DESIGN_READY", "PARTIAL", "DIAG_ONLY"}
NON_DISPATCH_TYPES = {"epic", "gate", "molecule", "convoy"}

KIND_RANK = {"merge_ready": 0, "handback": 1, "boot_ready": 2, "budget": 3, "device": 3, "host": 3, "blocked": 4,
             "stale": 5, "undriven": 6, "dispatchable": 7}

NOW = dt.datetime.now(dt.timezone.utc)
T0 = time.time()
ERRORS = []


class SourceReadError(RuntimeError):
    """An authoritative input could not be read completely and truthfully."""


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


def load_preserved_runs():
    try:
        with open(PRESERVED_RUNS_FILE, errors="replace") as f:
            rows = json.load(f)
        if not isinstance(rows, list):
            raise ValueError("top level must be a list")
        return rows
    except Exception as ex:
        err("preserved runs", ex)
        raise SourceReadError(f"preserved runs: {ex}") from ex


def load_coord_needs():
    """Load keyed producer refusals/idles; malformed state is a visible source error."""
    try:
        with open(COORD_NEEDS_FILE, errors="replace") as f:
            rows = json.load(f)
    except FileNotFoundError:
        return []
    except Exception as ex:
        err("coord needs", ex)
        raise SourceReadError(f"coord needs: {ex}") from ex
    if not isinstance(rows, list):
        err("coord needs", "top level must be a list")
        raise SourceReadError("coord needs: top level must be a list")
    out = []
    for row in rows:
        if not isinstance(row, dict) or not row.get("id") or not row.get("reason"):
            err("coord needs", "row missing id/reason")
            raise SourceReadError("coord needs: row missing id/reason")
        item = dict(row)
        item["age_s"] = age_s(parse_ts(item.get("since")))
        item.setdefault("kind", "refusal")
        item.setdefault("next", "gpu-14: inspect typed coordination need")
        out.append(item)
    return out


def in_scope(bid):
    return any(bid == r or bid.startswith(r + ".") for r in CAMPAIGN_ROOTS)


# -------------------------------------------------------------------- beads --
CLUSTER_ROWS_RE = re.compile(r"^## Rows[ \t]*\n(.*?)(?=^## |\Z)", re.M | re.S)
CLUSTER_ROW_ID_RE = re.compile(r"^- (tsp-[a-z0-9]+(?:\.[0-9]+)*)\b", re.M)


def cluster_rows(desc):
    """2026-11-02: a gpu-16 cluster bead lists the hardware-row beads its lane drives under '## Rows' ('- <id> ...')."""
    m = CLUSTER_ROWS_RE.search(desc or "") if "## Rows" in (desc or "") else None
    return CLUSTER_ROW_ID_RE.findall(m.group(1)) if m else []


CLUSTER_SHORT_RE = re.compile(r"(?:^|;)[ \t]*\.([0-9]+)\b", re.M)


def cluster_row_mentions(desc):
    """Every row bead a cluster bead's '## Rows' section lists, shorthand included: a line '- <full id> text; .N text'
    lists <full id> and, after a ';' or at the start of a continuation line, the sibling '<parent of full id>.N'.
    A '.N' inside parentheses or after a colon is a cross-reference, not a listed row. Display evidence only: the lane
    'driving' rule keeps using cluster_rows() (full ids)."""
    m = CLUSTER_ROWS_RE.search(desc or "") if "## Rows" in (desc or "") else None
    if not m:
        return []
    out, base = [], None
    for line in m.group(1).splitlines():
        full = CLUSTER_ROW_ID_RE.match(line)
        if full:
            out.append(full.group(1))
            base = full.group(1).rsplit(".", 1)[0] if "." in full.group(1) else None
        if base:
            out += [f"{base}.{n}" for n in CLUSTER_SHORT_RE.findall(line)]
    return list(dict.fromkeys(out))


def bead_chain(bid, index):
    """bid, then its ancestors: the parent field and every dotted prefix (tsp-x.1.2 is under tsp-x.1), nearest first.
    Cycle-safe; a bead missing from the index still yields its dotted prefixes."""
    out, seen, todo = [], set(), [bid]
    while todo:
        b = todo.pop(0)
        if not b or b in seen:
            continue
        seen.add(b)
        out.append(b)
        todo.append((index.get(b) or {}).get("parent"))
        if "." in b:
            todo.append(b.rsplit(".", 1)[0])
    return out


TARGET_CUE_RE = re.compile(r"\b(?:hardware[ \t]+)?rows?\b|\bevidence[ \t]+(?:to|on)\b", re.I)
TARGET_REACH = 120      # chars after a cue within which a bead id is read as the thing the cue points at


def declared_targets(text):
    """Bead ids a bead's own text declares as its target rows: an id that follows 'row(s)', 'hardware rows' or
    'evidence to/on' within TARGET_REACH chars, on the same line and in the same sentence ('parent X, row Y' declares
    Y, not X). An id with no such cue is a reference (a roll-up bead lists the rows it covers), not a target."""
    out = []
    for para in re.split(r"\n[ \t]*\n", text or ""):
        for cue in TARGET_CUE_RE.finditer(para):
            seg = para[cue.end():cue.end() + TARGET_REACH].split("\n", 1)[0]
            seg = re.split(r"\.(?=\s|$)", seg, 1)[0]
            out += BEAD_RE.findall(seg)
    return list(dict.fromkeys(out))


def collect_beads():
    """Return (index, ready_ids). index: id -> slim bead record for every bead."""
    index, ready = {}, []
    rc, out, errtxt = run_cmd(["bd", "list", "--all", "--json", "--flat", "-n", "0"], BD_TIMEOUT_S, cwd=MC)
    if rc != 0 or not out.strip():
        err("bd list --all", f"rc={rc} {errtxt.strip()[:300]}")
        raise SourceReadError(f"bd list --all: rc={rc} {errtxt.strip()[:300]}")
    try:
        rows = json.loads(out)
    except Exception as ex:
        err("bd list --all (json)", ex)
        raise SourceReadError(f"bd list --all json: {ex}") from ex
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
            "rows": cluster_rows(r.get("description")),
            # 2026-11-05: row evidence from kit windows. targets = the bead ids the title/description declares as its
            # target rows (declared_targets); cluster_ids = the row beads a gpu-16 cluster bead lists under '## Rows'
            "targets": [t for t in declared_targets((r.get("title") or "") + "\n"
                                                    + (r.get("description") or "")[:HW_MENTION_TEXT_MAX]) if t != r["id"]],
            "cluster_ids": cluster_row_mentions(r.get("description")),
        }
    rc, out, errtxt = run_cmd(["bd", "ready", "--json", "-n", "0"], BD_TIMEOUT_S, cwd=MC)
    if rc != 0 or not out.strip():
        err("bd ready", f"rc={rc} {errtxt.strip()[:300]}")
        raise SourceReadError(f"bd ready: rc={rc} {errtxt.strip()[:300]}")
    else:
        try:
            ready = [r["id"] for r in json.loads(out)]
        except Exception as ex:
            err("bd ready (json)", ex)
            raise SourceReadError(f"bd ready json: {ex}") from ex
    return index, ready


def fetch_comments(bid):
    rc, out, errtxt = run_cmd(["bd", "comments", bid, "--json"], COMMENTS_TIMEOUT_S, cwd=MC)
    if rc != 0:
        return bid, None, f"rc={rc} {errtxt.strip()[:200]}"
    try:
        rows = json.loads(out) if out.strip() else []
        rows.sort(key=lambda c: c.get("created_at") or "")
        recent = []
        for comment in rows[-RULING_COMMENTS_MAX:]:
            body = comment.get("text") or comment.get("body") or comment.get("comment") or ""
            recent.append({"created_at": comment.get("created_at"), "body": str(body)[:RULING_COMMENT_BYTES]})
        last = max((c.get("created_at") or "" for c in rows), default=None)
        return bid, {"count": len(rows), "last": last or None, "comments": recent}, None
    except Exception as ex:
        return bid, None, str(ex)


# -------------------------------------------------------------------- lanes --
# 2026-11-02 (tsp-mc9m.60.29.84.14): the fleet is gpu-16's managed lanes, not gpu-14's drive logs (retired). Sources,
# all read-only (watch-runs.py helpers are imported, never its loop; no run.send/release/recover/ack):
#   <G16>/runs/active.tsv            NAME<TAB>run_id[<TAB>home]; '#' rows are released (counted, not shown)
#   <G16>/homes.json                 pf-task homes (watch-runs.py active_runs()/pft() through g16_homes.py)
#   pf-task run.status               one primary-key call per lane on that lane's home
#   <G16>/runs/receipts-<NAME>.jsonl the watcher's preserved receipts: the newest G16_<CLUSTER>_STATUS line of the run
KV_RE = re.compile(r"(\w+)=(\S+)")
PR_RE = re.compile(r"^([\w.-]+/[\w.-]+)#(\d+)$")
BEAD_RE = re.compile(r"(tsp-[a-z0-9]+(?:\.[0-9]+)*)")
G16 = os.environ.get("FB_GPU16_DIR") or "/home/matt/recovery/gpu16"
G16_RUNS = os.path.join(G16, "runs")
G16_STATUS_RE = re.compile(r"G16_([A-Z0-9]+)_STATUS:[ \t]*([A-Z_]+)\b[ \t]*([^\n]*)")
# pf-task keeps a recovered usage-limit blocker's text and projects state=blocked after the run completed turns again
# (tsp-mc9m.60.29.84.11). Such a run is idle or working by its latest receipt, not blocked.
G16_QUOTA_BLOCKER_RE = re.compile(r"^(?:usage_limit_exceeded|provider_retry_budget_exhausted):")
G16_BAD_STATES = {"blocked", "failed", "interruption_unknown", "permission_blocked"}
G16_RECEIPTS_MAX_BYTES = 8 << 20  # receipts-<NAME>.jsonl read per lane per refresh
_G16W = None


def g16_watch():
    """watch-runs.py loaded as a module for its read-only helpers (active_runs, pft, text, BENCH_REQUEST_FILE_RE)."""
    global _G16W
    if _G16W is None:
        import importlib.util
        os.environ.setdefault("G16_RUNS_DIR", G16_RUNS)
        spec = importlib.util.spec_from_file_location("g16_watch_runs", os.path.join(G16, "watch-runs.py"))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _G16W = mod
    return _G16W


def g16_released_rows():
    """'#' rows of active.tsv -> [{lane, run}] (e.g. '#RELEASED BDLOCK<TAB>pft-...')."""
    out = []
    try:
        with open(os.path.join(G16_RUNS, "active.tsv")) as f:
            for line in f:
                if line.startswith("#") and "\t" in line:
                    c = line.rstrip("\n").split("\t")
                    words = c[0].lstrip("#").split()
                    out.append({"lane": words[-1] if words else c[0], "run": c[1]})
    except OSError as ex:
        err("active.tsv", ex)
    return out


def g16_status_line(final):
    """The last G16_<CLUSTER>_STATUS line of a receipt's final text -> {cluster, verdict, detail, raw, kv} | None."""
    ms = list(G16_STATUS_RE.finditer(final or ""))
    if not ms:
        return None
    m = ms[-1]
    detail = m.group(3).strip()
    kv = dict(KV_RE.findall(detail))
    return {"cluster": m.group(1), "verdict": m.group(2), "state": m.group(2), "detail": detail[:400],
            "raw": m.group(0).strip()[:400], "kv": kv, "reason": kv.get("reason")}


def g16_receipts(name, run_id=None, limit=None):
    """receipts-<NAME>.jsonl newest first -> [(receipt, status_line|None)] for run_id (None: any run), plus the
    file's mtime and the receipt on its last line. limit bounds the receipts parsed."""
    path = os.path.join(G16_RUNS, f"receipts-{name}.jsonl")
    try:
        size = os.path.getsize(path)
        mtime = os.path.getmtime(path)
        with open(path, errors="replace") as f:
            if size > G16_RECEIPTS_MAX_BYTES:
                f.seek(size - G16_RECEIPTS_MAX_BYTES)
                f.readline()  # drop the partial first line
            lines = f.read().splitlines()
    except FileNotFoundError:
        return [], None, None
    out, last = [], None
    w = g16_watch()
    for raw in reversed(lines):
        try:
            res = json.loads(raw)
        except ValueError:
            continue
        ev = res.get("evidence") or {}
        rid = res.get("receipt") or ev.get("receipt")
        if last is None:
            last = rid
        if run_id and ev.get("run_id") != run_id:
            continue
        out.append((rid, g16_status_line(w.text(res.get("final_text")))))
        if limit and len(out) >= limit:
            break
    return out, mtime, last


def g16_quota_episode(nr):
    """Newest epoch of the run's native_recovery.retryable episode (first/observed/last/recovered_at), 0 if none."""
    rt = (nr or {}).get("retryable") or {}
    return max((rt[k] for k in ("first_at", "observed_at", "last_at", "recovered_at")
                if isinstance(rt.get(k), (int, float))), default=0)


def g16_stale_quota(rs, blocker, nr, last_turn):
    """True when a `blocked` run's blocker is the kept usage-limit text of a quota episode that the run has since
    completed a turn after (.84.11). Unknown episode or turn time -> False (stays blocked)."""
    rx = getattr(g16_watch(), "QUOTA_BLOCKER_RE", None) or G16_QUOTA_BLOCKER_RE   # the watcher's own quota-text rule
    if rs != "blocked" or not rx.match(blocker or ""):
        return False
    episode = g16_quota_episode(nr)
    ended = last_turn.get("ended_at") if isinstance(last_turn.get("ended_at"), (int, float)) else 0
    return bool(episode and ended and ended > episode and last_turn.get("receipt"))


def collect_g16_lanes(index=None):
    """One row per active.tsv lane: run.status, the newest G16 status line and the board state."""
    w = g16_watch()
    lanes = []
    try:
        rows = w.active_runs()
    except Exception as ex:
        err("active.tsv", ex)
        return lanes
    for name, rid, home in rows:
        ln = {"lane": name, "run": rid, "home": home, "token": None, "statuses": [], "ci_waits": [], "pr": None,
              "source": "active.tsv", "driver_alive": False, "run_checked_at": iso(NOW), "run_fresh": True}
        try:
            st = w.pft("run.status", {"run_id": rid}, home)
        except Exception as ex:
            st = {"error": f"{type(ex).__name__}: {str(ex)[:160]}"}
        if not isinstance(st, dict) or "state" not in st:
            ln["run_error"] = (st or {}).get("error") or f"refused: {json.dumps(st)[:160]}"
            err(f"run.status {name}", ln["run_error"])
            st = {}
        prov = st.get("provenance") or {}
        lt = st.get("last_turn") or {}
        blk = st.get("blocker") or {}
        msgs, rcpt = st.get("messages") or {}, st.get("receipts") or {}
        rs = st.get("state")
        blocker = w.text(blk.get("blocker")) or w.text(blk.get("error"))
        nr = st.get("native_recovery") or blk.get("native_recovery")
        ln.update({
            "run_state": rs, "bead": st.get("task"), "session_id": st.get("session_id"),
            "model": w.text((prov.get("model") or {}).get("modelID")) or None,
            "provider": w.text((prov.get("model") or {}).get("providerID")) or None,
            "runtime": prov.get("runtime"), "worktree": w.text(st.get("worktree")) or None,
            "controller_alive": st.get("controller_alive"), "runtime_alive": st.get("runtime_alive"),
            "reconciler_alive": st.get("reconciler_alive"),
            "native_activity_age_s": st.get("native_activity_age_seconds"),
            "last_turn_end": iso(lt.get("ended_at")) if isinstance(lt.get("ended_at"), (int, float)) else None,
            "last_turn_reason": lt.get("reason"), "blocker_error": (blocker or "")[:300] or None,
            "messages_pending": msgs.get("pending"), "messages_total": msgs.get("total"),
            "receipts_total": rcpt.get("total"), "receipts_unacked": rcpt.get("unacknowledged"),
        })
        ln["driver_alive"] = bool(st.get("controller_alive") and st.get("reconciler_alive"))
        ln["bead_title"] = (index.get(ln["bead"]) or {}).get("title") if ln["bead"] and index else None
        # the newest receipt of this run that carries a status line; its time is the turn end when it is the turn's
        # receipt, else the receipts file mtime when it is the file's last line (the watcher appends within a minute)
        found, mtime, last_in_file = g16_receipts(name, rid, limit=40)
        ls = None
        for rec, line in found:
            if line:
                ls = dict(line, receipt=rec, ts=None, age_src=None)
                if rec == lt.get("receipt") and ln["last_turn_end"]:
                    ls["ts"], ls["age_src"] = ln["last_turn_end"], "turn end"
                elif rec == last_in_file and mtime:
                    ls["ts"], ls["age_src"] = iso(mtime), "receipt log"
                ls["newest"] = rec == (found[0][0] if found else None)
                break
        ln["last_status"] = ls
        ln["statuses"] = [ls] if ls else []
        ln["token"] = f"G16_{ls['cluster']}_STATUS" if ls else None
        ln["status_age_s"] = age_s(parse_ts(ls["ts"])) if ls and ls.get("ts") else None
        verdict = (ls or {}).get("verdict")
        ln["stale_quota"] = g16_stale_quota(rs, blocker, nr, lt)
        if ln.get("run_error"):
            live, cls, why = "unknown", "unknown", ln["run_error"]
        elif rs in ("busy", "pending"):
            na = ln["native_activity_age_s"]
            live, cls = "working", "running"
            why = "turn in progress" + (f", native activity {fmt_age(na)} ago" if na is not None else "")
        elif rs == "awaiting_release" or ln["stale_quota"]:
            live = "working" if verdict == "WORKING" else "idle"
            cls = "running" if live == "working" else "waiting"
            if verdict == "HANDBACK" and (ln["receipts_unacked"] or 0) > 0:
                cls = "needs"
            why = (f"turn ended {fmt_age(age_s(parse_ts(ln['last_turn_end'])))} ago" if ln["last_turn_end"] else "turn ended")
            if verdict is None:
                why += "; no G16 status line"
            elif verdict == "HANDBACK":
                why += "; HANDBACK " + ("not yet acknowledged by gpu-16" if cls == "needs" else "acknowledged by gpu-16")
            elif verdict == "WORKING":
                why += "; status WORKING (its children or a pending result own the next step)"
            else:
                why += f"; status {verdict}"
            if ln["stale_quota"]:
                why = (f"pf-task says blocked on kept quota text (.84.11); the run completed a turn at "
                       f"{short_iso(ln['last_turn_end'])} after the quota episode "
                       f"({short_iso(iso(g16_quota_episode(nr)))}): {why}")
        elif rs == "released":
            live, cls, why = "released", "released", "run released"
        elif rs in G16_BAD_STATES:
            live, cls = rs, "needs"
            why = f"pf-task {rs}" + (f": {blocker[:200]}" if blocker else "")
        else:
            live, cls, why = rs or "unknown", "unknown", f"pf-task state {rs}"
        ln.update({"state": live, "cls": cls, "cls_reason": why[:400], "kind": None, "next": ""})
        lanes.append(ln)
    return lanes


def short_iso(ts):
    """2026-11-02T19:28:21Z -> 11-02 19:28Z"""
    return (ts[5:16].replace("T", " ") + "Z") if ts else "?"


# ------------------------------------------------------------------- device --
# 2026-11-02 (tsp-mc9m.60.29.84.14): the bench is the BENCH lane plus pf-kit-window-runner. The window queue
# (window-queue.sh) and the kits queue (queue-runner.sh) are retired and no longer read. Sources (read-only):
#   BENCH's newest G16_BENCH_STATUS line (any BENCH run), and the newest runner=/dut=/place= values on one
#   systemctl --user show pf-kit-window-runner.service (ActiveState, MainPID, deployed clone from ExecStart)
#   <KIT_WINDOWS>/boot-open-<gen>.json of the last BENCH_QUEUE_WINDOW_H hours + <gen>/{runner,active,terminal}.json
#   <G16>/runs/relay-sent.json       {"<TARGET> <sha256>": {from, file, at}}: each lane's newest request to BENCH and
#                                    whether BENCH relayed anything back to that lane after it (watch-runs.py rule)
#   typed results, last 24 h: the kit windows' close records (collect_windows rows, read again for terminal.json) and the
#   BENCH-RESULT*.json / *BENCH-RESULT*.txt / DEPLOY-RECEIPT*.txt files under TYPED_RESULTS_ROOT (find -maxdepth)
KIT_WINDOWS = os.environ.get("PF_KIT_WINDOWS_DIR") or os.path.expanduser("~/.local/state/pocketforge/kit-windows")
RUNNER_UNIT = "pf-kit-window-runner.service"
BENCH_QUEUE_WINDOW_H = 24       # requests relayed to BENCH within this window form the BENCH queue
WINDOWS_SHOW = 6                # recent kit windows listed
BENCH_KV_KEYS = ("runner", "dut", "place")
BENCH_KV_RECEIPTS = 60          # BENCH receipts searched for the newest runner=/dut=/place= values
TYPED_RESULTS_ROOT = os.environ.get("FB_TYPED_RESULTS_ROOT") or "/home/matt/recovery"
TYPED_RESULTS_DEPTH = 4
TYPED_RESULTS_WINDOW_H = 24
TYPED_RESULTS_SHOW = 40
TYPED_RESULT_MAX_BYTES = 4 << 20
TYPED_REQUEST_SLACK_H = 8       # a window closes at most MaxTotalSeconds (7 h) after its request: read requests this much older
TYPED_STEP_STDOUT_MAX = 1 << 20  # bytes read of each step's payload stdout (the watcher reads 4 MiB; a result line is near the end)
TYPED_GOOD = {"PASS", "OK", "SUCCESS", "CLEAN", "DONE"}
TYPED_WARN = {"REFUSED", "SKIPPED", "WAITING", "PARTIAL"}   # refused before mutation / stopped on a ruling; any other non-pass state is crit
TYPED_MUTED = {"UNCLASSIFIED"}                              # a note with no Outcome the parser could place
GEN_RE = re.compile(r"[0-9a-f]{32}")
# watch-runs.py's WINDOW_RESULT event rules (tsp-hqm1p.179), re-stated here: the watcher is a daemon module, not a library
KIT_NORMAL_REASONS = frozenset({"lane_done", "success"})   # terminal.json Reason values that are not themselves a failure
KIT_STEP_ID_RE = re.compile(r"^(.+)-[0-9a-f]{12}$")        # a step's RequestID is <step>-<12 hex>; boot-open's is the bare generation
KIT_PAYLOAD_FAIL_RE = re.compile(r"^(PF_[A-Za-z0-9_]+)\b[^\n]*?\bresult=(?i:FAIL(?:ED|URE)?|ERROR|REFUSED)\b[^\n]*", re.M)
KIT_PAYLOAD_REASON_RE = re.compile(r"\breason=([A-Za-z0-9_.:-]+)")
KIT_FAILS_MAX = 3               # failing steps named in typed_cause before "+Nmore"
# lane-written *BENCH-RESULT*.txt: the first `Outcome:` line, classified on its first clause (prose, so a heuristic)
NOTE_OUTCOME_RE = re.compile(r"^\s*outcome\s*[:=]\s*(.*\S)", re.I | re.M)
NOTE_CLAUSE_SPLIT_RE = re.compile(r"(?<=[A-Za-z0-9)])[.;](?:\s|$)")
NOTE_STATES = (("FAIL", re.compile(r"\bNOT A PASS\b|\bFAIL(?:ED|URE|S)?\b", re.I)), ("REFUSED", re.compile(r"\bREFUS(?:ED|AL)\b", re.I)),
               ("PARTIAL", re.compile(r"\bPARTIAL\b", re.I)), ("PASS", re.compile(r"\bPASS(?:ED|ING)?\b", re.I)),
               ("CLEAN", re.compile(r"\b(?:CLEAN|COMPLETED?)\b", re.I)))
NOTE_REASON_RE = re.compile(r"\breason=([A-Za-z0-9_.:-]+)|\breason ([A-Za-z0-9]+(?:_[A-Za-z0-9]+)+)\b", re.I)
NOTE_CAUSE_RE = re.compile(r"\bfailure_reason=([A-Za-z0-9_.:-]+)", re.I)


def lane_base(name):
    return re.sub(r"\d+$", "", name or "")


def jread(path):
    try:
        with open(path) as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def typed_sev(state):
    s = (state or "").upper()
    return "good" if s in TYPED_GOOD else ("warn" if s in TYPED_WARN else ("muted" if not s or s in TYPED_MUTED else "crit"))


def typed_kind(base):
    return ("bench-result" if base.endswith(".json") else "deploy-receipt" if base.startswith("DEPLOY-RECEIPT")
            else "deploy-result" if "deploy" in base.lower() else "bench-result-txt")


def typed_result_name(base):
    """A file name the typed-results scan reads: BENCH-RESULT*.json (v1), DEPLOY-RECEIPT*.txt, or a lane's *BENCH-RESULT*.txt."""
    return ((base.startswith("BENCH-RESULT") and base.endswith(".json")) or (base.startswith("DEPLOY-RECEIPT") and base.endswith(".txt"))
            or ("BENCH-RESULT" in base and base.endswith(".txt")))


def note_outcome(text):
    """(state, reason, typed_cause) of a lane-written BENCH-RESULT note's `Outcome:` line, or None without one. The state is the first
    of FAIL / REFUSED / PARTIAL / PASS / CLEAN that the line's first clause names ("RUNNER-LEVEL CLEAN, PAYLOAD FAIL" is FAIL),
    UNCLASSIFIED when it names none; reason = the first reason=<token> (or `reason <snake_case>`), typed_cause = failure_reason=<token>."""
    m = NOTE_OUTCOME_RE.search(text)
    if not m:
        return None
    line = m.group(1)
    clause = NOTE_CLAUSE_SPLIT_RE.split(line, 1)[0]
    state = next((st for st, pat in NOTE_STATES if pat.search(clause)), "UNCLASSIFIED")
    r, c = NOTE_REASON_RE.search(line), NOTE_CAUSE_RE.search(line)
    return state, (r.group(1) or r.group(2)) if r else None, c.group(1) if c else None


def read_typed(path, mtime):
    """BENCH-RESULT*.json, *BENCH-RESULT*.txt or DEPLOY-RECEIPT*.txt -> {kind, state, reason, typed_cause, at, lane_hint, boundary}."""
    base = os.path.basename(path)
    out = {"path": path, "file": base, "mtime": iso(mtime), "at": iso(mtime), "state": None, "reason": None,
           "typed_cause": None, "lane_hint": None, "boundary": None}
    try:
        if os.path.getsize(path) > TYPED_RESULT_MAX_BYTES:
            out.update(kind=typed_kind(base), state="UNREAD", reason="file larger than TYPED_RESULT_MAX_BYTES")
            return out
        if base.endswith(".json"):
            out["kind"] = "bench-result"
            d = jread(path)
            if d is None:
                out.update(state="UNPARSED", reason="not a JSON object")
                return out
            # three schemas are live: State/Reason/TypedCause, lowercase state/reason, and pocketforge.bench-result/v1
            # (Outcome/Reason, the typed failure in Failure.Error)
            ci = {k.lower(): v for k, v in d.items()}
            fail = ci.get("failure") if isinstance(ci.get("failure"), dict) else {}
            out["state"] = str(ci.get("state") or ci.get("outcome") or "") or None
            out["reason"] = str(ci.get("reason") or "") or None
            out["typed_cause"] = str(ci.get("typedcause") or ci.get("typed_cause") or fail.get("Error") or "") or None
            at = ci.get("observedatutc") or ci.get("observed_at")
            if isinstance(at, str) and parse_ts(at):
                out["at"] = at
            out["lane_hint"] = ci.get("lane") or ci.get("discriminator")
            b = ci.get("boundary") if isinstance(ci.get("boundary"), dict) else None
            c = ci.get("close") if isinstance(ci.get("close"), dict) else None
            if b:
                out["boundary"] = {"dut": b.get("DUT"), "place": b.get("LabgridPlace")}
            elif c:
                out["boundary"] = {"dut": c.get("power_state"), "place": c.get("place")}
        elif not base.startswith("DEPLOY-RECEIPT"):
            # 2026-11-08 (tsp-hqm1p.181): the lanes' BENCH-RESULT notes are prose with an `Outcome:` line, not a schema
            out["kind"] = typed_kind(base)
            with open(path, errors="replace") as f:
                got = note_outcome(f.read(16384))
            if got is None:
                out.update(state="UNCLASSIFIED", reason="no Outcome line")
            else:
                out["state"], out["reason"], out["typed_cause"] = got
        else:
            out["kind"] = "deploy-receipt"
            with open(path, errors="replace") as f:
                lines = [next(f, "") for _ in range(60)]
            m = re.match(r"\s*DEPLOY_RECEIPT\b(.*)$", lines[0] if lines else "")
            if not m:
                out.update(state="UNPARSED", reason="first line is not DEPLOY_RECEIPT")
                return out
            kv = dict(KV_RE.findall(m.group(1)))
            for l in lines[1:]:   # key=value lines below the first; the first line wins
                mm = re.match(r"\s*(reason|typed_cause|typedcause)=(\S+)", l, re.I)
                if mm:
                    kv.setdefault(mm.group(1).lower(), mm.group(2))
            out["state"] = kv.get("state")
            out["reason"] = kv.get("reason")
            out["typed_cause"] = kv.get("typed_cause") or kv.get("typedcause")
    except Exception as ex:
        out.update(kind=out.get("kind") or "?", state="UNREAD", reason=f"{type(ex).__name__}: {str(ex)[:120]}")
    return out


def kit_step_stdout(gen, seq):
    """Text of GEN's step SEQ payload stdout (revision-input-<seq:06d>/*.stdout, staged candidate-* copies left out), "" when it has none."""
    d = os.path.join(KIT_WINDOWS, gen, f"revision-input-{seq:06d}")
    try:
        names = sorted(n for n in os.listdir(d) if n.endswith(".stdout") and not n.startswith("candidate-"))
    except OSError:
        return ""
    out = []
    for n in names:
        try:
            with open(os.path.join(d, n), "rb") as fh:
                out.append(fh.read(TYPED_STEP_STDOUT_MAX).decode("utf-8", "replace"))
        except OSError:
            continue
    return "\n".join(out)


def kit_attempt_error(gen, seq):
    """The Error of GEN's step SEQ receipt envelope (receipts/receipt-<seq:06d>-*.json), "" when it has none."""
    pat = os.path.join(glob.escape(os.path.join(KIT_WINDOWS, gen, "receipts")), f"receipt-{seq:06d}-*.json")
    for p in sorted(glob.glob(pat)):
        d = jread(p)
        if d and d.get("Error"):
            return str(d["Error"])
    return ""


def kit_window_fails(gen, doc):
    """[(step, reason)] of GEN's failed steps from its terminal.json DOC: the rules of the watcher's WINDOW_RESULT event (tsp-hqm1p.179,
    watch-runs.py window_fails). Per Attempt: the `PF_<TAG> ... result=FAIL [reason=<token>]` lines of the step's payload stdout (the
    runner receipt says pass when the helper exited 0; the payload is the truth), else the receipt's Error, else its Outcome. StepRows
    with outcome fail. A Reason that is neither normal nor the generic `failure` over named steps is a failing `window` step
    (for `failure` itself, failure.json's Reason when the runner wrote one)."""
    fails = []

    def add(step, reason):
        item = (re.sub(r"[\s,]+", "_", str(step or "-").strip())[:60] or "-", re.sub(r"[\s,]+", "_", str(reason or "fail").strip())[:80] or "fail")
        if item not in fails:
            fails.append(item)

    attempts = sorted((a for a in doc.get("Attempts") or [] if isinstance(a, dict) and isinstance(a.get("Sequence"), int)), key=lambda a: a["Sequence"])
    for a in attempts:
        rid, seq = str(a.get("RequestID") or ""), a["Sequence"]
        m = KIT_STEP_ID_RE.match(rid)
        step = m.group(1) if m else ("boot-open" if GEN_RE.fullmatch(rid) else rid or f"step-{seq}")
        pays = []
        for pm in KIT_PAYLOAD_FAIL_RE.finditer(kit_step_stdout(gen, seq)):
            r = KIT_PAYLOAD_REASON_RE.search(pm.group(0))
            item = (pm.group(1), r.group(1) if r else "")
            if item not in pays:
                pays.append(item)
        for tag, reason in pays:
            add(step, reason or tag)
        outcome = str(a.get("Outcome") or "").lower()
        if outcome != "pass" and not pays:
            add(step, kit_attempt_error(gen, seq) or outcome or "fail")
    for row in doc.get("StepRows") or []:
        if isinstance(row, dict) and str(row.get("outcome") or "").lower() == "fail":
            step = re.sub(r"[\s,]+", "_", str(row.get("step") or "-").strip())[:60]
            if not any(f[0] == step for f in fails):
                add(row.get("step"), "fail")
    reason = str(doc.get("Reason") or "")
    if reason and reason not in KIT_NORMAL_REASONS and not (reason == "failure" and fails):
        # the generic close reason `failure` with no failing step: the runner's own failure.json names why (R51: post_open_ops_pending)
        named = (jread(os.path.join(KIT_WINDOWS, gen, "failure.json")) or {}).get("Reason") if reason == "failure" else None
        add("window", named or reason)
    return fails


def kit_window_result(row, floor_ts):
    """A collect_windows ROW -> its typed-result item, or None while the window is open/activating or closed before FLOOR_TS (epoch).
    The close record by precedence (the order collect_windows reads them): a failed boot-open (BOOT_OPEN_FAILED); the runner's
    terminal.json (its End, CLEAN / DIRTY; FAILED / FAILED_DIRTY when a step failed: the watcher's outcome rule); a failed runner with
    no terminal.json (RUNNER_FAILED, failure.json's Reason); a revoked window; a closed session whose runner never finalized
    (UNFINALIZED)."""
    gen, st = row["gen"], row.get("state") or ""
    if row.get("open"):
        return None
    gd = os.path.join(KIT_WINDOWS, gen)
    out = {"kind": "kit-window", "gen": gen, "file": None, "path": None, "mtime": None, "at": None, "state": None, "reason": None,
           "typed_cause": None, "lane_reason": None, "purpose": row.get("purpose"), "lane_hint": row.get("lane"), "boundary": None}
    term_p = os.path.join(gd, "terminal.json")
    term = None if st == "boot-open failed" else jread(term_p)

    def source(path, at=None):
        base = os.path.basename(path)
        out["path"] = path
        out["file"] = base.replace(gen, gen[:8]) if gen in base else f"{gen[:8]}/{base}"
        try:
            mt = os.path.getmtime(path)
        except OSError:
            mt = None
        out["mtime"] = iso(mt)
        out["at"] = at if parse_ts(at) else (iso(mt) if mt is not None else row.get("last_activity") or row.get("requested_at"))

    if st == "boot-open failed":
        p = os.path.join(KIT_WINDOWS, f"boot-open-{gen}.failed.json")
        d = jread(p) or {}
        source(p, d.get("At"))
        out["state"], out["reason"] = "BOOT_OPEN_FAILED", str(d.get("Reason") or "boot_open_failed")
    elif term is not None:
        pac = term.get("PowerAtClose")
        source(term_p, pac.get("ClosedAt") if isinstance(pac, dict) else None)
        fails = kit_window_fails(gen, term)
        end = re.sub(r"\W+", "_", str(term.get("End") or "-")).strip("_").upper() or "-"
        out["state"] = ("FAILED_DIRTY" if end == "DIRTY" else "FAILED") if fails else (end if end != "-" else "UNKNOWN")
        out["reason"] = str(term.get("Reason") or "") or None
        out["lane_reason"] = str(term.get("LaneReason") or "") or None
        out["purpose"] = term.get("KitPurpose") or out["purpose"]
        shown = [f"{a}:{b}" for a, b in fails[:KIT_FAILS_MAX]]
        if len(fails) > KIT_FAILS_MAX:
            shown.append(f"+{len(fails) - KIT_FAILS_MAX}more")
        out["typed_cause"] = ",".join(shown) or None
    elif st == "failed":
        p = os.path.join(gd, "failure.json")
        d = jread(p)
        source(p if d is not None else os.path.join(gd, "runner.json"), (d or {}).get("At"))
        out["state"], out["reason"] = "RUNNER_FAILED", str((d or {}).get("Reason") or "runner_failed")
    elif st == "revoked":
        p = os.path.join(gd, "revoked.json")
        d = jread(p) or {}
        source(p, d.get("At"))
        out["state"], out["reason"] = "REVOKED", str(d.get("Reason") or "revoked")
    elif st == "session closed, runner not finalized":
        source(os.path.join(gd, "runner.json"), row.get("last_activity"))
        out["state"], out["reason"] = "UNFINALIZED", "runner_not_finalized"
    else:
        return None
    at = parse_ts(out["at"])
    return out if at is not None and at.timestamp() >= floor_ts else None


def kit_windows_closed(floor_ts):
    """Window dirs under KIT_WINDOWS whose terminal.json was modified since FLOOR_TS (epoch). A bare stat() scan on purpose: no JSON and
    nothing of kit_window_result, so a change to a close record's contents cannot blank this count the way it blanks the rows."""
    n = 0
    try:
        names = os.listdir(KIT_WINDOWS)
    except OSError:
        return 0
    for name in names:
        if GEN_RE.fullmatch(name):
            try:
                if os.stat(os.path.join(KIT_WINDOWS, name, "terminal.json")).st_mtime >= floor_ts:
                    n += 1
            except OSError:
                pass
    return n


def collect_typed_results(sent):
    """Last TYPED_RESULTS_WINDOW_H h of typed results, newest first, with the lane BENCH relayed each one to.
    Two sources: the kit windows' close records (kit_window_result over collect_windows rows) and the result files under
    TYPED_RESULTS_ROOT (read_typed). 2026-11-08 (tsp-hqm1p.181): a source that yields no row while windows closed (terminal.json files
    modified in the window, counted by kit_windows_closed) is a WARN in res["warns"]. The files source went blank on 11-03 when the
    kit-window-runner pipeline replaced BENCH-RESULT*.json, and nothing said so for five days."""
    res = {"window_h": TYPED_RESULTS_WINDOW_H, "root": TYPED_RESULTS_ROOT, "depth": TYPED_RESULTS_DEPTH, "windows_root": KIT_WINDOWS,
           "items": [], "groups": [], "total": 0, "error": None, "by_kind": {}, "windows_closed": 0, "warns": []}
    floor = NOW.timestamp() - TYPED_RESULTS_WINDOW_H * 3600
    errors, items = [], []
    try:
        for row in collect_windows(lookback_h=TYPED_RESULTS_WINDOW_H + TYPED_REQUEST_SLACK_H):
            try:
                it = kit_window_result(row, floor)
            except Exception as ex:   # a window whose record cannot be read is a visible row, not a missing one
                it = {"kind": "kit-window", "gen": row.get("gen"), "file": (row.get("gen") or "")[:8], "path": None, "mtime": None,
                      "at": row.get("requested_at"), "state": "UNREAD", "reason": f"{type(ex).__name__}: {str(ex)[:120]}",
                      "typed_cause": None, "lane_reason": None, "purpose": row.get("purpose"), "lane_hint": row.get("lane"), "boundary": None}
            if it:
                items.append(it)
    except Exception as ex:
        errors.append(f"kit windows: {type(ex).__name__}: {str(ex)[:160]}")
    # -H: /home/matt/recovery is a symlink to the programming tree; follow the starting point only
    rc, out, e = run_cmd(["find", "-H", TYPED_RESULTS_ROOT, "-maxdepth", str(TYPED_RESULTS_DEPTH),
                          "(", "-name", "BENCH-RESULT*.json", "-o", "-name", "DEPLOY-RECEIPT*.txt", "-o", "-name", "*BENCH-RESULT*.txt", ")",
                          "-type", "f", "-mmin", f"-{TYPED_RESULTS_WINDOW_H * 60}", "-printf", "%T@\t%p\n"], 60)
    if rc != 0 and not out.strip():
        errors.append(f"find rc={rc}: {e.strip()[:200]}")
        out = ""
    relayed_to = {}
    for pair, v in (sent or {}).items():
        if isinstance(v, dict) and lane_base(str(v.get("from") or "")) == "BENCH" and v.get("file"):
            relayed_to.setdefault(os.path.realpath(str(v["file"])), pair.split(" ", 1)[0])
    for line in out.splitlines():
        t, _, path = line.partition("\t")
        try:
            mtime = float(t)
        except ValueError:
            continue
        it = read_typed(path, mtime)
        it["lane"] = relayed_to.get(os.path.realpath(path))
        items.append(it)
    for it in items:
        it.setdefault("lane", None)
    if errors:
        res["error"] = "; ".join(errors)
        err("typed results", res["error"])
    items.sort(key=lambda x: x.get("at") or "", reverse=True)
    groups = {}
    for it in items:
        k = (it["kind"], it["state"] or "-", it["reason"] or "-", it["typed_cause"] or "-")
        g = groups.setdefault(k, {"kind": k[0], "state": k[1], "reason": k[2], "typed_cause": k[3], "count": 0,
                                  "latest_at": None, "lanes": [], "sev": typed_sev(it["state"])})
        g["count"] += 1
        g["latest_at"] = max(g["latest_at"] or "", it.get("at") or "") or None
        lane = it["lane"] or it.get("lane_hint")
        if lane and lane not in g["lanes"]:
            g["lanes"].append(lane)
        res["by_kind"][it["kind"]] = res["by_kind"].get(it["kind"], 0) + 1
    res["groups"] = sorted(groups.values(), key=lambda g: (g["count"], g["latest_at"] or ""), reverse=True)
    res["total"] = len(items)
    res["items"] = items[:TYPED_RESULTS_SHOW]
    res["windows_closed"] = closed = kit_windows_closed(floor)
    if closed:
        n_win = res["by_kind"].get("kit-window", 0)
        for source, n_rows, what in (("kit-window", n_win, f"the kit-window close records under {KIT_WINDOWS}"),
                                     ("files", res["total"] - n_win, f"the BENCH-RESULT / DEPLOY-RECEIPT files under {TYPED_RESULTS_ROOT}")):
            if n_rows == 0:
                res["warns"].append({"source": source, "windows_closed": closed,
                                     "text": f"{what} yielded 0 rows, so the format they are read in may have changed"})
    return res


def collect_runner():
    out = {"unit": RUNNER_UNIT, "active": None, "sub": None, "pid": None, "since": None, "deployed": None, "error": None}
    rc, txt, e = run_cmd(["systemctl", "--user", "show", "-p", "ActiveState", "-p", "SubState", "-p", "MainPID",
                          "-p", "ActiveEnterTimestamp", "-p", "ExecStart", RUNNER_UNIT], 20)
    if rc != 0:
        out["error"] = f"systemctl rc={rc}: {e.strip()[:160]}"
        err("runner unit", out["error"])
        return out
    for line in txt.splitlines():
        k, _, v = line.partition("=")
        if k == "ActiveState":
            out["active"] = v
        elif k == "SubState":
            out["sub"] = v
        elif k == "MainPID":
            out["pid"] = int(v) if v.isdigit() and v != "0" else None
        elif k == "ActiveEnterTimestamp":
            out["since"] = v or None
        elif k == "ExecStart":
            m = re.search(r"/deploy-clones/(pa-[A-Za-z0-9-]+)/", v)
            out["deployed"] = m.group(1) if m else None
    return out


def collect_windows(lookback_h=None):
    """pf-kit-window-runner generations requested in the last LOOKBACK_H (default BENCH_QUEUE_WINDOW_H) hours, newest first."""
    rows = []
    cutoff = NOW.timestamp() - (lookback_h or BENCH_QUEUE_WINDOW_H) * 3600
    try:
        names = os.listdir(KIT_WINDOWS)
    except FileNotFoundError:
        return rows
    except OSError as ex:
        err("kit-windows", ex)
        return rows
    for name in names:
        m = re.fullmatch(r"boot-open-([0-9a-f]{32})\.json", name)
        if not m:
            continue
        try:
            mt = os.path.getmtime(os.path.join(KIT_WINDOWS, name))
        except OSError:
            continue
        if mt < cutoff:
            continue
        gen = m.group(1)
        gd = os.path.join(KIT_WINDOWS, gen)
        row = {"gen": gen, "requested_at": iso(mt), "state": "activating", "outcome": None, "open": False,
               "lane": None, "purpose": None, "opened_at": None, "deadline": None, "last_activity": None}
        failed = jread(os.path.join(KIT_WINDOWS, f"boot-open-{gen}.failed.json"))
        runner, active, term = jread(os.path.join(gd, "runner.json")), jread(os.path.join(gd, "active.json")), \
            jread(os.path.join(gd, "terminal.json"))
        if active:
            row.update(lane=active.get("Lane"), purpose=active.get("KitPurpose"), opened_at=active.get("OpenedAt"),
                       deadline=active.get("Deadline"))
        if runner:
            row["last_activity"] = runner.get("LastActivity")
        if failed:
            row.update(state="boot-open failed", outcome=f"{failed.get('Reason') or '?'} at {failed.get('At') or '?'}")
        elif term:
            row.update(state=str(term.get("State") or "closed"),
                       outcome=f"{term.get('End') or '?'} {term.get('Reason') or ''}".strip())
        elif runner:
            row["state"] = str(runner.get("State") or "unknown")
            anc = (active or {}).get("AnchorPath") or ""
            if row["state"] == "open" and anc and os.path.exists(os.path.join(os.path.dirname(anc), "terminal.json")):
                row["state"] = "session closed, runner not finalized"
        elif os.path.exists(os.path.join(gd, "revoked.json")):
            row["state"] = "revoked"
        row["open"] = row["state"] in ("open", "activating")
        rows.append(row)
    rows.sort(key=lambda r: r["requested_at"], reverse=True)
    return rows


def hw_window_bead(holder):
    """A window's Holder is '<bead>.<generation>' (the lane's bead, then the 32-hex generation) -> <bead>."""
    h = re.sub(r"\.[0-9a-f]{32}$", "", str(holder or ""))
    return h if BEAD_RE.fullmatch(h) else None


def collect_hw_windows(root=None, now=None, lookback_h=None):
    """Kit-window runner results of the last HW_WINDOWS_LOOKBACK_H hours, newest first -> (windows, scanned).
    scanned = boot-open requests read (a failed boot-open is scanned, never a result). A window is
    {gen, bead, at, result ok|fail|open, state, reason, end, purpose, lane, source, receipt, pkg}: closed = the runner's
    terminal.json (ok = State closed with Reason lane_done/success, the rule velocity.py uses; at = PowerAtClose.ClosedAt,
    else revoked.json At, else the file's mtime), open = requested within HW_WINDOW_INFLIGHT_H with no terminal yet. A
    request with no terminal older than that is stale and skipped. bead = the Holder bead from active.json, else the
    boot-open request."""
    root, now = root or KIT_WINDOWS, now or NOW
    cutoff = now.timestamp() - (lookback_h or HW_WINDOWS_LOOKBACK_H) * 3600
    out, scanned = [], 0
    try:
        names = os.listdir(root)
    except FileNotFoundError:
        return out, scanned
    except OSError as ex:
        err("kit-windows (hardware rows)", ex)
        return out, scanned
    for name in names:
        m = re.fullmatch(r"boot-open-([0-9a-f]{32})\.json", name)
        if not m:
            continue
        gen, bo = m.group(1), os.path.join(root, name)
        try:
            req = os.path.getmtime(bo)
        except OSError:
            continue
        if req < cutoff:
            continue
        scanned += 1
        if os.path.exists(os.path.join(root, f"boot-open-{gen}.failed.json")):
            continue
        gd = os.path.join(root, gen)
        active, term = jread(os.path.join(gd, "active.json")) or {}, jread(os.path.join(gd, "terminal.json"))
        holder = active.get("Holder") or (jread(bo) or {}).get("Holder")
        anchor = str(active.get("AnchorPath") or "")
        w = {"gen": gen, "bead": hw_window_bead(holder), "lane": active.get("Lane"),
             "purpose": (term or {}).get("KitPurpose") or active.get("KitPurpose"), "state": None, "reason": None,
             "end": None, "source": None, "receipt": None,
             "pkg": os.path.dirname(os.path.dirname(anchor)) if anchor.startswith("/") else None}
        if term:
            tp = os.path.join(gd, "terminal.json")
            at = (term.get("PowerAtClose") or {}).get("ClosedAt")
            if not parse_ts(at):
                at = (jread(os.path.join(gd, "revoked.json")) or {}).get("At")
            if not parse_ts(at):
                try:
                    at = iso(os.path.getmtime(tp))
                except OSError:
                    at = iso(req)
            ok = term.get("State") == "closed" and term.get("Reason") in HW_WINDOW_OK_REASONS
            w.update(at=at, result="ok" if ok else "fail", state=str(term.get("State") or ""),
                     reason=str(term.get("Reason") or ""), end=str(term.get("End") or "") or None, source=tp,
                     receipt=term.get("ReceiptPath"))
        elif now.timestamp() - req <= HW_WINDOW_INFLIGHT_H * 3600:
            w.update(at=iso(req), result="open")
        else:
            continue
        out.append(w)
    out.sort(key=lambda x: x["at"], reverse=True)
    return out, scanned


VIA_RANK = {"bead": 0, "named": 1, "comment": 2, "cluster": 3}
STRONG_VIA = ("bead", "named", "comment")      # a window that reaches a row this way counts as evidence for that row


def hw_anchor_rows(doc):
    """{anchor: frozenset of the hardware-row ids that carry it}. A priority row (tier goal) that only reuses a row's
    anchor adds nothing; an anchor only a priority carries stands for itself."""
    out = {}
    for r in doc.get("rows") or []:
        for a in r.get("anchor") or []:
            if a:
                out[a] = out.get(a, frozenset()) | {r["id"]}
    for r in doc.get("priorities") or []:
        for a in r.get("anchor") or []:
            if a and a not in out:
                out[a] = frozenset({"anchor:" + a})
    return out


def window_links(bead, index, anchors):
    """{anchor: via} for the hardware-row anchors a window's bead reaches, strongest first-class wins:
    bead    the anchor is the bead or an ancestor of it (parent chain or dotted id);
    named   the bead's own text declares the anchor, or a bead under it, as its target row (declared_targets), and it
            declares one row only: a bead that declares several rows is a roll-up and does not say which one this
            window tested, so those drop to the cluster tier;
    cluster an ancestor cluster bead lists the anchor or a bead under it under '## Rows' (the lane that owns the rows).
    (comment, a fourth tier between named and cluster, comes from the row's own anchor comments: comment_links.)
    bead, named and comment are evidence a window ran for that row; cluster says only that a lane owning the row ran a window.
    anchors: {anchor: row-id set} (hw_anchor_rows) or a plain set of anchors."""
    links = {}

    def group(a):
        return anchors[a] if isinstance(anchors, dict) else frozenset({a})

    def put(a, via):
        if a in anchors and VIA_RANK[via] < VIA_RANK.get(links.get(a), 9):
            links[a] = via

    if not bead:
        return links
    chain = bead_chain(bead, index)
    for a in bead_chain(bead, index):
        put(a, "bead")
    named = {a for n in (index.get(bead) or {}).get("targets") or [] for a in bead_chain(n, index) if a in anchors}
    via = "named" if len({group(a) for a in named}) <= 1 else "cluster"
    for a in named:
        put(a, via)
    for c in chain:
        for n in (index.get(c) or {}).get("cluster_ids") or []:
            for a in bead_chain(n, index):
                put(a, "cluster")
    return links


def comment_links(w, comments, anchors):
    """The anchors whose own bead comments name window w: its 32-hex generation, or a package path in its family
    (the rule that ties a kit to an anchor, kit_cover.by_refs). The lane that posted the evidence tied the window to the
    row; nothing new is asked of lanes."""
    out = set()
    for a in anchors:
        refs = (comments.get(a) or {}).get("refs") or {}
        if w["gen"] in (refs.get("gens") or []) or (
                w.get("pkg") and any(kit_family_match(p, w["pkg"]) for p in refs.get("paths") or [])):
            out.add(a)
    return out


def _win_fields(prefix, closed):
    """The prefix_* fields of a row's latest closed window (+ ok/fail counts) among (window, via) pairs, newest first."""
    f = {prefix + "_" + k: None for k in ("at", "result", "reason", "generation", "bead", "purpose", "source")}
    f[prefix + "_ok_n"] = sum(1 for w, _ in closed if w["result"] == "ok")
    f[prefix + "_fail_n"] = sum(1 for w, _ in closed if w["result"] == "fail")
    if closed:
        w = closed[0][0]
        f.update({prefix + "_at": w["at"], prefix + "_result": w["result"], prefix + "_reason": w["reason"],
                  prefix + "_generation": w["gen"], prefix + "_bead": w["bead"], prefix + "_purpose": w["purpose"],
                  prefix + "_source": w["source"]})
    return f


def row_windows(anchors, wins):
    """The row-side view of linked windows (newest first) -> the window_* fields, the lane_window_* fields and the open
    windows as kits. window_* = the latest closed window that reached the row by bead/named (evidence for the row);
    lane_window_* = the latest closed window that reached it by cluster only (a lane that owns the row ran it; the
    window may never have touched this row). Neither changes the row's state."""
    mine = []
    for w in wins:
        vias = [w["links"][a] for a in anchors if a in w.get("links", {})]
        if vias:
            mine.append((w, min(vias, key=VIA_RANK.get)))
    done = lambda pairs: [(w, v) for w, v in pairs if w["result"] in ("ok", "fail")]
    strong = done([(w, v) for w, v in mine if v in STRONG_VIA])
    lane = done([(w, v) for w, v in mine if v not in STRONG_VIA])
    f = _win_fields("window", strong)
    f["window_via"] = strong[0][1] if strong else None
    f.update(_win_fields("lane_window", lane))
    f["windows"] = [{"gen": w["gen"], "at": w["at"], "result": w["result"], "bead": w["bead"], "via": v,
                     "purpose": w["purpose"]} for w, v in mine[:HW_WINDOWS_ROW_SHOW]]
    kits = [{"lane": w["lane"] or "?", "gen": w["gen"], "label": w["purpose"] or "", "position": None, "active": True,
             "pkg": w["pkg"] or "", "bead": w["bead"], "via": v} for w, v in mine if w["result"] == "open"]
    return f, kits


def collect_bench_queue(sent, lanes):
    """Each lane's newest request to BENCH in the window and the first BENCH relay back to that lane after it."""
    w = g16_watch()
    cutoff = NOW.timestamp() - BENCH_QUEUE_WINDOW_H * 3600
    active = {lane_base(l["lane"]): l["lane"] for l in lanes}
    latest, answers = {}, {}
    for pair, v in (sent or {}).items():
        if not isinstance(v, dict):
            continue
        target, _, sha = pair.partition(" ")
        src, f = str(v.get("from") or ""), str(v.get("file") or "")
        ts = parse_ts(v.get("at"))
        t = ts.timestamp() if ts else 0
        if lane_base(target) == "BENCH" and lane_base(src) != "BENCH" and w.BENCH_REQUEST_FILE_RE.search(os.path.basename(f)):
            if t >= cutoff and t > latest.get(lane_base(src), {}).get("t", 0):
                latest[lane_base(src)] = {"t": t, "from": src, "file": f, "sha256": sha, "at": v.get("at")}
        elif lane_base(src) == "BENCH" and lane_base(target) != "BENCH":
            answers.setdefault(lane_base(target), []).append({"t": t, "to": target, "file": f, "at": v.get("at")})
    rows = []
    for cl, q in latest.items():
        after = sorted((a for a in answers.get(cl, []) if a["t"] > q["t"]), key=lambda a: a["t"])
        a = after[0] if after else None
        row = {"cluster": cl, "lane": active.get(cl), "from": q["from"], "request": q["file"],
               "request_file": os.path.basename(q["file"]), "request_sha256": q["sha256"], "relayed_at": q["at"],
               "age_s": age_s(parse_ts(q["at"])), "answered": bool(a), "answers_after": len(after),
               "answer": None}
        if a:
            ans = {"to": a["to"], "file": a["file"], "at": a["at"], "state": None, "reason": None, "typed_cause": None}
            fb = os.path.basename(a["file"])
            if typed_result_name(fb):
                try:
                    tr = read_typed(a["file"], os.path.getmtime(a["file"]))
                    ans.update(state=tr["state"], reason=tr["reason"], typed_cause=tr["typed_cause"])
                except OSError:
                    pass
            row["answer"] = ans
        rows.append(row)
    rows.sort(key=lambda r: (r["answered"], -(parse_ts(r["relayed_at"]) or NOW).timestamp()))
    return rows


def collect_bench(lanes):
    dev = {"bench": None, "runner": collect_runner(), "windows": [], "windows_open": [], "queue": [],
           "results": None, "reported": {}, "boundary": None, "sent_error": None}
    bench = next((l for l in lanes if lane_base(l["lane"]) == "BENCH"), None)
    if bench:
        dev["bench"] = {k: bench.get(k) for k in ("lane", "run", "home", "bead", "run_state", "state", "cls",
                                                    "cls_reason", "last_status", "status_age_s", "messages_pending",
                                                    "messages_total", "native_activity_age_s", "stale_quota",
                                                    "blocker_error")}
        # runner=/dut=/place= are not on every BENCH status line: keep the newest value of each and how many
        # receipts back it was (any BENCH run: the lane rotates runs, the bench does not)
        found, _mt, _last = g16_receipts(bench["lane"], None, limit=BENCH_KV_RECEIPTS)
        for back, (rec, line) in enumerate(found):
            for k in BENCH_KV_KEYS:
                if line and k not in dev["reported"] and line["kv"].get(k):
                    dev["reported"][k] = {"value": line["kv"][k], "receipt": rec, "receipts_back": back}
    try:
        with open(os.path.join(G16_RUNS, "relay-sent.json")) as f:
            sent = json.load(f)
        if not isinstance(sent, dict):
            raise ValueError("relay-sent.json is not a JSON object")
    except Exception as ex:
        sent = {}
        dev["sent_error"] = str(ex)[:200]
        err("relay-sent.json", ex)
    dev["queue"] = collect_bench_queue(sent, lanes) if sent else []
    wins = collect_windows()
    dev["windows_open"] = [w for w in wins if w["open"]]
    dev["windows"], dev["windows_total"] = wins[:WINDOWS_SHOW], len(wins)
    dev["results"] = collect_typed_results(sent)
    dev["boundary"] = next(({**it["boundary"], "at": it["at"], "file": it["file"]}
                            for it in dev["results"]["items"] if it.get("boundary")), None)
    return dev


# --------------------------------------------------------------- owner asks --
# 2026-11-02 (tsp-mc9m.60.29.84.14): owner asks come from the owner intake (pf-owner-intake.sh list --id <id>, the
# durable owner bridge), not gpu14-owner-questions.md (Q60-Q68 there were stale). Only non-resolved tickets show.
OWNER_INTAKE = os.environ.get("FB_OWNER_INTAKE") or os.path.join(MC, "scripts", "pf-owner-intake.sh")
OWNER_INTAKE_IDS = [i for i in (os.environ.get("FB_OWNER_INTAKE_IDS") or "gpu-16").split(",") if i.strip()]
OWNER_INTAKE_TIMEOUT_S = 90
INTAKE_ROW_RE = re.compile(r"^(\S+)\tstatus=(\S*)\tround=(\S*)\tbead=(\S*)\s*$")


def collect_owner_asks(index=None):
    out = {"count": 0, "items": [], "error": None, "source": "pf-owner-intake.sh list", "ids": OWNER_INTAKE_IDS,
           "listed": 0, "resolved": 0}
    errs = []
    for ident in OWNER_INTAKE_IDS:
        rc, txt, e = run_cmd([OWNER_INTAKE, "list", "--id", ident.strip()], OWNER_INTAKE_TIMEOUT_S, cwd=MC)
        if rc != 0:
            errs.append(f"{ident}: rc={rc} {(e.strip().splitlines() or [''])[-1][:160]}")
            continue
        for line in txt.splitlines():
            m = INTAKE_ROW_RE.match(line)
            if not m:
                continue    # "pf-ask-owner: no tickets for <id>"
            out["listed"] += 1
            if m.group(2) == "resolved":
                out["resolved"] += 1
                continue
            bead = m.group(4) or None
            out["items"].append({"num": None, "ticket": m.group(1), "status": m.group(2), "round": m.group(3),
                                 "bead": bead, "id": ident.strip(),
                                 "title": ((index or {}).get(bead) or {}).get("title") if bead else None})
    if errs:
        out["error"] = "; ".join(errs)[:400]
        err("owner intake", out["error"])
    out["count"] = len(out["items"])
    return out


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
PARK_TOKEN_RE = re.compile(r"(?<![\w-])(until_bead|until_pr|until_date|until_owner|until_event|evidence_for)=(\S*)")
OWNER_DONE_RE = re.compile(r"\b(RESOLVED|ANSWERED)\b")
PARK_ID_RE = r"[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?"


def park_condition(reason, since, index, owner, lanes_by_name, prs=None):
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
        if key == "until_bead":
            if not re.fullmatch(PARK_ID_RE, val):
                bad.append(f"{tok} is not a bead id")
            else:
                bead = index.get(val) if index else None
                if bead is None:
                    bad.append(f"{tok}: {'bead index unreadable' if not index else 'unknown bead'}")
                elif bead.get("status") == "closed":
                    fires.append(f"{val} is closed")
                else:
                    holds.append(f"until {val} closes ({bead.get('status')})")
        elif key == "until_pr":
            if not PR_RE.fullmatch(val):
                bad.append(f"{tok} is not <owner>/<repo>#<n>")
            else:
                pr = (prs or {}).get(val)
                if pr is None:
                    bad.append(f"{tok}: PR state unreadable")
                elif pr.get("state") in ("MERGED", "CLOSED"):
                    fires.append(f"{val} is {pr.get('state')}")
                elif pr.get("state") == "OPEN":
                    holds.append(f"until {val} merges")
                else:
                    bad.append(f"{tok}: unknown PR state {pr.get('state')}")
        elif key == "until_date":
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


def wait_condition(bid, index, owner, lanes_by_name, prs):
    """Resolve the freshest matching waits.tsv row, including descendant wildcards.

    Typed rows are condition-driven and do not expire by age. Untyped rows keep
    the historical WAIT_MAX_H guard so forgotten bookkeeping resurfaces.
    """
    row = wait_for(bid)
    if not row:
        return None
    age = age_s(parse_ts(row[0]))
    cond = park_condition(row[1], row[0], index, owner, lanes_by_name, prs)
    if cond:
        return {**cond, "typed": True, "since": row[0], "reason": row[1], "age_s": age}
    state = "hold" if age is not None and age < WAIT_MAX_H * 3600 else "fire"
    text = f"untyped wait is {fmt_age(age)} old" if age is not None else "untyped wait time is unreadable"
    return {"state": state, "text": text, "typed": False, "since": row[0], "reason": row[1], "age_s": age,
            "evidence": None, "release": False}


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


# 2026-11-03 (tsp-mc9m.60.29.84.24): pf-shared-refresh skipped test-node-farm (dirty) for 6 days, saying so only in
# its journal; KIT2's deploy admission waited on it and the bench idled. The refresh hook (mission-control
# .agents/hooks/session-refresh-shared-checkouts.sh, every 5 min) now writes one row per checkout to this file; a
# checkout skipped (any state but ok) for more than SHARED_REFRESH_SKIP_ALARM_MIN, measured to its last check, is a
# host need. Exceptions come only from shared-refresh-allow.json beside this file: {path, states, reason, bead}; a
# malformed allowlist voids every exception. A missing, unreadable or stale status file is ONE "status unknown" need,
# not none: the board and the timer share this laptop, so no fresh file means the refresh stopped reporting, which is
# the silent failure this exists to end. A stale file's rows are summarized but never alarmed; a malformed row adds
# one "status unknown" need beside the valid rows' alarms.
SHARED_REFRESH_STATUS = (os.environ.get("FB_SHARED_REFRESH_STATUS")
                         or os.path.expanduser("~/.local/state/pocketforge/shared-refresh.json"))
SHARED_REFRESH_ALLOW = (os.environ.get("FB_SHARED_REFRESH_ALLOW")
                        or os.path.join(os.path.dirname(os.path.abspath(__file__)), "shared-refresh-allow.json"))
SHARED_REFRESH_SKIP_ALARM_MIN = 60   # skipped continuously for longer than this -> host need
SHARED_REFRESH_STALE_MIN = 30        # status file older than this (the timer runs every 5 min) -> status unknown
SHARED_REFRESH_SKIP_STATES = ("dirty", "ahead", "diverged", "fetch_failed", "ff_refused", "detached", "no_upstream",
                              "not_checked")
SHARED_REFRESH_NEXT = {
    "dirty": "Preserve the tracked edits first (commit to a branch and push, or stash under a named message), then "
             "restore the clean checkout; the 5-min timer fast-forwards it. Never reset unpreserved work.",
    "ahead": "Preserve the local commits (push to preserve/<repo>-<sha> or land them by PR), then reset the shared "
             "checkout to its upstream.",
    "diverged": "Preserve the local commits (push to preserve/<repo>-<sha> or land them by PR), then reset the shared "
                "checkout to its upstream.",
    "fetch_failed": "Upstream branch deleted: switch the clean checkout back to the default branch. Otherwise check "
                    "the remote, network and credentials (journalctl --user -u pf-shared-refresh).",
    "ff_refused": "An untracked file blocks the fast-forward (the detail names it): preserve it elsewhere or land it "
                  "upstream, then let the timer refresh.",
    "detached": "Check out the default branch.",
    "no_upstream": "Set the branch's upstream or switch to the default branch.",
    "not_checked": "The refresh budget ran out before this checkout: find the slow fetches earlier in the list "
                   "(journalctl --user -u pf-shared-refresh).",
}


def load_shared_refresh_allow():
    """Committed exceptions by path; unreadable or malformed -> none (fail closed) and a source error."""
    try:
        with open(SHARED_REFRESH_ALLOW) as f:
            rows = json.load(f)
        if not isinstance(rows, list):
            raise ValueError("top level must be a list")
        out = {}
        for r in rows:
            if not (isinstance(r, dict) and isinstance(r.get("path"), str) and r["path"]
                    and isinstance(r.get("reason"), str) and r["reason"].strip()
                    and isinstance(r.get("bead"), str) and r["bead"].strip()
                    and isinstance(r.get("states"), list) and r["states"]
                    and all(s in SHARED_REFRESH_SKIP_STATES for s in r["states"])):
                raise ValueError(f"entry needs path, reason, bead and states from {SHARED_REFRESH_SKIP_STATES}: "
                                 f"{r!r:.160}")
            out[r["path"]] = r
        return out
    except Exception as ex:
        err("shared refresh allowlist", ex)
        return {}


def classify_shared_refresh(now=None):
    """(needs, summary) from the pf-shared-refresh status file; see the comment above SHARED_REFRESH_STATUS."""
    now = now or NOW
    summary = {"status_path": SHARED_REFRESH_STATUS, "generated_at": None, "complete": None, "error": None,
               "checkouts": []}

    def unknown(why, since=None):
        summary["error"] = why
        return [{"kind": "host", "id": "shared-refresh-status", "lane": None, "bead": None, "run": None, "pr": None,
                 "reason": f"shared-checkout refresh status unknown: {why}", "since": since,
                 "age_s": max(0.0, (now - parse_ts(since)).total_seconds()) if parse_ts(since) else None,
                 "next": "Check `systemctl --user status pf-shared-refresh.timer` and `journalctl --user -u "
                         "pf-shared-refresh`; the mission-control refresh hook rewrites this file every run."}]

    try:
        with open(SHARED_REFRESH_STATUS) as f:
            doc = json.load(f)
    except FileNotFoundError:
        return unknown(f"{SHARED_REFRESH_STATUS} missing"), summary
    except Exception as ex:
        err("shared refresh status", ex)
        return unknown(f"{SHARED_REFRESH_STATUS} unreadable: {str(ex)[:160]}"), summary
    gen = parse_ts(doc.get("generated_at")) if isinstance(doc, dict) else None
    rows = doc.get("checkouts") if isinstance(doc, dict) else None
    if gen is None or not isinstance(rows, list):
        err("shared refresh status", "needs generated_at and a checkouts list")
        return unknown(f"{SHARED_REFRESH_STATUS} has no generated_at or checkouts list"), summary
    summary.update(generated_at=iso(gen), complete=doc.get("complete"))
    valid = [c for c in rows if isinstance(c, dict) and isinstance(c.get("path"), str) and c["path"]
             and isinstance(c.get("state"), str) and c["state"]]
    needs = []
    gen_age = (now - gen).total_seconds()
    # A stale file is status unknown as a whole: exactly one need, and its rows are summarized but never alarmed.
    stale = gen_age > SHARED_REFRESH_STALE_MIN * 60
    if stale:
        skips = sum(1 for c in valid if c["state"] != "ok")
        needs += unknown(f"last written {fmt_age(gen_age)} ago at {iso(gen)} (the timer runs every 5 min); it "
                         f"recorded {skips} skipped checkout(s)", iso(gen))
    elif len(valid) != len(rows):
        # A malformed row could hide a skipped checkout: fail closed; the valid rows are still classified.
        bad = next(c for c in rows if not any(c is v for v in valid))
        err("shared refresh status", f"{len(rows) - len(valid)} checkout row(s) without a path and state: {bad!r:.120}")
        needs += unknown(f"{len(rows) - len(valid)} malformed checkout row(s) in {SHARED_REFRESH_STATUS}", iso(gen))
    allow = load_shared_refresh_allow()
    for c in valid:
        path, state = c["path"], c["state"]
        first = parse_ts(c.get("first_skipped_at")) if isinstance(c.get("first_skipped_at"), str) else None
        checked = (parse_ts(c.get("checked_at")) if isinstance(c.get("checked_at"), str) else None) or gen
        skipped_s = max(0.0, (checked - first).total_seconds()) if state != "ok" and first else None
        a = allow.get(path)
        allowed = a["reason"] if a and state in a["states"] else None
        # an unreadable skip start fails closed: alarm now rather than never
        alarm = (not stale and state != "ok" and allowed is None
                 and (skipped_s is None or skipped_s > SHARED_REFRESH_SKIP_ALARM_MIN * 60))
        summary["checkouts"].append(dict({k: c.get(k) for k in ("path", "branch", "state", "ahead", "behind",
                                                                "first_skipped_at", "last_ok_at", "checked_at")},
                                         skipped_s=skipped_s, alarm=alarm, allowlisted=allowed))
        if not alarm:
            continue
        ab = (f" ahead={c.get('ahead')} behind={c.get('behind')}"
              if isinstance(c.get("ahead"), int) and isinstance(c.get("behind"), int) else "")
        detail = str(c.get("detail") or "")[:200]
        needs.append({
            "kind": "host", "id": f"shared-refresh:{path}", "lane": None, "bead": None, "run": None, "pr": None,
            "reason": (f"shared checkout {path} [{c.get('branch') or 'detached'}] not refreshed for "
                       f"{fmt_age(skipped_s) if skipped_s is not None else 'an unknown time'}: {state}{ab}"
                       + (f" ({detail})" if detail else "")
                       + f"; last ok {c.get('last_ok_at') or 'not seen'}"),
            "since": c.get("first_skipped_at"), "age_s": skipped_s,
            "next": "gpu-16 ops: " + SHARED_REFRESH_NEXT.get(
                state, "inspect `git -C <path> status` and journalctl --user -u pf-shared-refresh."),
        })
    return needs, summary


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


def reclassify_needs(needs, index, lanes, preserved_runs, comments, now):
    """Move board noise out of Needs without dropping an item.

    ``index`` is the single ``bd list --all --json`` snapshot collected above.
    Parent traversal never shells out and refuses cycles/missing parents.  Only a
    lane with a live driver can own descendants; an old undriven run sharing a
    bead with a live lane is therefore attributed to that live lane.
    """
    live_lane_by_bead = {}
    for lane in lanes:
        if lane.get("bead") and lane.get("driver_alive") and lane.get("cls") != "released":
            live_lane_by_bead.setdefault(lane["bead"], lane.get("lane"))

    active_preserves = {}
    for row in preserved_runs or []:
        if not isinstance(row, dict) or not row.get("run_id") or not row.get("reason") or not row.get("until"):
            continue
        until = parse_ts(row["until"])
        if until is not None and until > now:
            active_preserves[row["run_id"]] = row

    def ancestor_lane(bead):
        seen = set()
        current = bead
        for _depth in range(64):
            if not current or current in seen:
                return None
            seen.add(current)
            if current in live_lane_by_bead:
                return live_lane_by_bead[current]
            current = (index.get(current) or {}).get("parent")
        return None

    def blockers(bead):
        out = []
        for dep in (index.get(bead) or {}).get("deps") or []:
            if dep.get("type") != "blocks":
                continue
            target = index.get(dep.get("id")) or {}
            if target.get("status") != "closed":
                out.append({"id": dep.get("id"), "status": target.get("status", "unknown"),
                            "title": target.get("title", "")[:120]})
        return out

    def comment_text(bead):
        info = (comments or {}).get(bead) or {}
        return "\n".join(str(c.get("body") or "") for c in info.get("comments") or [])

    def comment_blocker(bead):
        text = comment_text(bead)
        matches = re.findall(
            r"(?:existing\s+owner\s+bead|blocked\s+(?:on|by))\s+"
            r"(tsp-[a-z0-9]+(?:\.[0-9]+)*)",
            text,
            re.IGNORECASE,
        )
        for target_id in reversed(matches):
            target = index.get(target_id) or {}
            if target.get("status") != "closed":
                return {"id": target_id, "status": target.get("status", "unknown"),
                        "title": target.get("title", "")[:120]}
        return None

    result = {name: [] for name in
              ("needs", "waiting_owner_attended", "waiting_bench", "blocked_by_bead",
               "closed_live_run", "lane_attributed", "blocked", "preserved", "mechanical",
               "stale_summary")}
    for original in needs:
        row = dict(original)
        keep = active_preserves.get(row.get("run"))
        if keep:
            row.update({"preserve_reason": keep["reason"], "preserve_until": keep["until"],
                        "waiting_owner": keep.get("owner") or "gpu-14"})
            if (index.get(row.get("bead")) or {}).get("status") == "closed":
                result["closed_live_run"].append(row)
            else:
                result["preserved"].append(row)
            continue
        text = comment_text(row.get("bead"))
        if text and (re.search(r"gpu-14\s+ruling:.*?deferred", text, re.IGNORECASE | re.DOTALL)
                     or re.search(r"owner[- ]attended|attended\s+bench\s+tests?\s+are\s+deferred",
                                  text, re.IGNORECASE)):
            row.update({"waiting_owner": "owner",
                        "waiting_reason": "owner-attended acceptance is explicitly deferred"})
            result["waiting_owner_attended"].append(row)
            continue
        named_blocker = comment_blocker(row.get("bead"))
        if named_blocker:
            row.update({"waiting_owner": named_blocker["id"], "blockers": [named_blocker],
                        "waiting_reason": "repair is owned by another open bead"})
            result["blocked_by_bead"].append(row)
            continue
        if (text and re.search(r"device\s+proof\s+(?:remains\s+)?pending|waiting\s+for\s+device\s+proof",
                               text, re.IGNORECASE)
                and re.search(r"deploy(?:ed|_ready|ment)", text, re.IGNORECASE)):
            row.update({"waiting_owner": "gpu-14",
                        "waiting_reason": "deployed; device proof waits for the held bench"})
            result["waiting_bench"].append(row)
            continue
        open_blockers = blockers(row.get("bead")) if row.get("bead") else []
        if open_blockers:
            row["blockers"] = open_blockers
            row["original_kind"] = row.get("kind")
            row["kind"] = "blocked"
            result["blocked"].append(row)
            continue
        if row.get("kind") == "handback" and re.search(r"\bPR\s+\S+#\d+\s+merged\b", row.get("reason") or ""):
            row["mechanical_reason"] = "merged PR awaits release and guarded bead close"
            result["mechanical"].append(row)
            continue
        if row.get("kind") == "stale" and row.get("id") == "stale-beads" and not row.get("bead"):
            result["stale_summary"].append(row)
            continue
        if row.get("kind") in ("stale", "undriven") and row.get("bead"):
            lane = ancestor_lane(row["bead"])
            if lane and lane != row.get("lane"):
                row["attributed_lane"] = lane
                result["lane_attributed"].append(row)
                continue
        result["needs"].append(row)
    return result


def fetch_comments_for(ids):
    out = {}
    with cf.ThreadPoolExecutor(COMMENTS_PARALLEL) as ex:
        for bid, info, e in ex.map(fetch_comments, ids[:COMMENTS_MAX]):
            if e:
                err(f"bd comments {bid}", e)
            out[bid] = info
    return out


def classify_beads(index, ready_ids, lanes, comments, prs=None, owner=None):
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
        _wd = wait_condition(s["id"], index, owner or {}, {ln["lane"]: ln for ln in lanes}, prs or {})
        if _wd and _wd["state"] in ("hold", "evidence"):
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
    lane's admitted bead, the row beads its cluster bead lists under '## Rows' (gpu-16 cluster lanes), plus its
    latest assign-next pop (lane-queue/*.done rows for the lane's run). Queued: the non-comment lines of
    lane-queue/<lane>.txt (assign-next.sh pops the first)."""
    driving, queued = {}, {}
    live = [l for l in lanes if l.get("cls") not in ("released", "evidence")]
    runs = {l["run"]: l["lane"] for l in live if l.get("run")}
    for l in live:
        for bid in ([l["bead"]] if l.get("bead") else []) + list(l.get("rows") or []):
            driving.setdefault(bid, set()).add(l["lane"])
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
        with open(wq["path"], errors="replace") as f:   # 2026-11-02: window queue retired; only an explicit wq reads
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
    """-> (named {bead: [kit]}, by_anchor_refs(anchor) -> [kit], batches {label: [member bead]}, by_lane(lane) -> [kit]).
    named: the bead ids a queued kit's package names (rule b). by_anchor_refs: kits an anchor's own comments name by
    package path/family or generation (rule b, read from the bead side). batches: batch:<slug> label -> members (rule c).
    by_lane: the queued kits a lane owns (rule c: a batch's kit need not name any member, e.g. kleaf2's package sits
    under the parent epic dir and its text names no member bead)."""
    named = {}
    for k in kits:
        for i in kit_ids.get(k["pkg"]) or []:
            named.setdefault(i, []).append(k)

    def by_refs(anchor):
        refs = (comments.get(anchor) or {}).get("refs") or {}
        gens, paths = set(refs.get("gens") or []), refs.get("paths") or []
        return [k for k in kits if (k["gen"] and k["gen"] in gens) or any(kit_family_match(p, k["pkg"]) for p in paths)]

    def by_lane(lane):
        return [k for k in kits if k["lane"] == lane]

    batches = {}
    for bid, b in index.items():
        for lab in b.get("labels") or []:
            if lab.startswith("batch:"):
                batches.setdefault(lab, []).append(bid)
    return named, by_refs, batches, by_lane


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
    from the anchor's comments) and batch:<slug> propagation (rule c): the lanes driving a batch's other members, and the
    kits those lanes own or the package names. -> (kits [{lane, gen, label, position, active, pkg, bead, via}],
    batch_lanes [{lane, bead, via}])."""
    named, by_refs, batches, by_lane = kc
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
            lab_lanes = {}      # lane -> the batch member it drives
            for m in sorted(batches.get(lab, ())):
                if m in cover:
                    continue
                for ln in sorted(driving.get(m, ())):
                    lab_lanes.setdefault(ln, m)
                    if all(x["lane"] != ln for x in blanes):
                        blanes.append({"lane": ln, "bead": m, "via": lab})
                for k in named.get(m, ()):
                    add(k, m, lab)
            for ln, m in sorted(lab_lanes.items()):
                for k in by_lane(ln):
                    add(k, m, lab)
    kits.sort(key=lambda k: (not k["active"], k["position"] or 0))
    return kits, blanes


def hw_row_live(r, index, kids, comments, driving, queued, kc=None, wins=()):
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
    wfields, wkits = row_windows(anchors, wins)
    kits = kits + wkits      # an open kit window on the row is live coverage (closed windows are evidence, not kits)
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
    out.update(wfields)      # after st: derived window fields can never overwrite state/evidence_at (different keys)
    return out


def build_hardware(index, lanes, comments, doc, wq=None, windows=None):
    kids = child_map(index)
    driving, queued = lane_coverage(lanes)
    kits = queued_kits(wq, lanes) if wq else []   # 2026-11-02: the window queue is retired; no queued kits
    kc = kit_cover(kits, kit_bead_ids(kits), index, comments, driving)
    # 2026-11-05 (tsp-hqm1p.100): the kit-window runner's results are the device evidence now
    wins, scanned = windows if windows is not None else collect_hw_windows()
    anchors = hw_anchor_rows(doc)
    for w in wins:
        w["links"] = window_links(w["bead"], index, anchors)
        for a in comment_links(w, comments, anchors):
            if VIA_RANK["comment"] < VIA_RANK.get(w["links"].get(a), 9):
                w["links"][a] = "comment"
    unmapped = sum(1 for w in wins if not w["links"])
    lane_only = sum(1 for w in wins if w["links"] and all(v not in STRONG_VIA for v in w["links"].values()))
    flag_names = ("unowned", "evidence_old", "anchor_closed", "no_anchor")

    def tally(rows):
        t = {s: sum(1 for x in rows if x["state"] == s) for s in HW_STATES}
        for x in rows:
            if x["state"] not in t:
                t[x["state"]] = t.get(x["state"], 0) + 1
        return t

    rows = [hw_row_live(r, index, kids, comments, driving, queued, kc, wins) for r in doc.get("rows") or []]
    hardware = {"rows": rows, "tally": tally(rows), "flags": {f: sum(1 for x in rows if f in x["flags"]) for f in flag_names},
                "source": HW_ROWS_FILE, "evidence_old_d": HW_EVIDENCE_OLD_D, "kits_scanned": len(kits) + scanned,
                "windows_lookback_h": HW_WINDOWS_LOOKBACK_H,
                "windows_closed": sum(1 for w in wins if w["result"] in ("ok", "fail")),
                "windows_open": sum(1 for w in wins if w["result"] == "open"), "windows_unmapped": unmapped,
                "windows_lane_only": lane_only,
                "rows_with_window": sum(1 for x in rows if x.get("window_at")),
                # a lane window counts when the row has no tied window or the lane window is newer than it
                "rows_with_lane_window": sum(1 for x in rows if x.get("lane_window_at")
                                             and (not x.get("window_at") or x["lane_window_at"] > x["window_at"]))}
    prows = [hw_row_live(p, index, kids, comments, driving, queued, kc, wins) for p in doc.get("priorities") or []]
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
    beads_box = {}

    # preliminary lane->bead map (gpu-16 runs/run-<NAME>.json task of each active.tsv lane) so the stale scan can run
    # alongside the pf-task lookups
    prelim_lanes = set()
    try:
        for _name, _rid, _home in g16_watch().active_runs():
            t = (jread(os.path.join(G16_RUNS, f"run-{_name}.json")) or {}).get("task")
            if t:
                prelim_lanes.add(t)
    except Exception as ex:
        err("active.tsv (prelim)", ex)

    def beads_job():
        beads_box["index"], beads_box["ready"] = collect_beads()
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
        lanes = collect_g16_lanes()                     # sequential pf-task run.status lookups, main thread
        refs = pr_refs_from_lanes(lanes)
        # until_pr=<owner/repo#N> park holds need that PR's state too.
        for _since, _why in list(PARKED.values()) + list(WAITS.values()):
            for _m in re.finditer(r"until_pr=([\w.-]+/[\w.-]+#\d+)", _why):
                if PR_RE.match(_m.group(1)):
                    refs.setdefault(_m.group(1), None)
        fut_prs = ex.submit(collect_prs, refs)
        fut_beads.result()
        prs = fut_prs.result()
    index, ready_ids = beads_box["index"], beads_box["ready"]
    for ln in lanes:
        b = (index.get(ln["bead"]) or {}) if ln.get("bead") and index else {}
        ln["bead_title"], ln["rows"] = b.get("title"), b.get("rows") or []
    dev = collect_bench(lanes)
    owner = collect_owner_asks(index)
    # 2026-11-02: lane handbacks and blocks reach gpu-16 through its watcher (watch-runs.py EVENTs); the board shows
    # them in the lanes table (cls needs) and does not repeat them as needs items.
    needs = classify_host()
    shared_refresh_needs, shared_refresh = classify_shared_refresh()
    needs += shared_refresh_needs
    for q in collect_model_quota():
        needs.append({"kind": "blocked", "id": "quota:" + q["worktree"], "lane": None, "bead": q["worktree"].split("/")[0],
                      "run": None, "pr": None,
                      "reason": f"OpenCode session {q['session'][:16]} (port {q['port']}) is in a provider retry loop: {q['message'][:140]}",
                      "since": None, "age_s": None,
                      "next": "Re-route to Codex (WT_ID=<bead>-cx, fetch unpushed commits by path), then POST /session/<id>/abort "
                              "so it cannot wake and push; if the lane is another coordinator's, tell them."})
    disp, stale, long_idle, bead_needs, lane_by_bead, owned = classify_beads(
        index, ready_ids, lanes, beads_box.get("comments") or {}, prs=prs, owner=owner)
    # 2026-10-20: hardware & driver rows, tier priorities, open backlog. Display only: never needs items.
    hardware, priorities, backlog = {"rows": [], "error": None}, {"goals": []}, None
    if beads_box.get("hw_doc") is not None and index:
        try:
            hardware, priorities = build_hardware(index, lanes, beads_box.get("hw_comments") or {}, beads_box["hw_doc"])
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
    lanes_by_name = {ln["lane"]: ln for ln in lanes}
    for n in bead_needs:
        wd = wait_condition(n.get("bead") or "", index, owner, lanes_by_name, prs)
        if wd and wd["state"] in ("hold", "evidence"):
            waited.append({"bead": n["bead"], "kind": n["kind"], "since": wd["since"],
                           "reason": wd["reason"], "condition": wd["text"], "typed": wd["typed"]})
            continue
        if wd:
            n["reason"] = f"wait condition {wd['state']}: {wd['text']} ({wd['reason'][:120]}); " + n["reason"]
        needs.append(n)
    # 2026-10-13: glcrash sat WINDOW_READY on a recorded wait (transport fix deploy) and re-flagged "undriven" every
    # tick. A fresh waits.tsv row for the lane's bead covers an undriven lane need too; handbacks and merges still show.
    kept = []
    for n in needs:
        if n.get("kind") == "undriven" and n.get("bead"):
            wd = wait_condition(n["bead"], index, owner, lanes_by_name, prs)
            if wd and wd["state"] in ("hold", "evidence"):
                waited.append({"bead": n["bead"], "kind": n["kind"], "since": wd["since"],
                               "reason": wd["reason"], "condition": wd["text"], "typed": wd["typed"]})
                continue
        kept.append(n)
    needs[:] = kept
    ruling_comments = dict(beads_box.get("comments") or {})
    ruling_ids = sorted({n.get("bead") for n in needs if n.get("bead")})
    missing_rulings = [bid for bid in ruling_ids if bid not in ruling_comments]
    if missing_rulings:
        ruling_comments.update(fetch_comments_for(missing_rulings))
    truth = reclassify_needs(needs, index, lanes, load_preserved_runs(), ruling_comments, NOW)
    needs = truth["needs"] + load_coord_needs()
    for n in needs:
        n["rank"] = KIND_RANK.get(n["kind"], 9)
    needs.sort(key=lambda n: (n["rank"], -(n["age_s"] or 0)))

    shown = [l for l in lanes if l.get("cls") != "released"]
    released = [l for l in lanes if l.get("cls") == "released"] + g16_released_rows()
    refd = set()
    for ln in shown:
        if ln.get("bead"):
            refd.add(ln["bead"])
    for n in needs:
        if n.get("bead"):
            refd.add(n["bead"])
    for section in ("waiting_owner_attended", "waiting_bench", "blocked_by_bead", "closed_live_run",
                    "lane_attributed", "blocked", "preserved", "mechanical", "stale_summary"):
        for n in truth[section]:
            if n.get("bead"):
                refd.add(n["bead"])
            for blocker in n.get("blockers") or []:
                if blocker.get("id"):
                    refd.add(blocker["id"])
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
    bindex = {i: {"title": index[i]["title"][:160], "status": index[i]["status"], "type": index[i]["type"],
                  "priority": index[i]["priority"]} for i in refd if i in index}

    lane_rows = []
    for ln in sorted(shown, key=lambda l: ({"needs": 0, "unknown": 1, "waiting": 2, "running": 3}.get(l["cls"], 4),
                                           -(l.get("status_age_s") or 0))):
        lane_rows.append({k: ln.get(k) for k in (
            "lane", "token", "run", "home", "run_state", "state", "stale_quota", "run_checked_at", "run_fresh",
            "run_error", "bead", "bead_title", "model", "provider", "runtime", "driver_alive", "last_status",
            "status_age_s", "last_turn_end", "last_turn_reason", "pr", "reconciler_alive", "controller_alive",
            "runtime_alive", "native_activity_age_s", "messages_pending", "messages_total", "receipts_total",
            "receipts_unacked", "worktree", "blocker_error", "cls", "kind", "cls_reason", "next", "source",
            "session_id", "rows")})
    summary = {
        "needs": len(needs),
        "waiting_owner_attended": len(truth["waiting_owner_attended"]),
        "waiting_bench": len(truth["waiting_bench"]),
        "blocked_by_bead": len(truth["blocked_by_bead"]),
        "closed_live_run": len(truth["closed_live_run"]),
        "lane_attributed": len(truth["lane_attributed"]),
        "blocked_claims": len(truth["blocked"]),
        "preserved": len(truth["preserved"]),
        "mechanical": len(truth["mechanical"]),
        "lanes_total": len(shown),
        "lanes_running": sum(1 for l in shown if l["cls"] == "running"),
        "lanes_waiting": sum(1 for l in shown if l["cls"] == "waiting"),
        "lanes_needs": sum(1 for l in shown if l["cls"] == "needs"),
        "lanes_unknown": sum(1 for l in shown if l["cls"] == "unknown"),
        "lanes_stale_quota": sum(1 for l in shown if l.get("stale_quota")),
        "owned": {w: sum(1 for o in owned if o["assignee"] == w) for w in COORD_OWNERS},
        "lanes_released_hidden": len(released),
        "dispatchable": disp["parallel_total"] + len(disp["newly_unblocked"]),
        "dispatchable_recent": disp["parallel_recent_total"] + len(disp["newly_unblocked"]),
        "lanes_unchecked": sum(1 for l in shown if (l.get("run_error") or "").startswith("not checked")),
        "stale_individual": sum(1 for n in needs if n["kind"] == "stale" and n.get("bead")),
        "newly_unblocked": len(disp["newly_unblocked"]),
        "stale": len(stale),
        "owner_asks": owner["count"],
        # 2026-11-02: BENCH + pf-kit-window-runner (the window queue is retired). running = the open kit window,
        # pending = BENCH queue requests with no answer yet, halted = runner unit not active
        "device": {"running": " ".join(x for x in (dev["windows_open"][0]["purpose"], dev["windows_open"][0]["gen"][:8]) if x)
                   if dev["windows_open"] else None,
                   "pending": sum(1 for q in dev["queue"] if not q.get("answered")),
                   "halted": dev["runner"].get("active") != "active", "runner_alive": dev["runner"].get("active") == "active",
                   "kit_running": bool(dev["windows_open"]), "windows_open": len(dev["windows_open"]),
                   "bench_state": (dev["bench"] or {}).get("state"),
                   "bench_verdict": ((dev["bench"] or {}).get("last_status") or {}).get("verdict"),
                   "queue_total": len(dev["queue"]), "results_24h": (dev["results"] or {}).get("total", 0),
                   "results_warn": len((dev["results"] or {}).get("warns") or [])},
        "needs_by_kind": {k: sum(1 for n in needs if n["kind"] == k) for k in KIND_RANK},
        "beads_in_scope_in_progress": sum(1 for i, b in index.items() if in_scope(i) and b["status"] == "in_progress"),
        "beads_in_scope_open": sum(1 for i, b in index.items() if in_scope(i) and b["status"] == "open"),
        "hardware": {"rows": len(hardware.get("rows") or []), "tally": hardware.get("tally") or {},
                     "flags": hardware.get("flags") or {}},
        "backlog_open": (backlog or {}).get("open_total"),
    }
    data = {
        "generated_at": iso(NOW), "generated_epoch": NOW.timestamp(), "host": socket.gethostname(),
        "runtime_s": round(time.time() - T0, 1),
        "thresholds": {k: v for k, v in globals().items() if k.isupper() and isinstance(v, (int, float, str))
                       and k not in ("G", "G16", "G16_RUNS", "MC", "BOARD", "OUT", "NOW", "T0", "KIT_WINDOWS",
                                     "RUNNER_UNIT", "TYPED_RESULTS_ROOT", "OWNER_INTAKE", "HW_ROWS_FILE",
                                     "HW_COMMENTS_CACHE", "HW_KITS_CACHE", "PRESERVED_RUNS_FILE", "COORD_NEEDS_FILE",
                                     "SHARED_REFRESH_STATUS", "SHARED_REFRESH_ALLOW", "LANE_QUEUE_DIR")},
        "campaign_roots": CAMPAIGN_ROOTS,
        "errors": ERRORS, "summary": summary, "needs": needs, "waits": waited, "lanes": lane_rows,
        "released_runs": [{"lane": l["lane"], "run": l["run"], "bead": l.get("bead")} for l in released],
        "prs": prs, "dispatchable": disp, "device": dev, "stale": stale, "long_idle": long_idle,
        "owner_asks": owner, "beads_index": bindex, "owned": owned,
        "lane_attributed": truth["lane_attributed"], "blocked": truth["blocked"],
        "waiting_owner_attended": truth["waiting_owner_attended"],
        "waiting_bench": truth["waiting_bench"], "blocked_by_bead": truth["blocked_by_bead"],
        "closed_live_run": truth["closed_live_run"],
        "preserved": truth["preserved"], "mechanical": truth["mechanical"],
        "stale_summary": truth["stale_summary"],
        "hardware": hardware, "priorities": priorities, "backlog": backlog,
        "shared_refresh": shared_refresh,
    }
    tmp = OUT + ".new"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=1, sort_keys=False)
    os.replace(tmp, OUT)
    print(f"COLLECT ok path={OUT} runtime_s={data['runtime_s']} lanes={len(shown)} needs={len(needs)} errors={len(ERRORS)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
