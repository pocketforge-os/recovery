# FEL Entry Procedure — TrimUI Smart Pro (Allwinner A133P)

FEL is a BROM-level USB recovery protocol built into every Allwinner SoC.
It survives any corrupted bootloader because it lives in mask ROM.

**USB ID:** `1f3a:efe8`
**SoC ID:** `0x1855` (A133)
**SPL address:** `0x20000`

## Entry Methods

### Method 1: BROM auto-fallthrough (no bootable media)

The BROM scans boot media in this order:

1. Check FEL key/pin (the FEL pads — see Method 2)
2. SD card (SMHC0) at sector 16 (8 KiB), then sector 256 (128 KiB)
3. eMMC (SMHC2): boot partitions (if enabled in EXT_CSD), then user area at sector 16 / sector 256
4. SPI NOR Flash (SPI0)
5. **FEL mode** (USB-OTG)

If ALL boot media fail to present a valid `eGON.BT0` header, the BROM
enters FEL mode automatically. The device enumerates as USB ID `1f3a:efe8`.

**For the TrimUI Smart Pro specifically:**
- The vendor boot chain lives on the **eMMC user area** (sector 16 onward),
  NOT the eMMC hardware boot partitions (mmcblk0boot0/boot1 are empty/all-zeros).
- This means the BROM will always find a bootable eMMC unless the eGON headers
  on the eMMC user area are corrupted — which we must NOT do (that's the stock OS safety net).
- **Practical consequence:** you cannot reach FEL by removing the SD card alone.
  The BROM will find the eMMC boot chain and boot stock CrossMix.

### Method 2: FEL pads on the PCB (hardware force)

The TrimUI Smart Pro PCB has **unpopulated pads** for a FEL button on the
bottom of the board. Shorting these pads while applying power forces the
BROM to skip all boot media and enter FEL mode immediately.

**Procedure:**
1. Power off the device completely (hold power button until off, wait 5 seconds).
2. Remove the SD card (recommended — simplifies the test).
3. Connect a USB-OTG cable from the device's USB-C port to the host machine.
4. Locate the FEL pads on the bottom of the PCB (two tinned pads, usually
   near the SD card slot or at the board edge — see the
   [linux-sunxi TrimUI Smart Pro page](https://linux-sunxi.org/TRIMUI_Smart_Pro)
   for photographs).
5. Short the two pads with a wire, tweezers, or conductive probe.
6. While holding the short, press the power button.
7. The device should NOT display anything on screen (the BROM entered FEL
   before the display driver loaded).
8. On the host, run: `lsusb -d 1f3a:efe8` — if the device appears, FEL is active.
9. Release the pad short.

**Important notes:**
- The FEL pads are on the **bottom** of the PCB. This requires opening the case.
- There is NO software "Flash mode" menu in stock CrossMix on the TG5040 unit
  (the linux-sunxi wiki claim about "Settings > System > Flash mode" was not
  reproducible on the 2026-06-11 probe; stock has only `/usr/bin/reboot`).
- FEL entry is **hardware/BROM-level only** on this device.

### Method 3: Serial console U-Boot intervention (if console is connected)

If you have a USB-UART adapter connected to the UART0 pads and can catch
the U-Boot prompt (typically a 1-2 second window during boot):

1. Boot the device with serial console connected (115200 8N1).
2. Press a key during the "Hit any key to stop autoboot" window.
3. At the `=>` U-Boot prompt, run: `run boot_fastboot`
4. This enters Android fastboot mode (NOT FEL), but it does prove the serial
   console path works. FEL is more useful for recovery because it's BROM-level.

**Note:** This method requires the device to successfully load U-Boot from
a bootable medium, so it does NOT work when the boot chain is completely
corrupted. Use Method 1 or 2 for those cases.

## Verifying FEL Mode

Once the device is in FEL mode:

```bash
# Check USB enumeration
lsusb -d 1f3a:efe8

# Verify sunxi-fel communication
sunxi-fel ver
# Expected output: AWUSBFEX soc=00001855(A133) ...

# Read SoC information
sunxi-fel soc-info
```

## Recovery from FEL

Once in FEL mode, you can push a bootloader over USB:

```bash
# Push SPL (boot0.img) — this initializes DRAM
sunxi-fel spl boot0.img

# Wait for DRAM init, then push U-Boot
sleep 3
sunxi-fel write 0x4a000000 u-boot.bin
sunxi-fel exe 0x4a000000
```

Or use the provided wrapper:

```bash
./scripts/fel-boot.sh --boot0 boot0.img --uboot u-boot.bin
```

## The Self-Recovery Path (SD-only, no FEL needed)

For normal PocketForge development, FEL is rarely needed because:

1. **PocketForge runs entirely from the SD card.**
2. **Stock CrossMix runs from internal eMMC.**
3. **A bricked SD is self-recovering: remove the card, and the device boots stock from eMMC.**

FEL is the last-resort safety net for scenarios where the eMMC itself is
corrupted — which PocketForge Phase 1 never does (no writes to `/dev/mmcblk0*`).

The typical recovery path is simply: pull the SD card, reflash it on the host
machine, re-insert, and boot.

## Host Prerequisites

- **sunxi-tools** installed: `sudo apt install sunxi-tools` (Debian/Ubuntu)
  - Verified version: 1.4.2 (provides `sunxi-fel` with A133 support)
- **USB-OTG cable** connected from host to device USB-C port
- **udev rule** (optional, for non-root access):
  ```
  # /etc/udev/rules.d/99-allwinner-fel.rules
  SUBSYSTEM=="usb", ATTR{idVendor}=="1f3a", ATTR{idProduct}=="efe8", \
    MODE="0666", GROUP="plugdev", SYMLINK+="allwinner-fel"
  ```
