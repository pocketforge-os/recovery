#!/usr/bin/env bash
# gpu-14 2026-10-16 (owner: "I'm not going to be selecting 76 repos ... how do we do this differently?", then
# "whatever makes sense, please proceed"): keep the pocketforge-dispatch App (actions:write, installation 167668847)
# on SELECTED repositories = every active, non-archived org repo EXCEPT the repos whose workflows request id-token or
# use signing/publishing secrets (lane dispbound org scan, DESIGN.md 3c7d337c). Bead tsp-mc9m.41.995.122 (parked:
# the GitHub->Forgejo move makes a deeper GitHub credential overhaul not worth it).
# Uses the owner's gh login (env -u GH_TOKEN): adding a repo to an App installation is an owner action; it carries no
# authored text. Never removes a repo; reports any denied repo found installed so a human can remove it.
# RESULT 2026-10-16T09:1xZ: --apply FAILS 65/65 with HTTP 403 "You do not have permission to modify this app on
# pocketforge-os": the gh CLI OAuth token cannot change App installation scope. Keep --check as a report only; add
# repos ON DEMAND (owner click) when an agent actually needs dispatch there (so far only pfvd). Forgejo replaces this.
# usage: dispatch-app-sync.sh [--check|--apply]   (default --check)
set -uo pipefail
MODE=${1:---check}
ORG=pocketforge-os
INST=167668847
DENY="infra image vendor-manifest handbook sim test-node-hw blitz libxkbcommon kernel-sunxi-4.9 gpu-km-tsp kernel-sunxi-5.15"
OWNER_GH=(env -u GH_TOKEN -u GITHUB_TOKEN gh)
mint() { PF_GH_APP_KEY_NAME=github/dispatch-app-key PF_GH_APP_META_NAME=github/dispatch-app-meta \
    /home/matt/pocketforge-automation/scripts/pf-github-bot-token.sh --force 2>/dev/null; }

T=$(mint); [ -n "$T" ] || { echo "DISPATCH_SYNC_REFUSED reason=token_mint_failed"; exit 2; }
installed=$(GH_TOKEN=$T gh api installation/repositories --paginate --jq '.repositories[].name' | sort -u) || {
    echo "DISPATCH_SYNC_REFUSED reason=installation_list_failed"; exit 2; }
repos=$("${OWNER_GH[@]}" api "orgs/$ORG/repos" --paginate --jq '.[] | select(.archived==false) | "\(.name)\t\(.id)"' | sort -u) || {
    echo "DISPATCH_SYNC_REFUSED reason=org_repo_list_failed"; exit 2; }
[ -n "$repos" ] || { echo "DISPATCH_SYNC_REFUSED reason=empty_org_repo_list"; exit 2; }

add=0; added=0; fail=0; bad=0
for d in $DENY; do grep -qx "$d" <<<"$installed" && { echo "DENIED_INSTALLED repo=$d (remove it in the installation UI)"; bad=$((bad+1)); }; done
while IFS=$'\t' read -r name id; do
    [ -n "$name" ] || continue
    case " $DENY " in *" $name "*) continue ;; esac
    grep -qx "$name" <<<"$installed" && continue
    add=$((add+1))
    if [ "$MODE" = --apply ]; then
        if "${OWNER_GH[@]}" api -X PUT "user/installations/$INST/repositories/$id" --silent 2>/dev/null; then
            added=$((added+1))
        else
            echo "ADD_FAILED repo=$name id=$id"; fail=$((fail+1))
        fi
    else
        echo "WOULD_ADD repo=$name"
    fi
done <<<"$repos"

if [ "$MODE" = --apply ]; then
    T=$(mint); now=$(GH_TOKEN=$T gh api installation/repositories --paginate --jq '.repositories[].name' | sort -u | wc -l)
    echo "DISPATCH_SYNC mode=apply added=$added failed=$fail denied_installed=$bad installed_now=$now"
else
    echo "DISPATCH_SYNC mode=check would_add=$add denied_installed=$bad installed=$(wc -l <<<"$installed")"
fi
[ "$fail" = 0 ] && [ "$bad" = 0 ]
