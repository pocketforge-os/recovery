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
# usage: bd-close-safe.sh [--check] [--keep-for-run <run_id>]... <bead> <reason...>     (--check: report only, never close)
# 2026-10-20 (tsp-mc9m.41.995.130.3, proc-coord approved): --keep-for-run <run_id> (repeatable) closes an acceptance-met
# bead whose worktree is still owned by a NAMED unreleasable v3 run (released only at the v3 drain endgame). The named run
# stops blocking; every other unreleased/unresolved run and every unmapped set still refuse. The reason must then carry
# unreleased_run=<id> per kept run, >=1 work_in_main=<owner/repo|repo>@<40-hex> (each fetched in /home/matt/<repo> and
# checked as an ancestor of the origin default branch, fail-closed) and release_tracked_by=<bead>. The close passes
# --keep-worktree to close_gate and writes one typed_close comment per kept run on the release_tracked_by bead.
set -uo pipefail
# 2026-10-20 (tsp-mc9m.41.995.130.3): every hardcoded root is env-overridable (defaults = the live paths) so
# gpu14/tests/bd-close-safe-test.sh can run hermetically against temp roots, a fake bd and a fake pf-task.
R=${GPU14_ROOT:-/home/matt/recovery/gpu14}
WT=${BD_CLOSE_SAFE_WT_ROOT:-/home/matt/wt}
MC=${BD_CLOSE_SAFE_MC:-/home/matt/mission-control}
SRC=${BD_CLOSE_SAFE_SRC_ROOT:-/home/matt}
check=0; keep_runs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) check=1; shift ;;
    --keep-for-run) [ -n "${2:-}" ] || { echo "BD_CLOSE_SAFE_REFUSED reason=keep_for_run_missing_id"; exit 2; }; keep_runs+=("$2"); shift 2 ;;
    --keep-for-run=?*) keep_runs+=("${1#*=}"); shift ;;
    *) break ;;
  esac
done
bead=${1:?usage: bd-close-safe.sh [--check] [--keep-for-run <run_id>]... <bead> <reason...>}; shift
[ "$check" = 1 ] || [ "$#" -gt 0 ] || { echo "BD_CLOSE_SAFE_REFUSED reason=missing_close_reason"; exit 2; }
cands=$(python3 - "$R" "$bead" "$WT" <<'PY'
import json, pathlib, sys
r, bead, wt_root = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
roots = (f"{wt_root}/{bead}/", f"{wt_root}/{bead}-")
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
blocked=0; kept=()
named() { local k; for k in ${keep_runs[@]+"${keep_runs[@]}"}; do [ "$k" = "$1" ] && return 0; done; return 1; }
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
  case "$st" in
    released|superseded) ;;
    unknown) blocked=$((blocked+1)) ;;   # unreadable status is never kept, even when named
    *) if named "$run"; then kept+=("$run $wt"); echo "BD_CLOSE_SAFE kept_for_run=$run state=$st worktree=$wt"
       else blocked=$((blocked+1)); fi ;;
  esac
done <<< "$cands"
for k in ${keep_runs[@]+"${keep_runs[@]}"}; do   # a named run that owns nothing of this bead is a typo: refuse
  printf '%s\n' "$cands" | grep -q "^$k " || { echo "BD_CLOSE_SAFE_REFUSED reason=keep_for_run_not_candidate bead=$bead run=$k"; blocked=$((blocked+1)); }
done
# 2026-10-14: closing .1026.3.1 removed browser-eval's worker tree /home/matt/wt/tsp-mc9m.41.1026.3.1/runtime. Sets with
# NO gpu-14 admission are other coordinators' (invisible to worktree.inspect): refuse unless --foreign-ok names why.
mapped=$(printf '%s\n' "$cands" | awk 'NF{print $2}')
for set in "$WT"/"$bead" "$WT"/"$bead"-* "$WT"/mc-"$bead"; do
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
if [ "${#kept[@]}" -eq 0 ]; then
  [ "$check" = 1 ] && { echo "BD_CLOSE_SAFE_CHECK_OK bead=$bead"; exit 0; }
  cd "$MC" && bd close "$bead" --reason "$*"
  exit
fi
# Typed close: validate the reason tokens, then prove every work_in_main is in its origin default branch.
incomplete() { echo "BD_CLOSE_SAFE_REFUSED reason=typed_close_reason_incomplete bead=$bead $1 hint=reason needs unreleased_run=<id> per kept run, work_in_main=<owner/repo|repo>@<40-hex>, release_tracked_by=<bead>"; exit 2; }
not_in_main() { echo "BD_CLOSE_SAFE_REFUSED reason=work_not_in_main bead=$bead work_in_main=$1 detail=$2"; exit 3; }
read -ra words <<< "$*"
rels=(); wims=(); have=" ${words[*]-} "
for w in ${words[@]+"${words[@]}"}; do
  case "$w" in
    release_tracked_by=*) rels+=("${w#*=}") ;;
    work_in_main=*) [[ "$w" =~ ^work_in_main=([A-Za-z0-9._-]+/)?([A-Za-z0-9._-]+)@[0-9a-f]{40}$ ]] && [[ ! "${BASH_REMATCH[2]}" =~ ^\.+$ ]] \
                      || incomplete "malformed=$w"; wims+=("$w") ;;
  esac
done
for e in "${kept[@]}"; do case "$have" in *" unreleased_run=${e%% *} "*) ;; *) incomplete "missing=unreleased_run=${e%% *}" ;; esac; done
[ "${#wims[@]}" -gt 0 ] || incomplete "missing=work_in_main"
[ "${#rels[@]}" -eq 1 ] && [[ "${rels[0]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || incomplete "missing=release_tracked_by"
rel=${rels[0]}
for w in "${wims[@]}"; do
  spec=${w#work_in_main=}; sha=${spec##*@}; repo=${spec%@*}; repo=${repo##*/}; dir=$SRC/$repo
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || not_in_main "$spec" repo_missing
  timeout 120 git -C "$dir" fetch -q origin >/dev/null 2>&1 || not_in_main "$spec" fetch_failed
  # The default branch is read from the remote NOW: fetch never refreshes the cached refs/remotes/origin/HEAD (review #21).
  head=$(timeout 120 git -C "$dir" ls-remote --symref origin HEAD 2>/dev/null) || not_in_main "$spec" origin_head_unresolved
  b=$(printf '%s\n' "$head" | awk '$1 == "ref:" && $3 == "HEAD" {sub("^refs/heads/", "", $2); print $2; exit}')
  if [ -n "$b" ]; then def=refs/remotes/origin/$b; git -C "$dir" rev-parse -q --verify "$def" >/dev/null || not_in_main "$spec" "default_branch_not_fetched of=origin/$b"
  else for b in main master; do git -C "$dir" rev-parse -q --verify "refs/remotes/origin/$b" >/dev/null && { def=refs/remotes/origin/$b; break; }; done; fi
  [ -n "${def:-}" ] || not_in_main "$spec" no_origin_default_branch
  git -C "$dir" merge-base --is-ancestor "$sha" "$def" 2>/dev/null || not_in_main "$spec" "not_ancestor of=${def#refs/remotes/}"
  echo "BD_CLOSE_SAFE work_in_main=$spec ancestor_of=${def#refs/remotes/}"; unset def
done
kept_ids=$(printf '%s\n' "${kept[@]}" | awk '{print $1}' | paste -sd, -)
track_line() { echo "typed_close bead=$bead unreleased_run=${1%% *} worktree=${1#* } ${wims[*]}"; }
if [ "$check" = 1 ]; then
  for e in "${kept[@]}"; do echo "BD_CLOSE_SAFE_CHECK would_comment release_bead=$rel line='$(track_line "$e")'"; done
  echo "BD_CLOSE_SAFE_CHECK_OK bead=$bead keep_worktree=1 kept=$kept_ids release_tracked_by=$rel"; exit 0
fi
cd "$MC" || { echo "BD_CLOSE_SAFE_REFUSED reason=mission_control_missing dir=$MC"; exit 2; }
bd close "$bead" --keep-worktree --reason "$*" || { rc=$?; echo "BD_CLOSE_SAFE_CLOSE_FAILED bead=$bead rc=$rc"; exit "$rc"; }
track_failed=0
for e in "${kept[@]}"; do
  line=$(track_line "$e")
  if printf '%s\n' "$line" | bd comment "$rel" --stdin >/dev/null; then echo "BD_CLOSE_SAFE_TRACKED release_bead=$rel run=${e%% *}"
  else echo "BD_CLOSE_SAFE_TRACK_FAILED bead=$bead release_bead=$rel append='$line' hint=bead is CLOSED; append by hand: bd comment $rel --stdin"; track_failed=1; fi
done
[ "$track_failed" = 0 ] || exit 4
echo "BD_CLOSE_SAFE_TYPED_CLOSED bead=$bead kept=$kept_ids release_tracked_by=$rel"
