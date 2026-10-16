#!/usr/bin/env bash
# gpu-14 2026-10-11: generalized from tsp-mc9m.41.1017/materialize-build7-image.sh (Build 7 CTS variant needed the same).
# usage: materialize-image.sh laptop|node <raw_sha256> <raw_bytes> <store_url> <dir> [ImageSource.json to copy beside it]
# Idempotent: an existing file with the exact size + sha256 is accepted; otherwise fetch the content-addressed store
# object, decompress to .part, verify size + sha256, then mv atomically. Refuses on low space or mismatch.
# Writes only under <dir> (which must be under /home/matt/recovery/); no device, relay, PSU or labgrid action.
set -euo pipefail
[ $# -ge 5 ] || { echo "usage: $0 laptop|node <raw_sha256> <raw_bytes> <url> <dir> [descriptor]" >&2; exit 2; }
WHERE=$1 SHA=$2 BYTES=$3 URL=$4 DIR=$5 DESC=${6:-}
[[ $SHA =~ ^[0-9a-f]{64}$ && $BYTES =~ ^[0-9]+$ && $URL == http://10.0.40.90:8790/artifacts/sha256/* ]] || { echo "MATERIALIZE_REFUSED reason=bad_args"; exit 2; }
case "$DIR" in /home/matt/recovery/?*) ;; *) echo "MATERIALIZE_REFUSED reason=dir_outside_recovery dir=$DIR"; exit 2 ;; esac
read -r -d '' BODY <<'REMOTE' || true
set -euo pipefail
sha=$1 bytes=$2 url=$3 dir=$4
mkdir -p "$dir"
if [ -f "$dir/Image.img" ] && [ "$(stat -c %s "$dir/Image.img")" = "$bytes" ] && [ "$(sha256sum "$dir/Image.img" | cut -d' ' -f1)" = "$sha" ]; then
  echo "MATERIALIZE ok=already_present host=$(hostname) path=$dir/Image.img sha256=$sha bytes=$bytes"; exit 0
fi
avail=$(df --output=avail -B1 "$dir" | tail -1)
need=$((bytes + 1073741824))
[ "$avail" -gt "$need" ] || { echo "MATERIALIZE_REFUSED host=$(hostname) reason=insufficient_space avail=$avail need=$need"; exit 3; }
rm -f "$dir/Image.img.part"
curl -fsS --max-time 1200 "$url" | xz -dc > "$dir/Image.img.part"
got_b=$(stat -c %s "$dir/Image.img.part"); got_s=$(sha256sum "$dir/Image.img.part" | cut -d' ' -f1)
if [ "$got_b" != "$bytes" ] || [ "$got_s" != "$sha" ]; then rm -f "$dir/Image.img.part"; echo "MATERIALIZE_REFUSED host=$(hostname) reason=identity_mismatch bytes=$got_b sha256=$got_s"; exit 3; fi
mv "$dir/Image.img.part" "$dir/Image.img"
echo "MATERIALIZE ok=fetched host=$(hostname) path=$dir/Image.img sha256=$got_s bytes=$got_b"
REMOTE
case "$WHERE" in
  laptop) bash -c "$BODY" _ "$SHA" "$BYTES" "$URL" "$DIR"
          if [ -n "$DESC" ]; then jq -e --arg s "$SHA" '.RawSHA256 == $s' "$DESC" >/dev/null && install -m 0644 "$DESC" "$DIR/ImageSource.json" && echo "DESCRIPTOR ok path=$DIR/ImageSource.json sha256=$(sha256sum < "$DIR/ImageSource.json" | cut -c1-64)"; fi ;;
  node)   ssh -o BatchMode=yes -o ConnectTimeout=10 matt@pf-node-01.lan bash -s -- "$SHA" "$BYTES" "$URL" "$DIR" <<<"$BODY" ;;
  *) echo "usage: $0 laptop|node ..." >&2; exit 2 ;;
esac
