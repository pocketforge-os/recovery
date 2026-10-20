#!/usr/bin/env bash
# tsp-mc9m.41.1030.47.1: hermetic tests that kit-preflight.sh C9, C10 and C11 fail closed on coverage and read errors.
# Review of recovery#19: comments-only/malformed/unreadable automation floors passed C9; hidden, dangling or unreadable
# series/ entries passed C10; hidden, dangling, nested or unreadable requests-sealed/ inputs and BOOT_READY passed C11.
# Everything is faked in a private temp root; only the asserted check's line is read (the other checks fail on these
# minimal packages by design). No device, labgrid, runner, pf-task or network.
# usage: kit-preflight-fail-closed-test.sh   rc 0 all pass
set -uo pipefail
BIN=${KP_BIN_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
KP=$BIN/kit-preflight.sh
T=$(mktemp -d "${TMPDIR:-/tmp}/kp-fail-closed-tests.XXXXXX")
trap 'chmod -R u+rwx "$T" 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf -- "$T"' EXIT
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
# A runner checkout with floor commit A, head B (contains A) and a side commit X (not an ancestor of B).
git -C "$T/clone" init -q -b main && git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m A
A=$(git -C "$T/clone" rev-parse HEAD)
git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m B; B=$(git -C "$T/clone" rev-parse HEAD)
git -C "$T/clone" checkout -q -b side "$A" && git -C "$T/clone" -c user.name=t -c user.email=t@t commit -q --allow-empty -m X
X=$(git -C "$T/clone" rev-parse HEAD); git -C "$T/clone" checkout -q main
ROOT_BYPASS=0; touch "$T/probe"; chmod 000 "$T/probe"; [ -r "$T/probe" ] && ROOT_BYPASS=1; chmod 600 "$T/probe"
FL=$T/root/kit-automation-floor.txt

pkg() {  # pkg <name>: a minimal package pinned at B
  PK=$T/p$((++N))-$1; mkdir -p "$PK/series"; chmod 700 "$PK"
  printf '{"AutomationSHA":"%s","Generation":"%s"}\n' "$B" "$G" > "$PK/boot-open-request.json"
}
line() { "$KP" "$PK" "$G" "$OWN" 2>&1 | grep "^KIT_PREFLIGHT check=$1 "; }
expect() {  # expect <check> <name> <PASS|FAIL|SKIP> <substring>
  local got; got=$(line "$1")
  case "$got" in *"result=$3 "*"$4"*) ok "$2" ;; *) no "$2" "${got:-no $1 line}" ;; esac
}
unreadable() {  # unreadable <check> <name> <path> <substring>: chmod 000, expect FAIL, restore
  if [ "$ROOT_BYPASS" = 1 ]; then ok "$2 (skipped: user bypasses mode bits)"; return; fi
  chmod 000 "$3"; expect "$1" "$2" FAIL "$4"; chmod 700 "$3"
}

# ---------------------------------------------------------------- C9
pkg c9
printf '# floor\n\n%s reason_a\n' "$A" > "$FL"
expect C9 c9_valid_floor_passes PASS "contains_floor=1"
printf '%s reason_x\n' "$X" > "$FL"
expect C9 c9_unmet_floor_fails FAIL "checkout_predates_floor"
printf '# only comments\n\n' > "$FL"
expect C9 c9_comments_only_floor_fails FAIL "floor_empty"
: > "$FL"
expect C9 c9_empty_floor_fails FAIL "floor_empty"
printf '%s reason_a\n%s0 too_long\n' "$A" "$A" > "$FL"
expect C9 c9_malformed_entry_fails FAIL "floor_entry_malformed"
printf '%s\n' "$A" > "$FL"
expect C9 c9_entry_without_reason_fails FAIL "floor_entry_malformed"
printf '%s reason_a\n' "$A" > "$FL"; chmod 600 "$FL"
if [ "$ROOT_BYPASS" = 1 ]; then ok "c9_unreadable_floor_fails (skipped: user bypasses mode bits)"
else chmod 000 "$FL"; expect C9 c9_unreadable_floor_fails FAIL "floor_file_unreadable"; chmod 600 "$FL"; fi
printf '%s reason_a' "$X" > "$FL"   # no trailing newline: the last entry is still checked
expect C9 c9_last_line_without_newline_checked FAIL "checkout_predates_floor"
printf '%s reason_a\n' "$A" > "$FL"

# ---------------------------------------------------------------- C10
pkg c10_clean; : > "$PK/series/window.lock"
expect C10 c10_lock_only_passes PASS "series_clean"
pkg c10_visible; echo '{}' > "$PK/series/initial-flash.json"
expect C10 c10_visible_receipt_fails FAIL "series_not_empty files=initial-flash.json"
pkg c10_hidden; echo 1 > "$PK/series/.request-001-id"
expect C10 c10_hidden_entry_fails FAIL "series_not_empty files=.request-001-id"
pkg c10_dangling; ln -s "$T/nonexistent" "$PK/series/initial-flash.json"
expect C10 c10_dangling_link_fails FAIL "series_not_empty files=initial-flash.json"
pkg c10_lock_link; ln -s "$T/nonexistent" "$PK/series/x.lock"
expect C10 c10_symlinked_lock_fails FAIL "files=x.lock"
pkg c10_unreadable; echo '{}' > "$PK/series/initial-flash.json"
unreadable C10 c10_unreadable_series_fails "$PK/series" "series_unreadable"
pkg c10_file; rmdir "$PK/series"; echo x > "$PK/series"
expect C10 c10_series_file_fails FAIL "series_not_directory"
pkg c10_absent; rmdir "$PK/series"
expect C10 c10_absent_series_passes PASS "series_clean"

# ---------------------------------------------------------------- C11
H64=$(printf 'a%.0s' $(seq 64)); H65=${H64}a
sealed() { mkdir -p "$PK/requests-sealed"; printf '{"sha256":"%s"}\n' "$2" > "$PK/requests-sealed/$1"; }
pkg c11_good; sealed sequence-01.json "$H64"
expect C11 c11_good_request_passes PASS "hashes_ok tokens=1"
pkg c11_bad; sealed sequence-01.json "$H65"
expect C11 c11_65_hex_fails FAIL "sealed_hash_malformed"
pkg c11_hidden; sealed sequence-01.json "$H64"; sealed .sequence-02.json "$H65"
expect C11 c11_hidden_entry_inspected FAIL "sealed_hash_malformed tokens=.sequence-02.json"
pkg c11_dangling; sealed sequence-01.json "$H64"; ln -s "$T/nonexistent" "$PK/requests-sealed/sequence-02.json"
expect C11 c11_dangling_entry_fails FAIL "sealed_input_unreadable inputs=sequence-02.json:not_regular_file"
pkg c11_nested; sealed sequence-01.json "$H64"; mkdir "$PK/requests-sealed/more"
expect C11 c11_nested_dir_fails FAIL "more:not_regular_file"
pkg c11_unreadable; sealed sequence-01.json "$H65"; chmod 600 "$PK/requests-sealed/sequence-01.json"
if [ "$ROOT_BYPASS" = 1 ]; then ok "c11_unreadable_entry_fails (skipped: user bypasses mode bits)"
else chmod 000 "$PK/requests-sealed/sequence-01.json"
  expect C11 c11_unreadable_entry_fails FAIL "sequence-01.json:unreadable"
  chmod 600 "$PK/requests-sealed/sequence-01.json"; fi
pkg c11_unreadable_dir; sealed sequence-01.json "$H65"
unreadable C11 c11_unreadable_requests_dir_fails "$PK/requests-sealed" "requests-sealed:unreadable"
pkg c11_boot_ready_dangling; ln -s "$T/nonexistent" "$PK/BOOT_READY"
expect C11 c11_dangling_boot_ready_fails FAIL "BOOT_READY:not_regular_file"
pkg c11_boot_ready_bad; printf 'KitPayloadSHA256=%s\n' "$H65" > "$PK/BOOT_READY"
expect C11 c11_boot_ready_checked FAIL "sealed_hash_malformed tokens=BOOT_READY"
pkg c11_none
expect C11 c11_nothing_sealed_skips SKIP "no_sealed_requests_or_boot_ready"

# ---------------------------------------------------------------- bounded reads (review of 265331b7)
printf '# %s\n%s reason_a\n' "$(printf 'x%.0s' $(seq 80))" "$A" > "$FL"; pkg c9_big
KP_MAX_FLOOR_BYTES=64 expect C9 c9_oversized_floor_fails FAIL "floor_file_too_large_or_unstatable"
expect C9 c9_floor_under_default_limit_passes PASS "contains_floor=1"
printf '%s reason_a\n' "$A" > "$FL"
pkg c10_many; for i in 1 2 3 4 5; do : > "$PK/series/w$i.lock"; done
KP_MAX_ENTRIES=5 expect C10 c10_at_entry_limit_passes PASS "series_clean"
KP_MAX_ENTRIES=4 expect C10 c10_over_entry_limit_fails FAIL "files=over_4_entries"
pkg c11_many; for i in 1 2 3 4 5; do sealed "sequence-0$i.json" "$H64"; done
KP_MAX_ENTRIES=5 expect C11 c11_at_entry_limit_passes PASS "hashes_ok tokens=5"
KP_MAX_ENTRIES=4 expect C11 c11_over_entry_limit_fails FAIL "requests-sealed:over_4_entries"
pkg c11_big; sealed sequence-01.json "$H64"; printf '{"pad":"%s"}\n' "$(printf 'x%.0s' $(seq 300))" > "$PK/requests-sealed/sequence-02.json"
KP_MAX_INPUT_BYTES=200 expect C11 c11_oversized_input_fails FAIL "sequence-02.json:over_200_bytes"
KP_MAX_TOTAL_BYTES=300 expect C11 c11_total_limit_fails FAIL "inputs:over_300_bytes_total"
expect C11 c11_inputs_under_default_limits_pass PASS "hashes_ok tokens=1"

echo "kit-preflight-fail-closed-test: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
