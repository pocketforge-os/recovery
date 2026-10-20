#!/usr/bin/env python3
"""Hermetic positive/negative controls for the battery plausibility probe."""
from __future__ import annotations

import hashlib
import json
import pathlib
import sys
import tempfile
import types
import unittest

HERE = pathlib.Path(__file__).resolve().parent
# Compile the checked-out source text directly: no import machinery, so a
# cached .pyc can never stand in for the file under test.
SOURCE = HERE / "battery_probe.py"
probe = types.ModuleType("battery_probe")
probe.__file__ = str(SOURCE)
exec(compile(SOURCE.read_text(encoding="utf-8"), str(SOURCE), "exec"), probe.__dict__)

RAW = "b1152bfa77897ac7516198d76c27ca0dddf9fa82c1a60edd947773c5c08b5e29"
BOOT_ID = "0300342b-418b-4f2f-ba6a-34f284731119"
IDENTITY = {
    "image_descriptor": {"Name": "Image.img.xz", "RawSHA256": RAW,
                         "Schema": "pocketforge.full-image/v1"},
    "image_raw_sha256": RAW,
    "boot_id": BOOT_ID,
}
GOOD = {"type": "Battery", "present": "1", "status": "Discharging",
        "capacity": "63", "voltage_now": "3850000", "current_now": "-310000",
        "health": "Good"}
# Build 11 bench reading (a8510ba4 / probe v3): the DUT's battery rail is a
# bench PSU, so these values say nothing about a real cell.
BENCH = {"type": "Battery", "present": "1", "status": "Charging",
         "capacity": "19", "voltage_now": "3729000", "current_now": "404000",
         "health": "Good"}


def fake_runner(argv):
    outputs = {
        ("/usr/bin/uname", "-a"): "Linux tsp-base-dut 7.2.0 #07bb60764cbc SMP\n",
        ("/bin/cat", "/proc/sys/kernel/random/boot_id"): BOOT_ID + "\n",
    }
    return 0, outputs[tuple(argv)]


class BatteryProbeTest(unittest.TestCase):
    def sysfs(self, supplies):
        temp = tempfile.TemporaryDirectory(dir=HERE)
        self.addCleanup(temp.cleanup)
        root = pathlib.Path(temp.name)
        for name, fields in supplies.items():
            directory = root / "class" / "power_supply" / name
            directory.mkdir(parents=True)
            for key, value in fields.items():
                (directory / key).write_text(value + "\n", encoding="utf-8")
        return root

    def receipt(self, supplies, identity=IDENTITY):
        return probe.collect_receipt(
            self.sysfs(supplies), runner=fake_runner, identity=identity)

    def test_positive_control_passes_as_plausibility_only(self):
        value = self.receipt({"axp20x-battery": GOOD})
        self.assertEqual(value["verdict"], "PASS")
        self.assertEqual(value["reason"], "battery_fields_plausible")
        self.assertEqual(value["scope"], "plausibility_not_cell_proof")
        self.assertIs(value["cell_proof"], False)

    def test_negative_controls_fail_the_same_predicate(self):
        cases = {
            "battery_absent": {},
            "battery_not_present": dict(GOOD, present="0"),
            "battery_capacity_out_of_range": dict(GOOD, capacity="101"),
            "battery_voltage_implausible": dict(GOOD, voltage_now="5100000"),
            "battery_status_invalid": dict(GOOD, status="Exploding"),
            "battery_fields_missing": {
                k: v for k, v in GOOD.items() if k != "voltage_now"},
        }
        for reason, fields in cases.items():
            with self.subTest(reason=reason):
                supplies = {} if reason == "battery_absent" else {
                    "axp20x-battery": fields}
                value = self.receipt(supplies)
                self.assertEqual(value["verdict"], "FAIL")
                self.assertEqual(value["reason"], reason)
                self.assertEqual(value["scope"], "plausibility_not_cell_proof")
                self.assertIs(value["cell_proof"], False)
        low = self.receipt({"b": dict(GOOD, voltage_now="2400000")})
        self.assertEqual(low["reason"], "battery_voltage_implausible")
        self.assertEqual(
            self.receipt({"b": dict(GOOD, capacity="-1")})["reason"],
            "battery_capacity_out_of_range")

    def test_bench_psu_reading_passes_but_never_claims_a_cell(self):
        value = self.receipt({"axp20x-battery": BENCH})
        self.assertEqual(value["verdict"], "PASS")
        self.assertEqual(value["reason"], "battery_fields_plausible")
        self.assertEqual(value["scope"], "plausibility_not_cell_proof")
        self.assertIs(value["cell_proof"], False)
        text = json.dumps(value).lower()
        self.assertNotIn("validated", text)
        self.assertNotIn('"cell_proof": true', text)
        # The predicate cannot tell the bench PSU from a real cell: the same
        # verdict comes back for a plausible discharging reading.
        good = self.receipt({"axp20x-battery": GOOD})
        self.assertEqual((value["verdict"], value["reason"]),
                         (good["verdict"], good["reason"]))

    def test_receipt_binds_identity_and_command_evidence(self):
        value = self.receipt({"axp20x-battery": GOOD})
        self.assertEqual(value["identity"]["boot_id"], BOOT_ID)
        self.assertEqual(value["identity"]["image_raw_sha256"], RAW)
        self.assertEqual(value["identity"]["image_descriptor"],
                         IDENTITY["image_descriptor"])
        commands = {tuple(item["argv"]): item for item in value["commands"]}
        uname = commands[("/usr/bin/uname", "-a")]
        self.assertEqual(uname["rc"], 0)
        self.assertEqual(uname["stdout_sha256"], hashlib.sha256(
            b"Linux tsp-base-dut 7.2.0 #07bb60764cbc SMP\n").hexdigest())
        self.assertEqual(value["observed"]["axp20x-battery"]["capacity"], "63")

    def test_identity_must_agree_and_be_well_formed(self):
        bad = {
            "raw sha mismatch": dict(IDENTITY, image_raw_sha256="0" * 64),
            "raw sha malformed": dict(IDENTITY, image_raw_sha256="abc"),
            "boot id malformed": dict(IDENTITY, boot_id="not-a-uuid"),
            "boot id differs from DUT": dict(
                IDENTITY, boot_id="11111111-1111-4111-8111-111111111111"),
            "descriptor missing": {k: v for k, v in IDENTITY.items()
                                   if k != "image_descriptor"},
        }
        for name, identity in bad.items():
            with self.subTest(name=name):
                with self.assertRaises(probe.IdentityRefused):
                    self.receipt({"axp20x-battery": GOOD}, identity)

    def test_failed_command_is_not_a_pass(self):
        def failing(argv):
            return 1, ""
        with self.assertRaises(probe.IdentityRefused):
            probe.collect_receipt(
                self.sysfs({"axp20x-battery": GOOD}), runner=failing,
                identity=IDENTITY)


if __name__ == "__main__":
    unittest.main()
