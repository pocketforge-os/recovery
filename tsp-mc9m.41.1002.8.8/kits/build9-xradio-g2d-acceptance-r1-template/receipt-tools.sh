#!/bin/sh
set -eu

invalid() {
    printf 'BUILD9_RECEIPT_STDOUT state=INVALID reason=%s\n' "$1"
    exit 65
}

case ${1:-} in
stdout)
    [ "$#" = 5 ] || invalid arguments
    receipt=$2 index=$3 output=$4 allowed_root=$5
    case $index in ''|*[!0-9]*) invalid index_invalid ;; esac
    if [ ! -f "$receipt" ] || [ -L "$receipt" ]; then
        invalid receipt_unreadable
    fi
    descriptor=$(jq -ce --argjson index "$index" '
      .StepResults[$index].Stdout |
      select(type=="object") |
      select((.Bytes|type)=="number" and (.Bytes|floor)==.Bytes and .Bytes>=0) |
      select((.Path|type)=="string" and (.Path|length)>0) |
      select((.SHA256|type)=="string" and (.SHA256|test("^[0-9a-f]{64}$"))) |
      {Bytes,Path,SHA256}' "$receipt") || invalid descriptor_invalid
    path=$(printf '%s\n' "$descriptor" | jq -r .Path)
    expected_bytes=$(printf '%s\n' "$descriptor" | jq -r .Bytes)
    expected_sha=$(printf '%s\n' "$descriptor" | jq -r .SHA256)
    if [ ! -f "$path" ] || [ -L "$path" ]; then
        invalid side_file_unreadable
    fi
    root_real=$(realpath -e -- "$allowed_root") || invalid allowed_root_unreadable
    path_real=$(realpath -e -- "$path") || invalid side_file_unreadable
    case $path_real in "$root_real"/*) ;; *) invalid path_outside_series ;; esac
    actual_bytes=$(wc -c <"$path_real" | tr -d ' ')
    [ "$actual_bytes" = "$expected_bytes" ] || invalid byte_count_mismatch
    actual_sha=$(sha256sum "$path_real" | awk '{print $1}')
    [ "$actual_sha" = "$expected_sha" ] || invalid sha256_mismatch

    output_dir=$(dirname -- "$output")
    mkdir -p -- "$output_dir"
    tmp=$output.tmp.$$
    cleanup() { find "$tmp" -maxdepth 0 -type f -delete; }
    trap cleanup EXIT HUP INT TERM
    cp -- "$path_real" "$tmp"
    [ "$(wc -c <"$tmp" | tr -d ' ')" = "$expected_bytes" ] || invalid verified_copy_byte_mismatch
    [ "$(sha256sum "$tmp" | awk '{print $1}')" = "$expected_sha" ] || invalid verified_copy_sha256_mismatch
    mv -- "$tmp" "$output"
    trap - EXIT HUP INT TERM
    printf '%s\n' "$output"
    ;;
close-reason)
    shift
    [ "$#" -gt 0 ] || { printf 'failure\n'; exit 0; }
    for receipt do
        if [ ! -f "$receipt" ] || [ -L "$receipt" ] ||
           ! jq -e '.Outcome=="pass" and (.StepResults|type)=="array" and
             (.StepResults|length)>0 and (.StepResults|all(.RC==0))' "$receipt" >/dev/null 2>&1; then
            printf 'failure\n'
            exit 0
        fi
    done
    printf 'success\n'
    ;;
*)
    printf 'usage: receipt-tools.sh stdout RECEIPT INDEX OUTPUT ALLOWED_ROOT | close-reason RECEIPT...\n' >&2
    exit 2
    ;;
esac
