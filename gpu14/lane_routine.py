"""Routine-turn classifier for gpu-14's lane supervisor (2026-09-27 ~16:10Z).

Every lane turn that only approved a child permission cost gpu-14 a full turn to read,
ACK and re-arm. This module lets the supervisor ACK such turns itself and keep watching,
waking gpu-14 only when a turn carries something for it. Any doubt wakes gpu-14:
- the turn must be outcome=completed / codex_completed;
- the COMPLETE final text (run.evidence, not the 2048-char run.result copy) must end in a
  `LANE <id> STATUS` block with INTEGRATION REQUESTS, BENCH REQUESTS and BLOCKERS lines;
- INTEGRATION REQUESTS must start with "None" and not mention gpu-14, or be identical to the
  previous classified turn's value (a standing request gpu-14 was already woken for);
- BENCH REQUESTS and BLOCKERS / OWNER QUESTIONS must each either start with "None" (and
  not mention gpu-14 or the owner) or be identical, after whitespace normalisation, to the
  value this run carried on the previous classified turn (a standing item already seen).
The verdict quotes the exact lines it scored (memory: a gate must quote the line it scored).
"""
import json
import os
import re

STATE_DIR = "/home/matt/recovery/gpu14/lane-routine"
KEYS = {"integration": "INTEGRATION REQUESTS", "bench": "BENCH REQUESTS",
        "blockers": "BLOCKERS / OWNER QUESTIONS"}


def norm(s):
    # 17:5xZ: lanes re-render the same standing line with/without markdown backticks or quotes;
    # formatting is not a change in the item.
    s = re.sub(r"[`*]", "", s or "")
    return re.sub(r"\s+", " ", s.strip())


def parse_status(text):
    """Return {integration, bench, blockers} from the LAST status block, or None."""
    starts = [m.start() for m in re.finditer(r"(?m)^LANE \S+ STATUS\b", text or "")]
    if not starts:
        return None
    block = text[starts[-1]:]
    out = {}
    for key, label in KEYS.items():
        if key == "blockers" and not _label(block, label):
            # 2026-10-02: FLEET g3 renders BLOCKERS and OWNER QUESTIONS as two headers. BOTH must be
            # present (else None, which wakes gpu-14); their items join, so either one being dirty wakes.
            parts = [_field(block, lab) for lab in ("BLOCKERS", "OWNER QUESTIONS")]
            if any(v is None for v in parts):
                return None
            out[key] = SEP.join(parts)
            continue
        value = _field(block, label)
        if value is None:
            return None
        out[key] = value
    return out


def _label(block, label):
    # 2026-10-02: CAP g6 / FLEET g3 write the label alone on its line ("INTEGRATION REQUESTS") then
    # bullets; the colon is optional. The label must still be the WHOLE head of the line.
    return re.search(r"(?m)^" + re.escape(label) + r"(?::[ \t]*|[ \t]+|$)(.*)$", block)


def _field(block, label):
    m = _label(block, label)
    if not m:
        return None
    value = m.group(1)
    if not value.strip():
        # 2026-09-28: CONF g4 renders each field as a bullet list on the following lines
        # ("INTEGRATION REQUESTS:\n- None until ..."), so the same-line value was empty and
        # every turn woke gpu-14. Collect the contiguous bullets. Each becomes one item, and
        # _none_clean requires EVERY item to be clean, so a real request in bullet 2 still wakes.
        items = []
        for line in block[m.end():].lstrip("\n").splitlines():
            b = re.match(r"^\s*[-*]\s+(.*)$", line)
            if not b:
                break
            items.append(norm(b.group(1)))
        value = SEP.join(items)
    return norm(value) if SEP not in value else value


SEP = " ;; "


def _none_clean(v, forbid):
    items = v.split(SEP) if v else [v]
    if not all(re.match(r"(?i)^none\b", i) for i in items):
        return False
    low = v.lower()
    return not any(f in low for f in forbid)


def verdict(text, last):
    """(routine: bool, reason: str, fields: dict|None)."""
    f = parse_status(text)
    if f is None:
        return False, "no_parseable_status_block", None
    if not _none_clean(f["integration"], ("gpu-14", "gpu14")) and not (
            last and norm(last.get("integration")) == f["integration"]):
        return False, "integration_request", f
    for key in ("bench", "blockers"):
        v = f[key]
        if _none_clean(v, ("gpu-14", "gpu14", "owner")):
            continue
        # 16:4xZ: a lane-internal blocker (review loop) that explicitly states there is no
        # owner question and never mentions gpu-14 needs nothing from gpu-14.
        low = v.lower()
        if key == "blockers" and re.search(r"\bno owner question", low) \
                and "gpu-14" not in low and "gpu14" not in low \
                and len(re.findall(r"owner", low)) == 1:
            continue
        if last and norm(last.get(key)) == v:
            continue
        return False, f"{key}_new_or_changed", f
    return True, "routine", f


def load_last(run_id):
    try:
        return json.load(open(os.path.join(STATE_DIR, run_id + ".json")))
    except Exception:
        return None


def save_last(run_id, fields):
    if not fields:
        return
    os.makedirs(STATE_DIR, exist_ok=True)
    p = os.path.join(STATE_DIR, run_id + ".json")
    tmp = p + ".tmp"
    json.dump(fields, open(tmp, "w"))
    os.replace(tmp, p)
