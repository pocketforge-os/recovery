#!/usr/bin/env python3
"""Approve one exact pf_task turn-end check after a newly sent canary arm starts."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import time


PF_TASK = "/home/matt/.pf-task-v2/bin/pf-task"
HOME = "/home/matt/.pf-task-v2"


def call(operation, payload, *, check=True):
    proc = subprocess.run(
        [PF_TASK, "--home", HOME, "--role", "coordinator", operation,
         json.dumps(payload, separators=(",", ":"))],
        text=True,
        capture_output=True,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"{operation} failed rc={proc.returncode} stdout={proc.stdout!r} stderr={proc.stderr!r}"
        )
    return proc


def pinned_run_evidence(run_id):
    for attempt in range(1, 61):
        first = call("run.evidence", {
            "run_id": run_id, "source": "run", "offset": 0, "limit": 8192,
        })
        page = json.loads(first.stdout)
        digest = page["sha256"]
        total = page["total_bytes"]
        chunks = [page["chunk"]]
        offset = page.get("next_offset")
        consistent = True
        while offset is not None:
            later = call("run.evidence", {
                "run_id": run_id,
                "source": "run",
                "offset": offset,
                "limit": 8192,
                "sha256": digest,
            }, check=False)
            if later.returncode != 0:
                consistent = False
                break
            item = json.loads(later.stdout)
            if "chunk" not in item:
                consistent = False
                break
            chunks.append(item["chunk"])
            offset = item.get("next_offset")
        if consistent:
            raw = "".join(chunks)
            if len(raw.encode("utf-8")) != total:
                raise RuntimeError("pinned evidence byte count mismatch")
            return json.loads(raw), digest, attempt
    raise RuntimeError("unable to obtain a consistent pinned run evidence snapshot")


def validate_permission(run_id, status, evidence):
    projected = status.get("blocker", {}).get("permissions", [])
    permissions = evidence.get("permissions", [])
    if status.get("state") != "permission_blocked":
        raise RuntimeError(f"permission projected from unexpected state={status.get('state')}")
    if len(projected) != 1 or len(permissions) != 1:
        raise RuntimeError(
            f"expected exactly one permission, projected={len(projected)} evidence={len(permissions)}"
        )
    permission = permissions[0]
    projected_id = projected[0].get("id", {}).get("text")
    if projected_id != permission.get("id"):
        raise RuntimeError("projected permission id disagrees with pinned evidence")
    if permission.get("method") != "mcpServer/elicitation/request":
        raise RuntimeError(f"foreign method={permission.get('method')!r}")
    params = permission.get("params")
    if not isinstance(params, dict):
        raise RuntimeError("permission params missing")
    if params.get("serverName") != "pf_task":
        raise RuntimeError(f"foreign serverName={params.get('serverName')!r}")
    if params.get("mode") != "form":
        raise RuntimeError(f"foreign mode={params.get('mode')!r}")
    if params.get("requestedSchema") != {"type": "object", "properties": {}}:
        raise RuntimeError(f"foreign requestedSchema={params.get('requestedSchema')!r}")
    meta = params.get("_meta")
    if not isinstance(meta, dict):
        raise RuntimeError("permission _meta missing")
    if meta.get("codex_approval_kind") != "mcp_tool_call":
        raise RuntimeError(f"foreign codex_approval_kind={meta.get('codex_approval_kind')!r}")
    if meta.get("tool_description") != "run.turn_end_check":
        raise RuntimeError(f"foreign tool_description={meta.get('tool_description')!r}")
    if meta.get("tool_params") != {"run_id": run_id}:
        raise RuntimeError(f"foreign tool_params={meta.get('tool_params')!r}")
    return permission


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run_id")
    parser.add_argument("baseline_messages", type=int)
    parser.add_argument("evidence_path", type=Path)
    args = parser.parse_args()
    deadline = time.monotonic() + 120
    arm_seen = False
    while time.monotonic() < deadline:
        status = json.loads(call("run.status", {"run_id": args.run_id}).stdout)
        messages = status.get("messages", {})
        if messages.get("total", 0) > args.baseline_messages or messages.get("pending", 0) > 0:
            arm_seen = True
        count = status.get("blocker", {}).get("permission_count", 0)
        if count:
            if not arm_seen:
                raise RuntimeError("permission appeared before the new arm was observed")
            evidence, digest, attempts = pinned_run_evidence(args.run_id)
            permission = validate_permission(args.run_id, status, evidence)
            record = {
                "validated_at": time.time(),
                "run_id": args.run_id,
                "evidence_sha256": digest,
                "evidence_capture_attempts": attempts,
                "permission": permission,
            }
            args.evidence_path.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n")
            print(json.dumps(record, sort_keys=True), flush=True)
            response = json.loads(call("run.permission", {
                "run_id": args.run_id,
                "request_id": permission["id"],
                "decision": "once",
            }).stdout)
            print(json.dumps({"approval_response": response}, sort_keys=True), flush=True)
            if response.get("request_id") != permission["id"]:
                raise RuntimeError("approval response request id mismatch")
            return 0
        if arm_seen and status.get("state") in {"awaiting_release", "released", "blocked"}:
            raise RuntimeError(f"new arm became terminal before permission: state={status.get('state')}")
        time.sleep(2)
    raise RuntimeError("approval window expired after 120 seconds")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"APPROVER_STOP: {exc}", file=sys.stderr, flush=True)
        raise SystemExit(1)
