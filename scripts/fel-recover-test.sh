#!/usr/bin/env bash
# fel-recover-test.sh — instrumented FEL recovery-boot test on the base A133 (pf-node-01).
# Runs on the BPI (matt@10.254.16.198). Tests a PATCHED boot0 that RETURNS TO FEL after
# DRAM init (bead tsp-bcx.30), so sunxi-fel can chain spl -> write u-boot -> exe.
#
# The authoritative success signal for the return-to-FEL patch is `sunxi-fel spl` EXIT 0
# (sunxi-fel internally reads back the "eGON.FEL" header marker the thunk writes and
# pr_fatal's if the SPL did not clean-return). We ALSO grep the DUT serial to confirm DRAM
# init still runs and the vendor MMC boot-media scan ("card no is") does NOT appear.
#
# Interlock-safe: battery stays connected; worst case the SoC resets back into FEL (strap
# held). No persistent write happens here — RAM-load + execute only.
#
# Usage (on the BPI):
#   fel-recover-test.sh --boot0 boot0-patched.img [--uboot u-boot.bin] \
#                       [--monitor monitor.bin] [--scp scp.bin]
#   # --boot0 only: stop after the SPL return (proves the patch). --uboot: also hand off.
set -u

BOOT0="" UBOOT="" MONITOR="" SCP=""
ESP=/dev/ttyACM0            # base A133 ESP32 serial+FEL bridge
UBOOT_ADDR=0x4a000000
LOG=/tmp/fel-recover-serial.log
FEL_VID=1f3a

log(){ echo "[$(date -u '+%H:%M:%SZ')] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do case "$1" in
  --boot0) BOOT0="${2:?}"; shift 2;;
  --uboot) UBOOT="${2:?}"; shift 2;;
  --monitor) MONITOR="${2:?}"; shift 2;;
  --scp) SCP="${2:?}"; shift 2;;
  -h|--help) grep '^#' "$0" | sed 's/^# \?//'; exit 0;;
  *) die "unknown arg: $1";;
esac; done

[ -n "$BOOT0" ] && [ -f "$BOOT0" ] || die "--boot0 <file> required"
# eGON.BT0 magic sanity (offset 4)
[ "$(dd if="$BOOT0" bs=1 skip=4 count=8 2>/dev/null | tr -d '\0')" = "eGON.BT0" ] \
  || die "$BOOT0 lacks eGON.BT0 magic at offset 4"
command -v sunxi-fel >/dev/null || die "sunxi-fel not found"

strap_on(){ python3 -c 'import serial,time;s=serial.Serial("'"$ESP"'",115200,timeout=2);s.write(b"\x01FEL on\n");s.flush();time.sleep(0.5);print("  strap:",repr(s.read(40).decode("utf-8","replace").strip()));s.close()' 2>/dev/null || echo "  (strap cmd sent)"; }
in_fel(){ lsusb | grep -qi "$FEL_VID"; }

echo "=== 1. assert FEL strap ==="; strap_on
echo "=== 2. ensure device in FEL (cold-POR with strap held; interlock-safe) ==="
# BROM samples the FEL strap only at a real power-on-reset. pf-power cold-cycle does
# vbus-off -> batt-off -> wait -> batt-on -> vbus-on (the daemon's interlock keeps
# battery connected before VBUS), i.e. a genuine cold POR. Works from any rail state.
if ! in_fel; then
  log "not in FEL — cold-cycle POR (strap held LOW)"; pf-power cold-cycle 3000
  for i in $(seq 1 12); do sleep 2; in_fel && break; done
fi
in_fel || die "FEL_ENTRY_FAILED (no ${FEL_VID}: device on USB)"
log "in FEL: $(lsusb | grep -i "$FEL_VID")"
log "sunxi-fel version: $(sudo sunxi-fel version 2>&1)"

echo "=== 3. start DUT serial capture (background) ==="
rm -f "$LOG"
setsid bash -c 'timeout 30 python3 -c "
import serial,sys,time
s=serial.Serial(\"'"$ESP"'\",115200,timeout=1)
end=time.time()+30
while time.time()<end:
    d=s.read(256)
    if d: sys.stdout.buffer.write(d); sys.stdout.flush()
s.close()" > '"$LOG"' 2>&1' </dev/null &
sleep 1.5

echo "=== 4. sunxi-fel spl <patched boot0> — expect CLEAN RETURN (exit 0) ==="
log "running: sudo sunxi-fel spl $BOOT0"
SPL_OUT=$(sudo sunxi-fel spl "$BOOT0" 2>&1); SPL_RC=$?
echo "$SPL_OUT" | sed 's/^/    spl: /'
log "sunxi-fel spl EXIT=$SPL_RC"
sleep 2   # let boot0 finish DRAM init + return

RETURN_CLEAN=0
if [ $SPL_RC -eq 0 ]; then
  log "RESULT: sunxi-fel spl returned 0 -> boot0 CLEAN-RETURNED to FEL (eGON.FEL confirmed by sunxi-fel)"
  RETURN_CLEAN=1
else
  log "RESULT: sunxi-fel spl EXIT=$SPL_RC -> did NOT clean-return (see spl output above)"
fi
# still in FEL after a clean return?
in_fel && log "device still enumerates in FEL (expected after a clean return)" \
        || log "device left FEL (unexpected for --boot0-only)"

if [ $RETURN_CLEAN -eq 1 ] && [ -n "$UBOOT" ]; then
  echo "=== 5. hand off to U-Boot: write $UBOOT @ $UBOOT_ADDR + exe ==="
  [ -f "$UBOOT" ] || die "--uboot $UBOOT not found"
  # Optional ATF/SCP preload (some vendor u-boot needs monitor.bin/scp.bin first).
  [ -n "$MONITOR" ] && [ -f "$MONITOR" ] && { log "write monitor.bin @0x48000000"; sudo sunxi-fel write 0x48000000 "$MONITOR" 2>&1 | sed 's/^/    /'; }
  [ -n "$SCP" ] && [ -f "$SCP" ] && { log "write scp.bin @0x48100000"; sudo sunxi-fel write 0x48100000 "$SCP" 2>&1 | sed 's/^/    /'; }
  log "write u-boot @ $UBOOT_ADDR"
  sudo sunxi-fel write "$UBOOT_ADDR" "$UBOOT" 2>&1 | sed 's/^/    /'
  log "exe $UBOOT_ADDR"
  sudo sunxi-fel exe "$UBOOT_ADDR" 2>&1 | sed 's/^/    /'
  log "u-boot exec issued — watching serial"
fi

echo "=== 6. wait for serial capture window ==="; sleep 12
echo "=== 7. DUT serial (printable) ==="
if [ -s "$LOG" ]; then tr -d '\000' < "$LOG" | strings | tail -60; else echo "  (serial EMPTY)"; fi

echo "=== 8. VERDICT ==="
SER=$(tr -d '\000' < "$LOG" 2>/dev/null | strings)
DRAM_OK=0;  echo "$SER" | grep -qiE 'DRAM.*(SIZE|simple test OK)' && DRAM_OK=1
CARDNO=0;   echo "$SER" | grep -qi 'card no is' && CARDNO=1
UBOOT_SEEN=0; echo "$SER" | grep -qiE 'U-Boot 20|=>|sunxi#|Hit any key' && UBOOT_SEEN=1
echo "  spl_exit=$SPL_RC  clean_return=$RETURN_CLEAN  dram_init_seen=$DRAM_OK  card_no_scan=$CARDNO  uboot_prompt=$UBOOT_SEEN"
if [ $RETURN_CLEAN -eq 1 ] && [ $CARDNO -eq 0 ]; then
  echo "  => PATCH WORKS: boot0 inited DRAM and returned to FEL without the MMC scan."
  [ -n "$UBOOT" ] && { [ $UBOOT_SEEN -eq 1 ] && echo "  => U-BOOT HANDOFF OK." || echo "  => u-boot handoff issued but no prompt seen (may need monitor/scp, or different load addr)."; }
elif [ $CARDNO -eq 1 ]; then
  echo "  => PATCH DID NOT INTERCEPT: 'card no is' still printed (media scan ran). Re-check patch site/offset."
else
  echo "  => INCONCLUSIVE: spl_exit=$SPL_RC. If USB re-enum but non-zero exit => thunk-scratch clobber risk; consider entry-stash fallback."
fi
echo "=== END fel-recover-test ==="
