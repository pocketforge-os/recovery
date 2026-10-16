#!/usr/bin/env bash
# Verify a built A133 open-7x image before any bench (runs ON modelmaker).
# usage: verify-a133-artifact.sh <image.img.xz> [kernel_addr fdt_addr initrd_addr]
# Checks, each printed with the value it scored:
#  1. VBUS: booted DTB phy@5100400 usb0_vbus_power-supply -> AXP717 usb-power supply; usb@5100000 dr_mode.
#  2. FIT: Image header image_size + 2 MiB margin <= next load address (fdt), and initrd/fdt don't overlap.
#  3. U-Boot: the built bootcmd carries the expected layout; no boot.scr/uEnv/env override on any FAT partition.
#  4. reserved-memory / memreserve ranges do not intersect any payload range.
# Scratch is one mktemp dir removed on exit (bounded by construction).
set -euo pipefail
img=$1
KA=${2:-0x44000000} FA=${3:-0x49000000} RA=${4:-0x4b000000}
MARGIN=$((2 * 1024 * 1024))
t=$(mktemp -d /tmp/gpu14-verify.XXXXXX)
trap 'rm -rf "$t"' EXIT
fail=0
say() { printf '%s\n' "$*"; }
bad() { say "FAIL $*"; fail=1; }

say "artifact=$img sha256=$(sha256sum "$img" | cut -d' ' -f1)"
xz -dc "$img" > "$t/raw.img"
say "raw_bytes=$(stat -c %s "$t/raw.img")"

# Partition table: find every FAT-looking partition; the boot payload partition is the one
# holding Image + dtb.bin (the bootcmd loads from mmc 0:4).
sfdisk -J "$t/raw.img" > "$t/pt.json"
python3 - "$t/pt.json" > "$t/parts.txt" <<'PY'
import json, sys
pt = json.load(open(sys.argv[1]))["partitiontable"]
for i, p in enumerate(pt["partitions"], 1):
    print(i, p["start"], p["size"], p.get("name", "-"))
PY
say "partitions:"; sed 's/^/  /' "$t/parts.txt"

boot_part=""
while read -r n start size name; do
    off=$((start * 512))
    if mdir -i "$t/raw.img@@$off" ::/ >/dev/null 2>&1; then
        listing=$(mdir -b -i "$t/raw.img@@$off" ::/ 2>/dev/null | tr '\n' ' ')
        say "fat_part=$n name=$name start=$start files=[$listing]"
        for f in boot.scr boot.cmd uEnv.txt uboot.env u-boot.env extlinux; do
            if mdir -i "$t/raw.img@@$off" "::/$f" >/dev/null 2>&1; then bad "override_file part=$n file=$f"; fi
        done
        if mdir -i "$t/raw.img@@$off" ::/Image >/dev/null 2>&1 && mdir -i "$t/raw.img@@$off" ::/dtb.bin >/dev/null 2>&1; then
            [ -z "$boot_part" ] && boot_part="$n:$off"
        fi
    fi
    case "$name" in env|env-redund|uboot-env|u-boot-env)
        dd if="$t/raw.img" of="$t/env.$n" bs=512 skip="$start" count="$size" status=none
        # Owned U-Boot's env source is ENV_IS_IN_FAT uboot.env on mmc 0:4 (checked above as an
        # override file); its runtime log shows the GPT env partitions are not consulted
        # (tsp-mc9m.41.923.40 RUNTIME LAYOUT AUTHORITY). A vendor blob here is inert: WARN only.
        say "WARN env_partition_not_consulted part=$n name=$name bootcmd=$(strings "$t/env.$n" | grep -E '^bootcmd=' | head -1 | cut -c9-120 || echo absent)" ;;
    esac
done < "$t/parts.txt"
[ -n "$boot_part" ] || { bad "no FAT partition holds Image+dtb.bin"; exit 1; }
bp=${boot_part%%:*} boff=${boot_part#*:}
say "boot_payload_partition=$bp (bootcmd loads mmc 0:4)"
[ "$bp" = 4 ] || bad "payload partition is $bp, bootcmd loads 0:4"

for f in Image dtb.bin initrd.gz; do mcopy -n -i "$t/raw.img@@$boff" "::/$f" "$t/$f"; done
isz=$(python3 -c "import struct,sys;d=open(sys.argv[1],'rb').read(64);assert d[56:60]==b'ARMd',d[56:60];print(struct.unpack_from('<Q',d,16)[0])" "$t/Image")
fsz=$(stat -c %s "$t/Image") dsz=$(stat -c %s "$t/dtb.bin") rsz=$(stat -c %s "$t/initrd.gz")
say "Image file_bytes=$fsz header_image_size=$(printf '0x%x' "$isz") dtb_bytes=$dsz initrd_bytes=$rsz"
kend=$((KA + isz)); fend=$((FA + dsz)); rend=$((RA + rsz))
# Pairwise disjoint payload ranges; the kernel range carries the 2 MiB post-image margin.
if ! python3 - "$KA" "$((kend + MARGIN))" "$FA" "$fend" "$RA" "$rend" <<'PY'
import sys
KA, KM, FA, FE, RA, RE = (int(x, 0) for x in sys.argv[1:7])
r = {"kernel+margin": (KA, KM), "fdt": (FA, FE), "initrd": (RA, RE)}
for k, (a, e) in r.items(): print(f"range {k} 0x{a:x}..0x{e:x}")
nxt = min([a for a, _ in (r["fdt"], r["initrd"]) if a > KA], default=None)
print(f"kernel_headroom_to_next=0x{nxt - (KM - 2*1024*1024):x}" if nxt else "kernel_headroom_to_next=none")
bad = [(x, y) for i, x in enumerate(r) for y in list(r)[i+1:] if r[x][0] < r[y][1] and r[y][0] < r[x][1]]
for x, y in bad: print(f"FAIL overlap {x} {y}")
print("PASS payload_ranges_disjoint" if not bad else "FAIL payload_ranges_overlap")
sys.exit(1 if bad else 0)
PY
then fail=1; fi

# 3. U-Boot bootcmd baked into the image (SPL/U-Boot proper live before the first partition).
first=$(awk 'NR==1{print $2}' "$t/parts.txt")
dd if="$t/raw.img" of="$t/boot0" bs=512 count="$first" status=none
bc=$(strings -n 20 "$t/boot0" | grep -E 'booti 0x' | sort -u || true)
say "bootcmd_strings:"; printf '%s\n' "$bc" | sed 's/^/  /' | cut -c1-260
want="booti $(printf '0x%08x' "$KA") $(printf '0x%08x' "$RA"):\${irdsz} $(printf '0x%08x' "$FA")"
printf '%s\n' "$bc" | grep -qF "$want" && say "PASS bootcmd_layout '$want'" || bad "bootcmd_layout_missing want='$want'"
[ "$((KA))" -ne $((0x45000000)) ] && printf '%s\n' "$bc" | grep -qE 'booti 0x45000000' && bad "old_layout_string_present" || true

# 1. VBUS wiring in the booted DTB.
dtc -I dtb -O dts -q "$t/dtb.bin" > "$t/dtb.dts"
phy_supply=$(fdtget -t x "$t/dtb.bin" /soc/phy@5100400 usb0_vbus_power-supply 2>/dev/null || echo missing)
dr=$(fdtget "$t/dtb.bin" /soc/usb@5100000 dr_mode 2>/dev/null || echo missing)
target=$(python3 - "$t/dtb.dts" "$phy_supply" <<'PY'
import re, sys
dts = open(sys.argv[1]).read(); ph = sys.argv[2]
if ph == "missing": print("missing"); sys.exit()
ph = int(ph, 16)
for m in re.finditer(r'\n(\t*)([\w@,.-]+) \{', dts):
    depth, name = m.group(1), m.group(2)
    body = dts[m.end(): dts.find('\n' + depth + '};', m.end())]
    own = re.search(r'\n' + depth + r'\tphandle = <(0x[0-9a-f]+)>;', body)
    if own and int(own.group(1), 16) == ph:
        compat = re.search(r'\n' + depth + r'\tcompatible = "([^"]+)"', body)
        print(name, compat.group(1) if compat else "-"); break
else:
    print("unresolved")
PY
)
say "vbus phy@5100400 usb0_vbus_power-supply=$phy_supply -> $target ; usb@5100000 dr_mode=$dr"
case "$target" in *usb-power*|*usb_power*) say "PASS vbus_supply_is_axp_usb_power" ;; *) bad "vbus_supply_target=$target" ;; esac
[ "$dr" = otg ] && say "PASS dr_mode=otg" || bad "dr_mode=$dr"

# 4. reserved memory vs payload ranges.
if ! python3 - "$t/dtb.bin" "$KA" "$kend" "$FA" "$fend" "$RA" "$rend" <<'PY'
import subprocess, sys, struct
dtb = sys.argv[1]
KA, KE, FA, FE, RA, RE = (int(x, 0) for x in sys.argv[2:8])
payload = {"kernel": (KA, KE), "fdt": (FA, FE), "initrd": (RA, RE)}
d = open(dtb, "rb").read()
off_rsv = struct.unpack_from(">I", d, 16)[0]
ranges = []
i = off_rsv
while True:
    a, s = struct.unpack_from(">QQ", d, i); i += 16
    if a == 0 and s == 0: break
    ranges.append(("memreserve", a, a + s))
nodes = subprocess.run(["fdtget", "-l", dtb, "/reserved-memory"], capture_output=True, text=True).stdout.split()
for n in nodes:
    r = subprocess.run(["fdtget", "-t", "x", dtb, "/reserved-memory/" + n, "reg"], capture_output=True, text=True).stdout.split()
    if len(r) >= 4:
        a = (int(r[0], 16) << 32) | int(r[1], 16); s = (int(r[2], 16) << 32) | int(r[3], 16)
        ranges.append((n, a, a + s))
    else:
        ranges.append((n + "(no-reg/dynamic)", 0, 0))
bad = 0
for name, a, e in ranges:
    hits = [k for k, (pa, pe) in payload.items() if a < pe and pa < e]
    # A /memreserve/ that covers the FDT itself is the normal "protect the blob" pattern.
    fdt_self = name == "memreserve" and hits == ["fdt"]
    print(f"reserved {name} 0x{a:x}..0x{e:x}" + (" (covers fdt: expected)" if fdt_self else f" COLLIDES {hits}" if hits else ""))
    bad |= bool(hits) and not fdt_self
print("FAIL reserved_memory_collision" if bad else "PASS reserved_memory_clear")
sys.exit(1 if bad else 0)
PY
then fail=1; fi
say "VERDICT $([ $fail = 0 ] && echo PASS || echo FAIL)"
exit $fail
