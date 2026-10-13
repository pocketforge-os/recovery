#!/usr/bin/env python3
"""Trusted kit-runner tool: finalize and reseal an A67 Build 8 request.

This owns the A67 specialization of the proven r19 seed lifecycle. It preserves
the secret, one-shot SeedHandle, staging, discard, receipt and sealed-smoke
paths, but treats ``pf-kit-payload.tar.gz`` as an already-built immutable A67
artifact. The r19 sealer rebuilt that file from its writeback-only source list;
doing so here silently replaced the A67 payload after its offline check.

Lifecycle base: build8-writeback-standalone-r19 ``seal-request.py``, SHA256
``8b61ead4c29c7a743f262f3c09bb0d09e1ccdda7f4c91a7f4061f0c0a3d2282d``.

Run this IMMEDIATELY BEFORE queuing the kit (the staged handle is one-shot and
volatile across node service restarts):

    python3 seal-request.py --kit <kit dir> --image <Build 8 Image.img or its dir> \
        --image-sha256 <expected raw sha256> \
        --transport-receipt-dir <new mode-0700 directory>

Add ``--check`` to perform the same template/image/payload and sealed direct-
boot validation without reading secrets, calling the node, or staging a handle.

It validates the published image + descriptor, reads the wifi seed secrets into
memory, generates an ephemeral ed25519 console key, builds the strict
pocketforge.nocloud-seed/v1 bundle, stages it on the node with
`sudo -n pf-seed-flash.py stage --dut tsp`, writes the returned opaque 32-hex
handle into felboot-request.json beside the descriptor, RESEALS SHA256SUMS and
prints the ready queue.tsv row. If the run later stops BEFORE the FelBoot POST
attempt (`felboot/handle-owner.txt` is absent), discard with:

    python3 seal-request.py --kit <kit dir> --discard <handle>

Exit codes: 0 ok; 2 usage; 64 image/request invalid (nothing staged);
75 secret/stage/discard failure; 76 interruption or seal failure after staging.
Once staging returns a handle, normal exceptions and INT/TERM automatically
discard it and restore the template.  If that discard itself fails, the
durable request is retained and a recovery marker names the handle.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path

SCHEMA = "pocketforge.nocloud-seed/v1"
SEED_FILES = ("meta-data", "network-config", "user-data")
HANDLE_RE = re.compile(r"[0-9a-f]{32}\Z")
SHA256_RE = re.compile(r"[0-9a-f]{64}\Z")
COUNTRY_RE = re.compile(r"[A-Z]{2}\Z")
REDACTED = "[REDACTED seed secret material]"
SEAL_EXCLUDES = ("SHA256SUMS", "queue.tsv", "HANDOFF.md")
TEMPLATE_NAME = "felboot-request.template.json"
REQUEST_NAME = "felboot-request.json"
PAYLOAD_NAME = "pf-kit-payload.tar.gz"
TRANSPORT_META_NAME = "kit-transport.json"
PAYLOAD_MAX_BYTES = 24 * 1024 * 1024
SEED_FILE_MAX_BYTES = 128 * 1024
MAX_STAGE_STDOUT = 65536
MAX_STDERR_TAIL = 2048
DEFAULTS = {
    "WRITEBACK_B8_SECRET_TOOL": "pf-secret",
    "WRITEBACK_B8_SSH_TOOL": "ssh",
    "WRITEBACK_B8_NODE": "matt@pf-node-01.lan",
    "WRITEBACK_B8_SEED_HELPER": "/usr/local/libexec/pocketforge/redfish/pf-seed-flash.py",
    "WRITEBACK_B8_SEED_DUT": "tsp",
    "WRITEBACK_B8_WIFI_SSID_NAME": "wifi/bench-ssid",
    "WRITEBACK_B8_WIFI_PSK_NAME": "wifi/bench-psk",
    "WRITEBACK_B8_WIFI_COUNTRY": "US",
    "WRITEBACK_B8_SHM": "/dev/shm",
}


class Refusal(Exception):
    def __init__(self, reason: str, detail: str = "", code: int = 64):
        super().__init__(reason)
        self.reason = reason
        self.detail = detail
        self.code = code


class SeedSignal(Exception):
    """Normal termination request received while this process owns a handle."""

    def __init__(self, signum: int):
        super().__init__(signal.Signals(signum).name)
        self.signum = signum


def env(name: str) -> str:
    return os.environ.get(name, DEFAULTS[name])


def fail(reason: str, detail: str = "", code: int = 64) -> "NoReturn":  # noqa: F821
    suffix = f" {detail}" if detail else ""
    print(f"WRITEBACK_B8_SEAL_ERROR reason={reason}{suffix}", file=sys.stderr)
    raise SystemExit(code)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_kit_seal(kit: Path) -> None:
    """Refuse a corrupt template before reading secrets or staging a handle."""
    try:
        checked = subprocess.run(
            ["sha256sum", "-c", "--quiet", "SHA256SUMS"],
            cwd=kit,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail("kit_manifest_check_failed", f"error={type(error).__name__}")
    if checked.returncode != 0:
        fail("kit_manifest_mismatch")


def image_gate(image: str, expected_sha: str) -> tuple[Path, str, dict]:
    """Validate the published image + descriptor. Runs BEFORE any staging."""
    if not SHA256_RE.fullmatch(expected_sha):
        fail("image_sha_format")
    path = Path(image)
    if path.is_dir():
        path = path / "Image.img"
    if not path.is_file():
        fail("image_missing", f"path={path}")
    path = path.resolve()
    digest = sha256_file(path)
    if digest != expected_sha:
        fail("image_sha_mismatch", f"expected={expected_sha} actual={digest}")
    desc_path = path.parent / "ImageSource.json"
    if not desc_path.is_file():
        fail("descriptor_missing", f"path={desc_path}")
    try:
        desc = json.loads(desc_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail("descriptor_invalid", f"error={type(error).__name__}")
    if not isinstance(desc, dict):
        fail("descriptor_invalid", "not an object")
    raw_bytes = path.stat().st_size
    checks = (
        desc.get("Schema") == "pocketforge.full-image/v1",
        desc.get("Compression") == "xz",
        isinstance(desc.get("Name"), str) and bool(desc["Name"]),
        desc.get("RawSHA256") == digest,
        desc.get("RawBytes") == raw_bytes,
        isinstance(desc.get("CompressedBytes"), int) and desc["CompressedBytes"] > 0,
        isinstance(desc.get("CompressedSHA256"), str)
        and bool(SHA256_RE.fullmatch(desc["CompressedSHA256"])),
        isinstance(desc.get("BuildManifestSHA256"), str)
        and bool(SHA256_RE.fullmatch(desc["BuildManifestSHA256"])),
    )
    if not all(checks):
        fail("image_descriptor_mismatch", f"checks={list(map(int, checks))}")
    return path, digest, desc


def load_template(kit: Path) -> dict:
    template_path = kit / TEMPLATE_NAME
    if not template_path.is_file():
        fail("seed_template_missing", f"path={template_path}")
    try:
        template = json.loads(template_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail("seed_template_invalid", f"error={type(error).__name__}")
    if not isinstance(template, dict) or not isinstance(template.get("ImageSource"), dict):
        fail("seed_template_invalid", "ImageSource object required")
    if template.get("SeedHandle") != "@SEED_HANDLE@":
        fail("seed_template_invalid", "SeedHandle must be the @SEED_HANDLE@ placeholder")
    expected = load_payload_identity(kit)
    if network_only(kit):
        if "KitPayload" in template:
            fail("network_only_template_has_payload")
    elif template.get("KitPayload") != expected:
        fail("payload_template_invalid")
    return template


def network_only(kit: Path) -> bool:
    try:
        value = json.loads((kit / TRANSPORT_META_NAME).read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail("transport_metadata_invalid", f"error={type(error).__name__}")
    mode = value.get("dut_transport")
    if mode not in {None, "fat-root", "network-only"}:
        fail("transport_metadata_invalid", "dut_transport")
    return mode == "network-only"


def load_payload_identity(kit: Path) -> dict:
    try:
        meta = json.loads((kit / TRANSPORT_META_NAME).read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail("transport_metadata_invalid", f"error={type(error).__name__}")
    payload = meta.get("payload") if isinstance(meta, dict) else None
    helper_commit = meta.get("helper_commit") if isinstance(meta, dict) else None
    helper_sha = meta.get("helper_sha256") if isinstance(meta, dict) else None
    if (meta.get("Schema") != "pocketforge.kit-transport/v1"
            or not isinstance(helper_commit, str) or len(helper_commit) != 40
            or not re.fullmatch(r"[0-9a-f]{40}", helper_commit)
            or not isinstance(helper_sha, str) or not SHA256_RE.fullmatch(helper_sha)
            or not isinstance(payload, dict)):
        fail("transport_metadata_invalid")
    expected = {
        "Schema": "pocketforge.kit-payload/v1",
        "Name": PAYLOAD_NAME,
        "Bytes": payload.get("Bytes"),
        "SHA256": payload.get("SHA256"),
    }
    path = kit / PAYLOAD_NAME
    if (not path.is_file() or not isinstance(expected["Bytes"], int)
            or expected["Bytes"] <= 0 or expected["Bytes"] > PAYLOAD_MAX_BYTES
            or not isinstance(expected["SHA256"], str)
            or not SHA256_RE.fullmatch(expected["SHA256"])
            or path.stat().st_size != expected["Bytes"]
            or sha256_file(path) != expected["SHA256"]):
        fail("payload_identity_invalid")
    return expected


def validate_payload_contract(kit: Path) -> dict:
    """Validate, but never rebuild, the exact pre-sealed A67 payload."""
    payload = load_payload_identity(kit)
    template = load_template(kit)
    if not network_only(kit) and template.get("KitPayload") != payload:
        fail("payload_template_invalid")
    return payload


def read_secret(tool: str, name: str) -> str:
    try:
        done = subprocess.run(
            [tool, "get", name],
            capture_output=True,
            timeout=20,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        fail("secret_tool_failed", f"name={name} error={type(error).__name__}", 75)
    if done.returncode != 0:
        fail("secret_read_failed", f"name={name} rc={done.returncode}", 75)
    value = done.stdout.decode("utf-8", "strict")
    if value.endswith("\n"):
        value = value[:-1]
    if not value or "\x00" in value:
        fail("secret_invalid", f"name={name}", 75)
    return value


def seed_bundle(ssid: str, psk: str, public_key: str, country: str) -> bytes:
    if not 1 <= len(ssid.encode("utf-8")) <= 32 or any(
        ord(c) < 0x20 for c in ssid
    ):
        fail("ssid_invalid", "", 75)
    if not 8 <= len(psk) <= 63 or "\r" in psk or "\n" in psk:
        fail("psk_invalid", "", 75)
    if not COUNTRY_RE.fullmatch(country):
        fail("wifi_country_invalid", f"value={country}", 75)
    meta = (
        "instance-id: iid-pocketforge-bench-" + secrets.token_hex(12) + "\n"
        "local-hostname: tsp-base-dut\n"
    )
    user = (
        "#cloud-config\n"
        "ssh_pwauth: false\n"
        "ssh_authorized_keys:\n"
        "  - " + json.dumps(public_key) + "\n"
    )
    network = (
        "version: 2\n"
        "wifis:\n"
        "  wlan0:\n"
        "    dhcp4: true\n"
        "    regulatory-domain: " + country + "\n"
        "    access-points:\n"
        "      " + json.dumps(ssid) + ":\n"
        "        password-b64: "
        + json.dumps(base64.b64encode(psk.encode("utf-8")).decode("ascii"))
        + "\n"
    )
    files = {
        "meta-data": meta.encode("utf-8"),
        "network-config": network.encode("utf-8"),
        "user-data": user.encode("utf-8"),
    }
    if tuple(sorted(files)) != SEED_FILES:
        fail("bundle_files_invalid", "")
    bundle = json.dumps(
        {
            "schema": SCHEMA,
            "files": {
                name: base64.b64encode(value).decode("ascii")
                for name, value in files.items()
            },
        },
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")
    return bundle


def overwrite_unlink(path: Path) -> None:
    try:
        size = path.stat().st_size
        with path.open("r+b") as handle:
            handle.write(b"\0" * size)
            handle.flush()
            os.fsync(handle.fileno())
        path.unlink()
    except OSError:
        pass


class ReceiptIdentity:
    """Generate the client key directly inside its mode-0700 run receipt."""

    def __init__(self, raw_receipt: str, comment: str):
        self.dir = Path(raw_receipt)
        if not self.dir.is_absolute():
            fail("transport_receipt_invalid", "path must be absolute", 75)
        try:
            info = self.dir.lstat()
        except OSError as error:
            fail("transport_receipt_invalid", f"error={type(error).__name__}", 75)
        if (not stat.S_ISDIR(info.st_mode) or self.dir.is_symlink()
                or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700):
            fail("transport_receipt_invalid", "mode-0700 owned directory required", 75)
        self.key = self.dir / "ssh-ed25519"
        self.public = self.dir / "ssh-ed25519.pub"
        if self.key.exists() or self.public.exists():
            fail("transport_receipt_key_exists", code=75)
        done = subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", comment,
             "-f", str(self.key)], capture_output=True, timeout=30, check=False,
        )
        if done.returncode != 0:
            self.cleanup()
            fail("keygen_failed", f"rc={done.returncode}", 75)
        os.chmod(self.key, 0o600)
        os.chmod(self.public, 0o600)
        fields = self.public.read_text().strip().split()
        if len(fields) < 2 or fields[0] != "ssh-ed25519":
            self.cleanup()
            fail("keygen_invalid_pubkey", code=75)
        self.public_key = " ".join(fields[:2])
        finger = subprocess.run(
            ["ssh-keygen", "-l", "-E", "sha256", "-f", str(self.public)],
            capture_output=True, text=True, timeout=30, check=False,
        )
        self.fingerprint = finger.stdout.split()[1] if finger.returncode == 0 else "unknown"

    def cleanup(self) -> None:
        for path in (self.key, self.public):
            if path.exists():
                overwrite_unlink(path)


def ssh_node(node: str, remote_command: str, stdin_data: bytes | None,
             timeout: int) -> tuple[int, bytes, bytes]:
    tool = env("WRITEBACK_B8_SSH_TOOL")
    argv = [
        tool, "-F", "/dev/null", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        node, remote_command,
    ]
    try:
        proc = subprocess.Popen(argv, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as error:
        fail("ssh_spawn_failed", f"error={type(error).__name__}", 75)
    try:
        out, err = proc.communicate(stdin_data, timeout=timeout)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        fail("ssh_timeout", f"timeout={timeout}", 75)
    return proc.returncode or 0, out, err


def redact(text: str, sensitive: list[str]) -> str:
    for value in sensitive:
        if value:
            text = text.replace(value, REDACTED)
    return text[-MAX_STDERR_TAIL:]


def canonical_json_line(value: dict) -> bytes:
    return (json.dumps(value, separators=(",", ":"), sort_keys=True) + "\n").encode(
        "ascii"
    )


def parse_seed_stage_response(out: bytes) -> tuple[str, list[str]]:
    if len(out) > MAX_STAGE_STDOUT or out.count(b"\n") != 1 or not out.endswith(b"\n"):
        fail("seed_stage_response_invalid", "exactly one JSON line required", 75)
    try:
        body = json.loads(out.decode("ascii", "strict"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("seed_stage_response_invalid", "stdout not canonical JSON", 75)
    if (type(body) is not dict or set(body) != {"Files", "Handle"}
            or canonical_json_line(body) != out):
        fail("seed_stage_response_invalid", "canonical Files/Handle object required", 75)
    handle = body.get("Handle")
    files = body.get("Files")
    if (not isinstance(handle, str) or not HANDLE_RE.fullmatch(handle)
            or type(files) is not list or len(files) != len(SEED_FILES)):
        fail("seed_stage_response_invalid", "invalid handle or file list", 75)
    names = []
    for item in files:
        if (type(item) is not dict or set(item) != {"Bytes", "Name"}
                or type(item.get("Bytes")) is not int
                or not (0 < item["Bytes"] <= SEED_FILE_MAX_BYTES)
                or item.get("Name") not in SEED_FILES):
            fail("seed_stage_response_invalid", "invalid file descriptor", 75)
        names.append(item["Name"])
    if tuple(names) != SEED_FILES:
        fail("seed_stage_response_invalid", "unexpected file order or names", 75)
    return handle, names


def parse_payload_stage_response(out: bytes, payload: dict) -> None:
    prefix = b"PF_PAYLOAD_STAGED "
    if (len(out) > MAX_STAGE_STDOUT or out.count(b"\n") != 1
            or not out.endswith(b"\n") or not out.startswith(prefix)):
        fail("payload_stage_response_invalid", code=75)
    try:
        body = json.loads(out[len(prefix):-1].decode("ascii", "strict"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        fail("payload_stage_response_invalid", code=75)
    if (type(body) is not dict
            or set(body) != {"Schema", "Name", "Bytes", "SHA256"}
            or body != payload
            or prefix + canonical_json_line(body) != out):
        fail("payload_stage_response_invalid", code=75)


def stage_seed(node: str, bundle: bytes, sensitive: list[str]) -> tuple[str, list]:
    helper = env("WRITEBACK_B8_SEED_HELPER")
    dut = env("WRITEBACK_B8_SEED_DUT")
    remote = "sudo -n " + shlex.quote(helper) + " stage --dut " + shlex.quote(dut)
    rc, out, err = ssh_node(node, remote, bundle, 45)
    if rc != 0:
        sub = "node_ssh_failed" if rc == 255 else "helper_exit_nonzero"
        fail("seed_stage_failed",
             f"sub_reason={sub} rc={rc} stderr={redact(err.decode('utf-8', 'replace'), sensitive)!r}",
             75)
    return parse_seed_stage_response(out)


def stage_payload(node: str, handle: str, kit: Path, payload: dict) -> None:
    helper = env("WRITEBACK_B8_SEED_HELPER")
    remote = (
        "sudo -n " + shlex.quote(helper) + " stage-payload --handle "
        + shlex.quote(handle) + " --bytes " + str(payload["Bytes"])
        + " --sha256 " + shlex.quote(payload["SHA256"])
    )
    data = (kit / PAYLOAD_NAME).read_bytes()
    # The ~20 MiB candidate kernel traverses the bounded FAT payload leg at
    # roughly 22 KiB/s.  Allow 20 minutes without changing any DutExec bound.
    rc, out, err = ssh_node(node, remote, data, 1200)
    if rc != 0:
        sub = "node_ssh_failed" if rc == 255 else "helper_exit_nonzero"
        fail("payload_stage_failed",
             f"sub_reason={sub} rc={rc} stderr={redact(err.decode('utf-8', 'replace'), [])!r}",
             75)
    parse_payload_stage_response(out, payload)


def write_request(kit: Path, descriptor: dict, handle: str, payload: dict) -> str:
    request = {"ImageSource": descriptor, "SeedHandle": handle}
    if not network_only(kit):
        request["KitPayload"] = payload
    data = (json.dumps(request, indent=2, sort_keys=True) + "\n").encode("utf-8")
    path = kit / REQUEST_NAME
    tmp = kit / (REQUEST_NAME + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)
    return hashlib.sha256(data).hexdigest()


def discard_staged_handle(node: str, handle: str) -> bool:
    """Consume a caller-owned handle without hiding the original failure."""
    helper = env("WRITEBACK_B8_SEED_HELPER")
    dut = env("WRITEBACK_B8_SEED_DUT")
    remote = (
        "sudo -n " + shlex.quote(helper) + " discard --handle "
        + shlex.quote(handle) + " --dut " + shlex.quote(dut)
    )
    try:
        rc, out, err = ssh_node(node, remote, None, 45)
    except (SystemExit, KeyboardInterrupt) as error:
        print(
            "WRITEBACK_B8_SEAL_CLEANUP state=fail "
            f"handle={handle} error={type(error).__name__}",
            file=sys.stderr,
        )
        return False
    if rc != 0:
        tail = redact(err.decode("utf-8", "replace"), [])
        print(
            "WRITEBACK_B8_SEAL_CLEANUP state=fail "
            f"handle={handle} rc={rc} stderr={tail!r}",
            file=sys.stderr,
        )
        return False
    if out != b"":
        print(
            "WRITEBACK_B8_SEAL_CLEANUP state=fail "
            f"handle={handle} reason=discard_response_invalid",
            file=sys.stderr,
        )
        return False
    print(
        f"WRITEBACK_B8_SEAL_CLEANUP state=discarded handle={handle}",
        file=sys.stderr,
    )
    return True


def restore_template_state(kit: Path, original_manifest: bytes) -> None:
    """After a successful discard, remove the request and restore the template seal."""
    for name in (REQUEST_NAME, REQUEST_NAME + ".tmp", "SHA256SUMS.tmp"):
        path = kit / name
        if path.exists():
            path.unlink()
    tmp = kit / "SHA256SUMS.tmp"
    tmp.write_bytes(original_manifest)
    os.replace(tmp, kit / "SHA256SUMS")


def reseal(kit: Path) -> str:
    entries = []
    for path in sorted(kit.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(kit).as_posix()
        if rel in SEAL_EXCLUDES or rel.endswith(".tmp"):
            continue
        entries.append(f"{sha256_file(path)}  {rel}\n")
    manifest = "".join(entries).encode("utf-8")
    path = kit / "SHA256SUMS"
    tmp = kit / "SHA256SUMS.tmp"
    tmp.write_bytes(manifest)
    os.replace(tmp, path)
    return hashlib.sha256(manifest).hexdigest()


def remove_tree(path: Path) -> None:
    """Remove a private receipt without invoking a broad shell deletion."""
    if not path.exists():
        return
    for root, dirs, files in os.walk(path, topdown=False):
        root_path = Path(root)
        for name in files:
            (root_path / name).unlink()
        for name in dirs:
            child = root_path / name
            if child.is_symlink():
                child.unlink()
            else:
                child.rmdir()
    path.rmdir()


def sealed_smoke_gate(kit: Path, image_path: Path, image_sha: str,
                      transport_receipt: Path) -> None:
    """Run the same sealed-byte smoke gate used by direct-boot before queueing."""
    override = os.environ.get("WRITEBACK_B8_SEALED_SMOKE_TOOL")
    receipt: Path | None = None
    if override:
        if os.environ.get("WRITEBACK_B8_TESTING") != "1":
            fail("sealed_smoke_override_forbidden", code=76)
        argv = [override, str(kit), str(image_path), image_sha]
        expected = "WRITEBACK_B8_SEALED_SMOKE PASS"
    else:
        argv = [
            str(kit / "postseal-check.sh"), str(image_path), image_sha,
        ]
        expected = "POSTSEAL_CHECK PASS"
    try:
        try:
            checked = subprocess.run(
                argv,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=1800,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            fail(
                "sealed_smoke_failed",
                f"error={type(error).__name__}",
                code=76,
            )
        if checked.returncode != 0 or expected not in checked.stdout:
            detail = (
                f"rc={checked.returncode} "
                f"stdout={checked.stdout[-MAX_STDERR_TAIL:]!r} "
                f"stderr={checked.stderr[-MAX_STDERR_TAIL:]!r}"
            )
            fail("sealed_smoke_failed", detail, code=76)
        print(
            "WRITEBACK_B8_SEALED_SMOKE state=pass "
            f"entry=direct-boot image_sha256={image_sha}"
        )
    finally:
        if receipt is not None:
            remove_tree(receipt)


def queue_line(kit: Path, manifest_sha: str, image_path: Path, image_sha: str,
               transport_receipt: Path) -> str:
    path = kit / "queue.tsv"
    if not path.is_file():
        return ""
    rows = [line for line in path.read_text().splitlines()
            if line and not line.startswith("#")]
    if len(rows) != 1:
        return ""
    row = (
        rows[0].replace("@MANIFEST_SHA256@", manifest_sha)
        .replace("@BUILD8_IMAGE@", str(image_path))
        .replace("@BUILD8_SHA256@", image_sha)
        .replace("@TRANSPORT_RECEIPT@", str(transport_receipt))
    )
    fields = row.split("\t")
    if (len(fields) != 7 or "@" in row or fields[3] != manifest_sha
            or f"--image {image_path}" not in fields[6]
            or f"--image-sha256 {image_sha}" not in fields[6]
            or f"--transport-receipt-dir {transport_receipt}" not in fields[6]):
        return ""
    return row


def do_seal(args: argparse.Namespace) -> int:
    kit = Path(args.kit).resolve()
    if not (kit / TEMPLATE_NAME).is_file() or not (kit / "SHA256SUMS").is_file():
        fail("kit_invalid", f"path={kit}")
    verify_kit_seal(kit)
    validate_payload_contract(kit)
    reseal(kit)
    image_path, image_sha, descriptor = image_gate(args.image, args.image_sha256)
    template = load_template(kit)
    payload = load_payload_identity(kit)
    if template["ImageSource"] != descriptor:
        fail("template_image_mismatch")
    previous = kit / REQUEST_NAME
    if previous.is_file():
        fail(
            "prior_seed_ownership_unresolved",
            f"request={previous} action=discard_proven_caller_owned_handle_first",
        )
    original_manifest = (kit / "SHA256SUMS").read_bytes()
    node = args.node or env("WRITEBACK_B8_NODE")
    ssid = read_secret(env("WRITEBACK_B8_SECRET_TOOL"), env("WRITEBACK_B8_WIFI_SSID_NAME"))
    psk = read_secret(env("WRITEBACK_B8_SECRET_TOOL"), env("WRITEBACK_B8_WIFI_PSK_NAME"))
    comment = f"writeback-b8-r19-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    client_identity = ReceiptIdentity(args.transport_receipt_dir, comment)
    handle = ""
    released = False
    stage_signals = {signal.SIGINT, signal.SIGTERM}
    old_handlers = {}

    def interrupted(signum, _frame):
        raise SeedSignal(signum)

    try:
        bundle = seed_bundle(
            ssid, psk, client_identity.public_key, env("WRITEBACK_B8_WIFI_COUNTRY"),
        )
        for signum in stage_signals:
            old_handlers[signum] = signal.signal(signum, interrupted)
        old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, stage_signals)
        try:
            try:
                handle, names = stage_seed(
                    node, bundle,
                    [ssid, psk, client_identity.public_key],
                )
                # The handle becomes caller-owned when stage_seed returns.  Record it
                # durably before normal INT/TERM delivery or any reseal/queue work.
                request_sha = write_request(kit, descriptor, handle, payload)
                if not network_only(kit):
                    stage_payload(node, handle, kit, payload)
            finally:
                del bundle
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
        manifest_sha = reseal(kit)
        sealed_smoke_gate(kit, image_path, image_sha, client_identity.dir)
        row = queue_line(
            kit, manifest_sha, image_path, image_sha, client_identity.dir)
        if not row:
            fail("queue_row_invalid", f"discard={handle}", code=76)
        # Output and ownership transfer are one signal-atomic operation: before
        # this block cleanup discards; after it the emitted queued instance owns.
        old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, stage_signals)
        print(
            "WRITEBACK_B8_SEAL state=pass "
            f"kit={kit} image={image_path} image_sha256={image_sha} "
            f"seed_handle={handle} staged_files={','.join(names) or 'na'} "
            f"request_sha256={request_sha} manifest_sha256={manifest_sha} "
            f"key_fingerprint={client_identity.fingerprint} "
            "host_key_source=serial-control "
            f"payload_bytes={payload['Bytes']} payload_sha256={payload['SHA256']} "
            f"dut_transport={'network-only' if network_only(kit) else 'fat-root'} "
            f"node={node} dut={env('WRITEBACK_B8_SEED_DUT')}"
        )
        print("WRITEBACK_B8_QUEUE_LINE " + row)
        released = True
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)
    except BaseException as error:
        if handle and not released:
            cleanup_mask = signal.pthread_sigmask(signal.SIG_BLOCK, stage_signals)
            try:
                if discard_staged_handle(node, handle):
                    restore_template_state(kit, original_manifest)
                else:
                    # Keep the durable request and bind it into the manifest when
                    # possible so an operator can recover it with --discard.
                    try:
                        reseal(kit)
                    except (OSError, SystemExit):
                        pass
                    print(
                        "WRITEBACK_B8_SEAL_RECOVERY state=required "
                        f"handle={handle} request={kit / REQUEST_NAME}",
                        file=sys.stderr,
                    )
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, cleanup_mask)
        if isinstance(error, SeedSignal):
            fail("interrupted", f"signal={signal.Signals(error.signum).name}", 76)
        raise
    finally:
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)
        if not released:
            client_identity.cleanup()
    return 0


def do_check(args: argparse.Namespace) -> int:
    """Exercise the real seal-to-direct-boot path without secrets or staging."""
    kit = Path(args.kit).resolve()
    if not (kit / TEMPLATE_NAME).is_file() or not (kit / "SHA256SUMS").is_file():
        fail("kit_invalid", f"path={kit}")
    verify_kit_seal(kit)
    image_path, image_sha, descriptor = image_gate(args.image, args.image_sha256)
    if (kit / REQUEST_NAME).exists():
        fail("check_requires_unsealed_template")
    transport = Path(args.transport_receipt_dir).resolve()
    if not transport.is_dir():
        fail("transport_receipt_missing")
    root = Path(tempfile.mkdtemp(
        prefix="writeback-b8-no-stage-check.",
        dir=os.environ.get("RUNNER_TEMP", "/tmp"),
    ))
    try:
        checked_kit = root / "kit"
        shutil.copytree(kit, checked_kit)
        validate_payload_contract(checked_kit)
        template = load_template(checked_kit)
        payload = load_payload_identity(checked_kit)
        if template["ImageSource"] != descriptor:
            fail("template_image_mismatch")
        write_request(checked_kit, descriptor, "0" * 32, payload)
        reseal(checked_kit)
        sealed_smoke_gate(checked_kit, image_path, image_sha, transport)
        print(
            "WRITEBACK_B8_CHECK state=pass no_stage=1 secrets_read=0 node_calls=0 "
            f"image={image_path} image_sha256={image_sha}"
        )
        return 0
    finally:
        remove_tree(root)


def restore_discarded_request(kit: Path, handle: str) -> str:
    """Remove a request only after its exact handle was confirmed discarded."""
    request_path = kit / REQUEST_NAME
    try:
        request = json.loads(request_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        fail("discarded_request_restore_failed", f"error={type(error).__name__}", 76)
    if request.get("SeedHandle") != handle:
        fail("discarded_request_handle_mismatch", code=76)
    request_path.unlink()
    return reseal(kit)


def do_discard(args: argparse.Namespace) -> int:
    handle = args.discard
    if not HANDLE_RE.fullmatch(handle or ""):
        fail("seed_handle_invalid", f"value={handle!r}")
    node = args.node or env("WRITEBACK_B8_NODE")
    helper = env("WRITEBACK_B8_SEED_HELPER")
    dut = env("WRITEBACK_B8_SEED_DUT")
    remote = (
        "sudo -n " + shlex.quote(helper) + " discard --handle " + shlex.quote(handle)
        + " --dut " + shlex.quote(dut)
    )
    rc, out, err = ssh_node(node, remote, None, 45)
    if rc != 0:
        tail = redact(err.decode("utf-8", "replace"), [])
        print(f"WRITEBACK_B8_SEAL_DISCARD state=fail handle={handle} rc={rc} stderr={tail!r}",
              file=sys.stderr)
        return 75
    if out != b"":
        print(
            f"WRITEBACK_B8_SEAL_DISCARD state=fail handle={handle} "
            "reason=discard_response_invalid",
            file=sys.stderr,
        )
        return 75
    kit = Path(args.kit).resolve()
    manifest_sha = restore_discarded_request(kit, handle)
    print(
        f"WRITEBACK_B8_SEAL_DISCARD state=consumed handle={handle} node={node} dut={dut} "
        f"template_restored=1 manifest_sha256={manifest_sha}"
    )
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--kit", required=True)
    parser.add_argument("--image")
    parser.add_argument("--image-sha256")
    parser.add_argument("--node")
    parser.add_argument("--discard")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--transport-receipt-dir")
    args = parser.parse_args(argv)
    if args.discard:
        return do_discard(args)
    if not args.image or not args.image_sha256:
        parser.error("--image and --image-sha256 are required unless --discard")
    if not args.transport_receipt_dir:
        parser.error("--transport-receipt-dir is required unless --discard")
    if args.check:
        return do_check(args)
    return do_seal(args)


if __name__ == "__main__":
    sys.exit(main())
