# Fleet board (gpu-14)

Generated operations page: is every in-flight piece of the A133/GPU campaign
moving, and what is waiting on gpu-14 right now. Zero hand maintenance; every
refresh re-reads live sources. gpu-14 runs `refresh.sh` about every 20 minutes
during active work and publishes `fleet-board.html` with its own tool.

```
./refresh.sh                       # collect -> render -> summary lines on stdout, exit 0
FB_PFTASK_BUDGET_S=400 ./refresh.sh  # one-off: check every lane's run state (warms the cache)
```

Files: `collect.py` (sources -> `data.json`, schema documented at its top),
`render.py` (`data.json` -> `fleet-board.html`, self-contained, data embedded),
`refresh.sh` (runs both, prints `NEEDS_GPU14 kind=... id=... detail=...` lines,
`SOURCE_ERROR ...` lines, then one `BOARD path=... generated_at=... lanes=N needs=N ...`
line). `cache/run-state.json` is the only state kept between runs: pf-task
`run.status` answers, so a `released` run is never queried again and a lane
outside this refresh's pf-task budget shows its last known state with its age.

## Sources (read-only)

| Source | How | Bound |
|---|---|---|
| Beads | `bd list --all --json --flat -n 0` (one call), `bd ready --json -n 0`, `bd comments <id> --json` for stale candidates only | COMMENTS_MAX=150, 4 parallel |
| Lanes | `/home/matt/recovery/gpu14/<lane>-drive.log` touched in the last LANE_LOG_WINDOW_H; `ps` for live `lane-drive.sh pft-...`; `admission-*.json` for run -> bead/model; `pf-task run.status` per run id | sequential, PFTASK_TIMEOUT_S each, PFTASK_BUDGET_S total; never the pf-task journal/DB |
| PRs | `gh pr view <n> -R <repo> --json state,mergedAt,headRefOid,statusCheckRollup,reviewDecision,...` for PRs named in lane status lines | GH_PARALLEL=4 |
| Device | `queue.tsv`, `queue.done`, `device-queue.txt`, `ps` for `queue-runner.sh` and a live `direct-boot.sh` | files only |
| Owner asks | `/home/matt/gpu14-owner-questions.md`, `## Needs you` section, `N. **title**` items | file only |

Scope: a bead counts when its id is a campaign root or a descendant
(`CAMPAIGN_ROOTS` at the top of `collect.py`). Lane runs are shown whatever
their bead; a lane with a `released` run is hidden (count in the Lanes footer).
pf-task lookups are ordered no-driver first, never-checked first, newest status
first, so the lanes most likely to be real handbacks are checked first and the
rest round-robin across refreshes.

## Classification

A lane NEEDS gpu-14 when
(a) no live driver and the run is not released and the last status line is
HANDBACK / BOOT_READY / BLOCKED / IDLE / QUESTION (or CI_WAIT / WAITING with
no driver: kind `undriven`);
(b) the run is `busy` but `reconciler_alive` is false, or native activity is
older than BUSY_IDLE_ALARM_MIN (kind `stale`);
(c) a referenced PR is merge-ready (OPEN, all checks success, reviewDecision
APPROVED) with no driver (kind `merge_ready`), or merged while the lane sits
undriven (kind `handback`);
(d) a bead is in_progress, in scope, has no lane and no update or comment for
STALE_BEAD_H (kind `stale`; beads idle longer than STALE_INDIVIDUAL_H are one
aggregated item pointing at the Stale beads table).
The device queue adds kind `device` when the runner halted or is not running
with steps pending, and `stale` when a step runs longer than KIT_STUCK_H.
`dispatchable` items are ready beads whose blockers all closed within
NEWLY_UNBLOCKED_H ("newly unblocked").

Waiting legitimately (shown as "waiting (reason)", not alarmed): CI running
with a live driver, a BOOT_READY kit that is pending or running in the device
queue (matched by the 64-hex manifest sha in the status line against
`queue.tsv`), a BLOCKED lane whose named blocker bead is still open. When that
blocker closes, or the kit's result lands, the lane flips to needs.

Dispatchable = `bd ready` in scope, open, not a container type (epic, gate,
molecule, convoy), no lane. "Recent" means touched within RECENT_DAYS; the
rest is counted as backlog and listed collapsed. Chains list every open
in-scope blocker and the beads it holds (fan-out first).

## Thresholds

All constants sit at the top of `collect.py` and are echoed in `data.json`
(`thresholds`) and the page footer: LANE_LOG_WINDOW_H 72, PFTASK_BUDGET_S 150
(env `FB_PFTASK_BUDGET_S`), PFTASK_TIMEOUT_S 60, BUSY_IDLE_ALARM_MIN 45,
BUSY_NO_SIGNAL_ALARM_MIN 75, HANDBACK_WITH_DRIVER_GRACE_MIN 10, KIT_STUCK_H 3,
STALE_BEAD_H 6, STALE_INDIVIDUAL_H 24, STALE_LOOKBACK_H 168, NEWLY_UNBLOCKED_H
72, RECENT_DAYS 14, RESULTS_SHOW 10 within RESULTS_WINDOW_H 24, NEXT_SHOW 5,
PARALLEL_SHOW 40, CHAINS_SHOW 30.

## Extending

- New source: add a `collect_<x>()` returning plain dicts, call it from `main()`,
  add the key to the schema comment, render it with a `render_<x>(d)` in
  `render.py` wrapped in `section(...)`. Record failures with `err(source, e)`;
  never raise out of a collector (the board must still render).
- New needs rule: extend `classify_lanes` / `classify_device` / `classify_beads`;
  give the item a `kind` listed in `KIND_RANK` (collect) and `KIND_LABEL` /
  `KIND_SEV` (render) so it sorts and colors.
- New campaign root: append to `CAMPAIGN_ROOTS`.
- Page: tokens live on `:root` with dark overrides under
  `@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) }` and
  `:root[data-theme="dark"]`; semantic colors (`--crit/--warn/--good`) are
  separate from the accent. Rows carry `data-filter` text for the filter box;
  sections are `<details>` so they collapse without script.
- Keep the hard rules: pf-task calls are single-run `run.status` lookups,
  sequential, each with a timeout; nothing here writes to beads, pf-task, git,
  the device or any script in `/home/matt/recovery/gpu14`.

`until_pr=<owner/repo#N>` in a parked.tsv reason (2026-10-12) keeps the lane waiting while that PR is OPEN. Once it is MERGED or CLOSED, the lane raises `NEEDS_GPU14 kind=unblocked`, so a park on a PR cannot outlive the merge. Use it whenever a lane waits on someone else's PR.

### Epic-wide waits (2026-10-12)
A `waits.tsv` id ending in `.*` (for example `tsp-ihne1.*`) covers every descendant bead, which suits an owner-paused coordinator's epic. Among matching rows (exact or prefix), the freshest one wins, and the usual 24 h expiry still applies, so one row is refreshed daily rather than one per bead.
