#!/usr/bin/env bash
set -euo pipefail

for proc_dir in /proc/[0-9]*; do
  pid=${proc_dir##*/}
  [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue

  [[ -r "$proc_dir/cmdline" ]] || continue
  cmdline=$(tr '\0' ' ' 2>/dev/null <"$proc_dir/cmdline") || continue
  case "$cmdline" in
    *'/home/matt/.local/share/pocketforge/pf-task/'*|*'/home/matt/.pf-task-v2/bin/pf-task'*|*'codex app-server'*|*'pf_task/mcp'*|*'pf-task-mcp'*) ;;
    *) continue ;;
  esac

  stat_line=$(<"$proc_dir/stat") || continue
  stat_rest=${stat_line#*) }
  read -r -a stat_fields <<<"$stat_rest"
  [[ ${#stat_fields[@]} -ge 20 ]] || continue
  starttime=${stat_fields[19]}
  exe=$(readlink "$proc_dir/exe" 2>/dev/null || printf '<unreadable>')
  printf '%s\t%s\t%s\t%s\n' "$pid" "$starttime" "$exe" "$cmdline"
done | sort -n
