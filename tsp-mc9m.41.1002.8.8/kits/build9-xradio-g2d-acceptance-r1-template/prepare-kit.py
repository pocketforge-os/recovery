#!/usr/bin/env python3
"""Create the raw-bound, unsealed Build 9 xradio+G2D acceptance kit."""
from __future__ import annotations

import argparse, hashlib, os, re, shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RAW_RE = re.compile(r"[0-9a-f]{64}\Z")
KERNEL = "45b87a7d"
PLATFORM = "3e9bda124b7bd3579600579d0468890c839d62ca"
IMAGE = "dc3637f774e304f5a42a22f948bdd6d54608f259"
G2D_PAYLOAD_SHA = "2c2c5f1f67e7ed2943a1df6afb7dbf3f37a265e5b8a85b1dc821c9a478fbd9f5"
SMOKE_SHA = "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58"
HOST_WIFI_INTERFACE = "wlp4s0"
DUT_INTERFACE = "wlan0"

def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()

def write(path: Path, value: str, mode: int = 0o644) -> None:
    path.write_text(value, encoding="utf-8")
    path.chmod(mode)

def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--output", required=True)
    p.add_argument("--image-sha256", required=True)
    a = p.parse_args()
    if not RAW_RE.fullmatch(a.image_sha256):
        p.error("--image-sha256 must be 64 lowercase hex characters")
    out = Path(a.output).resolve()
    if out.exists() or out.is_symlink():
        raise SystemExit("output already exists")
    out.mkdir(parents=True, mode=0o700)
    copies = {
        ROOT / "assets/g2d-payload.tar.gz": out / "pf-kit-payload.tar.gz",
        ROOT / "assets/pf-kit-transport.py": out / "pf-kit-transport.py",
        ROOT / "assets/a67-first-run/prepare-seed-template.py": out / "prepare-seed-template.py",
        ROOT / "assets/a67-first-run/a67-seal-request.py": out / "seal-request.py",
        ROOT / "assets/a67-first-run/a67-postseal-check.sh": out / "postseal-check.sh",
    }
    for name in ("bootstrap-dut.sh", "network-dut.sh", "g2d-dut-run.sh",
                 "run-network-step", "run-g2d-step", "smoke.sh",
                 "test-bootstrap-unprivileged.sh"):
        copies[ROOT / name] = out / name
    for src, dst in copies.items():
        shutil.copyfile(src, dst)
    shutil.copyfile(ROOT / "assets/a67-first-run/a67-postseal-check.sh",
                    out / "a67-postseal-check.sh")
    shutil.copyfile(ROOT / "assets/a67-first-run/a67-seal-request.py",
                    out / "a67-seal-request.py")
    for name in ("pf-kit-transport.py", "prepare-seed-template.py", "seal-request.py",
                 "a67-seal-request.py", "postseal-check.sh", "a67-postseal-check.sh",
                 "bootstrap-dut.sh", "network-dut.sh",
                 "g2d-dut-run.sh", "run-network-step", "run-g2d-step", "smoke.sh",
                 "test-bootstrap-unprivileged.sh"):
        (out / name).chmod(0o755)
    with (out / "network-smoke.bin").open("wb") as f:
        f.truncate(1024 * 1024)
    if digest(out / "network-smoke.bin") != SMOKE_SHA:
        raise SystemExit("deterministic smoke fixture mismatch")
    if digest(out / "pf-kit-payload.tar.gz") != G2D_PAYLOAD_SHA:
        raise SystemExit("G2D template payload mismatch")
    helper_sha = digest(out / "pf-kit-transport.py")
    identity = (
        "schema=pocketforge.build9-xradio-g2d-acceptance/v1\n"
        f"build9_raw_sha256={a.image_sha256}\nplatform_commit={PLATFORM}\n"
        f"image_commit={IMAGE}\n"
        f"kernel_sunxi_7x={KERNEL}\nextra_boot_args=absent\nxradio_source=in-tree\n"
        f"host_wifi_interface={HOST_WIFI_INTERFACE}\ndut_interface={DUT_INTERFACE}\n"
        "transport_order=wifi-ssh\nresult_transport=network-only\n"
        f"network_smoke_bytes=1048576\nnetwork_smoke_sha256={SMOKE_SHA}\n"
        f"g2d_template_manifest_sha256=730aefb67e125ae49674674c0d93e26353a644eec556060cc63e5480ed341792\n"
        f"g2d_payload_sha256={G2D_PAYLOAD_SHA}\nhelper_commit=dcee1dfc258091984e70e62305c2c86e5544efae\n"
        f"helper_sha256={helper_sha}\n"
    )
    write(out / "IDENTITY", identity)
    runbook = (ROOT / "RUNBOOK.md.in").read_text(encoding="utf-8")
    runbook = runbook.replace("@IMAGE_SHA@", a.image_sha256)
    runbook = runbook.replace("@HELPER_SHA@", helper_sha)
    write(out / "RUNBOOK.md", runbook)
    write(out / "DUT-COMMANDS", f"dut_interface={DUT_INTERFACE}\nbootstrap-dut.sh\nnetwork-dut.sh\ng2d-dut-run.sh\n")
    sums = []
    for path in sorted(out.iterdir()):
        if path.name != "SHA256SUMS":
            sums.append(f"{digest(path)}  {path.name}\n")
    write(out / "SHA256SUMS", "".join(sums))
    print(f"BUILD9_ACCEPTANCE_KIT state=BOOT_READY_UNSEALED path={out} raw_sha256={a.image_sha256} seal=not_staged queue=not_queued")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
