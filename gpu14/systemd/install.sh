#!/usr/bin/env bash
# proc-coord 2026-10-17 (tsp-mc9m.41.1030, owner D5 = A): install the zero-LLM report units on the coordinator laptop.
# pf-fleet-board.timer regenerates the fleet board every 15 min (no model turns); pf-reports-http serves ~/pf-reports
# on 127.0.0.1:8765; tailscale serve publishes that port on the tailnet only (https://<host>.<tailnet>.ts.net/board.html).
# Idempotent. usage: install.sh [--no-tailscale]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dst=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
mkdir -p "$dst" "$HOME/pf-reports"
for u in pf-fleet-board.service pf-fleet-board.timer pf-reports-http.service; do
  install -m 0644 "$here/$u" "$dst/$u"
done
systemctl --user daemon-reload
systemctl --user enable --now pf-reports-http.service pf-fleet-board.timer
# Serving a port (not a file path) avoids needing root; the tailnet operator must be this user (tailscale set --operator).
[ "${1:-}" = --no-tailscale ] || tailscale serve --bg 8765
systemctl --user --no-pager status pf-reports-http.service pf-fleet-board.timer | grep -E '^\S|Active:'
