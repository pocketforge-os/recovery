#!/usr/bin/env bash
# gpu-14 2026-10-16 (owner D3 lane triage): release idle runs. Preserve ignored+untracked evidence, skip unpushed work.
set -uo pipefail
R=/home/matt/recovery/gpu14
for pair in "$@"; do
  run=${pair%%:*}; bead=${pair#*:}
  wid=$(grep -l "\"$run\"" $R/admission-*.json 2>/dev/null | head -1 | sed -E 's#.*/admission-(.*)\.json#\1#')
  [ -n "$wid" ] || wid=$bead
  skip=""
  for w in /home/matt/wt/$wid/*/; do
    [ -d "$w/.git" ] || [ -f "$w/.git" ] || continue
    if [ -z "$(git -C "$w" branch -r --contains HEAD 2>/dev/null | head -1)" ]; then skip="unpushed_head:$w"; break; fi
    paths=$(git -C "$w" status --porcelain --ignored 2>/dev/null | grep -E '^(\?\?|!!) ' | cut -c4- | grep -vE '(^|/)(__pycache__|\.pytest_cache|node_modules|target|\.mypy_cache)/?$' || true)
    if [ -n "$paths" ]; then
      d=/home/matt/recovery/$bead/preserved-$run/$(basename "$w"); mkdir -p "$d"
      (cd "$w" && printf '%s\n' "$paths" | while read -r p; do cp -a --parents "$p" "$d/" 2>/dev/null; done)
      (cd "$d" && find . -type f -print0 | xargs -0 -r sha256sum > ../$(basename "$w").SHA256SUMS)
      echo "preserved run=$run from=$w to=$d files=$(find "$d" -type f | wc -l)"
    fi
  done
  if [ -n "$skip" ]; then echo "SKIP run=$run bead=$bead reason=$skip"; continue; fi
  out=$($R/release-run.sh "$run" "$bead" 2>&1); rc=$?
  echo "RELEASE run=$run bead=$bead rc=$rc $(printf '%s' "$out" | tail -n1 | cut -c1-120)"
done
