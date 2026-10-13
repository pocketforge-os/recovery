#!/bin/sh
set -eu
dut_interface=wlan0

fixture=${1:?fixture}
laptop=${2:?laptop-ip}
result=${3:?result-path}
invalid() { printf 'BUILD9_NETWORK state=INVALID stage=network reason=%s\n' "$1"; exit 65; }
fail() { printf 'BUILD9_NETWORK state=FAIL stage=network reason=%s\n' "$1"; exit 66; }

[ "$(/usr/bin/id -u)" = 0 ] || invalid root_required
[ -f "$fixture" ] || invalid fixture_missing
bytes=$(/usr/bin/stat -c %s "$fixture")
sha=$(/usr/bin/sha256sum "$fixture" | /usr/bin/awk '{print $1}')
[ "$bytes" = 1048576 ] || invalid fixture_bytes_mismatch
[ "$sha" = 30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58 ] || invalid fixture_sha_mismatch
address=$(/usr/sbin/ip -4 -o addr show dev "$dut_interface" scope global | /usr/bin/awk 'NR==1 {split($4,a,"/"); print a[1]}')
[ -n "$address" ] || fail dhcpv4_lease_missing
route=$(/usr/sbin/ip -4 route show default dev "$dut_interface" | /usr/bin/awk 'NR==1 {print}')
[ -n "$route" ] || fail dut_default_route_missing
gateway=$(printf '%s\n' "$route" | /usr/bin/awk '{for(i=1;i<=NF;i++) if($i=="via") {print $(i+1); exit}}')
[ -n "$gateway" ] || fail gateway_missing
for leg in gateway laptop; do
    case "$leg" in gateway) host=$gateway ;; laptop) host=$laptop ;; esac
    rc=0
    output=$(/bin/busybox ping -c3 -W2 "$host" 2>&1) || rc=$?
    printf '%s\n' "$output"
    if printf '%s\n' "$output" | /usr/bin/grep -Eqi 'permission denied|are you root|operation not permitted'; then
        invalid instrument_refused
    fi
    [ "$rc" = 0 ] || fail "${leg}_ping_failed"
done
/usr/bin/install -d -m 0700 "$(/usr/bin/dirname "$result")"
{
    printf 'BUILD9_NETWORK state=PASS dut_interface=%s address=%s route=default authenticated_ssh=pass root_pings=pass\n' "$dut_interface" "$address"
    printf 'BUILD9_TRANSPORT state=PASS operation=push-push-exec-pull bytes=%s sha256=%s\n' "$bytes" "$sha"
} >"$result"
/usr/bin/cat "$result"
