#!/usr/bin/env python3
"""Fetch a managed run result's COMPLETE final text via run.evidence (source=result), chunked + sha-pinned.
run.result's final_text is capped at 2048 chars (pf_task/results.py text(final, 2048)); lane status
blocks live at the END of the text, so the capped copy loses them."""
import json, os, subprocess, sys

_ROUTES = {}


def _route(run_id):
    if run_id not in _ROUTES:
        root = os.environ.get("GPU14_ROOT", "/home/matt/recovery/gpu14")
        resolver = os.environ.get("PF_TASK_RUN_HOME_RESOLVER", root + "/pf-task-run-home")
        try:
            result = subprocess.run(
                [resolver, "resolve", run_id], capture_output=True, text=True,
                timeout=float(os.environ.get("PF_TASK_RUN_HOME_RESOLVE_TIMEOUT", "320")))
            value = json.loads(result.stdout)
        except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
            raise RuntimeError(f"run home unreadable: {run_id}: {exc}") from exc
        required = ("control_home", "pf_task", "host_config")
        if result.returncode or not isinstance(value, dict) or any(
                not isinstance(value.get(key), str) or not value[key] for key in required):
            raise RuntimeError(f"run home unresolved: {run_id}: rc={result.returncode}")
        _ROUTES[run_id] = value
    return _ROUTES[run_id]


def pf(run_id, op, args):
    route = _route(run_id)
    env = dict(os.environ, PF_TASK_HOST_CONFIG=route["host_config"])
    out = subprocess.run([route["pf_task"], "--home", route["control_home"], "--role", "coordinator", op, json.dumps(args)],
                         capture_output=True, text=True, timeout=120, env=env).stdout
    return json.loads(out)

def full_value(run_id, receipt):
    buf, off, sha = "", 0, None
    while True:
        a = {"run_id": run_id, "source": "result", "receipt": receipt, "offset": off, "limit": 8192}
        if sha:
            a["sha256"] = sha
        d = pf(run_id, "run.evidence", a)
        if "chunk" not in d:
            raise RuntimeError(f"evidence refused: {json.dumps(d)[:300]}")
        buf += d["chunk"]; sha = d["sha256"]
        if d.get("next_offset") is None:
            return json.loads(buf)
        off = d["next_offset"]

def final_text(value):
    parts = (value.get("assistant") or {}).get("parts") or []
    t = "\n".join(p.get("text", "") for p in parts if p.get("type") == "text")
    if t:
        return t
    # fall back: search any nested final text field
    def walk(o):
        if isinstance(o, dict):
            for k, v in o.items():
                if k in ("final_text", "text") and isinstance(v, str) and "LANE " in v:
                    return v
                r = walk(v)
                if r: return r
        elif isinstance(o, list):
            for v in o:
                r = walk(v)
                if r: return r
        return None
    return walk(value) or ""

def final_text_fast(run_id, receipt, tail=65536):
    """Keys serialize sorted, so assistant.parts follows the (huge) assistant.native item log and
    sits near the END (a lane result was 891 KB = ~110 8-KB pages). Read the sha-pinned first
    chunk, then only the last `tail` bytes, and decode the parts array from there. Falls back to
    a full read if the tail does not hold a complete parts array."""
    first = pf(run_id, "run.evidence", {"run_id": run_id, "source": "result", "receipt": receipt, "offset": 0, "limit": 8192})
    if "chunk" not in first:
        raise RuntimeError(f"evidence refused: {json.dumps(first)[:300]}")
    total, sha = first["total_bytes"], first["sha256"]
    if first.get("next_offset") is None:
        return final_text(json.loads(first["chunk"]))
    off, buf = max(8192, total - tail), ""
    start = off
    while off is not None:
        d = pf(run_id, "run.evidence", {"run_id": run_id, "source": "result", "receipt": receipt,
                                "offset": off, "limit": 8192, "sha256": sha})
        if "chunk" not in d:
            raise RuntimeError(f"evidence refused: {json.dumps(d)[:300]}")
        buf += d["chunk"]; off = d.get("next_offset")
    # The serialization ends with the final message's last text part: {"text":"...","type":"text"}]}]}.
    # Decode the LAST "text" string in the tail; the status block lives in that final part.
    i = buf.rfind('"text":"')
    if i >= 0:
        try:
            t, _ = json.JSONDecoder().raw_decode(buf, i + len('"text":'))
            if isinstance(t, str) and t:
                return t
        except ValueError:
            pass
    return final_text(full_value(run_id, receipt))


if __name__ == "__main__":
    print(final_text_fast(sys.argv[1], sys.argv[2]))
