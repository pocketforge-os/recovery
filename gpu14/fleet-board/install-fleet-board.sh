#!/usr/bin/env bash
# install-fleet-board.sh -- deploy the fleet board scripts and user units from this checkout (tsp-mc9m.41.1030.43).
#
# usage: install-fleet-board.sh --check   compare repo copies with the live ones; typed drift lines, exit 0 ok / 1 drift
#        install-fleet-board.sh --apply   install drifted/missing files (atomic rename, <file>.bak-<UTC> of each
#                                         replaced file); if anything changed: daemon-reload + restart the TIMER only
# Last line is always fleet_board_install=ok|drift|fail. Exit 2 is a usage error.
#
# The units are the gpu14/systemd/ copies, the same files gpu14/systemd/install.sh deploys (one source per unit).
# Only the files named in SCRIPTS and UNITS are ever written. Everything else in the live board dir is live-only
# data (parked.tsv, waits.tsv, data.json, needs/, window-done/, *.log, window-queue.*, cache/, lane-queue*,
# notify-on-merge.txt, close-pending.tsv, *.bak*, fleet-board*.html, velocity.json) and is never read or written.
#
# env (defaults are the live gpu-14 paths; the hermetic test redirects all three):
#   FB_LIVE_DIR  live board dir    (/home/matt/recovery/gpu14/fleet-board)
#   FB_UNIT_DIR  user unit dir     (${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user, the user manager's search path)
#   SYSTEMCTL    systemctl binary  (systemctl)
set -uo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
UNIT_SRC=$(dirname "$SRC")/systemd
LIVE=${FB_LIVE_DIR:-/home/matt/recovery/gpu14/fleet-board}
UNIT_DIR=${FB_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
TIMER=pf-fleet-board.timer
SCRIPTS=(collect.py render.py refresh.sh velocity.py)
UNITS=(pf-fleet-board.service pf-fleet-board.timer)

usage() { echo "usage: $0 --check|--apply" >&2; echo "fleet_board_install=fail reason=usage"; exit 2; }
[ $# -eq 1 ] || usage
case $1 in --check) MODE=check ;; --apply) MODE=apply ;; *) usage ;; esac

sha() { sha256sum "$1" | cut -c1-64; }

# Emit "<name> <repo path> <live path>" for every managed file.
managed() {
  local n
  for n in "${SCRIPTS[@]}"; do printf '%s %s %s\n' "$n" "$SRC/$n" "$LIVE/$n"; done
  for n in "${UNITS[@]}"; do printf '%s %s %s\n' "$n" "$UNIT_SRC/$n" "$UNIT_DIR/$n"; done
}

# drift_of <name> <repo> <live>: prints one typed drift line, or nothing when the live copy matches.
drift_of() {
  local name=$1 repo=$2 live=$3
  if [ ! -f "$repo" ]; then
    echo "fleet_board_drift kind=repo_missing file=$name repo=$repo"
  elif [ ! -f "$live" ]; then
    echo "fleet_board_drift kind=missing file=$name live=$live repo_sha256=$(sha "$repo" | cut -c1-12)"
  elif [ "$(sha "$repo")" != "$(sha "$live")" ]; then
    echo "fleet_board_drift kind=content file=$name live=$live repo_sha256=$(sha "$repo" | cut -c1-12) live_sha256=$(sha "$live" | cut -c1-12)"
  elif [ -x "$repo" ] && [ ! -x "$live" ]; then
    echo "fleet_board_drift kind=not_executable file=$name live=$live"
  fi
}

check() {
  local name repo live line n=0
  while read -r name repo live; do
    line=$(drift_of "$name" "$repo" "$live")
    [ -n "$line" ] && { echo "$line"; n=$((n + 1)); }
  done < <(managed)
  return $((n > 0))
}

if [ "$MODE" = check ]; then
  if check; then echo "fleet_board_install=ok"; exit 0; fi
  echo "fleet_board_install=drift"; exit 1
fi

fail() { echo "fleet_board_install=fail reason=$1${2:+ detail=${2@Q}}"; exit 1; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
changed=0
while read -r name repo live; do
  line=$(drift_of "$name" "$repo" "$live")
  [ -z "$line" ] && continue
  case $line in *kind=repo_missing*) echo "$line"; fail repo_missing "$name" ;; esac
  dir=$(dirname "$live")
  mkdir -p "$dir" || fail mkdir_failed "$dir"
  # Keep the live file's mode (the board dir is 0664/0775 today); a fresh file takes the repo's exec bit.
  if [ -f "$live" ]; then
    mode=$(stat -c %a "$live")
    [ -x "$repo" ] && mode=$(printf '%o' $((8#$mode | 8#111)))
    bak="$live.bak-$stamp"; i=1
    while [ -e "$bak" ]; do bak="$live.bak-$stamp.$i"; i=$((i + 1)); done   # never overwrite an earlier backup
    cp -p "$live" "$bak" || fail backup_failed "$live"
  elif [ -x "$repo" ]; then mode=755; else mode=644; fi
  tmp=$(mktemp "$dir/.$name.install.XXXXXX") || fail tmp_failed "$dir"
  if ! { cp "$repo" "$tmp" && chmod "$mode" "$tmp" && mv -f "$tmp" "$live"; }; then
    rm -f "$tmp"; fail install_failed "$live"
  fi
  echo "fleet_board_installed file=$name live=$live sha256=$(sha "$live" | cut -c1-12)${mode:+ mode=$mode}"
  changed=$((changed + 1))
done < <(managed)

if [ "$changed" -gt 0 ]; then
  "$SYSTEMCTL" --user daemon-reload || fail systemctl_failed daemon-reload
  # Restart the timer, never the service: OnActiveSec= re-arms it; the next tick runs the new scripts.
  "$SYSTEMCTL" --user restart "$TIMER" || fail systemctl_failed "restart $TIMER"
fi
check >/dev/null || fail drift_after_apply
echo "fleet_board_install=ok changed=$changed"
