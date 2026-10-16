#!/usr/bin/env bash
# Hermetic test for ci-wait-continue.sh: a stub `gh` serves scripted PR heads, check TSVs, job
# conclusions and log lines; a stub rerun command records calls. No network, no real GitHub.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=0123456789abcdef0123456789abcdef01234567
H2=fedcba9876543210fedcba9876543210fedcba98
cat >"$T/gh" <<'STUB'
#!/usr/bin/env bash
# state files: $T/head, $T/checks.N (served in order, last one repeats), $T/concl.<job>, $T/log.<job>
d=$CIW_TEST_DIR
case "$1 $2" in
  "pr view") case "$*" in *mergeable*) cat "$d/mergeable" 2>/dev/null || echo MERGEABLE ;; *baseRefName*) echo main ;; *) cat "$d/head" ;; esac ;;
  "pr checks") n=$(cat "$d/n" 2>/dev/null || echo 0); f="$d/checks.$n"; [ -e "$f" ] || f=$(ls "$d"/checks.* | sort -V | tail -1); cat "$f"; echo $((n+1)) >"$d/n" ;;
  "api repos/"*"/contents/.github/workflows"*) if [ -e "$d/noworkflows" ]; then echo '{"message":"Not Found","status":"404"}'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi; echo 'stub gh: workflow listing unavailable (non-404)' >&2; exit 1 ;;
  "api repos/"*/logs) j=${2%/logs}; j=${j##*/}; cat "$d/log.$j" 2>/dev/null ;;
  "api repos/"*) j=${2##*/}; cat "$d/concl.$j" 2>/dev/null ;;
  "run view") echo "stub gh: run view --log-failed is unreliable for re-attempted runs; helper must not use it" >&2; exit 9 ;;
  *) echo "stub gh: unexpected $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$T/gh"
cat >"$T/rerun" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$CIW_TEST_DIR/reruns"; echo "RERUN ok"
STUB
chmod +x "$T/rerun"
fail=0
export CIW_GRACE_STEP=0 CIW_CONFLICT_STEP=0
run_case() { # name expected_rc expected_result_regex
  local name=$1 erc=$2 ere=$3 out rc
  out=$(CIW_TEST_DIR="$T/$name" CIW_GH="$T/gh" CIW_RERUN_CMD="$T/rerun" CIW_POLL_S=0 CIW_STATE_DIR="$T/$name/state" \
        "$here/ci-wait-continue.sh" "${ARGS[@]}" 2>"$T/$name/stderr"); rc=$?
  if [ "$rc" = "$erc" ] && [[ $out =~ $ere ]]; then echo "PASS $name ($out)"; else echo "FAIL $name rc=$rc out=$out"; fail=1; fi
}
mk() { mkdir -p "$T/$1"; echo "$2" >"$T/$1/head"; }
L=https://github.com/pocketforge-os/x/actions/runs/777/job

# 1 GREEN after one pending poll
mk green $H; printf 'a\tpending\t0\t%s/1\n' $L >"$T/green/checks.0"; printf 'a\tpass\t1m\t%s/1\nb\tpass\t2m\t%s/2\n' $L $L >"$T/green/checks.1"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/green/msg" 5); run_case green 0 'result=GREEN'
grep -q 'pf-pr-merge.sh --dry-run pocketforge-os/x#5' "$T/green/msg" && grep -q 'TESTX_STATUS state=CI_WAIT' "$T/green/msg" || { echo "FAIL green message content"; fail=1; }

# 2 RED (real failure) -> message with job lines, no rerun
mk red $H; printf 'a\tpass\t1m\t%s/1\nsuites\tfail\t3m\t%s/9\n' $L $L >"$T/red/checks.0"; echo failure >"$T/red/concl.9"
printf '2026Z \033[36;1m echo AssertionError: script-echo-noise\033[0m\n2026Z ok 8 - passing-test carries a reason= line\n2026Z AssertionError: boom happened\n' >"$T/red/log.9"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/red/msg" 5); run_case red 0 'result=RED'
grep -q 'AssertionError: boom happened' "$T/red/msg" && ! grep -q 'script-echo-noise' "$T/red/msg" && ! grep -q 'passing-test carries' "$T/red/msg" && [ ! -e "$T/red/reruns" ] || { echo "FAIL red message/rerun"; fail=1; }

# 3 known flake cancelled -> exactly one rerun, then GREEN
mk flake $H; printf 'pf-runner-pool\tfail\t10m\t%s/4\n' $L >"$T/flake/checks.0"; echo cancelled >"$T/flake/concl.4"
printf 'pf-runner-pool\tpass\t9m\t%s/5\n' $L >"$T/flake/checks.1"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/flake/msg" 5); run_case flake 0 'result=GREEN'
[ "$(wc -l <"$T/flake/reruns")" = 1 ] && grep -q '^pocketforge-os/x 777$' "$T/flake/reruns" || { echo "FAIL flake rerun count/args"; fail=1; }

# 4 known flake cancelled twice -> one rerun only, then RED with the "already spent" note
mk flake2 $H; printf 'pf-runner-pool\tfail\t10m\t%s/4\n' $L >"$T/flake2/checks.0"; echo cancelled >"$T/flake2/concl.4"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/flake2/msg" 5); run_case flake2 0 'result=RED'
[ "$(wc -l <"$T/flake2/reruns")" = 1 ] && grep -q 'already spent' "$T/flake2/msg" || { echo "FAIL flake2 single rerun"; fail=1; }

# 5 flake-named check that FAILED (not cancelled) is real -> no rerun
mk flake3 $H; printf 'pf-runner-pool\tfail\t3m\t%s/4\n' $L >"$T/flake3/checks.0"; echo failure >"$T/flake3/concl.4"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/flake3/msg" 5); run_case flake3 0 'result=RED'
[ ! -e "$T/flake3/reruns" ] || { echo "FAIL flake3 reran a real failure"; fail=1; }

# 5b capacity refusal (tsp-hqm1p.39.7 admission guard, exit 75) on ANY check name -> exactly one rerun, then GREEN
mk cap $H; printf 'rust / Rust container\tfail\t1m\t%s/6\n' $L >"$T/cap/checks.0"; echo failure >"$T/cap/concl.6"
printf '2026Z {"rust_ci": "waiting_for_slots", "count": 2, "timeout_seconds": 3}\n2026Z {"rust_ci": "refused", "reason": "memory_capacity"}\n2026Z ##[error]Process completed with exit code 75.\n' >"$T/cap/log.6"
printf 'rust / Rust container\tpass\t9m\t%s/7\n' $L >"$T/cap/checks.1"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/cap/msg" 5); run_case cap 0 'result=GREEN'
[ "$(wc -l <"$T/cap/reruns" 2>/dev/null)" = 1 ] && grep -q 'capacity_rerun' "$T/cap/stderr" || { echo "FAIL cap rerun count/log"; fail=1; }

# 5c same check failing WITHOUT the refusal line is real -> RED, no rerun
mk cap2 $H; printf 'rust / Rust container\tfail\t4m\t%s/6\n' $L >"$T/cap2/checks.0"; echo failure >"$T/cap2/concl.6"
printf '2026Z error[E0308]: mismatched types\n2026Z ##[error]Process completed with exit code 101.\n' >"$T/cap2/log.6"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/cap2/msg" 5); run_case cap2 0 'result=RED'
[ ! -e "$T/cap2/reruns" ] || { echo "FAIL cap2 reran a real failure"; fail=1; }

# 5d refusal plus a real failure in another job -> RED, no rerun (a rerun would not fix the real one)
mk cap3 $H; printf 'rust / Rust container\tfail\t1m\t%s/6\nsuites\tfail\t3m\t%s/9\n' $L $L >"$T/cap3/checks.0"; echo failure >"$T/cap3/concl.6"; echo failure >"$T/cap3/concl.9"
printf '2026Z {"rust_ci": "refused", "reason": "memory_capacity"}\n' >"$T/cap3/log.6"; printf '2026Z AssertionError: real\n' >"$T/cap3/log.9"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/cap3/msg" 5); run_case cap3 0 'result=RED'
[ ! -e "$T/cap3/reruns" ] || { echo "FAIL cap3 reran with a real failure present"; fail=1; }

# 5e refusal twice on one head -> one rerun only, then RED with the "already spent" note
mk cap4 $H; printf 'rust / Rust container\tfail\t1m\t%s/6\n' $L >"$T/cap4/checks.0"; echo failure >"$T/cap4/concl.6"
printf '2026Z {"rust_ci": "refused", "reason": "memory_capacity"}\n' >"$T/cap4/log.6"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/cap4/msg" 5); run_case cap4 0 'result=RED'
[ "$(wc -l <"$T/cap4/reruns" 2>/dev/null)" = 1 ] && grep -q 'already spent' "$T/cap4/msg" || { echo "FAIL cap4 single rerun"; fail=1; }

# 5f flaky shard (capacity refusal) plus its derived aggregate failure -> exactly one rerun, then GREEN (kitres #1424)
mk agg $H; printf 'class-a-shard (0)\tfail\t1m\t%s/6\nclass-a-aggregate\tfail\t6s\t%s/8\n' $L $L >"$T/agg/checks.0"; echo failure >"$T/agg/concl.6"; echo failure >"$T/agg/concl.8"
printf '2026Z {"rust_ci": "refused", "reason": "memory_capacity"}\n' >"$T/agg/log.6"; printf '2026Z ##[error]shard 0 failed\n' >"$T/agg/log.8"
printf 'class-a-shard (0)\tpass\t9m\t%s/16\nclass-a-aggregate\tpass\t5s\t%s/18\n' $L $L >"$T/agg/checks.1"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/agg/msg" 5); run_case agg 0 'result=GREEN'
[ "$(wc -l <"$T/agg/reruns" 2>/dev/null)" = 1 ] && grep -q 'capacity_rerun' "$T/agg/stderr" || { echo "FAIL agg rerun count/log"; fail=1; }

# 5g an aggregate failing ALONE is real -> RED, no rerun
mk agg2 $H; printf 'class-a-aggregate\tfail\t6s\t%s/8\n' $L >"$T/agg2/checks.0"; echo failure >"$T/agg2/concl.8"; printf '2026Z ##[error]aggregate bug\n' >"$T/agg2/log.8"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/agg2/msg" 5); run_case agg2 0 'result=RED'
[ ! -e "$T/agg2/reruns" ] || { echo "FAIL agg2 reran a lone aggregate failure"; fail=1; }

# 6 HEAD_MOVED -> rc 3, no message
mk moved $H2; printf 'a\tpass\t1m\t%s/1\n' $L >"$T/moved/checks.0"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/moved/msg" 5); run_case moved 3 'result=HEAD_MOVED'
[ ! -e "$T/moved/msg" ] || { echo "FAIL moved wrote a message"; fail=1; }

# 7 BAD_ARGS: short sha, bad pr spec, lowercase token
mkdir -p "$T/bad"
ARGS=(pocketforge-os/x#5 abc123 TESTX_STATUS "$T/bad/msg"); run_case bad 3 'result=BAD_ARGS'
ARGS=('x#5' $H TESTX_STATUS "$T/bad/msg"); run_case bad 3 'result=BAD_ARGS'
ARGS=(pocketforge-os/x#5 $H bad_tok "$T/bad/msg"); run_case bad 3 'result=BAD_ARGS'

# 8 unwritable state dir fails closed (otherwise the rerun-once marker cannot be written)
mkdir -p "$T/ro"; ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/ro/msg" 5)
out=$(CIW_GH="$T/gh" CIW_STATE_DIR=/proc/ciw-nope "$here/ci-wait-continue.sh" "${ARGS[@]}" 2>/dev/null); rc=$?
[ "$rc" = 3 ] && [[ $out =~ state_dir_unwritable ]] && echo "PASS state-dir" || { echo "FAIL state-dir rc=$rc $out"; fail=1; }
# 9 startup_failure with NO checks (homelan infra#79: unpinned actions/checkout@v4 under org sha_pinning_required)
#   -> STARTUP_FAILURE at once, message names the run and SHA pinning; never waits to TIMEOUT
mk sfail $H; printf '38333447860\t.github/workflows/laptop-home-lan.yml\n' >"$T/sfail/concl.runs?head_sha=$H&per_page=50"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/sfail/msg" 5); run_case sfail 0 'result=STARTUP_FAILURE .*runs=38333447860'
grep -q 'laptop-home-lan.yml (run 38333447860)' "$T/sfail/msg" && grep -q 'sha_pinning_required' "$T/sfail/msg" && grep -q 'TESTX_STATUS state=CI_WAIT' "$T/sfail/msg" || { echo "FAIL sfail message content"; fail=1; }

# 9b other workflows green but one refused at startup -> STARTUP_FAILURE, not GREEN
mk sfail2 $H; printf 'a\tpass\t1m\t%s/1\n' $L >"$T/sfail2/checks.0"; printf '99\t.github/workflows/new.yml\n' >"$T/sfail2/concl.runs?head_sha=$H&per_page=50"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/sfail2/msg" 5); run_case sfail2 0 'result=STARTUP_FAILURE'
! grep -q 'is GREEN' "$T/sfail2/msg" || { echo "FAIL sfail2 said GREEN"; fail=1; }

# 9c no checks yet and no startup failure -> keeps waiting (TIMEOUT with a 0-minute budget), never STARTUP_FAILURE
mk sfail3 $H
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/sfail3/msg" 0); run_case sfail3 3 'result=TIMEOUT'

# 10 design#10 (input-coord 2026-10-13): default branch has NO workflows, but the PR ADDS one and its run is already on
#    the exact head -> wait for it like any CI (GREEN here), never NO_CI
mk addci $H; touch "$T/addci/noworkflows"; echo 1 >"$T/addci/concl.runs?head_sha=$H&per_page=1"; printf 'payload / Rust container\tpass\t3m\t%s/1\n' $L >"$T/addci/checks.0"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/addci/msg" 5); run_case addci 0 'result=GREEN'
# 10b check-runs alone (no Actions run listed yet) also count as CI on the head
mk addci2 $H; touch "$T/addci2/noworkflows"; echo 2 >"$T/addci2/concl.check-runs?per_page=1"; printf 'a\tpass\t1m\t%s/1\n' $L >"$T/addci2/checks.0"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/addci2/msg" 5); run_case addci2 0 'result=GREEN'
# 11 control: no workflows at the head AND no runs/check-runs after the grace period -> NO_CI still fires
mk noci $H; touch "$T/noci/noworkflows"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/noci/msg" 5); run_case noci 0 'result=NO_CI'
grep -q 'has NO .github/workflows' "$T/noci/msg" || { echo "FAIL noci message"; fail=1; }

# 12 image#245 (input-coord 2026-10-13): PR CONFLICTING with its base, no checks ever -> CONFLICT at once with a merge-main
#    message, never a 240-min TIMEOUT. (9c above is the control: no checks + MERGEABLE keeps waiting.)
mk conflict $H; echo CONFLICTING >"$T/conflict/mergeable"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/conflict/msg" 5); run_case conflict 0 'result=CONFLICT .*base=main'
grep -q 'is CONFLICTING with its base main' "$T/conflict/msg" && grep -q 'TESTX_STATUS state=CI_WAIT' "$T/conflict/msg" || { echo "FAIL conflict message"; fail=1; }
# 12b UNKNOWN (GitHub still computing) is not a conflict: keeps waiting (TIMEOUT with a 0-minute budget)
mk unknownm $H; echo UNKNOWN >"$T/unknownm/mergeable"
ARGS=(pocketforge-os/x#5 $H TESTX_STATUS "$T/unknownm/msg" 0); run_case unknownm 3 'result=TIMEOUT'

# 13 fabricated sha tail (2026-10-14 qreb: 7 real chars then invented): unknown declared sha sharing 7 chars -> waits on the real head -> GREEN
F7=${H:0:7}$(printf '9%.0s' {1..33})
mk typo7 $H; printf 'a\tpass\t1m\t%s/1\n' $L >"$T/typo7/checks.0"
ARGS=(pocketforge-os/x#5 $F7 TESTX_STATUS "$T/typo7/msg" 5); run_case typo7 0 'result=GREEN'
grep -q 'sha_corrected' "$T/typo7/stderr" || { echo "FAIL typo7 no sha_corrected note"; fail=1; }
# 13b same 7-char prefix but the declared sha EXISTS in the repo (a real different push) -> HEAD_MOVED, no correction
mk typo7real $H; printf 'a\tpass\t1m\t%s/1\n' $L >"$T/typo7real/checks.0"; echo exists >"$T/typo7real/concl.$F7"
ARGS=(pocketforge-os/x#5 $F7 TESTX_STATUS "$T/typo7real/msg" 5); run_case typo7real 3 'result=HEAD_MOVED'
# 13c only 6 shared chars -> not treated as a typo -> HEAD_MOVED
F6=${H:0:6}$(printf '9%.0s' {1..34})
mk typo6 $H; printf 'a\tpass\t1m\t%s/1\n' $L >"$T/typo6/checks.0"
ARGS=(pocketforge-os/x#5 $F6 TESTX_STATUS "$T/typo6/msg" 5); run_case typo6 3 'result=HEAD_MOVED'

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
