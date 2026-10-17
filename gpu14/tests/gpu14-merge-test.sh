#!/usr/bin/env bash
# proc-coord 2026-10-17 (tsp-mc9m.41.1030, recovery#13 re-look): gpu14-merge.sh must forward pf-pr-merge.sh options
# placed after the PR ref (merge-ready passes --expect-head there). Hermetic part: gh and pf-automation-tool are faked
# in a private temp root. Compatibility part (host-only): the REAL wrapper reaches the REAL pf-pr-merge.sh parser,
# which must know --expect-head; a non-hex value makes the parser refuse before any GitHub read or merge.
# Skip it with GM_REAL=0 (CI or a host without pf-automation-tool).
# usage: gpu14-merge-test.sh      rc 0 all pass
set -uo pipefail
GM=${GM_SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/gpu14-merge.sh}
T=$(mktemp -d "${TMPDIR:-/tmp}/gm-tests.XXXXXX"); trap '[ -n "${KEEP:-}" ] || { find "$T" -mindepth 1 -delete; rmdir -- "$T"; }' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1 :: ${2:-}"; }
H=0123456789abcdef0123456789abcdef01234567
mkdir -p "$T/fake" "$T/ghonly"
for d in fake ghonly; do printf '#!/bin/sh\necho scripts/foo.sh\n' > "$T/$d/gh"; done
cat > "$T/fake/pf-automation-tool" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$GM_ARGV"
SH
chmod +x "$T"/fake/* "$T"/ghonly/*
# BASH_ENV on the coordinator laptop prepends ~/.local/bin, which would shadow the fakes.
# Each case records argv to its own fresh file ($T/argv-<case>), so nothing is removed between cases.
run() { env -u BASH_ENV PATH="$1:$PATH" GM_ARGV="$T/argv-$C" bash "$GM" "${@:2}"; }

C=1; o=$(run "$T/fake" own/repo#7 --expect-head "$H" 2>&1); rc=$?
exp=$(printf '%s\n' pf-pr-merge.sh own/repo#7 --expect-head "$H")
[ "$rc" -eq 0 ] && [ "$(cat "$T/argv-$C" 2>/dev/null)" = "$exp" ] && ok forwards_expect_head_after_ref \
  || no forwards_expect_head_after_ref "rc=$rc argv=$(tr '\n' ' ' < "$T/argv-$C" 2>/dev/null) out=$o"

C=2; o=$(run "$T/fake" --vendor-ok 'src@abc reason' own/repo#7 --allow-red x --expect-head "$H" 2>&1); rc=$?
exp=$(printf '%s\n' pf-pr-merge.sh own/repo#7 --allow-red x --expect-head "$H")
[ "$rc" -eq 0 ] && [ "$(cat "$T/argv-$C" 2>/dev/null)" = "$exp" ] && ok forwards_all_args_after_vendor_ok \
  || no forwards_all_args_after_vendor_ok "rc=$rc argv=$(tr '\n' ' ' < "$T/argv-$C" 2>/dev/null) out=$o"

if [ "${GM_REAL:-1}" = 0 ]; then echo "SKIP real_parser_knows_expect_head (GM_REAL=0)"
elif ! command -v pf-automation-tool >/dev/null; then echo "SKIP real_parser_knows_expect_head (no pf-automation-tool)"
else
  C=3; o=$(run "$T/ghonly" pocketforge-os/recovery#1 --expect-head NOT-A-SHA 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && grep -q -- '--expect-head requires a full commit sha' <<<"$o" && ! grep -q 'unknown option' <<<"$o"; then
    ok real_parser_knows_expect_head
  else no real_parser_knows_expect_head "rc=$rc out=$(tail -n 3 <<<"$o" | tr '\n' ' ')"; fi
fi
echo "gpu14-merge-test: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
