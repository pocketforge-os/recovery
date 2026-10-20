#!/usr/bin/env python3
"""Battery plausibility probe with an identity-bound receipt.

The predicate checks that the PMIC reports a battery supply with fields a
single Li-ion cell could produce. It cannot tell a real cell from a bench PSU,
so every receipt says scope=plausibility_not_cell_proof and cell_proof=false.
"""
from __future__ import annotations

import hashlib
import pathlib
import re
import subprocess

SCOPE = "plausibility_not_cell_proof"
STATUSES = frozenset({"Charging", "Discharging", "Not charging", "Full", "Unknown"})
FIELDS = ("type", "present", "online", "status", "capacity", "voltage_now",
          "current_now", "health")
REQUIRED = ("present", "status", "capacity", "voltage_now")
MIN_UV, MAX_UV = 2_500_000, 4_500_000
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")
COMMANDS = (("/usr/bin/uname", "-a"), ("/bin/cat", "/proc/sys/kernel/random/boot_id"))


class IdentityRefused(RuntimeError):
    """The receipt cannot be bound to an image, boot, and successful commands."""


def default_runner(argv):
    done = subprocess.run(list(argv), stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, timeout=20, check=False)
    return done.returncode, done.stdout


def read_supplies(sys_root: pathlib.Path) -> dict[str, dict[str, str]]:
    supplies: dict[str, dict[str, str]] = {}
    base = pathlib.Path(sys_root) / "class" / "power_supply"
    for directory in sorted(base.glob("*")) if base.is_dir() else []:
        values = {}
        for key in FIELDS:
            path = directory / key
            if path.is_file():
                values[key] = path.read_text(encoding="utf-8").strip()
        supplies[directory.name] = values
    return supplies


def _int(value: str | None) -> int | None:
    if value is None or re.fullmatch(r"-?[0-9]+", value) is None:
        return None
    return int(value)


def classify(supplies: dict[str, dict[str, str]]) -> tuple[str, str]:
    batteries = [v for v in supplies.values() if v.get("type") == "Battery"]
    if not batteries:
        return "FAIL", "battery_absent"
    first_failure = "battery_not_present"
    for fields in batteries:
        if fields.get("present") != "1":
            continue
        if any(key not in fields for key in REQUIRED) \
                or _int(fields["capacity"]) is None \
                or _int(fields["voltage_now"]) is None:
            first_failure = "battery_fields_missing"
            continue
        if not 0 <= _int(fields["capacity"]) <= 100:
            first_failure = "battery_capacity_out_of_range"
            continue
        if not MIN_UV <= _int(fields["voltage_now"]) <= MAX_UV:
            first_failure = "battery_voltage_implausible"
            continue
        if fields["status"] not in STATUSES:
            first_failure = "battery_status_invalid"
            continue
        return "PASS", "battery_fields_plausible"
    return "FAIL", first_failure


def collect_receipt(sys_root, *, runner=default_runner, identity: dict) -> dict:
    descriptor = identity.get("image_descriptor")
    raw = identity.get("image_raw_sha256")
    boot_id = identity.get("boot_id")
    if (not isinstance(descriptor, dict) or not isinstance(raw, str)
            or HEX64.match(raw) is None or descriptor.get("RawSHA256") != raw
            or not isinstance(boot_id, str) or UUID.match(boot_id) is None):
        raise IdentityRefused("identity_invalid")
    commands = []
    outputs = {}
    for argv in COMMANDS:
        rc, stdout = runner(argv)
        if rc != 0:
            raise IdentityRefused("command_failed")
        outputs[argv] = stdout
        commands.append({"argv": list(argv), "rc": rc,
                         "stdout_sha256": hashlib.sha256(stdout.encode()).hexdigest()})
    if outputs[COMMANDS[1]].strip() != boot_id:
        raise IdentityRefused("boot_id_mismatch")
    supplies = read_supplies(pathlib.Path(sys_root))
    verdict, reason = classify(supplies)
    return {
        "schema": "pocketforge.battery-plausibility/v1",
        "verdict": verdict, "reason": reason, "scope": SCOPE, "cell_proof": False,
        "identity": {"image_descriptor": descriptor, "image_raw_sha256": raw,
                     "boot_id": boot_id,
                     "kernel": outputs[COMMANDS[0]].strip()},
        "commands": commands, "observed": supplies,
    }

