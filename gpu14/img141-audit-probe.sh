#!/usr/bin/env bash
set -euo pipefail
fail() { echo "REFUSED: $*"; exit 1; }
source tests/session-authority-systemd/docker-argv-audit.sh
run_label=org.pocketforge.session-authority-run=x; systemd_container=c; test_image=img:t
ephemeral_admitted=1; docker_run_profile=owner-exception; allow_full_cache_prune=0
base=(run --detach --tty --name c --label "$run_label" --cgroupns=private --network=none
  --tmpfs '/run:rw,nosuid,nodev,mode=755' --tmpfs '/run/lock:rw,nosuid,nodev,mode=755'
  --security-opt apparmor=unconfined --cap-add SYS_ADMIN)
tail=(img:t /usr/local/libexec/remount-cgroup-systemd)
case "$1" in
  base) audit_docker_argv "${base[@]}" "${tail[@]}" ;;
  *) extra=("${@:2}"); audit_docker_argv "${base[@]}" "${extra[@]}" "${tail[@]}" ;;
esac
echo ADMITTED
