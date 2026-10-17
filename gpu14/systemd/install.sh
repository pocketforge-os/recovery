#!/usr/bin/env bash
# proc-coord 2026-10-17 (tsp-mc9m.41.1030, owner D5 = A): install the zero-LLM report units on the coordinator laptop.
# pf-fleet-board.timer regenerates the fleet board every 15 min (no model turns); pf-reports-http serves ~/pf-reports
# on 127.0.0.1:8765; tailscale serve publishes that port on the tailnet only (https://<host>.<tailnet>.ts.net/board.html).
# pf-shared-refresh.timer fast-forwards the shared code checkouts every 5 min (ff-only, clean-only; the PATH tools and
# worktree bases were 32-340 commits stale with the refresh hook opt-in). Idempotent. usage: install.sh [--no-tailscale]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd)
dst=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
# The units name the coordinator's gpu14 root by absolute path; install only from that checkout, and provision the
# runtime directories refresh.sh writes into (recovery#15 review: a clean checkout has no fleet-board/cache).
want=$(sed -n 's#^ExecStart=/usr/bin/flock -n \(.*\)/fleet-board/\.refresh\.lock .*#\1#p' "$here/pf-fleet-board.service")
[ "$root" = "$want" ] || { echo "install.sh: refusing: units expect gpu14 root $want, this checkout is $root" >&2; exit 2; }
[ -x "$root/fleet-board/refresh.sh" ] || { echo "install.sh: refusing: $root/fleet-board/refresh.sh missing or not executable" >&2; exit 2; }
mkdir -p "$dst" "$HOME/pf-reports" "$root/fleet-board/cache"
for u in pf-fleet-board.service pf-fleet-board.timer pf-reports-http.service pf-shared-refresh.service pf-shared-refresh.timer; do
  install -m 0644 "$here/$u" "$dst/$u"
done
systemctl --user daemon-reload
systemctl --user enable --now pf-reports-http.service pf-fleet-board.timer pf-shared-refresh.timer
# Serving a port (not a file path) avoids needing root; the tailnet operator must be this user (tailscale set --operator).
[ "${1:-}" = --no-tailscale ] || tailscale serve --bg 8765
systemctl --user --no-pager status pf-reports-http.service pf-fleet-board.timer pf-shared-refresh.timer | grep -E '^\S|Active:'
