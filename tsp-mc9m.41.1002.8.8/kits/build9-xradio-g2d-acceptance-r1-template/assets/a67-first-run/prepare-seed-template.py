#!/usr/bin/env python3
"""Create an unsealed A67 seed kit from a consumed seed template."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys


REQUEST = "felboot-request.json"
TEMPLATE = "felboot-request.template.json"
PAYLOAD = "pf-kit-payload.tar.gz"
TRANSPORT = "kit-transport.json"
SHA256_RE = re.compile(r"[0-9a-f]{64}")
HANDLE_RE = re.compile(r"[0-9a-f]{32}")


def fail(message: str) -> None:
    raise SystemExit(f"A67_SEED_TEMPLATE state=FAIL reason={message}")


def regular(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.is_file():
        fail(f"{label}_invalid path={path}")
    return path


def read_object(path: Path, label: str) -> dict:
    try:
        value = json.loads(regular(path, label).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{label}_invalid error={type(error).__name__}")
    if not isinstance(value, dict):
        fail(f"{label}_invalid type=not_object")
    return value


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def identity_value(text: str, key: str) -> str:
    prefix = key + "="
    values = [line[len(prefix):] for line in text.splitlines()
              if line.startswith(prefix)]
    if len(values) != 1 or not values[0]:
        fail(f"identity_{key}_invalid")
    return values[0]


def atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.replace(temporary, path)


def reseal(root: Path) -> str:
    excluded = {"SHA256SUMS", "queue.tsv", "HANDOFF.md", REQUEST}
    lines = []
    for path in sorted(root.iterdir()):
        if (path.is_file() and not path.is_symlink()
                and path.name not in excluded and not path.name.endswith(".tmp")):
            lines.append(f"{digest(path)}  {path.name}\n")
    manifest = "".join(lines)
    temporary = root / "SHA256SUMS.tmp"
    temporary.write_text(manifest, encoding="ascii")
    os.replace(temporary, root / "SHA256SUMS")
    return hashlib.sha256(manifest.encode("ascii")).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--payload", required=True)
    parser.add_argument("--image-source", required=True)
    parser.add_argument("--consumed-handle", required=True)
    parser.add_argument("--network-only", action="store_true")
    args = parser.parse_args()

    source = Path(args.source).resolve()
    output = Path(args.output).resolve()
    payload_source = regular(Path(args.payload).resolve(), "payload")
    identity_source = regular(payload_source.parent / "IDENTITY", "identity")
    identity_text = identity_source.read_text(encoding="utf-8")
    host_interface = identity_value(identity_text, "host_wifi_interface")
    dut_interface = identity_value(identity_text, "dut_interface")
    if host_interface == dut_interface:
        fail("identity_interface_alias")
    image = read_object(Path(args.image_source).resolve(), "image_source")
    companion = regular(Path(__file__).resolve().parent / "a67-postseal-check.sh",
                        "postseal_companion")
    sealer = regular(Path(__file__).resolve().parent / "a67-seal-request.py",
                     "sealer_companion")
    if source.is_symlink() or not source.is_dir():
        fail(f"source_invalid path={source}")
    if output.exists() or output.is_symlink():
        fail(f"output_exists path={output}")
    if not HANDLE_RE.fullmatch(args.consumed_handle):
        fail("consumed_handle_invalid")

    prior = read_object(source / REQUEST, "prior_request")
    if prior.get("SeedHandle") != args.consumed_handle:
        fail("prior request handle mismatch")
    template = read_object(source / TEMPLATE, "seed_template")
    metadata = read_object(source / TRANSPORT, "transport_metadata")
    if metadata.get("Schema") != "pocketforge.kit-transport/v1":
        fail("transport_metadata_schema")

    payload_bytes = payload_source.stat().st_size
    payload_sha = digest(payload_source)
    payload = {
        "Schema": "pocketforge.kit-payload/v1",
        "Name": PAYLOAD,
        "Bytes": payload_bytes,
        "SHA256": payload_sha,
    }
    metadata["payload"] = payload
    metadata["dut_transport"] = "network-only" if args.network_only else "fat-root"
    template["ImageSource"] = image
    if args.network_only:
        template.pop("KitPayload", None)
    else:
        template["KitPayload"] = payload
    template["SeedHandle"] = "@SEED_HANDLE@"

    try:
        shutil.copytree(source, output, symlinks=False)
        (output / REQUEST).unlink()
        shutil.copyfile(payload_source, output / PAYLOAD)
        (output / PAYLOAD).chmod(0o644)
        shutil.copyfile(identity_source, output / "IDENTITY")
        shutil.copyfile(companion, output / "postseal-check.sh")
        (output / "postseal-check.sh").chmod(0o755)
        shutil.copyfile(sealer, output / "seal-request.py")
        (output / "seal-request.py").chmod(0o755)
        atomic_json(output / TRANSPORT, metadata)
        atomic_json(output / TEMPLATE, template)
        manifest_sha = reseal(output)
    except (OSError, shutil.Error) as error:
        if output.exists():
            for root, dirs, files in os.walk(output, topdown=False):
                root_path = Path(root)
                for name in files:
                    (root_path / name).unlink()
                for name in dirs:
                    child = root_path / name
                    if child.is_symlink():
                        child.unlink()
                    else:
                        child.rmdir()
            output.rmdir()
        fail(f"prepare_failed error={type(error).__name__}")

    print(
        "A67_SEED_TEMPLATE state=PASS "
        f"prior_handle={args.consumed_handle} payload_bytes={payload_bytes} "
        f"payload_sha256={payload_sha} transport={metadata['dut_transport']} "
        f"manifest_sha256={manifest_sha} output={output}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
