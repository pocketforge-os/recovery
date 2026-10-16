#!/usr/bin/env bash
# gpu-14 2026-10-11: append a timestamped note to the current RESUME file from STDIN only.
# Why: an unquoted heredoc used to get $(date -u) also executed `Login incorrect` (backticks) and dropped it from the
# note (witness #5 of unquoted-heredoc-executes-backticks). Use:  resume-note.sh <<'EOF' ... EOF  (quoted delimiter).
# The stamp comes from the clock here; a body line starting with a typed ISO time is refused (stamp-from-the-clock).
set -euo pipefail
F=${RESUME_FILE:-/home/matt/recovery/gpu14/RESUME.md}
# 2026-10-14: a call with the note as an ARGUMENT and a socket on stdin hung `cat` for 14 h (task bfvuk8r7z).
# Refuse arguments, and refuse any stdin that is not a pipe or regular file, instead of blocking.
[ $# -eq 0 ] || { echo "RESUME_NOTE_REFUSED reason=args_given hint=pipe_the_note_on_stdin_with_a_quoted_heredoc"; exit 2; }
[ -p /dev/stdin ] || [ -f /dev/stdin ] || { echo "RESUME_NOTE_REFUSED reason=stdin_not_pipe_or_file"; exit 2; }
body=$(cat)
[ -n "$body" ] || { echo "RESUME_NOTE_REFUSED reason=empty_body"; exit 2; }
if printf '%s\n' "$body" | head -1 | grep -qE '^-? *20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}'; then echo "RESUME_NOTE_REFUSED reason=typed_timestamp hint=the script stamps the clock"; exit 2; fi
{ printf '\n## NOTE %s\n' "$(date -u +%FT%TZ)"; printf '%s\n' "$body"; } >> "$F"
echo "RESUME_NOTE ok file=$F lines=$(printf '%s\n' "$body" | wc -l)"
