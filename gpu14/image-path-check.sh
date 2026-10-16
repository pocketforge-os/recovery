#!/usr/bin/env bash
# gpu-14 2026-10-15: offline check that a raw image's rootfs carries the paths a window will execute.
# Why: batch10 (15c76b27) flashed Build 13 (default profile) for 4 GPU arms that call /opt/pocketforge/cts/bin/{glcts,
# deqp-gles3}; the CTS tree exists only in the CTS profile, so every arm was INSTRUMENT_INVALID after a 20 min flash and
# 4 boots (memory: check-the-image-profile-carries-the-feature-before-queuing-its-gate, witness 2). Package loader gates
# checked the lanes' DSOs, never the image paths the lanes call. debugfs reads the ext4 rootfs inside the raw image in ms.
# usage: image-path-check.sh <raw-image.img> <abs-path>...    (read-only)
# prints IMAGE_PATHS result=PASS|FAIL image=<file> part=<name> checked=<n> missing=<p1,p2,...>; rc 0 PASS, 1 FAIL, 2 usage.
set -uo pipefail
img=${1:?raw image}; shift
[ -f "$img" ] || { echo "IMAGE_PATHS result=ERROR reason=image_missing image=$img"; exit 2; }
[ $# -gt 0 ] || { echo "IMAGE_PATHS result=PASS image=$img checked=0 missing="; exit 0; }
read -r start pname < <(sfdisk -J "$img" 2>/dev/null | python3 -c '
import json,sys
ps=json.load(sys.stdin)["partitiontable"]["partitions"]
named=[p for p in ps if p.get("name") in ("rootfs","userdata","root")]
lin=[p for p in ps if p.get("type","").upper().startswith("0FC63DAF")]
p=(named or sorted(lin,key=lambda p:-p["size"]) or [None])[0]
print(p["start"], p.get("name","?")) if p else print("")') || true
[ -n "${start:-}" ] || { echo "IMAGE_PATHS result=ERROR reason=no_rootfs_partition image=$img"; exit 2; }
off=$((start * 512)); missing=(); n=0
for p in "$@"; do
  n=$((n + 1))
  out=$(debugfs -R "stat \"$p\"" "$img?offset=$off" 2>&1)
  case "$out" in *"Inode:"*) ;; *) missing+=("$p") ;; esac
done
m=$(IFS=,; echo "${missing[*]:-}")
if [ ${#missing[@]} -eq 0 ]; then echo "IMAGE_PATHS result=PASS image=$img part=$pname checked=$n missing="; exit 0; fi
echo "IMAGE_PATHS result=FAIL image=$img part=$pname checked=$n missing=$m"; exit 1
