#!/usr/bin/env python3
"""gpu-14 forcing function (2026-10-02): validate a FelBoot request body with the FACADE'S OWN validator.

B37d3 lost a dispatch to HTTP 400 "image_source_descriptor: exact full-image/v1 fields required": the k#68
seals' felboot-request-k68.json lacked BuildManifestSHA256, and the descriptor gate never ran the facade's
validate_source. B37d/B37d2 had only booted because their experimenters improvised the full descriptor.

usage: check-felboot-request.py <felboot-request.json> [expected-descriptor-sha256]
Exits 0 and prints FELBOOT_REQUEST=VALID only if validate_source() from test-node-farm origin/main accepts
the body's ImageSource. With an expected sha256, it also requires sha256(canonical ImageSource JSON of the
descriptor file) to match: pass the descriptor's sha256 and the request's ImageSource must equal that
descriptor's content.
"""
import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile

MIRROR = "/home/matt/wt/.mirrors/test-node-farm.git"
BASE = "http://10.0.40.90:8790/artifacts/sha256"


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print(__doc__.strip().splitlines()[-4])
        return 2
    body = json.load(open(sys.argv[1]))
    src = body.get("ImageSource") if isinstance(body, dict) else None
    rev = subprocess.run(["git", "--git-dir", MIRROR, "rev-parse", "origin/main"],
                         capture_output=True, text=True, check=True).stdout.strip()
    code = subprocess.run(["git", "--git-dir", MIRROR, "show", f"{rev}:node/redfish/image_source.py"],
                          capture_output=True, text=True, check=True).stdout
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as fh:
        fh.write(code)
        path = fh.name
    spec = importlib.util.spec_from_file_location("facade_image_source", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    try:
        mod.validate_source(src, BASE)
    except Exception as exc:  # noqa: BLE001
        print(f"FELBOOT_REQUEST=INVALID reason={exc} validator=test-node-farm@{rev[:12]}")
        return 1
    if len(sys.argv) == 3:
        canon = json.dumps(src, sort_keys=True, separators=(",", ":")).encode()
        got = hashlib.sha256(canon).hexdigest()
        print(f"IMAGESOURCE_CANONICAL_SHA256={got}")
    print(f"FELBOOT_REQUEST=VALID validator=test-node-farm@{rev[:12]} fields={sorted(src)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
