#!/usr/bin/env bash
# gpu-14 2026-10-12: fill {{NAME}} placeholders in a QUOTED heredoc, so values can be interpolated without an unquoted
# heredoc (whose backticks execute: qdc-pub3 lost its status-line example; memory unquoted-heredoc-executes-backticks).
# usage: ./tmpl.sh <out-file> NAME=value [NAME=value ...] <<'EOF' ... {{NAME}} ... EOF
# Refuses an unfilled {{PLACEHOLDER}} and an existing output file.
set -euo pipefail
out=$1; shift
[ ! -e "$out" ] || { echo "TMPL_REFUSED reason=exists out=$out"; exit 2; }
body=$(cat)
for kv in "$@"; do k=${kv%%=*}; v=${kv#*=}; body=${body//"{{$k}}"/$v}; done
if printf '%s' "$body" | grep -qE '\{\{[A-Z0-9_]+\}\}'; then echo "TMPL_REFUSED reason=unfilled $(printf '%s' "$body" | grep -oE '\{\{[A-Z0-9_]+\}\}' | sort -u | tr '\n' ' ')"; exit 2; fi
printf '%s\n' "$body" > "$out"; echo "TMPL_OK out=$out bytes=$(wc -c < "$out")"
