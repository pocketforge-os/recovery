#!/bin/sh
set -eu
K=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
IMAGE=${1:?published-build9-image.img}
D=$(mktemp -d "${RUNNER_TEMP:-/tmp}/build9-acceptance-kit.XXXXXX")
cleanup() { find "$D" -mindepth 1 -delete; rmdir "$D"; }
trap cleanup EXIT HUP INT TERM
if "$K/prepare-kit.py" --output "$D/missing" >"$D/missing.out" 2>&1; then exit 1; fi
if "$K/prepare-kit.py" --output "$D/bad" --image-sha256 nope >"$D/bad.out" 2>&1; then exit 1; fi
raw=$(printf 'Build 9 hermetic raw fixture\n' | sha256sum | cut -d' ' -f1)
"$K/prepare-kit.py" --output "$D/one" --image-sha256 "$raw"
"$K/prepare-kit.py" --output "$D/two" --image-sha256 "$raw" >/dev/null
cmp "$D/one/network-smoke.bin" "$D/two/network-smoke.bin"
cmp "$D/one/pf-kit-payload.tar.gz" "$D/two/pf-kit-payload.tar.gz"
grep -Fx "build9_raw_sha256=$raw" "$D/one/IDENTITY" >/dev/null
env PATH=/usr/bin:/bin "$D/one/smoke.sh"
"$D/one/test-bootstrap-unprivileged.sh" "$IMAGE"

# Exercise the generated seed preparer itself, including its sibling companion
# lookup. This is a hermetic consumed-seed fixture: no secret, node, seal, or
# queue operation is possible in this test.
seed_source=$D/seed-source
mkdir "$seed_source"
printf '%s\n' '{"SeedHandle":"183b36e3dc8474620e948abfe12e469f"}' >"$seed_source/felboot-request.json"
printf '%s\n' '{"ImageSource":{},"SeedHandle":"@SEED_HANDLE@","KitPayload":{}}' >"$seed_source/felboot-request.template.json"
printf '%s\n' '{"Schema":"pocketforge.kit-transport/v1"}' >"$seed_source/kit-transport.json"
printf '%s\n' '{"Schema":"pocketforge.full-image/v1","RawSHA256":"'"$raw"'"}' >"$D/ImageSource.json"
cp -a "$D/one" "$D/no-postseal"
find "$D/no-postseal/a67-postseal-check.sh" -maxdepth 0 -type f -delete
if "$D/no-postseal/prepare-seed-template.py" --network-only \
    --source "$seed_source" --output "$D/no-postseal-output" \
    --payload "$D/no-postseal/pf-kit-payload.tar.gz" --image-source "$D/ImageSource.json" \
    --consumed-handle 183b36e3dc8474620e948abfe12e469f >"$D/no-postseal.out" 2>&1; then exit 1; fi
grep -F 'state=FAIL reason=postseal_companion_invalid' "$D/no-postseal.out" >/dev/null
cp -a "$D/one" "$D/no-sealer"
find "$D/no-sealer/a67-seal-request.py" -maxdepth 0 -type f -delete
if "$D/no-sealer/prepare-seed-template.py" --network-only \
    --source "$seed_source" --output "$D/no-sealer-output" \
    --payload "$D/no-sealer/pf-kit-payload.tar.gz" --image-source "$D/ImageSource.json" \
    --consumed-handle 183b36e3dc8474620e948abfe12e469f >"$D/no-sealer.out" 2>&1; then exit 1; fi
grep -F 'state=FAIL reason=sealer_companion_invalid' "$D/no-sealer.out" >/dev/null
cp -a "$D/one" "$D/aliased-interface"
sed -i 's/^host_wifi_interface=.*/host_wifi_interface=wlan0/' "$D/aliased-interface/IDENTITY"
if "$D/aliased-interface/prepare-seed-template.py" --network-only \
    --source "$seed_source" --output "$D/aliased-interface-output" \
    --payload "$D/aliased-interface/pf-kit-payload.tar.gz" --image-source "$D/ImageSource.json" \
    --consumed-handle 183b36e3dc8474620e948abfe12e469f >"$D/aliased-interface.out" 2>&1; then exit 1; fi
grep -F 'state=FAIL reason=identity_interface_alias' "$D/aliased-interface.out" >/dev/null
"$D/one/prepare-seed-template.py" --network-only \
  --source "$seed_source" --output "$D/seed-output" \
  --payload "$D/one/pf-kit-payload.tar.gz" --image-source "$D/ImageSource.json" \
  --consumed-handle 183b36e3dc8474620e948abfe12e469f
jq -e --arg raw "$raw" \
  '.ImageSource.RawSHA256==$raw and (has("KitPayload")|not)' \
  "$D/seed-output/felboot-request.template.json" >/dev/null
test -x "$D/seed-output/postseal-check.sh"
grep -Fx 'platform_commit=3e9bda124b7bd3579600579d0468890c839d62ca' "$D/one/IDENTITY" >/dev/null
grep -Fx 'image_commit=dc3637f774e304f5a42a22f948bdd6d54608f259' "$D/one/IDENTITY" >/dev/null
grep -Fx 'host_wifi_interface=wlp4s0' "$D/one/IDENTITY" >/dev/null
grep -Fx 'dut_interface=wlan0' "$D/one/IDENTITY" >/dev/null
grep -Fx 'host_wifi_interface=wlp4s0' "$D/seed-output/IDENTITY" >/dev/null
grep -Fx 'dut_interface=wlan0' "$D/seed-output/IDENTITY" >/dev/null
if "$K/prepare-kit.py" --output "$D/upper" --image-sha256 "$(printf '%s' "$raw" | tr a-f A-F)" >"$D/upper.out" 2>&1; then exit 1; fi
printf 'BUILD9_ACCEPTANCE_KIT_TEST state=PASS raw_refusal=pass deterministic=pass sealed_smoke=pass companion_refusal=pass interface_alias_refusal=pass seed_template=pass\n'
