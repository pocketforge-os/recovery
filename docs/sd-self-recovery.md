# SD Self-Recovery — How It Works

## The Safety Model

PocketForge's SD-boot design is inherently self-recovering:

```
                                    +-----------------+
                                    |  Allwinner A133 |
                                    |      BROM       |
                                    +--------+--------+
                                             |
                                    Check FEL pads?
                                             |
                                    (no) ----+
                                             |
                              +------  SD card present?
                              |              |
                              |         (yes, valid SPL)
                              |              |
                              |     Boot PocketForge from SD
                              |
                    (no, or invalid SPL)
                              |
                      eMMC valid SPL?
                              |
                         (yes, always)
                              |
                    Boot stock CrossMix from eMMC
                              |
                     Device works normally
```

## Key Properties

1. **Stock eMMC is never modified.** PocketForge Phase 1 performs zero writes
   to `/dev/mmcblk0*` (the internal eMMC). The stock CrossMix boot chain and
   rootfs remain intact.

2. **SD corruption is self-recovering.** If the SD card's SPL is corrupted,
   the BROM simply skips it and boots from eMMC. The user sees stock CrossMix
   and can reflash the SD on a host machine.

3. **FEL is the last-resort safety net** for the (Phase 1: impossible) scenario
   where eMMC itself is corrupted. It survives in mask ROM and cannot be
   bricked by any software operation.

## The Corrupt-and-Recover Test

This test proves the self-recovery path works:

### Phase 1: Establish baseline
- SD card with a known-good boot chain (eGON.BT0 at sector 256) is inserted.
- Device boots from SD (or from eMMC if the SD has no PocketForge image yet).

### Phase 2: Corrupt the SD
- Zero the eGON.BT0 region on the SD card (sector 256, 32 KiB).
- Insert the corrupted SD card.

### Phase 3: Verify boot failure + self-recovery
- Power on the device.
- **Expected:** the BROM finds no valid SPL on the SD, skips it, and boots
  from the eMMC (stock CrossMix). The serial console shows the eMMC boot
  chain loading (eGON.BT0 from eMMC sector 16, U-Boot, stock kernel).
- **This IS the self-recovery:** the device boots normally despite the
  corrupted SD.

### Phase 4: Restore the SD
- Remove the SD card.
- On the host machine, re-write the SPL to sector 256.
- Re-insert the SD card.
- Device boots from SD again.

### What this test proves
- The BROM correctly falls through from a corrupted SD to a valid eMMC.
- Stock CrossMix is unaffected by the PocketForge SD card.
- The recovery is as simple as "pull the card."
- No FEL, no case opening, no special tools needed for SD-level recovery.
