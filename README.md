# PocketForge Recovery

FEL unbrick and flashing host tooling for the TrimUI Smart Pro (Allwinner A133P, USB ID `1f3a:efe8`).

## Safety Model

PocketForge boots entirely from SD card. Stock CrossMix lives on internal eMMC untouched.
**A bricked SD is self-recovering: remove the card, and the device boots stock from eMMC.**

FEL (BROM-level USB recovery) is the last-resort safety net for the scenario where eMMC
itself is corrupted — which PocketForge Phase 1 never does.

```
Boot priority (Allwinner A133 BROM):
  1. FEL pads shorted?  --> FEL mode (USB 1f3a:efe8)
  2. SD card valid SPL? --> Boot from SD (PocketForge)
  3. eMMC valid SPL?    --> Boot from eMMC (stock CrossMix)
  4. SPI NOR Flash?     --> (not present on TSP)
  5. Nothing bootable   --> FEL mode (USB 1f3a:efe8)
```

## Scripts

All scripts live in `scripts/` and refuse to write to eMMC (`mmcblk0`) by default.

| Script | Purpose |
|--------|---------|
| `check-fel.sh` | Detect a FEL device (USB `1f3a:efe8`); exits 0 if found. Supports `--wait N` for polling. |
| `restore-sd.sh` | Write a PocketForge boot chain onto an SD card (`--boot0` for SPL only, `--image` for full image). |
| `corrupt-sd-spl.sh` | Deliberately corrupt the SPL on an SD card for testing. Supports `--backup`. |
| `fel-boot.sh` | Push SPL + U-Boot to a device in FEL mode over USB-OTG. RAM-only — nothing persistent. |
| `run-sd-recovery-test.sh` | End-to-end corrupt-and-recover test with transcript logging. |
| `common.sh` | Shared constants and helpers (sourced by other scripts). |

### eMMC Write Protection

Every script that takes a `--device` argument **refuses `mmcblk0`** (internal eMMC) by default.
To override (you almost certainly should not):

```bash
./scripts/restore-sd.sh --device /dev/mmcblk0 --touch-emmc=YES_I_KNOW_WHAT_IM_DOING --boot0 ...
```

This is code-level enforcement of the "FEL needed only before eMMC writes" scope.

## FEL Entry

See [docs/fel-entry.md](docs/fel-entry.md) for the full procedure. Summary:

- **No software "Flash mode" menu** exists in stock CrossMix (the linux-sunxi wiki claim
  was not reproducible on the TG5040 probed 2026-06-11; stock has only `/usr/bin/reboot`).
- **FEL entry is hardware/BROM-level only:**
  1. Short the FEL pads on the bottom of the PCB while pressing power (requires opening the case).
  2. BROM auto-fallthrough when no bootable medium is present.
- The vendor boot chain lives on the **eMMC user area** (sector 16), NOT the eMMC hardware
  boot partitions (mmcblk0boot0/boot1 are all-zeros). Removing the SD card alone does NOT
  reach FEL — the BROM finds the eMMC boot chain.

## SD Self-Recovery

See [docs/sd-self-recovery.md](docs/sd-self-recovery.md) for the full explanation.

**Short version:** if your SD card is corrupted or broken, remove it. The device boots
stock CrossMix from eMMC. Reflash the SD on your host machine. Done.

## Host Prerequisites

- **sunxi-tools** (provides `sunxi-fel`): `sudo apt install sunxi-tools`
  - Verified: v1.4.2 (Debian `sunxi-tools 1.4.2+git20221128.530adf-3`)
  - A133 SoC ID `0x1855` is supported
- **usbutils** (provides `lsusb`): `sudo apt install usbutils`
- **USB-OTG cable** from host to device USB-C port (for FEL mode)
- **udev rule** (optional, for non-root `sunxi-fel`):
  ```
  # /etc/udev/rules.d/99-allwinner-fel.rules
  SUBSYSTEM=="usb", ATTR{idVendor}=="1f3a", ATTR{idProduct}=="efe8", \
    MODE="0666", GROUP="plugdev", SYMLINK+="allwinner-fel"
  ```

## Test Transcripts

End-to-end recovery test transcripts are committed to `tests/`.
Each transcript shows all four phases: corrupt, boot-fail, self-recover, restore.

## References

- [linux-sunxi.org/FEL](https://linux-sunxi.org/FEL) — FEL protocol documentation
- [linux-sunxi.org/TRIMUI_Smart_Pro](https://linux-sunxi.org/TRIMUI_Smart_Pro) — Device page (FEL pad location)
- [linux-sunxi.org/Bootable_SD_card](https://linux-sunxi.org/Bootable_SD_card) — SD boot layout
- [linux-sunxi.org/BROM](https://linux-sunxi.org/BROM) — Boot ROM scan order
- [U-Boot Allwinner docs](https://docs.u-boot.org/en/latest/board/allwinner/sunxi.html) — FEL + eMMC install

## License

MIT. See [LICENSE](LICENSE).
