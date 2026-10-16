#!/usr/bin/env bash
# gpu-14 stopgap for tsp-mc9m.41.984.49.11 (fix merged as #1169, not yet deployed to the v2 home).
# A Codex run blocked with child_processes_after_turn leaves the app-server's cua-repl JS
# kernel children alive under a non-reaping node_repl. This kills ONLY those leftovers, and ONLY
# for processes whose cwd is inside the given worker worktree root.
# usage: clear-turn-children.sh <worktree-root> [--dry-run]
set -u
root=${1:?worktree root}; dry=${2:-}
case "$root" in /home/matt/wt/?*) ;; *) echo "REFUSE root_not_under_wt $root"; exit 2;; esac
killed=0
for p in $(ls /proc | /usr/bin/grep -E '^[0-9]+$'); do
  c=$(readlink "/proc/$p/cwd" 2>/dev/null) || continue
  case "$c" in "$root"|"$root"/*) ;; *) continue;; esac
  cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
  case "$cmd" in */cua_node/bin/node_repl*) ;; *) continue;; esac
  pp=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
  pcmd=$(tr '\0' ' ' < "/proc/$pp/cmdline" 2>/dev/null)
  case "$pcmd" in *cua-repl.mjs*) ;; *) continue;; esac   # only the cua-repl-owned node_repl
  for k in $(ps -o pid= --ppid "$p" 2>/dev/null); do
    kc=$(tr '\0' ' ' < "/proc/$k/cmdline" 2>/dev/null)
    case "$kc" in *kernel.js*|*trusted-worker.js*|*"codex app-server --listen stdio://"*|"")
      echo "leftover pid=$k parent=$p cmd=${kc:0:100}"
      [ "$dry" = --dry-run ] || { kill -9 "$k" 2>/dev/null; killed=$((killed+1)); } ;;
    esac
  done
  echo "node_repl pid=$p (parent cua-repl $pp)"
  [ "$dry" = --dry-run ] || { kill "$p" 2>/dev/null; killed=$((killed+1)); }
done
echo "cleared=$killed root=$root"
