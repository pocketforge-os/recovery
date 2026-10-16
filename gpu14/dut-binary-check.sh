#!/usr/bin/env bash
# gpu-14 (2026-10-12): verify that every absolute binary path a kit runs ON THE DUT exists in the exact image's
# root filesystem, before a boot is spent finding out. Feature-proof lost three Build 8 boots to DUT-environment
# assumptions; r5 died on `/usr/bin/jq: not found` because its smoke ran with the laptop's jq.
# usage: dut-binary-check.sh <image.img> <dut-command-text-file|->
#   Reads DUT-side command text (DutExec Command strings, payload scripts), extracts absolute paths under
#   /bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin /usr/libexec /usr/lib/pocketforge, and checks
#   each in the rootfs partition (GPT name "userdata", else the largest Linux-data partition) with debugfs.
#   Symlinks are followed one level. Output: one DUT_BINARY_CHECK line per path plus a summary line.
#   rc 0 = all present, 1 = something missing, 2 = usage/image error.
set -uo pipefail
img=${1:?image}; src=${2:?command text file or -}
[ -r "$img" ] || { echo "DUT_BINARY_CHECK_SUMMARY result=ERROR reason=image_unreadable image=$img"; exit 2; }
command -v debugfs >/dev/null || PATH=$PATH:/usr/sbin:/sbin
start=$(/sbin/sfdisk -J "$img" 2>/dev/null | python3 -c '
import json,sys
p=json.load(sys.stdin)["partitiontable"]; ss=p.get("sectorsize",512)
parts=p["partitions"]
named=[x for x in parts if x.get("name")=="userdata"]
lin=[x for x in parts if x.get("type","").upper()=="0FC63DAF-8483-4772-8E79-3D69D8477DE4"]
pick=(named or sorted(lin,key=lambda x:x["size"])[-1:])
print(pick[0]["start"]*ss if pick else "")' 2>/dev/null)
[ -n "$start" ] || { echo "DUT_BINARY_CHECK_SUMMARY result=ERROR reason=rootfs_partition_not_found image=$img"; exit 2; }
dev="$img?offset=$start"
text=$(cat -- "$src") || { echo "DUT_BINARY_CHECK_SUMMARY result=ERROR reason=commands_unreadable"; exit 2; }
paths=$(printf '%s\n' "$text" | grep -oE '(^|[^A-Za-z0-9_./-])/(usr/(local/)?)?(s?bin|libexec|lib/pocketforge)/[A-Za-z0-9._+-]+' \
  | sed -E 's#^[^/]##' | sort -u)
lookup() {  # prints present|missing|symlink:<dest>
  local out; out=$(timeout 20 debugfs -R "stat $1" "$dev" 2>&1 | grep -vE '^debugfs [0-9]')
  case "$out" in *"File not found"*|*"not found by ext2_lookup"*) echo missing ;;
    *"Type: symlink"*) printf 'symlink:%s\n' "$(printf '%s\n' "$out" | sed -nE 's/^Fast link dest: "(.*)"$/\1/p' | head -n1)" ;;
    Inode*) echo present ;; *) echo "error" ;; esac
}
n=0; miss=0
for p in $paths; do
  n=$((n+1)); st=$(lookup "$p")
  case "$st" in
    symlink:*) d=${st#symlink:}; case "$d" in /*) t=$d ;; "") t="" ;; *) t="$(dirname "$p")/$d" ;; esac
      if [ -n "$t" ] && [ "$(lookup "$t")" != missing ]; then st=present; else st=missing; fi ;;
  esac
  [ "$st" = present ] || miss=$((miss+1))
  echo "DUT_BINARY_CHECK path=$p state=$st"
done
res=PASS; [ "$miss" -eq 0 ] || res=FAIL
echo "DUT_BINARY_CHECK_SUMMARY result=$res checked=$n missing=$miss image=$img rootfs_offset=$start"
[ "$res" = PASS ]
