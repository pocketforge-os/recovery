#!/usr/bin/env bash
# gpu-14 2026-10-16 (owner D3 lane triage): release idle runs. Preserve ignored+untracked evidence, skip unpushed work.
set -uo pipefail
R=${GPU14_ROOT:-/home/matt/recovery/gpu14}; WT=${BR_WT_ROOT:-/home/matt/wt}; PRES=${BR_PRESERVE_ROOT:-/home/matt/recovery}; REL=${BR_RELEASE:-$R/release-run.sh}
for pair in "$@"; do
  run=${pair%%:*}; bead=${pair#*:}
  wid=$(grep -l "\"$run\"" $R/admission-*.json 2>/dev/null | head -1 | sed -E 's#.*/admission-(.*)\.json#\1#')
  [ -n "$wid" ] || wid=$bead
  skip=""
  for w in "$WT/$wid"/*/; do
    [ -d "$w/.git" ] || [ -f "$w/.git" ] || continue
    if [ -z "$(git -C "$w" branch -r --contains HEAD 2>/dev/null | head -1)" ]; then skip="unpushed_head:$w"; break; fi
    # proc-coord 2026-10-17 (recovery#13 review): fail closed. NUL-separated status; tracked changes (modified, deleted,
    # staged, renamed) are never released; any status or copy failure skips the release.
    st=$(mktemp); if ! git -C "$w" status --porcelain=v1 -z --ignored > "$st" 2>/dev/null; then rm -f "$st"; skip="git_status_failed:$w"; break; fi
    tracked=$(tr '\0' '\n' < "$st" | grep -cvE '^(\?\?|!!) |^$' || true)
    if [ "$tracked" -gt 0 ]; then rm -f "$st"; skip="tracked_changes:$tracked:$w"; break; fi
    d=$PRES/$bead/preserved-$run/$(basename "$w"); cpfail=0; ncp=0
    while IFS= read -r -d '' e; do
      p=${e:3}
      case "$p" in */) p=${p%/} ;; esac
      [[ $p =~ (^|/)(__pycache__|\.pytest_cache|node_modules|target|\.mypy_cache)$ ]] && continue
      mkdir -p "$d" && (cd "$w" && cp -a --parents -- "$p" "$d/") || { cpfail=$((cpfail+1)); continue; }
      ncp=$((ncp+1))
    done < "$st"; rm -f "$st"
    if [ "$cpfail" -gt 0 ]; then skip="preserve_copy_failed:$cpfail:$w"; break; fi
    if [ "$ncp" -gt 0 ]; then
      (cd "$d" && find . -type f -print0 | xargs -0 -r sha256sum > "../$(basename "$w").SHA256SUMS") || { skip="preserve_hash_failed:$w"; break; }
      echo "preserved run=$run from=$w to=$d entries=$ncp files=$(find "$d" -type f | wc -l)"
    fi
  done
  if [ -n "$skip" ]; then echo "SKIP run=$run bead=$bead reason=$skip"; continue; fi
  out=$("$REL" "$run" "$bead" 2>&1); rc=$?
  echo "RELEASE run=$run bead=$bead rc=$rc $(printf '%s' "$out" | tail -n1 | cut -c1-120)"
done
