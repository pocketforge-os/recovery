#!/usr/bin/env python3
"""Fail-closed bulk transport for sealed PocketForge device kits.

The helper accepts only a direct route to the bench /24, binds SSH to that
route's source address, and never invokes a serial program.  Kit runners keep
the per-run private key in their mode-0700 receipt directory and must install a
trap that calls ``teardown-key`` on both success and failure.
"""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import ipaddress
import json
import os
from pathlib import Path, PurePosixPath
import re
import select
import shlex
import socket
import stat
import subprocess
import sys
import time


BENCH_NETWORK = ipaddress.ip_network("192.168.86.0/24")
PRIVATE_KEY_NAME = "ssh-ed25519"
PUBLIC_KEY_NAME = "ssh-ed25519.pub"
RECEIPT_NAME = "transport.log"
SSH_ATTEMPTS = 3
SSH_CONNECT_TIMEOUT_SECONDS = 10
SSH_PROCESS_TIMEOUT_SECONDS = 12
TRANSFER_TIMEOUT_SECONDS = 600
RETRY_DELAY_SECONDS = 1
DUTEXEC_CONTROL_MAX_BYTES = 4096
ITER_MAX_FILES = 32
ITER_MAX_FILE_BYTES = 64 * 1024 * 1024
ITER_MAX_TOTAL_BYTES = 256 * 1024 * 1024
PUSH_EXEC_MAX_COMMAND_BYTES = 16 * 1024
PUSH_EXEC_MAX_TARGET_PATHS = 64
PUSH_EXEC_MIN_TIMEOUT_SECONDS = 1
PUSH_EXEC_MAX_TIMEOUT_SECONDS = 900
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
USER = re.compile(r"[A-Za-z_][A-Za-z0-9_.-]{0,31}\Z")
INTERFACE = re.compile(r"[A-Za-z0-9_.:@-]{1,64}\Z")
SERIAL_REASON = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z")
HOST_KEY_TYPE = re.compile(r"[A-Za-z0-9][A-Za-z0-9@._+-]{0,63}\Z")
HOST_KEY_MAX_BYTES = 4096
FORBIDDEN_INTERFACES = (
    "tailscale", "tun", "tap", "wg", "vpn", "ipsec", "ppp", "gre",
    "gretap", "sit", "ip6tnl", "vxlan", "docker", "veth", "virbr",
)
_SELF_SOURCE_FD: int | None = None


class TransportError(RuntimeError):
    def __init__(self, reason: str, *, transport: str = "ssh",
                 direction: str = "control", interface: str = "none",
                 source: str = "none", attempts: int | None = None):
        super().__init__(reason)
        self.reason = reason
        self.transport = transport
        self.direction = direction
        self.interface = interface
        self.source = source
        self.attempts = attempts


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def validate_receipt_dir(raw: str) -> Path:
    path = Path(raw)
    try:
        info = path.lstat()
    except OSError as exc:
        raise TransportError("receipt_directory_invalid") from exc
    if (not stat.S_ISDIR(info.st_mode) or path.is_symlink()
            or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise TransportError("receipt_directory_invalid")
    return path


def append_receipt(receipt_dir: Path, line: str) -> None:
    path = receipt_dir / RECEIPT_NAME
    flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                or stat.S_IMODE(info.st_mode) != 0o600):
            os.close(fd)
            raise TransportError("transport_receipt_invalid")
        os.write(fd, (line + "\n").encode("ascii"))
        os.fsync(fd)
        os.close(fd)
    except TransportError:
        raise
    except OSError as exc:
        raise TransportError("transport_receipt_unwritable") from exc


def emit(receipt_dir: Path, fields: list[tuple[str, str | int]], *,
         error: bool = False) -> None:
    line = "PF_KIT_TRANSPORT " + " ".join(
        f"{key}={value}" for key, value in fields)
    if any(character not in "\t" and not (32 <= ord(character) <= 126)
           for character in line):
        raise TransportError("transport_receipt_invalid")
    append_receipt(receipt_dir, line)
    print(line, file=sys.stderr if error else sys.stdout, flush=True)


def validate_host(raw: str) -> str:
    try:
        address = ipaddress.ip_address(raw)
    except ValueError as exc:
        raise TransportError("bench_host_invalid") from exc
    if address.version != 4 or address not in BENCH_NETWORK \
            or address in {BENCH_NETWORK.network_address, BENCH_NETWORK.broadcast_address}:
        raise TransportError("bench_host_invalid")
    return str(address)


def route_for(host: str, direction: str) -> tuple[str, str]:
    try:
        result = subprocess.run(
            ["ip", "-json", "route", "get", host], check=False,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise TransportError("route_unavailable", direction=direction) from exc
    if result.returncode != 0:
        raise TransportError("route_unavailable", direction=direction)
    try:
        routes = json.loads(result.stdout.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise TransportError("route_unreadable", direction=direction) from exc
    if type(routes) is not list or len(routes) != 1 or type(routes[0]) is not dict:
        raise TransportError("route_unreadable", direction=direction)
    route = routes[0]
    interface = route.get("dev", "none")
    source = route.get("prefsrc", route.get("src", "none"))
    if not isinstance(interface, str) or INTERFACE.fullmatch(interface) is None:
        interface = "none"
    if not isinstance(source, str):
        source = "none"
    lower_interface = interface.lower()
    if (lower_interface == "lo"
            or any(lower_interface.startswith(prefix)
                   for prefix in FORBIDDEN_INTERFACES)):
        raise TransportError(
            "route_transport_forbidden", direction=direction,
            interface=interface, source=source)
    if "gateway" in route or "via" in route \
            or route.get("type", "unicast") != "unicast":
        raise TransportError(
            "route_not_direct", direction=direction,
            interface=interface, source=source)
    try:
        source_address = ipaddress.ip_address(source)
    except ValueError as exc:
        raise TransportError(
            "route_source_invalid", direction=direction,
            interface=interface, source="none") from exc
    if source_address.version != 4 or source_address not in BENCH_NETWORK:
        raise TransportError(
            "route_source_forbidden", direction=direction,
            interface=interface, source=source)
    return interface, str(source_address)


def validate_key(receipt_dir: Path) -> Path:
    key = receipt_dir / PRIVATE_KEY_NAME
    try:
        info = key.lstat()
    except OSError as exc:
        raise TransportError("private_key_invalid") from exc
    if (not stat.S_ISREG(info.st_mode) or key.is_symlink()
            or info.st_uid != os.geteuid() or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size == 0):
        raise TransportError("private_key_invalid")
    return key


def validate_host_key(raw: str, expected_sha256: str, host: str) -> str:
    path = Path(raw)
    if not path.is_absolute() or HEX64.fullmatch(expected_sha256) is None:
        raise TransportError("host_key_invalid")
    flags = os.O_RDONLY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        fd = os.open(path, flags)
        try:
            info = os.fstat(fd)
            mode = stat.S_IMODE(info.st_mode)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or info.st_nlink != 1 or mode not in {0o600, 0o644}
                    or info.st_size <= 0 or info.st_size > HOST_KEY_MAX_BYTES):
                raise TransportError("host_key_invalid")
            data = os.read(fd, HOST_KEY_MAX_BYTES + 1)
            if len(data) != info.st_size:
                raise TransportError("host_key_invalid")
        finally:
            os.close(fd)
    except TransportError:
        raise
    except OSError as exc:
        raise TransportError("host_key_invalid") from exc
    if hashlib.sha256(data).hexdigest() != expected_sha256:
        raise TransportError("host_key_invalid")
    try:
        text = data.decode("ascii")
        lines = text.splitlines()
        fields = lines[0].split()
        decoded_key = base64.b64decode(fields[2], validate=True)
    except (UnicodeError, IndexError, binascii.Error) as exc:
        raise TransportError("host_key_invalid") from exc
    if (len(lines) != 1 or len(fields) != 3 or fields[0] != host
            or HOST_KEY_TYPE.fullmatch(fields[1]) is None
            or len(decoded_key) < 16):
        raise TransportError("host_key_invalid")
    canonical = f"{fields[0]} {fields[1]} {fields[2]}\n".encode("ascii")
    if data != canonical:
        raise TransportError("host_key_invalid")
    return shlex.join([
        "/usr/bin/printf", f"{fields[0]} {fields[1]} {fields[2]}\\n",
    ])


def assert_route(host: str, direction: str, interface: str, source: str) -> None:
    current_interface, current_source = route_for(host, direction)
    if (current_interface, current_source) != (interface, source):
        raise TransportError(
            "route_changed", direction=direction,
            interface=current_interface, source=current_source)


def assert_explicit_route(host: str, direction: str, interface: str,
                          source: str) -> None:
    """Verify the caller-selected device route, bypassing policy-table capture."""
    try:
        result = subprocess.run(
            ["ip", "-json", "route", "get", host,
             "oif", interface, "from", source],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=5,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise TransportError(
            "route_transport_forbidden", direction=direction,
            interface=interface, source=source) from exc
    try:
        routes = json.loads(result.stdout.decode("utf-8"))
        route = routes[0]
        observed_interface = route.get("dev")
        observed_source = route.get("prefsrc", route.get("src"))
    except (UnicodeError, json.JSONDecodeError, IndexError, KeyError,
            TypeError, AttributeError) as exc:
        raise TransportError(
            "route_transport_forbidden", direction=direction,
            interface=interface, source=source) from exc
    if (result.returncode != 0 or type(routes) is not list or len(routes) != 1
            or type(route) is not dict or observed_interface != interface
            or observed_source != source or "gateway" in route or "via" in route
            or route.get("type", "unicast") != "unicast"):
        raise TransportError(
            "route_transport_forbidden", direction=direction,
            interface=interface, source=source)


def self_source_path() -> str:
    global _SELF_SOURCE_FD
    if _SELF_SOURCE_FD is None:
        flags = os.O_RDONLY | os.O_NOFOLLOW
        if hasattr(os, "O_CLOEXEC"):
            flags |= os.O_CLOEXEC
        try:
            fd = os.open(Path(__file__).resolve(), flags)
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                os.close(fd)
                raise TransportError("transport_helper_invalid")
        except OSError as exc:
            raise TransportError("transport_helper_invalid") from exc
        _SELF_SOURCE_FD = fd
    return f"/proc/{os.getpid()}/fd/{_SELF_SOURCE_FD}"


def direct_proxy_command(host: str, interface: str, source: str) -> str:
    return shlex.join([
        sys.executable, "-B", self_source_path(), "_direct-connect",
        "--host", host, "--interface", interface, "--source", source,
    ])


def ssh_base(key: Path, known_hosts_command: str, host: str, source: str,
             interface: str) -> list[str]:
    return [
        "ssh",
        "-F", "/dev/null",
        "-o", "BatchMode=yes",
        "-o", "IdentitiesOnly=yes",
        "-o", f"ProxyCommand={direct_proxy_command(host, interface, source)}",
        "-o", "ProxyJump=none",
        "-o", f"ConnectTimeout={SSH_CONNECT_TIMEOUT_SECONDS}",
        "-o", "ConnectionAttempts=1",
        "-o", "StrictHostKeyChecking=yes",
        "-o", "GlobalKnownHostsFile=/dev/null",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", f"KnownHostsCommand={known_hosts_command}",
        "-o", f"BindInterface={interface}",
        "-b", source,
        "-i", str(key),
    ]


def run_probe(host: str, user: str, key: Path, known_hosts_command: str,
              interface: str, source: str, direction: str) -> float:
    start = time.monotonic()
    command = [
        *ssh_base(key, known_hosts_command, host, source, interface),
        f"{user}@{host}", "true",
    ]
    for attempt in range(1, SSH_ATTEMPTS + 1):
        assert_route(host, direction, interface, source)
        try:
            result = subprocess.run(
                command, check=False, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=SSH_PROCESS_TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.TimeoutExpired):
            result = None
        assert_route(host, direction, interface, source)
        if result is not None and result.returncode == 0:
            return time.monotonic() - start
        if attempt != SSH_ATTEMPTS:
            time.sleep(RETRY_DELAY_SECONDS)
    raise TransportError(
        "network_transport_unavailable", direction=direction,
        interface=interface, source=source, attempts=SSH_ATTEMPTS)


def validate_expected(byte_count: int, digest: str) -> None:
    if byte_count < 0 or byte_count > (1 << 63) - 1 or HEX64.fullmatch(digest) is None:
        raise TransportError("payload_identity_invalid")


def validate_user(user: str) -> str:
    if USER.fullmatch(user) is None:
        raise TransportError("ssh_user_invalid")
    return user


def validate_remote_path(raw: str) -> str:
    path = PurePosixPath(raw)
    if (not raw.startswith("/") or str(path) != raw
            or any(part in {"", ".", ".."} for part in path.parts[1:])
            or any(character in raw for character in "\x00\r\n")):
        raise TransportError("remote_path_invalid")
    return raw


def verify_local_source(path: Path, byte_count: int, digest: str) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise TransportError("local_payload_invalid", direction="in") from exc
    if (not stat.S_ISREG(info.st_mode) or path.is_symlink()
            or info.st_uid != os.geteuid() or info.st_size != byte_count
            or sha256_file(path) != digest):
        raise TransportError("local_payload_mismatch", direction="in")


def rsync_ssh(key: Path, known_hosts_command: str, host: str, source: str,
              interface: str) -> str:
    return shlex.join(ssh_base(
        key, known_hosts_command, host, source, interface))


def scp_base(key: Path, known_hosts_command: str, host: str, source: str,
             interface: str) -> list[str]:
    """Build SCP arguments from the exact SSH identity and route options."""
    command = ssh_base(key, known_hosts_command, host, source, interface)
    bind_index = command.index("-b")
    del command[bind_index:bind_index + 2]
    return ["scp", "-O", *command[1:], "-o", f"BindAddress={source}"]


def iteration_error(error: TransportError, operation: str) -> TransportError:
    if error.reason in {
            "route_unavailable", "route_unreadable", "route_transport_forbidden",
            "route_not_direct", "route_source_invalid", "route_source_forbidden",
            "route_changed", "direct_socket_unavailable"}:
        reason = "route_forbidden"
    elif error.reason in {"network_transport_unavailable", "remote_exec_failed"}:
        reason = "ssh_unreachable"
    else:
        return error
    return TransportError(
        reason, direction=operation, interface=error.interface,
        source=error.source, attempts=error.attempts)


def run_push_ssh(command: list[str], *, host: str, interface: str,
                 source: str, timeout: int, operation: str = "push-exec",
                 stdout: object = subprocess.DEVNULL,
                 stderr: object = subprocess.DEVNULL,
                 timeout_reason: str = "ssh_unreachable") \
        -> subprocess.CompletedProcess[bytes]:
    assert_route(host, operation, interface, source)
    try:
        completed = subprocess.run(
            command, check=False, stdin=subprocess.DEVNULL,
            stdout=stdout, stderr=stderr, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        raise TransportError(
            timeout_reason, direction=operation,
            interface=interface, source=source) from exc
    except OSError as exc:
        raise TransportError(
            "ssh_unreachable", direction=operation,
            interface=interface, source=source) from exc
    assert_route(host, operation, interface, source)
    return completed


def run_push_scp(command: list[str], *, host: str,
                 interface: str, source: str,
                 operation: str = "push-exec") -> None:
    for attempt in range(1, SSH_ATTEMPTS + 1):
        completed = run_push_ssh(
            command, host=host, interface=interface, source=source,
            timeout=TRANSFER_TIMEOUT_SECONDS, operation=operation,
        )
        if completed.returncode == 0:
            return
        if attempt != SSH_ATTEMPTS:
            time.sleep(RETRY_DELAY_SECONDS)
    raise TransportError(
        "ssh_unreachable", direction=operation, interface=interface,
        source=source, attempts=SSH_ATTEMPTS)


def validate_push_files(raw_files: list[list[str]],
                        operation: str = "push-exec") \
        -> tuple[list[dict[str, object]], int]:
    if not 1 <= len(raw_files) <= ITER_MAX_FILES:
        raise TransportError("transfer_bounds", direction=operation)
    files: list[dict[str, object]] = []
    names: set[str] = set()
    total_bytes = 0
    for source_raw, name, digest in raw_files:
        source = Path(source_raw)
        if (not source.is_absolute()
                or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", name) is None
                or name in names or HEX64.fullmatch(digest) is None):
            raise TransportError("transfer_bounds", direction=operation)
        try:
            byte_count = source.lstat().st_size
        except OSError as exc:
            raise TransportError("local_payload_invalid", direction=operation) from exc
        total_bytes += byte_count
        if (byte_count > ITER_MAX_FILE_BYTES
                or total_bytes > ITER_MAX_TOTAL_BYTES):
            raise TransportError("transfer_bounds", direction=operation)
        names.add(name)
        files.append({
            "Source": source, "Name": name, "Bytes": byte_count,
            "SHA256": digest,
        })
    for item in files:
        verify_local_source(
            item["Source"], int(item["Bytes"]), str(item["SHA256"]))
    return files, total_bytes


def validate_push_request(args: argparse.Namespace) \
        -> tuple[list[dict[str, object]], list[str]]:
    if (not 0 <= args.sequence <= 999_999_999
            or not PUSH_EXEC_MIN_TIMEOUT_SECONDS <= args.timeout_seconds
            <= PUSH_EXEC_MAX_TIMEOUT_SECONDS
            or not isinstance(args.command_text, str)
            or not args.command_text
            or "\x00" in args.command_text
            or len(args.command_text.encode("utf-8")) > PUSH_EXEC_MAX_COMMAND_BYTES
            or len(args.target_path) > PUSH_EXEC_MAX_TARGET_PATHS):
        raise TransportError("transfer_bounds", direction="push-exec")
    files, unused_total_bytes = validate_push_files(args.file)
    target_paths: list[str] = []
    for raw in args.target_path:
        try:
            target_paths.append(validate_remote_path(raw))
        except TransportError as exc:
            raise TransportError("transfer_bounds", direction="push-exec") from exc
    return files, target_paths


def is_persistent_path(path: str) -> bool:
    return any(path == root or path.startswith(root + "/")
               for root in ("/boot", "/etc", "/lib/modules"))


def open_side_file(path: Path) -> object:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
        return os.fdopen(fd, "wb")
    except OSError as exc:
        raise TransportError("push_exec_receipt_invalid", direction="push-exec") from exc


def side_file_identity(path: Path) -> dict[str, object]:
    try:
        info = path.lstat()
    except OSError as exc:
        raise TransportError("push_exec_receipt_invalid", direction="push-exec") from exc
    if (not stat.S_ISREG(info.st_mode) or path.is_symlink()
            or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600):
        raise TransportError("push_exec_receipt_invalid", direction="push-exec")
    return {"Path": str(path), "Bytes": info.st_size, "SHA256": sha256_file(path)}


def iteration_receipt(*, operation: str, sequence: int,
                      files: list[dict[str, object]], command: str | None = None,
                      return_code: int | None = None,
                      stdout_path: Path | None = None,
                      stderr_path: Path | None = None,
                      persistent_mutation: bool = False) -> dict[str, object]:
    """Adapt push, push-exec, and pull evidence to one receipt shape."""
    outcome = "pass" if return_code in {None, 0} else "fail"
    verified_dut_files = {
        str(item["RemotePath"]): str(item["RemoteSHA256"])
        for item in files
    }
    return {
        "Schema": "pocketforge.iteration-transport/v1", "Transport": "ssh",
        "Operation": operation, "Sequence": sequence, "Outcome": outcome,
        "Error": None if outcome == "pass" else "command_failed",
        "Files": files, "VerifiedDutFiles": verified_dut_files,
        "Command": command, "RC": return_code,
        "Stdout": side_file_identity(stdout_path) if stdout_path else None,
        "Stderr": side_file_identity(stderr_path) if stderr_path else None,
        "PersistentMutation": persistent_mutation,
    }


def write_iteration_receipt(receipt_dir: Path, operation: str, sequence: int,
                            value: dict[str, object]) -> Path:
    path = receipt_dir / f"{operation}-{sequence}.json"
    payload = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
    try:
        fd = os.open(path, flags, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    except OSError as exc:
        raise TransportError(
            "iteration_receipt_invalid", direction=operation) from exc
    return path


def validate_sequence(sequence: int, operation: str) -> None:
    if not 0 <= sequence <= 999_999_999:
        raise TransportError("transfer_bounds", direction=operation)


def prepare_iteration_connection(args: argparse.Namespace, receipt_dir: Path,
                                 operation: str) \
        -> tuple[str, str, Path, str, str, str]:
    host = validate_host(args.host)
    user = validate_user(args.user)
    key = validate_key(receipt_dir)
    known_hosts_command = validate_host_key(
        args.host_key_file, args.host_key_sha256, host)
    interface, source = route_for(host, operation)
    run_probe(
        host, user, key, known_hosts_command, interface, source, operation)
    return host, user, key, known_hosts_command, interface, source


def initialize_upload_root(*, sequence: int, host: str, user: str, key: Path,
                           known_hosts_command: str, interface: str,
                           source: str, operation: str) -> str:
    remote_root = f"/run/pf-iter/{sequence}"
    initialize = (
        "set -eu; sudo -n /usr/bin/install -d -o root -g root -m 0755 "
        "/run/pf-iter; if sudo -n /usr/bin/test -e "
        + shlex.quote(remote_root) + "; then exit 73; fi; "
        "sudo -n /usr/bin/install -d -o " + shlex.quote(user)
        + " -g " + shlex.quote(user) + " -m 0700 "
        + shlex.quote(remote_root)
    )
    initialized = run_push_ssh(
        [*ssh_base(key, known_hosts_command, host, source, interface),
         f"{user}@{host}", initialize], host=host, interface=interface,
        source=source, timeout=SSH_PROCESS_TIMEOUT_SECONDS,
        operation=operation,
    )
    if initialized.returncode != 0:
        raise TransportError(
            "ssh_unreachable", direction=operation,
            interface=interface, source=source)
    return remote_root


def upload_iteration_files(*, files: list[dict[str, object]],
                           remote_root: str, host: str, user: str, key: Path,
                           known_hosts_command: str, interface: str,
                           source: str, operation: str) \
        -> list[dict[str, object]]:
    uploaded: list[dict[str, object]] = []
    for index, item in enumerate(files):
        remote_path = f"{remote_root}/{item['Name']}"
        incoming = f"{remote_path}.incoming-{index}"
        run_push_scp([
            *scp_base(key, known_hosts_command, host, source, interface),
            str(item["Source"]), f"{user}@{host}:{incoming}",
        ], host=host, interface=interface, source=source,
            operation=operation)
        verify = (
            "set -eu; bytes=$(sudo -n /usr/bin/stat -c %s -- "
            + shlex.quote(incoming)
            + "); actual=$(sudo -n /usr/bin/sha256sum -- "
            + shlex.quote(incoming) + "); actual=${actual%% *}; "
            "printf 'PF_ITER_UPLOAD_IDENTITY %s %s\\n' \"$bytes\" \"$actual\"; "
            "test \"$bytes\" = " + shlex.quote(str(item["Bytes"]))
            + " || exit 42; test \"$actual\" = "
            + shlex.quote(str(item["SHA256"]))
            + " || exit 42; sudo -n /usr/bin/chown root:root -- "
            + shlex.quote(incoming)
            + "; sudo -n /usr/bin/chmod 0700 -- " + shlex.quote(incoming)
            + "; sudo -n /usr/bin/mv -- " + shlex.quote(incoming)
            + " " + shlex.quote(remote_path)
        )
        verified = run_push_ssh(
            [*ssh_base(key, known_hosts_command, host, source, interface),
             f"{user}@{host}", verify], host=host, interface=interface,
            source=source, timeout=SSH_PROCESS_TIMEOUT_SECONDS,
            operation=operation, stdout=subprocess.PIPE,
        )
        output = verified.stdout.decode("ascii", errors="replace").splitlines()
        identity = next((line.split() for line in output
                         if line.startswith("PF_ITER_UPLOAD_IDENTITY ")), [])
        if verified.returncode == 42:
            raise TransportError(
                "sha_mismatch", direction=operation,
                interface=interface, source=source)
        if verified.returncode != 0:
            raise TransportError(
                "ssh_unreachable", direction=operation,
                interface=interface, source=source)
        try:
            remote_bytes = int(identity[1])
            remote_sha = identity[2]
        except (ValueError, IndexError) as exc:
            raise TransportError(
                "sha_mismatch", direction=operation,
                interface=interface, source=source) from exc
        if remote_bytes != item["Bytes"] or remote_sha != item["SHA256"]:
            raise TransportError(
                "sha_mismatch", direction=operation,
                interface=interface, source=source)
        uploaded.append({
            "Name": item["Name"], "Direction": "in",
            "LocalPath": str(item["Source"]), "RemotePath": remote_path,
            "LocalBytes": item["Bytes"], "LocalSHA256": item["SHA256"],
            "RemoteBytes": remote_bytes, "RemoteSHA256": remote_sha,
            "Verified": True,
        })
    return uploaded


def emit_iteration_complete(*, receipt_dir: Path, operation: str,
                            sequence: int, files: list[dict[str, object]],
                            receipt: dict[str, object], interface: str,
                            source: str) -> None:
    receipt_path = write_iteration_receipt(
        receipt_dir, operation, sequence, receipt)
    emit(receipt_dir, [
        ("state", "complete"), ("transport", "ssh"),
        ("direction", operation), ("operation", operation),
        ("sequence", sequence), ("files", len(files)),
        ("bytes", sum(int(item["LocalBytes"]) for item in files)),
        ("outcome", str(receipt["Outcome"])),
        ("persistent_mutation",
         str(receipt["PersistentMutation"]).lower()),
        ("receipt", receipt_path.name), ("interface", interface),
        ("source", source),
    ])


def command_push(args: argparse.Namespace, receipt_dir: Path) -> None:
    operation = "push"
    validate_sequence(args.sequence, operation)
    files, unused_total_bytes = validate_push_files(args.file, operation)
    try:
        connection = prepare_iteration_connection(args, receipt_dir, operation)
        host, user, key, known_hosts_command, interface, source = connection
        remote_root = initialize_upload_root(
            sequence=args.sequence, host=host, user=user, key=key,
            known_hosts_command=known_hosts_command, interface=interface,
            source=source, operation=operation)
        uploaded = upload_iteration_files(
            files=files, remote_root=remote_root, host=host, user=user,
            key=key, known_hosts_command=known_hosts_command,
            interface=interface, source=source, operation=operation)
        receipt = iteration_receipt(
            operation=operation, sequence=args.sequence, files=uploaded)
        emit_iteration_complete(
            receipt_dir=receipt_dir, operation=operation,
            sequence=args.sequence, files=uploaded, receipt=receipt,
            interface=interface, source=source)
    except TransportError as exc:
        raise iteration_error(exc, operation) from exc


def command_push_exec(args: argparse.Namespace, receipt_dir: Path) -> None:
    operation = "push-exec"
    files, target_paths = validate_push_request(args)
    try:
        connection = prepare_iteration_connection(args, receipt_dir, operation)
        host, user, key, known_hosts_command, interface, source = connection
        remote_root = initialize_upload_root(
            sequence=args.sequence, host=host, user=user, key=key,
            known_hosts_command=known_hosts_command, interface=interface,
            source=source, operation=operation)
        uploaded = upload_iteration_files(
            files=files, remote_root=remote_root, host=host, user=user,
            key=key, known_hosts_command=known_hosts_command,
            interface=interface, source=source, operation=operation)
        stdout_path = receipt_dir / f"push-exec-{args.sequence}.stdout"
        stderr_path = receipt_dir / f"push-exec-{args.sequence}.stderr"
        remote_command = (
            ": PF_PUSH_EXEC_COMMAND; sudo -n /usr/bin/timeout --signal=TERM "
            f"--kill-after=5 {args.timeout_seconds} /usr/bin/env -i "
            "HOME=/root USER=root LOGNAME=root "
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "
            "LANG=C LC_ALL=C /bin/sh -c " + shlex.quote(args.command_text)
        )
        with open_side_file(stdout_path) as stdout_stream, \
                open_side_file(stderr_path) as stderr_stream:
            completed = run_push_ssh(
                [*ssh_base(key, known_hosts_command, host, source, interface),
                 f"{user}@{host}", remote_command], host=host,
                interface=interface, source=source,
                timeout=args.timeout_seconds + SSH_CONNECT_TIMEOUT_SECONDS + 10,
                operation=operation, stdout=stdout_stream,
                stderr=stderr_stream, timeout_reason="timeout")
        if completed.returncode == 124:
            raise TransportError(
                "timeout", direction=operation,
                interface=interface, source=source)
        if completed.returncode == 255:
            raise TransportError(
                "ssh_unreachable", direction=operation,
                interface=interface, source=source)
        persistent_mutation = any(is_persistent_path(path)
                                  for path in target_paths)
        receipt = iteration_receipt(
            operation=operation, sequence=args.sequence, files=uploaded,
            command=args.command_text, return_code=completed.returncode,
            stdout_path=stdout_path, stderr_path=stderr_path,
            persistent_mutation=persistent_mutation)
        emit_iteration_complete(
            receipt_dir=receipt_dir, operation=operation,
            sequence=args.sequence, files=uploaded, receipt=receipt,
            interface=interface, source=source)
    except TransportError as exc:
        raise iteration_error(exc, operation) from exc


def validate_pull_files(raw_files: list[list[str]]) -> list[dict[str, str]]:
    operation = "pull"
    if not 1 <= len(raw_files) <= ITER_MAX_FILES:
        raise TransportError("transfer_bounds", direction=operation)
    files: list[dict[str, str]] = []
    names: set[str] = set()
    for remote_raw, name in raw_files:
        try:
            remote = validate_remote_path(remote_raw)
        except TransportError as exc:
            raise TransportError("transfer_bounds", direction=operation) from exc
        if (re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", name) is None
                or name in names):
            raise TransportError("transfer_bounds", direction=operation)
        names.add(name)
        files.append({"RemotePath": remote, "Name": name})
    return files


def inspect_pull_file(*, remote_path: str, host: str, user: str, key: Path,
                      known_hosts_command: str, interface: str,
                      source: str) -> tuple[int, str]:
    operation = "pull"
    inspect = (
        "set -eu; if ! sudo -n /usr/bin/test -e -- "
        + shlex.quote(remote_path)
        + "; then printf 'PF_ITER_PULL_MISSING\\n'; exit 44; fi; "
        "sudo -n /usr/bin/test -f -- " + shlex.quote(remote_path)
        + " || exit 45; bytes=$(sudo -n /usr/bin/stat -c %s -- "
        + shlex.quote(remote_path)
        + "); actual=$(sudo -n /usr/bin/sha256sum -- "
        + shlex.quote(remote_path)
        + "); actual=${actual%% *}; printf 'PF_ITER_PULL_IDENTITY %s %s\\n' "
        '"$bytes" "$actual"'
    )
    completed = run_push_ssh(
        [*ssh_base(key, known_hosts_command, host, source, interface),
         f"{user}@{host}", inspect], host=host, interface=interface,
        source=source, timeout=SSH_PROCESS_TIMEOUT_SECONDS,
        operation=operation, stdout=subprocess.PIPE)
    if completed.returncode == 44:
        raise TransportError(
            "path_missing", direction=operation,
            interface=interface, source=source)
    if completed.returncode == 45:
        raise TransportError(
            "path_not_regular", direction=operation,
            interface=interface, source=source)
    if completed.returncode != 0:
        raise TransportError(
            "ssh_unreachable", direction=operation,
            interface=interface, source=source)
    line = next((line.split() for line in
                 completed.stdout.decode("ascii", errors="replace").splitlines()
                 if line.startswith("PF_ITER_PULL_IDENTITY ")), [])
    try:
        byte_count = int(line[1])
        digest = line[2]
    except (ValueError, IndexError) as exc:
        raise TransportError(
            "sha_mismatch", direction=operation,
            interface=interface, source=source) from exc
    if byte_count < 0 or HEX64.fullmatch(digest) is None:
        raise TransportError(
            "sha_mismatch", direction=operation,
            interface=interface, source=source)
    return byte_count, digest


def create_pull_directory(receipt_dir: Path, sequence: int) -> Path:
    destination = receipt_dir / f"pull-{sequence}"
    try:
        destination.mkdir(mode=0o700)
    except OSError as exc:
        raise TransportError("pull_receipt_invalid", direction="pull") from exc
    return destination


def initialize_pull_root(*, sequence: int, host: str, user: str, key: Path,
                         known_hosts_command: str, interface: str,
                         source: str) -> str:
    operation = "pull"
    remote_root = f"/run/pf-iter/{sequence}"
    initialize = (
        "set -eu; sudo -n /usr/bin/install -d -o root -g root -m 0755 "
        "/run/pf-iter; if sudo -n /usr/bin/test -e "
        + shlex.quote(remote_root) + "; then exit 73; fi; "
        "sudo -n /usr/bin/install -d -o root -g root -m 0755 "
        + shlex.quote(remote_root) + "; : PF_ITER_PULL_ROOT"
    )
    completed = run_push_ssh(
        [*ssh_base(key, known_hosts_command, host, source, interface),
         f"{user}@{host}", initialize], host=host, interface=interface,
        source=source, timeout=SSH_PROCESS_TIMEOUT_SECONDS,
        operation=operation)
    if completed.returncode == 73:
        raise TransportError(
            "stale_sequence", direction=operation,
            interface=interface, source=source)
    if completed.returncode != 0:
        raise TransportError(
            "ssh_unreachable", direction=operation,
            interface=interface, source=source)
    return remote_root


def pull_iteration_file(*, item: dict[str, object], index: int,
                        remote_root: str, destination_dir: Path, host: str,
                        user: str, key: Path, known_hosts_command: str,
                        interface: str, source: str) -> dict[str, object]:
    operation = "pull"
    staged = f"{remote_root}/.pull-{index}-{item['Name']}"
    stage = (
        "set -eu; sudo -n /usr/bin/test ! -e " + shlex.quote(staged)
        + "; sudo -n /usr/bin/install -o " + shlex.quote(user)
        + " -g " + shlex.quote(user) + " -m 0600 -- "
        + shlex.quote(str(item["RemotePath"])) + " " + shlex.quote(staged)
        + "; actual=$(sudo -n /usr/bin/sha256sum -- " + shlex.quote(staged)
        + "); actual=${actual%% *}; test \"$actual\" = "
        + shlex.quote(str(item["RemoteSHA256"]))
        + " || exit 42; : PF_ITER_PULL_STAGE"
    )
    staged_result = run_push_ssh(
        [*ssh_base(key, known_hosts_command, host, source, interface),
         f"{user}@{host}", stage], host=host, interface=interface,
        source=source, timeout=SSH_PROCESS_TIMEOUT_SECONDS,
        operation=operation)
    if staged_result.returncode == 42:
        raise TransportError(
            "sha_mismatch", direction=operation,
            interface=interface, source=source)
    if staged_result.returncode != 0:
        raise TransportError(
            "ssh_unreachable", direction=operation,
            interface=interface, source=source)
    destination = destination_dir / str(item["Name"])
    partial = destination_dir / f".{item['Name']}.partial"
    run_push_scp([
        *scp_base(key, known_hosts_command, host, source, interface),
        f"{user}@{host}:{staged}", str(partial),
    ], host=host, interface=interface, source=source, operation=operation)
    try:
        info = partial.lstat()
        local_sha = sha256_file(partial)
    except OSError as exc:
        raise TransportError(
            "sha_mismatch", direction=operation,
            interface=interface, source=source) from exc
    if (not stat.S_ISREG(info.st_mode) or partial.is_symlink()
            or info.st_uid != os.geteuid()
            or info.st_size != item["RemoteBytes"]
            or local_sha != item["RemoteSHA256"]):
        raise TransportError(
            "sha_mismatch", direction=operation,
            interface=interface, source=source)
    partial.chmod(0o600)
    os.replace(partial, destination)
    directory_fd = os.open(destination_dir, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    return {
        "Name": item["Name"], "Direction": "out",
        "LocalPath": str(destination), "RemotePath": item["RemotePath"],
        "LocalBytes": info.st_size, "LocalSHA256": local_sha,
        "RemoteBytes": item["RemoteBytes"],
        "RemoteSHA256": item["RemoteSHA256"], "Verified": True,
    }


def command_pull(args: argparse.Namespace, receipt_dir: Path) -> None:
    operation = "pull"
    validate_sequence(args.sequence, operation)
    requested = validate_pull_files(args.file)
    try:
        connection = prepare_iteration_connection(args, receipt_dir, operation)
        host, user, key, known_hosts_command, interface, source = connection
        total_bytes = 0
        inspected: list[dict[str, object]] = []
        for item in requested:
            byte_count, digest = inspect_pull_file(
                remote_path=item["RemotePath"], host=host, user=user, key=key,
                known_hosts_command=known_hosts_command, interface=interface,
                source=source)
            total_bytes += byte_count
            if (byte_count > ITER_MAX_FILE_BYTES
                    or total_bytes > ITER_MAX_TOTAL_BYTES):
                raise TransportError(
                    "transfer_bounds", direction=operation,
                    interface=interface, source=source)
            inspected.append({**item, "RemoteBytes": byte_count,
                              "RemoteSHA256": digest})
        remote_root = initialize_pull_root(
            sequence=args.sequence, host=host, user=user, key=key,
            known_hosts_command=known_hosts_command, interface=interface,
            source=source)
        destination_dir = create_pull_directory(receipt_dir, args.sequence)
        pulled = [
            pull_iteration_file(
                item=item, index=index, remote_root=remote_root,
                destination_dir=destination_dir, host=host, user=user, key=key,
                known_hosts_command=known_hosts_command, interface=interface,
                source=source)
            for index, item in enumerate(inspected)
        ]
        receipt = iteration_receipt(
            operation=operation, sequence=args.sequence, files=pulled)
        emit_iteration_complete(
            receipt_dir=receipt_dir, operation=operation,
            sequence=args.sequence, files=pulled, receipt=receipt,
            interface=interface, source=source)
    except TransportError as exc:
        raise iteration_error(exc, operation) from exc


def command_direct_connect(args: argparse.Namespace) -> None:
    host = validate_host(args.host)
    if INTERFACE.fullmatch(args.interface) is None:
        raise TransportError("route_transport_forbidden")
    try:
        source_address = ipaddress.ip_address(args.source)
    except ValueError as exc:
        raise TransportError("route_source_invalid") from exc
    if source_address.version != 4 or source_address not in BENCH_NETWORK:
        raise TransportError("route_source_forbidden")
    assert_explicit_route(host, "control", args.interface, str(source_address))
    if not hasattr(socket, "SO_BINDTODEVICE"):
        raise TransportError("direct_socket_unavailable")
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as connection:
            connection.setsockopt(
                socket.SOL_SOCKET, socket.SO_BINDTODEVICE,
                (args.interface + "\0").encode("ascii"),
            )
            connection.setsockopt(socket.SOL_SOCKET, socket.SO_DONTROUTE, 1)
            connection.settimeout(SSH_CONNECT_TIMEOUT_SECONDS)
            connection.bind((str(source_address), 0))
            connection.connect((host, 22))
            connection.settimeout(None)
            stdin_open = True
            while True:
                readers: list[object] = [connection]
                if stdin_open:
                    readers.append(sys.stdin.buffer)
                ready, _, _ = select.select(readers, [], [])
                if connection in ready:
                    block = connection.recv(65536)
                    if not block:
                        return
                    sys.stdout.buffer.write(block)
                    sys.stdout.buffer.flush()
                if stdin_open and sys.stdin.buffer in ready:
                    block = os.read(sys.stdin.fileno(), 65536)
                    if block:
                        connection.sendall(block)
                    else:
                        connection.shutdown(socket.SHUT_WR)
                        stdin_open = False
    except (OSError, ValueError) as exc:
        raise TransportError("direct_socket_unavailable") from exc


def run_transfer(command: list[str], *, direction: str,
                 host: str, interface: str, source: str) -> None:
    for attempt in range(1, SSH_ATTEMPTS + 1):
        assert_route(host, direction, interface, source)
        try:
            result = subprocess.run(
                command, check=False, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=TRANSFER_TIMEOUT_SECONDS,
            )
        except (OSError, subprocess.TimeoutExpired):
            result = None
        assert_route(host, direction, interface, source)
        if result is not None and result.returncode == 0:
            return
        if attempt != SSH_ATTEMPTS:
            time.sleep(RETRY_DELAY_SECONDS)
    raise TransportError(
        "network_transport_unavailable", direction=direction,
        interface=interface, source=source, attempts=SSH_ATTEMPTS)


def complete_fields(*, direction: str, operation: str, byte_count: int,
                    digest: str, seconds: float, interface: str,
                    source: str,
                    host_key_sha256: str) -> list[tuple[str, str | int]]:
    rate = int(byte_count / seconds) if seconds > 0 else byte_count
    return [
        ("state", "complete"), ("transport", "ssh"),
        ("direction", direction), ("operation", operation),
        ("bytes", byte_count), ("seconds", f"{seconds:.3f}"),
        ("bytes_per_second", rate), ("sha256", digest),
        ("host_key_sha256", host_key_sha256),
        ("interface", interface), ("source", source),
    ]


def command_probe(args: argparse.Namespace, receipt_dir: Path) -> None:
    host = validate_host(args.host)
    user = validate_user(args.user)
    key = validate_key(receipt_dir)
    known_hosts_command = validate_host_key(
        args.host_key_file, args.host_key_sha256, host)
    interface, source = route_for(host, "control")
    seconds = run_probe(
        host, user, key, known_hosts_command, interface, source, "control")
    emit(receipt_dir, complete_fields(
        direction="control", operation="probe", byte_count=0,
        digest=EMPTY_SHA256, seconds=seconds,
        interface=interface, source=source,
        host_key_sha256=args.host_key_sha256))


def command_send(args: argparse.Namespace, receipt_dir: Path) -> None:
    validate_expected(args.expected_bytes, args.expected_sha256)
    local = Path(args.source)
    remote = validate_remote_path(args.destination)
    verify_local_source(local, args.expected_bytes, args.expected_sha256)
    host = validate_host(args.host)
    user = validate_user(args.user)
    key = validate_key(receipt_dir)
    known_hosts_command = validate_host_key(
        args.host_key_file, args.host_key_sha256, host)
    interface, source = route_for(host, "in")
    start = time.monotonic()
    run_probe(host, user, key, known_hosts_command, interface, source, "in")
    run_transfer([
        "rsync", "--archive", "--partial", "--protect-args", "--timeout=30",
        "-e", rsync_ssh(
            key, known_hosts_command, host, source, interface), str(local),
        f"{user}@{host}:{remote}",
    ], direction="in", host=host, interface=interface, source=source)
    proof_command = (
        "set -eu; stat -c %s -- " + shlex.quote(remote)
        + "; sha256sum -- " + shlex.quote(remote)
    )
    assert_route(host, "in", interface, source)
    try:
        proof = subprocess.run(
            [*ssh_base(key, known_hosts_command, host, source, interface),
             f"{user}@{host}", proof_command],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=SSH_PROCESS_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise TransportError(
            "remote_verification_failed", direction="in",
            interface=interface, source=source) from exc
    assert_route(host, "in", interface, source)
    try:
        lines = proof.stdout.decode("ascii").splitlines()
        remote_bytes = int(lines[0])
        remote_sha = lines[1].split()[0]
    except (UnicodeError, ValueError, IndexError) as exc:
        raise TransportError(
            "remote_verification_failed", direction="in",
            interface=interface, source=source) from exc
    if (proof.returncode != 0 or remote_bytes != args.expected_bytes
            or remote_sha != args.expected_sha256):
        raise TransportError(
            "transferred_payload_mismatch", direction="in",
            interface=interface, source=source)
    emit(receipt_dir, complete_fields(
        direction="in", operation="send", byte_count=args.expected_bytes,
        digest=args.expected_sha256, seconds=time.monotonic() - start,
        interface=interface, source=source,
        host_key_sha256=args.host_key_sha256))


def command_collect(args: argparse.Namespace, receipt_dir: Path) -> None:
    validate_expected(args.expected_bytes, args.expected_sha256)
    remote = validate_remote_path(args.source)
    destination = Path(args.destination)
    if (not destination.is_absolute() or not destination.parent.is_dir()
            or destination.is_symlink() or destination.exists()):
        raise TransportError("collection_destination_invalid", direction="out")
    partial = Path(str(destination) + ".partial")
    if partial.is_symlink() or (partial.exists() and not partial.is_file()):
        raise TransportError("collection_partial_invalid", direction="out")
    host = validate_host(args.host)
    user = validate_user(args.user)
    key = validate_key(receipt_dir)
    known_hosts_command = validate_host_key(
        args.host_key_file, args.host_key_sha256, host)
    interface, source = route_for(host, "out")
    start = time.monotonic()
    run_probe(host, user, key, known_hosts_command, interface, source, "out")
    run_transfer([
        "rsync", "--archive", "--partial", "--append-verify",
        "--protect-args", "--timeout=30",
        "-e", rsync_ssh(
            key, known_hosts_command, host, source, interface),
        f"{user}@{host}:{remote}", str(partial),
    ], direction="out", host=host, interface=interface, source=source)
    try:
        info = partial.lstat()
        actual_sha = sha256_file(partial)
    except OSError as exc:
        raise TransportError(
            "transferred_payload_mismatch", direction="out",
            interface=interface, source=source) from exc
    if (not stat.S_ISREG(info.st_mode) or partial.is_symlink()
            or info.st_uid != os.geteuid() or info.st_size != args.expected_bytes
            or actual_sha != args.expected_sha256):
        raise TransportError(
            "transferred_payload_mismatch", direction="out",
            interface=interface, source=source)
    os.replace(partial, destination)
    directory_fd = os.open(destination.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)
    emit(receipt_dir, complete_fields(
        direction="out", operation="collect", byte_count=args.expected_bytes,
        digest=args.expected_sha256, seconds=time.monotonic() - start,
        interface=interface, source=source,
        host_key_sha256=args.host_key_sha256))


def command_emergency(args: argparse.Namespace, receipt_dir: Path) -> None:
    validate_expected(args.expected_bytes, args.expected_sha256)
    if os.environ.get("PF_KIT_ALLOW_SERIAL_BULK") != "1":
        raise TransportError(
            "serial_bulk_forbidden", transport="serial-emergency",
            direction=args.direction)
    reason = os.environ.get("PF_KIT_SERIAL_BULK_REASON", "")
    if SERIAL_REASON.fullmatch(reason) is None:
        raise TransportError(
            "serial_bulk_reason_required", transport="serial-emergency",
            direction=args.direction)
    raise TransportError(
        "serial_bulk_emergency_unavailable", transport="serial-emergency",
        direction=args.direction)


def command_control_check(args: argparse.Namespace, receipt_dir: Path) -> None:
    if (args.request_bytes < 0 or args.response_bytes < 0
            or args.request_bytes > DUTEXEC_CONTROL_MAX_BYTES
            or args.response_bytes > DUTEXEC_CONTROL_MAX_BYTES):
        raise TransportError(
            "control_size_exceeded", transport="serial-control")
    emit(receipt_dir, [
        ("state", "control_accepted"), ("transport", "serial-control"),
        ("direction", "control"), ("request_bytes", args.request_bytes),
        ("response_bytes", args.response_bytes),
        ("cap_bytes", DUTEXEC_CONTROL_MAX_BYTES),
        ("interface", "none"), ("source", "none"),
    ])


def command_teardown(receipt_dir: Path) -> None:
    states = []
    for name in (PRIVATE_KEY_NAME, PUBLIC_KEY_NAME):
        path = receipt_dir / name
        try:
            path.unlink()
            states.append("deleted")
        except FileNotFoundError:
            states.append("absent")
        except OSError as exc:
            raise TransportError(
                "private_key_teardown_failed", transport="none") from exc
    emit(receipt_dir, [
        ("state", "key_deleted"), ("transport", "none"),
        ("direction", "control"), ("bytes", 0), ("seconds", "0.000"),
        ("bytes_per_second", 0), ("sha256", EMPTY_SHA256),
        ("interface", "none"), ("source", "none"),
        ("private_key", states[0]), ("public_key", states[1]),
    ])


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    commands = result.add_subparsers(dest="command", required=True)

    def add_connection(command: argparse.ArgumentParser) -> None:
        command.add_argument("--host", required=True)
        command.add_argument("--user", required=True)
        command.add_argument("--receipt-dir", required=True)
        command.add_argument("--host-key-file", required=True)
        command.add_argument("--host-key-sha256", required=True)

    probe = commands.add_parser("probe")
    add_connection(probe)
    send = commands.add_parser("send")
    add_connection(send)
    send.add_argument("--source", required=True)
    send.add_argument("--destination", required=True)
    send.add_argument("--expected-bytes", required=True, type=int)
    send.add_argument("--expected-sha256", required=True)
    collect = commands.add_parser("collect")
    add_connection(collect)
    collect.add_argument("--source", required=True)
    collect.add_argument("--destination", required=True)
    collect.add_argument("--expected-bytes", required=True, type=int)
    collect.add_argument("--expected-sha256", required=True)
    def add_push_files(command: argparse.ArgumentParser) -> None:
        command.add_argument("--sequence", required=True, type=int)
        command.add_argument(
            "--file", action="append", nargs=3, default=[],
            metavar=("SOURCE", "NAME", "EXPECTED_SHA256"),
        )

    push = commands.add_parser("push")
    add_connection(push)
    add_push_files(push)
    push_exec = commands.add_parser("push-exec")
    add_connection(push_exec)
    add_push_files(push_exec)
    push_exec.add_argument(
        "--command", dest="command_text", required=True)
    push_exec.add_argument("--timeout-seconds", required=True, type=int)
    push_exec.add_argument("--target-path", action="append", default=[])
    pull = commands.add_parser("pull")
    add_connection(pull)
    pull.add_argument("--sequence", required=True, type=int)
    pull.add_argument(
        "--file", action="append", nargs=2, default=[],
        metavar=("REMOTE_PATH", "NAME"),
    )
    emergency = commands.add_parser("emergency-authorize")
    emergency.add_argument("--receipt-dir", required=True)
    emergency.add_argument("--direction", choices=("in", "out"), required=True)
    emergency.add_argument("--expected-bytes", required=True, type=int)
    emergency.add_argument("--expected-sha256", required=True)
    control = commands.add_parser("control-check")
    control.add_argument("--receipt-dir", required=True)
    control.add_argument("--request-bytes", required=True, type=int)
    control.add_argument("--response-bytes", required=True, type=int)
    teardown = commands.add_parser("teardown-key")
    teardown.add_argument("--receipt-dir", required=True)
    direct = commands.add_parser("_direct-connect")
    direct.add_argument("--host", required=True)
    direct.add_argument("--interface", required=True)
    direct.add_argument("--source", required=True)
    return result


def refusal_fields(error: TransportError) -> list[tuple[str, str | int]]:
    fields: list[tuple[str, str | int]] = [
        ("state", "refused"), ("reason", error.reason),
        ("transport", error.transport), ("direction", error.direction),
    ]
    if error.attempts is not None:
        fields.extend([
            ("attempts", error.attempts), ("serial_bulk", "forbidden"),
        ])
    fields.extend([
        ("interface", error.interface), ("source", error.source),
    ])
    return fields


def main() -> int:
    args = parser().parse_args()
    if args.command == "_direct-connect":
        try:
            command_direct_connect(args)
            return 0
        except TransportError:
            return 75
    receipt_dir: Path | None = None
    try:
        receipt_dir = validate_receipt_dir(args.receipt_dir)
        if args.command == "probe":
            command_probe(args, receipt_dir)
        elif args.command == "send":
            command_send(args, receipt_dir)
        elif args.command == "collect":
            command_collect(args, receipt_dir)
        elif args.command == "push":
            command_push(args, receipt_dir)
        elif args.command == "push-exec":
            command_push_exec(args, receipt_dir)
        elif args.command == "pull":
            command_pull(args, receipt_dir)
        elif args.command == "emergency-authorize":
            command_emergency(args, receipt_dir)
        elif args.command == "control-check":
            command_control_check(args, receipt_dir)
        elif args.command == "teardown-key":
            command_teardown(receipt_dir)
        else:
            raise TransportError("transport_command_invalid")
        return 0
    except TransportError as exc:
        fields = refusal_fields(exc)
        if receipt_dir is not None:
            try:
                emit(receipt_dir, fields, error=True)
            except TransportError:
                print(
                    "PF_KIT_TRANSPORT state=refused "
                    "reason=transport_receipt_unwritable transport=none "
                    "direction=control interface=none source=none",
                    file=sys.stderr,
                )
        else:
            print(
                "PF_KIT_TRANSPORT "
                + " ".join(f"{key}={value}" for key, value in fields),
                file=sys.stderr,
            )
        return 75


if __name__ == "__main__":
    raise SystemExit(main())
