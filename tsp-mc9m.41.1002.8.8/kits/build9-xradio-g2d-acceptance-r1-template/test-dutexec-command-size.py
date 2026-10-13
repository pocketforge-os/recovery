#!/usr/bin/env python3
"""Run pf-kit-session's own step validator on every template DutExec command."""
from __future__ import annotations

import importlib
import re
import sys
from pathlib import Path


def fail(reason: str) -> None:
    print(f"BUILD9_DUTEXEC_SIZE_TEST state=FAIL reason={reason}")
    raise SystemExit(1)


def main() -> int:
    if len(sys.argv) != 2:
        fail("usage_session_source_required")
    root = Path(__file__).resolve().parent
    source = Path(sys.argv[1]).resolve()
    if source.name != "pf_kit_session_resume.py" or not source.is_file():
        fail("session_source_invalid")
    sys.path.insert(0, str(source.parent))
    resume = importlib.import_module("pf_kit_session_resume")
    runbook = (root / "RUNBOOK.md.in").read_text(encoding="utf-8")
    rawfiles = dict(re.findall(r'--rawfile\s+(\w+)\s+"\$kit/([^"\n]+)"', runbook))
    variables = re.findall(r'Transport:"dutexec",\s*\n?\s*Command:\$(\w+)', runbook)
    if not variables or len(variables) != len(set(variables)):
        fail("dutexec_discovery_invalid")
    checked: list[str] = []
    for variable in variables:
        relative = rawfiles.get(variable)
        if relative is None:
            fail(f"dutexec_source_unresolved_{variable}")
        command = (root / relative).read_text(encoding="utf-8")
        try:
            resume._validate_step({
                "Name": variable,
                "Transport": "dutexec",
                "Command": command,
            })
        except resume.session.SessionError as exc:
            print(
                "BUILD9_DUTEXEC_SIZE_TEST state=FAIL "
                f"command={relative} bytes={len(command.encode())} session_reason={exc.code}"
            )
            return 1
        checked.append(f"{relative}:{len(command.encode())}")

    resume._validate_step({"Name": "below-cap", "Transport": "dutexec",
                           "Command": "x" * 4095})
    try:
        resume._validate_step({"Name": "at-cap", "Transport": "dutexec",
                               "Command": "x" * 4096})
    except resume.session.SessionError as exc:
        if exc.code != "DUTEXEC_CONTROL_TOO_LARGE":
            fail(f"wrong_boundary_reason_{exc.code}")
    else:
        fail("session_boundary_control_accepted")
    print(
        "BUILD9_DUTEXEC_SIZE_TEST state=PASS "
        f"commands={len(checked)} details={','.join(checked)} boundary=4095_pass_4096_refused"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
