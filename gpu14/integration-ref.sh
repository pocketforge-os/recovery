#!/usr/bin/env bash
# proc-coord 2026-10-16 (tsp-mc9m.41.1030): build ONE integration commit for a deploy-first runner.
# This replaces serial per-PR deploy-first: #1490 -> #1488 -> #1493/#1494 cost ~22 h of merge-main +
# re-review + CI + redeploy + window, one PR at a time.
# The commit is a merge of: origin/<base> + every candidate PR head + the currently DEPLOYED head
# (carried so that runner-redeploy.sh's no-drop ancestry guard holds without change).
# It is pushed as the bot to a throwaway branch integ/<UTC>, so runner-redeploy.sh can fetch it by SHA.
# One live window then proves the whole batch; the PRs merge afterwards in any order.
# It never resolves conflicts: any conflict refuses and names the PR.
# usage: integration-ref.sh [--repo owner/name] [--base main] [--deployed <40-hex>|--deployed-from-runner] [--no-push] <pr#>...
# out:   INTEG_REF sha=<40-hex> ref=integ/<stamp>-<sha8> base=<sha> deployed=<sha|none> heads=<N:sha,...>   (exit 0)
#        INTEG_REFUSED reason=<...> [hint=...]                                                      (exit 2/3/4)
set -uo pipefail
repo=pocketforge-os/pocketforge-automation; base=main; deployed=""; push=1; prs=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo=${2:?}; shift 2 ;;
    --base) base=${2:?}; shift 2 ;;
    --deployed) deployed=${2:?}; shift 2 ;;
    --deployed-from-runner)
      d=$(systemctl --user show pf-kit-window-runner.service -p Environment --value | tr ' ' '\n' | sed -n 's/^PF_KIT_AUTOMATION_REPO=//p')
      [ -d "$d" ] || { echo "INTEG_REFUSED reason=runner_clone_unknown"; exit 2; }
      deployed=$(git -C "$d" rev-parse HEAD); shift ;;
    --no-push) push=0; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    [0-9]*) prs+=("$1"); shift ;;
    *) echo "INTEG_REFUSED reason=bad_arg arg=$1"; exit 2 ;;
  esac
done
[ "${#prs[@]}" -gt 0 ] || { echo "INTEG_REFUSED reason=no_prs"; exit 2; }
[[ $repo =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || { echo "INTEG_REFUSED reason=bad_repo"; exit 2; }
[ -z "$deployed" ] || [[ $deployed =~ ^[0-9a-f]{40}$ ]] || { echo "INTEG_REFUSED reason=bad_deployed_sha"; exit 2; }
R=${GPU14_ROOT:-/home/matt/recovery/gpu14}; W=$R/integ-work/${repo//\//_}; RC=$R/integ-receipts
mkdir -p "$RC"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
url=${PF_INTEG_REMOTE_URL:-https://github.com/$repo.git}
g() { git -C "$W" "$@"; }
[ -d "$W/.git" ] || git clone -q --no-checkout "$url" "$W" || { echo "INTEG_REFUSED reason=clone_failed"; exit 3; }
g remote set-url origin "$url"
g fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" || { echo "INTEG_REFUSED reason=fetch_base_failed"; exit 3; }
heads=(); hs=""
for n in "${prs[@]}"; do
  if [ -z "${PF_INTEG_REMOTE_URL:-}" ]; then
    st=$(env -u GH_TOKEN -u GITHUB_TOKEN gh api "repos/$repo/pulls/$n" --jq '.state+" "+.head.sha' 2>/dev/null) || { echo "INTEG_REFUSED reason=pr_read_failed pr=$n"; exit 3; }
    [ "${st%% *}" = open ] || { echo "INTEG_REFUSED reason=pr_not_open pr=$n state=${st%% *}"; exit 3; }
  fi
  g fetch -q origin "+refs/pull/$n/head:refs/integ-src/pr-$n" || { echo "INTEG_REFUSED reason=fetch_pr_failed pr=$n"; exit 3; }
  h=$(g rev-parse "refs/integ-src/pr-$n"); heads+=("$h"); hs+="${hs:+,}$n:$h"
done
if [ -n "$deployed" ]; then
  g cat-file -e "$deployed^{commit}" 2>/dev/null || g fetch -q origin "$deployed" 2>/dev/null
  g cat-file -e "$deployed^{commit}" 2>/dev/null || { echo "INTEG_REFUSED reason=deployed_unreachable sha=$deployed"; exit 3; }
fi
b=$(g rev-parse "refs/remotes/origin/$base")
g -c advice.detachedHead=false checkout -q --force --detach "$b" || { echo "INTEG_REFUSED reason=checkout_failed"; exit 3; }
g clean -qfdx
mg() { # <sha> <label>
  g merge-base --is-ancestor "$1" HEAD && return 0
  if ! g -c user.name="pocketforge-agent[bot]" -c user.email="pocketforge-agent[bot]@users.noreply.github.com" \
       merge -q --no-ff --no-edit -m "integ: merge $2 ($1)" "$1" >/dev/null 2>&1; then
    files=$(g diff --name-only --diff-filter=U | head -5 | tr '\n' ' '); g merge --abort 2>/dev/null
    echo "INTEG_REFUSED reason=conflict with=$2 files=${files:-?} hint=merge base into that branch, or drop it from this batch"; exit 4
  fi
}
for i in "${!prs[@]}"; do mg "${heads[$i]}" "pr-${prs[$i]}"; done
[ -z "$deployed" ] || mg "$deployed" deployed
sha=$(g rev-parse HEAD); ref="integ/$stamp-${sha:0:8}"
for h in "${heads[@]}" ${deployed:+"$deployed"} "$b"; do
  g merge-base --is-ancestor "$h" "$sha" || { echo "INTEG_REFUSED reason=postcheck_not_ancestor sha=$h"; exit 4; }
done
if [ "$push" = 1 ]; then
  if [ -z "${PF_INTEG_REMOTE_URL:-}" ]; then
    PF_INTEG_BOT_TOKEN=$(/home/matt/pocketforge-automation/scripts/pf-github-bot-token.sh) && [ -n "$PF_INTEG_BOT_TOKEN" ] \
      || { echo "INTEG_REFUSED reason=bot_token_unavailable"; exit 3; }
    export PF_INTEG_BOT_TOKEN
    # The token travels in the environment to the credential helper, never in argv.
    g -c credential.helper= -c 'credential.helper=!f() { echo username=x-access-token; echo "password=$PF_INTEG_BOT_TOKEN"; }; f' \
      push -q origin "$sha:refs/heads/$ref" || { echo "INTEG_REFUSED reason=push_failed"; exit 3; }
    unset PF_INTEG_BOT_TOKEN
  else
    g push -q origin "$sha:refs/heads/$ref" || { echo "INTEG_REFUSED reason=push_failed"; exit 3; }
  fi
else
  ref=none
fi
jq -n --arg sha "$sha" --arg ref "$ref" --arg repo "$repo" --arg base "$b" --arg deployed "${deployed:-}" --arg heads "$hs" --arg at "$stamp" \
  '{at:$at,repo:$repo,sha:$sha,ref:$ref,base:$base,deployed:$deployed,heads:$heads}' > "$RC/$stamp-${sha:0:8}.json"
echo "INTEG_REF sha=$sha ref=$ref base=$b deployed=${deployed:-none} heads=$hs receipt=$RC/$stamp-${sha:0:8}.json"
