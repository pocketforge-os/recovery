#!/usr/bin/env bash
# 2026-10-14 fix from tsp-f3fm (adopted by gpu-14 after reproducing (a)): legacy ~/.pf-task run.status reports state at .blocker.state, not .state; the original read only
# .state, and pipefail made the v2 miss read "unknown\nunknown" so the legacy fallback never ran; every released LEGACY run counted as unreleased (BD_CLOSE_SAFE_REFUSED on tsp-f3fm.244). Fix sent to gpu-14.
# gpu-14 2026-10-13: bd close's close_gate REMOVES the bead's worktree sets (/home/matt/wt/<bead>/<repo>, not only
# mc-<bead>). Closing tsp-mc9m.41.1018.12.6 removed the worktree of rdp run pft-7637b9a7, which was still
# awaiting_release; pf-task cannot release a run whose worktree is gone, so the tree had to be recreated by hand.
# This wrapper refuses the close while any NON-released gpu-14 run's worktree lies under /home/matt/wt/<bead>/ or
# /home/matt/wt/<bead>-<suffix>/, or while such a run's task is the bead itself.
# Coverage: runs gpu-14 admitted (admission-*.json <-> run-*.json pairs in this dir). Other coordinators' runs are not
# visible here (pf-task worktree.inspect is role_refused for coordinator/observer/owner-admin).
# usage: bd-close-safe.sh [--check] <bead> <reason...>     (--check: report only, never close)
set -uo pipefail
R=/home/matt/recovery/gpu14
check=0; [ "${1:-}" = --check ] && { check=1; shift; }
bead=${1:?usage: bd-close-safe.sh [--check] <bead> <reason...>}; shift
[ "$check" = 1 ] || [ "$#" -gt 0 ] || { echo "BD_CLOSE_SAFE_REFUSED reason=missing_close_reason"; exit 2; }
cands=$(python3 - "$R" "$bead" <<'PY'
import json, pathlib, sys
r, bead = pathlib.Path(sys.argv[1]), sys.argv[2]
roots = (f"/home/matt/wt/{bead}/", f"/home/matt/wt/{bead}-")
seen = set()
for adm in sorted(r.glob("admission-*.json")):
    run_file = r / ("run-" + adm.name[len("admission-"):])
    try:
        run_id = json.loads(adm.read_text()).get("run_id")
        spec = json.loads(run_file.read_text())
    except Exception:
        continue
    wt, task = str(spec.get("worktree") or ""), spec.get("task")
    if run_id and run_id not in seen and (wt.startswith(roots) or task == bead):
        seen.add(run_id)
        print(run_id, wt or "-", task or "-")
PY
)
blocked=0
while read -r run wt task; do
  [ -n "$run" ] || continue
  if ! resolved_home=$("$R/pf-task-run-home" resolve "$run" --format shell); then
    echo "BD_CLOSE_SAFE run=$run state=unresolved task=$task worktree=$wt"; blocked=$((blocked+1)); continue
  fi
  eval "$resolved_home"
  st=$(timeout 100 "$PFT" --home "$H" --role coordinator run.status "{\"run_id\":\"$run\"}" 2>/dev/null \
       | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("state") or (d.get("blocker") or {}).get("state") or "unknown")' 2>/dev/null || echo unknown)
  st=$(printf '%s\n' "$st" | head -n1)
  echo "BD_CLOSE_SAFE run=$run state=$st task=$task worktree=$wt"
  case "$st" in released|superseded) ;; *) blocked=$((blocked+1)) ;; esac
done <<< "$cands"
# 2026-10-14: closing .1026.3.1 removed browser-eval's worker tree /home/matt/wt/tsp-mc9m.41.1026.3.1/runtime. Sets with
# NO gpu-14 admission are other coordinators' (invisible to worktree.inspect): refuse unless --foreign-ok names why.
mapped=$(printf '%s\n' "$cands" | awk 'NF{print $2}')
for set in /home/matt/wt/"$bead" /home/matt/wt/"$bead"-* /home/matt/wt/mc-"$bead"; do
  [ -e "$set" ] || continue
  if ! printf '%s\n' "$mapped" | grep -q "^$set/"; then
    if [ -z "${BD_CLOSE_FOREIGN_OK:-}" ]; then
      echo "BD_CLOSE_SAFE_REFUSED reason=unmapped_worktree_set bead=$bead set=$set hint=ask the owning coordinator to release it or confirm; rerun with BD_CLOSE_FOREIGN_OK='<who confirmed>'"
      blocked=$((blocked+1))
    else
      echo "BD_CLOSE_SAFE foreign_set_ok='$BD_CLOSE_FOREIGN_OK' set=$set"
    fi
  fi
done
if [ "$blocked" -gt 0 ]; then
  echo "BD_CLOSE_SAFE_REFUSED reason=unreleased_run_owns_bead_worktree bead=$bead count=$blocked hint=release each run with release-run.sh (read rc) first"
  exit 3
fi
[ "$check" = 1 ] && { echo "BD_CLOSE_SAFE_CHECK_OK bead=$bead"; exit 0; }
cd /home/matt/mission-control && bd close "$bead" --reason "$*"
