#!/usr/bin/env bash
# 2026-10-13 gpu-14: ask pf-kit-window-runner whether a queue row may touch the bench (live windows, .1018.12).
# Uses the unit's own ExecStart binary and Environment/EnvironmentFile so it reads the same window root as the service.
# Prints RUN, WAIT or HALT. Anything unreadable prints HALT and exits 2 (fail closed).
set -uo pipefail
row_type=${1:?row_type}
unit=pf-kit-window-runner.service
halt() { printf 'HALT reason=%s\n' "$1"; exit 2; }
show=$(systemctl --user show "$unit" -p ExecStart -p Environment -p EnvironmentFiles -p LoadState 2>/dev/null) || halt unit_unreadable
grep -qx 'LoadState=loaded' <<<"$show" || halt unit_not_loaded
bin=$(sed -n 's/^ExecStart={ path=\([^ ;]*\).*/\1/p' <<<"$show" | head -1)
[ -x "$bin" ] || halt "runner_binary_missing:${bin:-none}"
env_line=$(sed -n 's/^Environment=//p' <<<"$show")
envs=()
for kv in $env_line; do [[ $kv == *=* ]] && envs+=("$kv"); done
while read -r ef; do
  ef=${ef%% (ignore_errors=*}; [ -n "$ef" ] && [ -f "$ef" ] || continue
  while IFS= read -r l; do [[ $l =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && envs+=("$l"); done < "$ef"
done < <(sed -n 's/^EnvironmentFiles=//p' <<<"$show")
[ -n "${WINDOW_DISPOSITION_TEST_ROOT:-}" ] && envs+=("PF_KIT_WINDOW_ROOT=$WINDOW_DISPOSITION_TEST_ROOT")  # hermetic tests only
out=$(env "${envs[@]}" timeout 30 "$bin" queue-disposition "$row_type" 2>&1); rc=$?
[ "$rc" -eq 0 ] || halt "disposition_rc_$rc:$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)"
case "$out" in RUN|WAIT|HALT) printf '%s\n' "$out" ;; *) halt "disposition_unparsed:$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-120)" ;; esac
