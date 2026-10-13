#!/usr/bin/env bash
# Source this before boot-open, then arm it as soon as the series anchor exists.

build9_close_queued=0

build9_queue_close() {
    local mode=${1:?close-mode}
    if [[ ${build9_close_queued:-0} -eq 1 ]]; then
        return 0
    fi
    # Supplied by the generated RUNBOOK before this helper is sourced.
    # shellcheck disable=SC2154
    "$kit/runbook-close.sh" "$mode" "$kit" "$run" "$anchor" \
        "$live_repo" "$SQ_DIR" "$SQ_QUEUE" "$generation"
    build9_close_queued=1
}

build9_close_on_exit() {
    local original_rc=$?
    local close_rc=0
    trap - EXIT HUP INT TERM
    set +e
    if [[ ${build9_close_queued:-0} -eq 0 ]]; then
        build9_queue_close failure
        close_rc=$?
        if [[ $close_rc -ne 0 ]]; then
            printf 'BUILD9_CLOSE state=FAIL reason=exit_cleanup_queue_failed rc=%s original_rc=%s\n' \
                "$close_rc" "$original_rc" >&2
        fi
    fi
    exit "$original_rc"
}

build9_close_on_signal() {
    local signal_rc=${1:?signal-exit-status}
    local close_rc=0
    trap - EXIT HUP INT TERM
    set +e
    if [[ ${build9_close_queued:-0} -eq 0 ]]; then
        build9_queue_close failure
        close_rc=$?
        if [[ $close_rc -ne 0 ]]; then
            printf 'BUILD9_CLOSE state=FAIL reason=signal_cleanup_queue_failed rc=%s signal_rc=%s\n' \
                "$close_rc" "$signal_rc" >&2
        fi
    fi
    exit "$signal_rc"
}

build9_arm_close() {
    trap build9_close_on_exit EXIT
    trap 'build9_close_on_signal 129' HUP
    trap 'build9_close_on_signal 130' INT
    trap 'build9_close_on_signal 143' TERM
}

build9_disarm_close() {
    [[ ${build9_close_queued:-0} -eq 1 ]] || return 1
    trap - EXIT HUP INT TERM
}
