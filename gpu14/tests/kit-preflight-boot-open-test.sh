#!/usr/bin/env bash
# tsp-mc9m.41.1030.47: hermetic tests for kit-preflight.sh C13, the boot-open request render/receipt-path gate.
# Window 946aed02 sealed "OriginalBootReceipt": "@ORIGINAL_BOOT_RECEIPT@", passed preflight and stage, FelBooted and
# only then failed RESUME_RECEIPT_WRITE_FAILED. Everything is faked in a private temp root; only the C13 line is
# asserted (the other checks fail on this minimal package by design). No device, labgrid, runner, pf-task or network.
# usage: kit-preflight-boot-open-test.sh   rc 0 all pass
set -uo pipefail
BIN=${KP_BIN_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
KP=$BIN/kit-preflight.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/kp-boot-open-tests.XXXXXX"); trap '[ -n "${KEEP:-}" ] || rm -rf -- "$T"' EXIT
pass=0; fail=0; N=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1 :: ${2:-}"; }
G=11111111111111111111111111111111; OWN=pft-aaaaaaaaaaaaaaaaaaaaaaaa
export GPU14_ROOT=$T/root PF_KIT_WINDOWS_DIR=$T/kw PF_WINDOW_RUNNER_REPO=$T/clone KP_PUBLISH_ROOT=$T/root \
  KP_RUN_HOME=$T/fake-run-home KP_IMAGE_PATH_CHECK=$T/fake KP_CHAIN=$T/fake KP_BUDGET=$T/fake \
  KP_PLAN_PREFIX=$T/plans/ KP_DENYLIST=$T/root/image-denylist.txt KP_ARTIFACT_BASE=http://127.0.0.1:9/none
mkdir -p "$T"/{root,kw,clone,plans}; echo '# deny' > "$T/root/image-denylist.txt"
printf '#!/bin/sh\nexit 2\n' > "$T/fake-run-home"; printf '#!/bin/sh\nexit 2\n' > "$T/fake"
chmod +x "$T/fake-run-home" "$T/fake"

# pkg <name> <OriginalBootReceipt json value> [extra json fields]: a native-format template package.
pkg() {
  PK=$T/p$((++N))-$1; mkdir -p "$PK/series"; chmod 700 "$PK"
  printf '{"Anchor":"%s","Generation":"%s","FelBootRequest":"@STAGE_FROM_SEED_KIT@","OriginalBootReceipt":%s%s}\n' \
    "$PK/series/resume-anchor.json" "$G" "$2" "${3:-}" > "$PK/boot-open-request.template.json"
}
c13() { "$KP" "$PK" "$G" "$OWN" 2>&1 | grep '^KIT_PREFLIGHT check=C13 '; }
expect() {  # expect <name> <PASS|FAIL> <substring>
  local line; line=$(c13)
  case "$line" in *"result=$2 "*"$3"*) ok "$1" ;; *) no "$1" "${line:-no C13 line}" ;; esac
}

pkg rendered "\"__P__/series/initial-flash.json\""
sed -i "s#__P__#$PK#" "$PK/boot-open-request.template.json"
expect rendered_receipt_passes PASS boot_open_requests_rendered

# The 946aed02 shape.
pkg unrendered '"@ORIGINAL_BOOT_RECEIPT@"'
expect unrendered_receipt_token_fails FAIL "UNRENDERED_TEMPLATE_TOKEN file=boot-open-request.template.json tokens=@ORIGINAL_BOOT_RECEIPT@"
expect unrendered_receipt_path_fails FAIL "ORIGINAL_BOOT_RECEIPT_PATH_INVALID file=boot-open-request.template.json receipt=not_absolute"

pkg other_token "\"__P__/series/initial-flash.json\"" ',"Holder":"@HOLDER@","AnchorSHA256":"@POST_OPEN_ANCHOR_SHA256@"'
sed -i "s#__P__#$PK#" "$PK/boot-open-request.template.json"
expect other_token_fails_allowlist_kept FAIL "tokens=@HOLDER@ "

pkg relative '"series/initial-flash.json"'
expect relative_receipt_fails FAIL "receipt=not_absolute"

pkg outside "\"$T/elsewhere/initial-flash.json\""
expect outside_series_fails FAIL "receipt=outside_series"

pkg dotdot "\"__P__/series/../initial-flash.json\""
sed -i "s#__P__#$PK#" "$PK/boot-open-request.template.json"
expect dotdot_escape_fails FAIL "receipt=outside_series"

pkg existing "\"__P__/series/initial-flash.json\""
sed -i "s#__P__#$PK#" "$PK/boot-open-request.template.json"; echo '{}' > "$PK/series/initial-flash.json"
expect existing_receipt_fails FAIL "receipt=exists"

# boot-open creates missing parents (mkdir -p), so a missing intermediate directory passes; a non-directory component
# or a non-writable parent fails only after FEL and must be refused here.
pkg missing_parent "\"__P__/series/run-1/initial-flash.json\""
sed -i "s#__P__#$PK#" "$PK/boot-open-request.template.json"
expect missing_intermediate_dir_passes PASS boot_open_requests_rendered

pkg file_parent "\"__P__/series/blocker/initial-flash.json\""
sed -i "s#__P__#$PK#" "$PK/boot-open-request.template.json"; echo x > "$PK/series/blocker"
expect file_parent_fails FAIL "receipt=parent_unwritable:$PK/series/blocker"

pkg readonly_parent "\"__P__/series/initial-flash.json\""
sed -i "s#__P__#$PK#" "$PK/boot-open-request.template.json"; chmod 500 "$PK/series"
if [ -w "$PK/series" ]; then ok "readonly_parent_fails (skipped: running as a user that bypasses mode bits)"
else expect readonly_parent_fails FAIL "receipt=parent_unwritable:$PK/series"; fi
chmod 700 "$PK/series"

pkg missing ''
sed -i 's#,"OriginalBootReceipt":}#}#' "$PK/boot-open-request.template.json"
expect missing_receipt_fails FAIL "receipt=unreadable"

# glesproof: ~/recovery is a symlink, so the package path and the receipt path may name different spellings of the
# same directory. A receipt written through the realpath of a symlinked package root must pass, and the reverse.
mkdir -p "$T/real"; ln -s "$T/real" "$T/link"
PK=$T/real/pkg-sym; mkdir -p "$PK/series"; chmod 700 "$PK"
printf '{"Generation":"%s","FelBootRequest":"@STAGE_FROM_SEED_KIT@","OriginalBootReceipt":"%s"}\n' \
  "$G" "$T/real/pkg-sym/series/initial-flash.json" > "$PK/boot-open-request.template.json"
PK=$T/link/pkg-sym; expect symlinked_package_realpath_receipt_passes PASS boot_open_requests_rendered
printf '{"Generation":"%s","FelBootRequest":"@STAGE_FROM_SEED_KIT@","OriginalBootReceipt":"%s"}\n' \
  "$G" "$T/link/pkg-sym/series/initial-flash.json" > "$PK/boot-open-request.template.json"
PK=$T/real/pkg-sym; expect realpath_package_symlink_receipt_passes PASS boot_open_requests_rendered

# A staged request is checked too, and C13 is not overridable.
pkg staged "\"__P__/series/initial-flash.json\""
sed -i "s#__P__#$PK#" "$PK/boot-open-request.template.json"; mkdir -p "$PK/stage"
printf '{"OriginalBootReceipt":"@ORIGINAL_BOOT_RECEIPT@"}\n' > "$PK/stage/boot-open-request.json"
KIT_PREFLIGHT_OVERRIDE_C13="operator says it is fine" expect staged_request_checked_and_not_overridable FAIL "file=stage/boot-open-request.json"
line=$(KIT_PREFLIGHT_OVERRIDE_C13="operator says it is fine" c13)
case "$line" in *override_refused=not_overridable*) ok c13_override_refused ;; *) no c13_override_refused "$line" ;; esac

echo "kit-preflight-boot-open-test: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
