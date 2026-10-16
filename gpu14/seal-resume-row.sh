#!/usr/bin/env bash
# Validate and append only kit-resume rows. The installed seal-and-queue.sh keeps
# exclusive ownership of ordinary sealing, resealing, seed handles, and kit rows.
set -euo pipefail

G=${SQ_DIR:-/home/matt/recovery/gpu14}
Q=${SQ_QUEUE:-$G/queue.tsv}
QDONE=${SQ_QUEUE_DONE:-$G/queue.done}

usage() {
  echo 'usage: seal-resume-row.sh NAME kit-resume-boot-open|kit-resume-open|kit-resume-step|kit-resume-close REQUEST_JSON RECEIPT_PREFIX POSTSEAL_CHECK' >&2
  echo 'POSTSEAL_CHECK is required for boot-open/open/step and must be - for close' >&2
  exit 2
}

[ "$#" -eq 5 ] || usage
name=$1; type=$2; request=$3; prefix=$4; check=$5
case "$name" in ''|*[!A-Za-z0-9_.-]*) echo 'SEALR_REFUSED reason=invalid_name'; exit 2 ;; esac
case "$type" in kit-resume-boot-open|kit-resume-open|kit-resume-step|kit-resume-close) ;; *) echo 'SEALR_REFUSED reason=invalid_resume_row_type'; exit 2 ;; esac
[ -f "$Q" ] || { echo 'SEALR_REFUSED reason=queue_missing'; exit 2; }
[ -f "$request" ] || { echo 'SEALR_REFUSED reason=request_missing'; exit 2; }
request=$(readlink -f "$request")
if [ -z "$prefix" ] || [[ "$prefix" == *$'\t'* ]] || [[ "$prefix" == *$'\n'* ]]; then
  echo 'SEALR_REFUSED reason=receipt_prefix_invalid'
  exit 2
fi

anchor=$(jq -er '.Anchor | select(type=="string" and startswith("/"))' "$request") || { echo 'SEALR_REFUSED reason=anchor_invalid'; exit 2; }
[ "$(readlink -m "$anchor")" = "$anchor" ] || { echo 'SEALR_REFUSED reason=anchor_not_canonical'; exit 2; }
repo=$(jq -er '.Live.Repo | select(type=="string" and startswith("/"))' "$request") || { echo 'SEALR_REFUSED reason=live_repo_invalid'; exit 2; }
if [ ! -d "$repo" ] || [ "$(readlink -f "$repo")" != "$repo" ]; then
  echo 'SEALR_REFUSED reason=live_repo_not_canonical'
  exit 2
fi

manifest=""
kit=""
sealed_kit() {
  local directory="$1"
  [ -d "$directory" ] && [ "$(readlink -f "$directory")" = "$directory" ] || return 1
  [ -f "$directory/SHA256SUMS" ] || return 1
  (cd "$directory" && sha256sum -c --quiet SHA256SUMS) || return 1
  manifest=$(sha256sum < "$directory/SHA256SUMS" | cut -c1-64)
}

case "$type" in
  kit-resume-boot-open)
    [ ! -e "$anchor" ] || { echo 'SEALR_REFUSED reason=anchor_already_exists'; exit 2; }
    jq -e '.Generation as $generation
      | ($generation|test("^[0-9a-f]{32}$"))
        and (.Holder|type=="string" and (contains("/")|not) and test("^.+[.][0-9a-f]{32}$") and endswith("."+$generation))
        and (.Place|type=="string" and length>0)
        and (.ImageSource|type=="object")
        and (.FelBootRequest.ImageSource == .ImageSource)
        and (.FelBootRequest.SeedHandle|type=="string" and test("^[0-9a-f]{32}$"))
        and (.OriginalBootReceipt|type=="string" and startswith("/"))' "$request" >/dev/null \
      || { echo 'SEALR_REFUSED reason=boot_open_request_invalid'; exit 2; }
    kit=$(jq -er '.BaseKitDirectory | select(type=="string" and startswith("/"))' "$request") \
      || { echo 'SEALR_REFUSED reason=base_kit_directory_invalid'; exit 2; }
    if [ "$check" = - ] || [ -z "$check" ]; then
      echo 'SEALR_REFUSED reason=postseal_check_required'
      exit 2
    fi
    sealed_kit "$kit" || { echo 'SEALR_REFUSED reason=base_kit_seal_invalid'; exit 2; } ;;
  kit-resume-open)
    [ ! -e "$anchor" ] || { echo 'SEALR_REFUSED reason=anchor_already_exists'; exit 2; }
    jq -e '.Generation as $generation
      | ($generation|test("^[0-9a-f]{32}$"))
        and (.Holder|type=="string" and (contains("/")|not) and test("^.+[.][0-9a-f]{32}$") and endswith("."+$generation))
        and (.Place|type=="string" and length>0)
        and (.ImageSource|type=="object")
        and (.InitialFlash|type=="object")
        and (.OriginalBootReceipt|type=="string" and startswith("/"))' "$request" >/dev/null \
      || { echo 'SEALR_REFUSED reason=open_request_invalid'; exit 2; }
    kit=$(jq -er '.BaseKitDirectory | select(type=="string" and startswith("/"))' "$request") \
      || { echo 'SEALR_REFUSED reason=base_kit_directory_invalid'; exit 2; }
    if [ "$check" = - ] || [ -z "$check" ]; then
      echo 'SEALR_REFUSED reason=postseal_check_required'
      exit 2
    fi
    sealed_kit "$kit" || { echo 'SEALR_REFUSED reason=base_kit_seal_invalid'; exit 2; } ;;
  kit-resume-step)
    if [ ! -f "$anchor" ] || [ "$(readlink -f "$anchor")" != "$anchor" ]; then
      echo 'SEALR_REFUSED reason=anchor_missing'
      exit 2
    fi
    jq -e '(.Final|type=="boolean") and (.ImageSource|type=="object") and (.Steps|type=="array" and length>0)' "$request" >/dev/null \
      || { echo 'SEALR_REFUSED reason=step_request_invalid'; exit 2; }
    [ "$(jq -cS .ImageSource "$request")" = "$(jq -cS .BaseImageDescriptor "$anchor")" ] \
      || { echo 'SEALR_REFUSED reason=base_image_changed'; exit 2; }
    kit=$(jq -er '.RevisionDirectory | select(type=="string" and startswith("/"))' "$request") \
      || { echo 'SEALR_REFUSED reason=revision_directory_invalid'; exit 2; }
    if [ "$check" = - ] || [ -z "$check" ]; then
      echo 'SEALR_REFUSED reason=postseal_check_required'
      exit 2
    fi
    sealed_kit "$kit" || { echo 'SEALR_REFUSED reason=revision_kit_seal_invalid'; exit 2; } ;;
  kit-resume-close)
    if [ ! -f "$anchor" ] || [ "$(readlink -f "$anchor")" != "$anchor" ]; then
      echo 'SEALR_REFUSED reason=anchor_missing'
      exit 2
    fi
    [ "$check" = - ] || { echo 'SEALR_REFUSED reason=close_check_must_be_dash'; exit 2; }
    jq -e '.Reason|IN("success","failure","timeout","gpu14_abort","identity_refusal")' "$request" >/dev/null \
      || { echo 'SEALR_REFUSED reason=close_reason_invalid'; exit 2; } ;;
esac

if [ -n "$kit" ]; then
  guard=$(mktemp -d "$G/.sealr-guard.XXXXXX")
  for tool in ssh scp curl; do
    # $0/$* must expand in the generated stub.
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nprintf "%%s\\n" "$0 $*" >> "%s/calls"\nexit 99\n' "$guard" > "$guard/$tool"
    chmod +x "$guard/$tool"
  done
  check_log="$G/.sealr-$name.check"
  rc=0
  (cd "$kit" && PATH="$guard:$PATH" timeout 600 bash -c "$check") > "$check_log" 2>&1 || rc=$?
  calls=0; [ ! -f "$guard/calls" ] || calls=$(wc -l < "$guard/calls")
  find "$guard" -mindepth 1 -delete
  rmdir "$guard"
  if [ "$rc" -ne 0 ] || [ "$calls" -ne 0 ]; then
    echo "SEALR_REFUSED reason=postseal_check_failed rc=$rc network_calls=$calls last=$(tail -n 2 "$check_log" | tr '\n' ' ' | cut -c1-200)"
    exit 2
  fi
fi

if awk -F'\t' -v name="$name" '$1==name{found=1}END{exit found?0:1}' "$Q" \
    || grep -qxF "$name" "$QDONE" 2>/dev/null; then
  echo 'SEALR_REFUSED reason=name_already_used'
  exit 2
fi
sha=$(sha256sum < "$request" | cut -c1-64)
row=$(printf '%s\t%s\t%s\t%s\t-\t%s\t-' "$name" "$type" "$request" "$sha" "$prefix")
{ cat "$Q"; printf '%s\n' "$row"; } > "$Q.new"
mv "$Q.new" "$Q"
echo "SEALR_QUEUED name=$name type=$type request_sha256=$sha anchor=$anchor manifest=${manifest:--}"
