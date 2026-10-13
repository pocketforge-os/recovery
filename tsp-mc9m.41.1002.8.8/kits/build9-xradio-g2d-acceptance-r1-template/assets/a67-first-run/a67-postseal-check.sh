#!/bin/sh
set -eu

kit=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
image=${1:?image path required}
image_sha=${2:?image sha256 required}
meta=$kit/kit-transport.json
payload=$kit/pf-kit-payload.tar.gz

# The image itself was already checked by seal-request.py. Bind this smoke to
# the declared Build 9 argument and verify the network payload from its contract.
case "$image" in /*) ;; *) exit 64 ;; esac
expected_image_sha=$(sed -n 's/^build9_raw_sha256=//p' "$kit/IDENTITY")
case "$expected_image_sha" in *[!0-9a-f]*|'') exit 64 ;; esac
test "${#expected_image_sha}" -eq 64
test "$image_sha" = "$expected_image_sha"
test "$(jq -r '.Schema' "$meta")" = pocketforge.kit-transport/v1
test "$(jq -r '.payload.Schema' "$meta")" = pocketforge.kit-payload/v1
test "$(jq -r '.payload.Name' "$meta")" = pf-kit-payload.tar.gz
expected_bytes=$(jq -r '.payload.Bytes' "$meta")
expected_sha=$(jq -r '.payload.SHA256' "$meta")
case "$expected_bytes" in ''|*[!0-9]*) exit 64 ;; esac
case "$expected_sha" in *[!0-9a-f]*|'') exit 64 ;; esac
test "${#expected_sha}" -eq 64
test "$(stat -c %s "$payload")" = "$expected_bytes"
test "$(sha256sum "$payload" | cut -d' ' -f1)" = "$expected_sha"
printf '%s\n' 'POSTSEAL_CHECK PASS payload=verified transport=network-only'
