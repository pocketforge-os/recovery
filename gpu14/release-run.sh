#!/usr/bin/env bash
# gpu-14 forcing function for retiring a managed worker run (2026-09-27, after removing a
# worktree before its release was confirmed — for the SECOND time, despite a memory saying not to).
#
# usage: release-run.sh <run_id> <bead_id> [default_branch]
# Without [default_branch], each repo's default is its remote HEAD (`git ls-remote --symref origin HEAD`):
# e.g. gamescope -> pocketforge, kernel-sunxi-* -> device/a133, others -> main. Unresolvable -> REFUSED.
# With [default_branch], that branch is used for every repo (the old behaviour).
# Order enforced: every worktree under /home/matt/wt/<bead>/ is clean and its HEAD is an
# ancestor of origin/<default>  ->  a [gone]/missing upstream is repointed to origin/<default>
# ->  run.release  ->  run.status must say `released`  ->  ONLY THEN pf-wt rm.
# Any failed step stops before pf-wt rm and prints why.
# Single-worktree mode (2026-10-04): if /home/matt/wt/<bead> is ITSELF a linked worktree (a .git FILE),
# e.g. a `bd worktree create` Mission Control tree, it is checked as one repo and removed with
# `bd worktree remove <exact path>` (mission-control) or `git worktree remove` (other repos), not pf-wt rm.
# 2026-10-20 (tsp-mc9m.41.1030.62): the exact path, never the basename; the bd shim refuses a bare name, which upstream
# bd resolves to the first registered worktree with that basename (possibly another worker's tree).
# Superseded work (e.g. a reviewer tree pinned to a pre-force-push head): SUPERSEDED_BY=<owner/repo#N |
# 40-hex commit | bead> SUPERSEDE_REASON=<text> skips ONLY this script's landed check and passes pf-task's
# audited `supersede` to run.release, which itself refuses unless the tree is clean and HEAD is exactly on
# a pushed origin branch (push the branch with -u first). Replaces the weaker ALLOW_HEAD bypass.
# Kept worktrees (2026-10-20, tsp-mc9m.41.1030.42): KEEP_WORKTREE=1 [KEEP_REASON=<text>] releases but keeps the set:
# pf-task records release_worktree retention=kept for every repo path, and nothing is removed.
# PRESERVATION=bundle:<path>#<sha256> (with SUPERSEDED_BY) releases a HEAD that is on NO origin branch, preserved
# by a git bundle under ~/recovery/release-preserved; the bundle is pre-checked here (regular file, no symlink,
# sha256) and fully verified by pf-task. It implies KEEP_WORKTREE=1. After every release the run.status receipt is
# read back: kept paths / bundle sha256 that differ from the request (or an unrequested keep) exit 5
# RELEASE_RECEIPT_MISMATCH and remove nothing. A remover that fails after the release exits 6
# (WORKTREE_REMOVE_FAILED; the run IS released).
# QUIESCE_ACTOR=<actor> QUIESCE_REASON=<reason> passes the audited fenced stop used by terminal launch failures.
# SUPERSEDED_CONTROLLER_LOST=1 additionally passes disposition=superseded_controller_lost and requires both
# quiesce fields plus SUPERSEDED_BY/SUPERSEDE_REASON. Receipt mismatches keep every worktree.
set -u
RUN=$1; BEAD=$2; DEF=${3:-}
WT_BASE=${PF_RELEASE_WT_BASE:-/home/matt/wt}
PRESERVED_BASE=${PF_RELEASE_PRESERVED_BASE:-/home/matt/recovery/release-preserved}
ROOT=$WT_BASE/$BEAD
KEEP=${KEEP_WORKTREE:-0}; PRES_PATH=""; PRES_SHA=""
case "$KEEP" in 0|1) ;; *) echo "RELEASE_REFUSED reason=keep_worktree_not_0_or_1"; exit 2 ;; esac
CONTROLLER_LOST=${SUPERSEDED_CONTROLLER_LOST:-0}
case "$CONTROLLER_LOST" in
  0|1) ;;
  *) echo "RELEASE_REFUSED reason=superseded_controller_lost_not_0_or_1"; exit 2 ;;
esac
if { [ -n "${QUIESCE_ACTOR:-}" ] && [ -z "${QUIESCE_REASON:-}" ]; } \
    || { [ -z "${QUIESCE_ACTOR:-}" ] && [ -n "${QUIESCE_REASON:-}" ]; }; then
  echo "RELEASE_REFUSED reason=quiesce_actor_reason_must_be_paired"; exit 2
fi
if [ "$CONTROLLER_LOST" = 1 ]; then
  [ -n "${SUPERSEDED_BY:-}" ] || { echo "RELEASE_REFUSED reason=superseded_controller_lost_requires_superseded_by"; exit 2; }
  [ -n "${SUPERSEDE_REASON:-}" ] || { echo "RELEASE_REFUSED reason=superseded_controller_lost_requires_supersede_reason"; exit 2; }
  [ -n "${QUIESCE_ACTOR:-}" ] || { echo "RELEASE_REFUSED reason=superseded_controller_lost_requires_quiesce"; exit 2; }
fi
if [ -n "${PRESERVATION:-}" ]; then
  case "$PRESERVATION" in bundle:/*'#'*) ;; *) echo "RELEASE_REFUSED reason=preservation_malformed hint=bundle:<abs path>#<sha256>"; exit 2 ;; esac
  spec=${PRESERVATION#bundle:}; PRES_PATH=${spec%'#'*}; PRES_SHA=${spec##*'#'}
  [[ "$PRES_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "RELEASE_REFUSED reason=preservation_sha256_malformed"; exit 2; }
  [ -n "${SUPERSEDED_BY:-}" ] || { echo "RELEASE_REFUSED reason=preservation_requires_superseded_by"; exit 2; }
  # One open file identity (lstat regular, O_NOFOLLOW|O_NONBLOCK, fstat same inode) is contained, hashed and re-matched to the path; an
  # unresolvable root refuses. pf-task re-verifies the bundle independently (hash before and after).
  pres_why=$(python3 - "$PRES_PATH" "$PRESERVED_BASE" "$PRES_SHA" <<'PY'
import hashlib, os, stat, sys
path, base, want = sys.argv[1:]
try:
    root = os.path.realpath(base, strict=True)
except OSError:
    print("preservation_root_unresolved"); sys.exit()
if not os.path.isdir(root):
    print("preservation_root_unresolved"); sys.exit()
# lstat first and open O_NONBLOCK: a FIFO or device is rejected without ever blocking on open.
try:
    seen = os.lstat(path)
except OSError:
    print("preservation_not_regular_file"); sys.exit()
if not stat.S_ISREG(seen.st_mode):
    print("preservation_not_regular_file"); sys.exit()
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError:
    print("preservation_not_regular_file"); sys.exit()
with os.fdopen(fd, "rb") as stream:
    held = os.fstat(fd)
    if not stat.S_ISREG(held.st_mode) or (held.st_dev, held.st_ino) != (seen.st_dev, seen.st_ino):
        print("preservation_not_regular_file"); sys.exit()
    real = os.path.realpath("/proc/self/fd/%d" % fd)
    if os.path.commonpath([root, real]) != root or real == root:
        print("preservation_outside_root"); sys.exit()
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1 << 20), b""):
        digest.update(chunk)
    try:
        now = os.lstat(path)
    except OSError:
        now = None
    if now is None or (now.st_dev, now.st_ino) != (held.st_dev, held.st_ino):
        print("preservation_path_changed"); sys.exit()
    if digest.hexdigest() != want:
        print("preservation_sha256_mismatch")
PY
)
  [ -z "$pres_why" ] || { echo "RELEASE_REFUSED reason=$pres_why path=$PRES_PATH root=$PRESERVED_BASE"; exit 2; }
  KEEP=1
fi
# 2026-10-06: coordinator lanes live in `bd worktree` trees named by lane (mc-compositor-lane-g1),
# not by bead, so a lane's release refused `no_worktree_set` and sat unreleased for ~20 h.
# WORKTREE_ROOT=<path under /home/matt/wt/> names that tree explicitly; every check below still applies.
if [ -n "${WORKTREE_ROOT:-}" ]; then
  case "$WORKTREE_ROOT" in "$WT_BASE"/?*) ROOT=${WORKTREE_ROOT%/} ;; *) echo "RELEASE_REFUSED reason=worktree_root_outside_wt root=$WORKTREE_ROOT"; exit 2 ;; esac
fi
R=${GPU14_ROOT:-/home/matt/recovery/gpu14}
PF_TOOL=${PF_AUTOMATION_TOOL:-pf-automation-tool}
resolved_home=$("$R/pf-task-run-home" resolve "$RUN" --format shell) || { echo "RELEASE_REFUSED reason=run_home_unresolved run=$RUN"; exit 2; }
eval "$resolved_home"
PFT=("$PFT" --home "$H" --role coordinator)
# Resolve and positively probe the one registered home before touching any worktree.
rs=$("${PFT[@]}" run.status "{\"run_id\":\"$RUN\"}" 2>/dev/null)
if printf '%s' "$rs" | grep -q '"run_not_found"'; then
  echo "RELEASE_REFUSED reason=registered_run_not_found run=$RUN home=$H"; exit 2
fi
# 2026-10-11: dispatches with WT_ID=<bead>-cx (the Qwen-quota re-route) put the set at /home/matt/wt/<bead>-cx, so the
# default ROOT refused no_worktree_set. Without WORKTREE_ROOT, take the set from the run's own recorded worktree.
if [ -z "${WORKTREE_ROOT:-}" ]; then
  rwt=$("${PFT[@]}" run.status "{\"run_id\":\"$RUN\"}" 2>/dev/null | python3 -c 'import json,sys
d=json.load(sys.stdin); r=d.get("result",d); r=r.get("run",r); w=r.get("worktree")
print((w.get("text") if isinstance(w,dict) else w) or "")' 2>/dev/null)
  case "$rwt" in
    "$WT_BASE"/?*/?*) rset=$WT_BASE/$(printf '%s' "${rwt#"$WT_BASE"/}" | cut -d/ -f1)
      if [ "$rset" != "$ROOT" ] && [ -d "$rset" ]; then echo "RELEASE_NOTE worktree set from run.status: $rset (default $ROOT)"; ROOT=$rset; fi ;;
  esac
fi
# 2026-10-11: pf-task run.release itself refuses a run whose worktree is gone (Errno 2), so there is no
# local escape; tsp-mc9m.41.995.74 adds an audited pf-task mode. Until then such runs stay awaiting_release.
[ -d "$ROOT" ] || { echo "RELEASE_REFUSED reason=no_worktree_set root=$ROOT hint=WORKTREE_ROOT=<real set> if renamed; if the tree is truly gone pf-task cannot release it yet (tsp-mc9m.41.995.74)"; exit 2; }
NOWT=0
if [ -f "$ROOT/.git" ]; then SINGLE=1; REPOS=("$ROOT/"); else SINGLE=0; REPOS=("$ROOT"/*/); fi
for r in "${REPOS[@]}"; do
  n=$(basename "$r"); d=$DEF
  # 2026-10-11 (qfw): a worker's emptied scratch/ dir blocked release; an EMPTY non-git dir is removed, anything else refuses.
  # 2026-10-14 (tsp-f3fm .246 release): a worker left build-logs/ in the set and the release needed a hand move. A
  # NON-empty non-git dir is now MOVED (never deleted) to release-preserved/<set>/ and reported; nothing is lost.
  if [ ! -e "$r/.git" ]; then
    rmdir "$r" 2>/dev/null && { echo "removed empty non-git dir $r"; continue; }
    pres=$PRESERVED_BASE/$(basename "$ROOT")/$(basename "$r")-$(date -u +%Y%m%dT%H%M%SZ)
    mkdir -p "$(dirname "$pres")" && mv "$r" "$pres" \
      && { echo "preserved_non_git_dir path=$r -> $pres files=$(find "$pres" -type f | wc -l) bytes=$(du -sb "$pres" | cut -f1)"; continue; }
    echo "RELEASE_REFUSED reason=not_a_git_worktree path=$r hint=move_failed; move it out by hand"; exit 3
  fi
  if [ -z "$d" ]; then
    # Per-repo default from the remote's HEAD (2026-10-04: gamescope's default is `pocketforge`,
    # and one fixed default for every repo refused a correct release). Fail closed if unresolvable.
    d=$(git -C "$r" ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}')
    [ -n "$d" ] || { echo "RELEASE_REFUSED reason=default_branch_unresolved repo=$n hint=pass [default_branch]"; exit 3; }
  fi
  git -C "$r" fetch -q origin "$d" || { echo "RELEASE_REFUSED reason=fetch_failed repo=$n branch=$d${DEF:+ hint=omit [default_branch] so each repo uses its remote HEAD}"; exit 3; }
  # 2026-10-12 (lin, gamescope default pocketforge -> pocketforge-linear): pf-task's release_check reads the CACHED
  # refs/remotes/origin/HEAD, which fetch never refreshes, so a moved default refused a landed tree (tsp-mc9m.41.984.49.21).
  rh=$(git -C "$r" ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/","",$2); print $2; exit}')
  ch=$(git -C "$r" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$rh" ] && [ "$ch" != "origin/$rh" ]; then
    git -C "$r" fetch -q origin "$rh" && git -C "$r" remote set-head origin "$rh" >/dev/null \
      || { echo "RELEASE_REFUSED reason=origin_head_refresh_failed repo=$n"; exit 3; }
    echo "origin_head_refreshed repo=$n ${ch:-unset} -> origin/$rh"
  fi
  # 2026-10-11 (ctc pft-9d60ed2c): the branch ref advanced from another worktree, leaving this tree's index and files
  # at an OLD pushed head (8e404a42, 73k staged deletions). Repair ONLY when nothing can be lost: no unstaged or
  # untracked paths, and the index tree is byte-identical to a commit already in origin/$d; anything else refuses.
  if [ -n "$(git -C "$r" status --porcelain)" ]; then
    stale=""
    if [ -z "$(git -C "$r" status --porcelain --untracked-files=all | grep -v '^[MADR]  ')" ] && t=$(git -C "$r" write-tree 2>/dev/null); then
      stale=$(git -C "$r" log --format='%H %T' -n 500 HEAD | awk -v t="$t" '$2==t {print $1; exit}')
      [ -n "$stale" ] && ! git -C "$r" merge-base --is-ancestor "$stale" "origin/$d" && stale=""
    fi
    [ -n "$stale" ] || { echo "RELEASE_REFUSED reason=dirty repo=$n"; exit 3; }
    git -C "$r" reset -q --hard HEAD || { echo "RELEASE_REFUSED reason=stale_tree_reset_failed repo=$n"; exit 3; }
    echo "stale_tree_reset repo=$n tree_was=${stale:0:12} (landed in origin/$d) -> HEAD $(git -C "$r" rev-parse --short=12 HEAD)"
  fi
  h=$(git -C "$r" rev-parse HEAD)
  # 2026-10-12 (gamescope linear canary, tsp-mc9m.41.996.15): when a repo's default moves to a linear replay
  # (pocketforge -> pocketforge-linear), work merged into the old branch is landed in the ARCHIVE, not in the new default.
  # archive-branches.tsv (repo<TAB>branch...) names those archives; a HEAD contained in one counts as landed there.
  if ! git -C "$r" merge-base --is-ancestor "$h" "origin/$d" 2>/dev/null; then
    for ab in $(awk -F'\t' -v n="$n" '$1==n{for(i=2;i<=NF;i++) print $i}' "$R/archive-branches.tsv" 2>/dev/null); do
      git -C "$r" fetch -q origin "$ab" 2>/dev/null || continue
      if git -C "$r" merge-base --is-ancestor "$h" "origin/$ab"; then echo "landed_in_archive repo=$n branch=$ab default=$d"; d=$ab; break; fi
    done
  fi
  # 2026-10-12 (lin pft-fe54e79f, gamescope#13): a linear-path merge (pf-pr-merge.sh replay) lands the PR's content
  # as NEW commits, so the reviewed head is never an ancestor of the default. Count it landed only when GitHub says a
  # PR whose exact headRefOid is HEAD was MERGED into $d and its recorded merge commit is in origin/$d.
  if ! git -C "$r" merge-base --is-ancestor "$h" "origin/$d" 2>/dev/null; then
    slug=$(git -C "$r" remote get-url origin | sed -E 's#^(git@github.com:|https://github.com/)##; s#\.git$##')
    read -r rpr rmc rbr < <(gh pr list -R "$slug" --state merged --base "$d" --search "$h" --json number,headRefOid,mergeCommit,headRefName \
      -q ".[] | select(.headRefOid==\"$h\") | \"\(.number) \(.mergeCommit.oid // \"\") \(.headRefName)\"" 2>/dev/null | head -n 1) || true
    if [ -n "${rmc:-}" ] && git -C "$r" merge-base --is-ancestor "$rmc" "origin/$d" 2>/dev/null; then
      echo "landed_by_replay repo=$n head=${h:0:12} pr=$slug#$rpr merge=${rmc:0:12} in origin/$d"
      # pf-task run.release only knows ancestry and refuses "branch not merged to remote default" (gap tsp-mc9m.41.984.49.21).
      # The tree is clean here and the reviewed head stays on origin/$rbr, so moving the local branch to origin/$d loses nothing.
      # 2026-10-13 (lin rotation): GitHub deletes the PR branch on merge, so the reviewed head lived only in this tree
      # (4 repos, restored by hand). Re-create an ABSENT branch at exactly $h (plain push, never force); a branch that
      # exists at any other sha still refuses.
      if [ -z "$(git -C "$r" ls-remote origin "refs/heads/$rbr" 2>/dev/null)" ]; then
        git -C "$r" push -q origin "$h:refs/heads/$rbr" 2>/dev/null \
          && echo "replayed_head_restored repo=$n branch=$rbr head=${h:0:12} (branch was deleted on merge)" \
          || { echo "RELEASE_REFUSED reason=replayed_head_restore_failed repo=$n branch=$rbr head=$h"; exit 3; }
      fi
      git -C "$r" fetch -q origin "$rbr" 2>/dev/null && [ "$(git -C "$r" rev-parse "origin/$rbr" 2>/dev/null)" = "$h" ] \
        || { echo "RELEASE_REFUSED reason=replayed_head_not_preserved repo=$n branch=$rbr head=$h"; exit 3; }
      git -C "$r" reset -q --hard "origin/$d" && git -C "$r" branch --set-upstream-to="origin/$d" >/dev/null \
        || { echo "RELEASE_REFUSED reason=replay_repoint_failed repo=$n"; exit 3; }
      echo "replay_repointed repo=$n ${h:0:12} (kept on origin/$rbr) -> $(git -C "$r" rev-parse --short=12 HEAD) origin/$d"
      continue
    fi
  fi
  if [ -n "${SUPERSEDED_BY:-}" ] && ! git -C "$r" merge-base --is-ancestor "$h" "origin/$d"; then
    [ -n "${SUPERSEDE_REASON:-}" ] || { echo "RELEASE_REFUSED reason=supersede_reason_required"; exit 3; }
    echo "superseded repo=$n head=${h:0:12} by=$SUPERSEDED_BY (pf-task verifies HEAD is preserved on origin)"
    continue
  fi
  git -C "$r" merge-base --is-ancestor "$h" "origin/$d" || { echo "RELEASE_REFUSED reason=head_not_in_default repo=$n head=$h default=$d"; exit 3; }
  # 2026-10-14 (tsp-f3fm .246 release): a worker left its tree DETACHED at the base commit, and
  # `branch --set-upstream-to` below failed "HEAD does not point to a branch". HEAD is verified landed and the tree clean,
  # so re-attach to the set's branch: switch to it only if its tip is landed too, else create it at HEAD; never reset it.
  if ! git -C "$r" symbolic-ref -q HEAD >/dev/null; then
    bn=$(basename "$ROOT")
    if git -C "$r" show-ref --verify -q "refs/heads/$bn"; then
      git -C "$r" merge-base --is-ancestor "$(git -C "$r" rev-parse "refs/heads/$bn")" "origin/$d" \
        || { echo "RELEASE_REFUSED reason=detached_head_branch_unlanded repo=$n branch=$bn hint=its tip is not in origin/$d; inspect before releasing"; exit 3; }
      git -C "$r" switch -q "$bn" || { echo "RELEASE_REFUSED reason=detached_head_reattach_failed repo=$n branch=$bn"; exit 3; }
    else
      git -C "$r" switch -q -c "$bn" || { echo "RELEASE_REFUSED reason=detached_head_reattach_failed repo=$n branch=$bn"; exit 3; }
    fi
    h=$(git -C "$r" rev-parse HEAD); echo "reattached_detached_head repo=$n branch=$bn head=${h:0:12}"
  fi
  # Head is verified landed, so repointing is always safe. Do it unconditionally: run.release
  # fetches with prune, so a merged branch's tracking ref can vanish after a check here.
  git -C "$r" branch --set-upstream-to="origin/$d" >/dev/null && echo "upstream_pinned repo=$n -> origin/$d"
  # 2026-10-11 (prf pft-b8e08db1): in a superseded release, pf-task requires EVERY tree's HEAD to equal its pushed
  # upstream, so a clean, landed tree that is merely BEHIND origin/$d refused `HEAD differs from pushed upstream`
  # and needed a hand fast-forward. The tree is clean and HEAD is an ancestor, so --ff-only loses nothing.
  if [ -n "${SUPERSEDED_BY:-}" ] && [ "$h" != "$(git -C "$r" rev-parse "origin/$d")" ]; then
    git -C "$r" merge -q --ff-only "origin/$d" || { echo "RELEASE_REFUSED reason=ff_to_upstream_failed repo=$n"; exit 3; }
    echo "fast_forwarded repo=$n ${h:0:12} -> $(git -C "$r" rev-parse --short=12 HEAD) (superseded release needs HEAD == upstream)"
  fi
  echo "landed repo=$n head=${h:0:12} in origin/$d"
done
[ "${DRY_RUN:-0}" = 1 ] && { echo "DRY_RUN: all pre-release checks passed; nothing acked/released/removed"; exit 0; }
# Result receipts must be acknowledged before run.release (else unreconciled_deliveries_or_receipts).
# Only reached after every worktree head is verified landed, so the results have been acted on.
# Page through ALL results (a run can hold dozens); limit 4 per page.
tot=$("${PFT[@]}" run.result "{\"run_id\":\"$RUN\",\"limit\":1}" 2>/dev/null | python3 -c 'import sys,json; print(json.load(sys.stdin).get("total",0))')
pending=""
for ((off=0; off<${tot:-0}; off+=4)); do
  pending+=" $("${PFT[@]}" run.result "{\"run_id\":\"$RUN\",\"offset\":$off,\"limit\":4}" 2>/dev/null | python3 -c 'import sys,json; [print(x["evidence"]["receipt"]) for x in json.load(sys.stdin).get("results",[]) if not x.get("acknowledged")]' | tr '\n' ' ')"
done
for rc in $pending; do
  "${PFT[@]}" run.result "{\"run_id\":\"$RUN\",\"ack_receipt\":\"$rc\"}" >/dev/null 2>&1 && echo "acked $rc"
done
KEPT_PATHS=()
for r in "${REPOS[@]}"; do [ -e "${r%/}/.git" ] && KEPT_PATHS+=("$(realpath -e "${r%/}")"); done
req=$(RUN="$RUN" KEEP="$KEEP" PRES_PATH="$PRES_PATH" PRES_SHA="$PRES_SHA" CONTROLLER_LOST="$CONTROLLER_LOST" python3 -c 'import json,os,sys
e=os.environ; req={"run_id": e["RUN"]}
if e.get("SUPERSEDED_BY"):
    req["supersede"]={"superseded_by": e["SUPERSEDED_BY"], "reason": e["SUPERSEDE_REASON"]}
    if e["PRES_SHA"]:
        req["supersede"]["preservation"]={"kind": "bundle", "path": e["PRES_PATH"], "sha256": e["PRES_SHA"]}
if e.get("QUIESCE_ACTOR"):
    req["quiesce"]={"actor": e["QUIESCE_ACTOR"], "reason": e["QUIESCE_REASON"]}
if e["CONTROLLER_LOST"] == "1":
    req["disposition"]={"type": "superseded_controller_lost", "reason": e["QUIESCE_REASON"]}
if e["KEEP"] == "1":
    reason=e.get("KEEP_REASON") or ("bundle preservation: HEAD on no origin branch" if e["PRES_SHA"] else "release-run.sh KEEP_WORKTREE=1")
    req["worktree_retention"]={"reason": reason, "paths": sys.argv[1:]}
print(json.dumps(req))' "${KEPT_PATHS[@]}")
out=$("${PFT[@]}" run.release "$req" 2>&1)
sj=$("${PFT[@]}" run.status "{\"run_id\":\"$RUN\"}" 2>/dev/null)
st=$(printf '%s' "$sj" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("state"))' 2>/dev/null)
if [ "$st" != released ]; then
  echo "RELEASE_REFUSED reason=run_state_$st detail=$(tail -c 400 <<<"$out" | tr '\n' ' ')"
  if [ "${tot:-0}" = 0 ] && grep -q 'unreconciled_deliveries_or_receipts' <<<"$out"; then
    echo 'hint=run.release disposition interrupted_lost may apply: prove native loss, a clean tree, and HEAD containment in disposition.landed_ref; do not fabricate or ACK a receipt'
  fi
  echo "worktrees KEPT at $ROOT (pf-wt rm NOT run)"
  exit 4
fi
echo "released run=$RUN"
# Read the durable receipt back; never trust the request. Any mismatch keeps every tree.
mismatch=$(printf '%s' "$sj" | KEEP="$KEEP" PRES_PATH="$PRES_PATH" PRES_SHA="$PRES_SHA" CONTROLLER_LOST="$CONTROLLER_LOST" python3 -c 'import json,os,sys
t=lambda v: v.get("text") if isinstance(v, dict) else v
e=os.environ; d=json.load(sys.stdin); rw=d.get("release_worktree") or {}
kept={os.path.realpath(t(k.get("path")) or "") for k in rw.get("kept_paths") or [] if isinstance(k, dict)}
if e["KEEP"] == "1":
    if rw.get("retention") != "kept": print("retention=%s" % rw.get("retention")); sys.exit()
    missing=[p for p in sys.argv[1:] if os.path.realpath(p) not in kept]
    if missing: print("kept_path_missing=" + missing[0]); sys.exit()
elif rw.get("retention") == "kept":
    print("unrequested_keep"); sys.exit()
if e["PRES_SHA"]:
    p=(d.get("release_disposition") or {}).get("preservation") or {}
    if t(p.get("sha256")) != e["PRES_SHA"] or t(p.get("path")) != e["PRES_PATH"]:
        print("bundle_receipt=%s" % (t(p.get("sha256")) or "absent")); sys.exit()
if e.get("QUIESCE_ACTOR"):
    q=(d.get("release_runtime") or {}).get("quiescence") or {}
    if t(q.get("actor")) != e["QUIESCE_ACTOR"] or t(q.get("reason")) != e["QUIESCE_REASON"]:
        print("quiesce_receipt=%s" % (t(q.get("actor")) or "absent")); sys.exit()
if e["CONTROLLER_LOST"] == "1":
    p=d.get("release_disposition") or {}
    if p.get("disposition") != "superseded_controller_lost" or t(p.get("superseded_by")) != e["SUPERSEDED_BY"]:
        print("controller_lost_receipt=%s" % (p.get("disposition") or "absent")); sys.exit()' "${KEPT_PATHS[@]}" 2>&1)
if [ -n "$mismatch" ]; then
  echo "RELEASE_RECEIPT_MISMATCH run=$RUN $mismatch"
  echo "worktrees KEPT at $ROOT (run IS released; nothing removed)"
  exit 5
fi
if [ "$KEEP" = 1 ]; then
  echo "worktrees KEPT at $ROOT (receipt retention=kept paths=${#KEPT_PATHS[@]}${PRES_SHA:+ bundle_sha256=$PRES_SHA})"
  exit 0
fi
# 2026-10-20 (review on recovery#26, tsp-mc9m.41.1030.62): every remover's status propagates. A refusal after the
# release (e.g. the removal guard's ownership_unproven) used to be swallowed by `| tail` and exit 0 with the tree left
# behind; now it prints WORKTREE_REMOVE_FAILED and the script exits 6 (the run IS released).
cleanup_failed=0
remove_step() {  # remover argv...: run it, show its tail, record a nonzero status
  local out rc
  out=$("$@" 2>&1); rc=$?
  [ -z "$out" ] || printf '%s\n' "$out" | tail -3
  [ "$rc" = 0 ] || { echo "WORKTREE_REMOVE_FAILED rc=$rc cmd=$1 (run IS released)"; cleanup_failed=1; }
}
if [ "$NOWT" = 1 ]; then
  echo "no worktree to remove"
elif [ "$SINGLE" = 1 ]; then
  common=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)
  if [ "$common" = /home/matt/mission-control/.git ]; then
    remove_step bd -C /home/matt/mission-control worktree remove "$ROOT"
  else
    remove_step git -C "$ROOT" worktree remove "$ROOT"
  fi
  if [ -e "$ROOT" ]; then echo "WORKTREE_REMOVE_FAILED path=$ROOT (run IS released)"; cleanup_failed=1; else echo "removed worktree $ROOT"; fi
elif [ "$ROOT" = "$WT_BASE/$BEAD" ]; then
  # 2026-10-10: the shared ~/.local/bin/pf-wt is 1010 commits stale (tsp-hqm1p.52) and cannot remove a
  # set holding a pf-wt evidence target (tsp-f3fm.234); the pinned origin/main pf-wt can.
  remove_step "$PF_TOOL" pf-wt.sh rm "$BEAD"
  if [ -e "$ROOT" ]; then echo "WORKTREE_REMOVE_FAILED path=$ROOT reason=set_survived (run IS released)"; cleanup_failed=1; fi
else
  # 2026-10-06: with WORKTREE_ROOT=<...-r2> the checks verified ROOT, but `pf-wt rm $BEAD` removed
  # /home/matt/wt/$BEAD, a DIFFERENT (preserved) run's tree. Remove only the verified ROOT, per repo,
  # with git's own dirty-tree refusal; never fall back to pf-wt rm for an overridden root.
  # 2026-10-11: pf-wt locks each tree with reason `pf-wt <set name>`, so git refused every overridden root
  # (4 sets left behind). The set name is basename(ROOT): when the lock names exactly that set, pf-wt rm of
  # that name removes exactly the verified ROOT (with pf-wt's own dirty-tree refusal).
  set_name=$(basename "$ROOT")
  if grep -qx "pf-wt $set_name" "$(git -C "$(ls -d "$ROOT"/*/ | head -n 1)" rev-parse --git-dir 2>/dev/null)/locked" 2>/dev/null; then
    remove_step "$PF_TOOL" pf-wt.sh rm "$set_name"
  fi
  for d in "$ROOT"/*/; do
    d=${d%/}; [ -e "$d/.git" ] || continue
    remove_step git -C "$d" worktree remove "$d"
    if [ -e "$d" ]; then echo "WORKTREE_REMOVE_FAILED path=$d (run IS released)"; cleanup_failed=1; else echo "removed worktree $d"; fi
  done
  if [ ! -e "$ROOT" ]; then echo "set dir $ROOT already removed"; elif rmdir "$ROOT" 2>/dev/null; then echo "removed set dir $ROOT"
  else echo "WORKTREE_REMOVE_FAILED path=$ROOT reason=set_dir_not_empty (run IS released)"; cleanup_failed=1; fi
fi
[ "$cleanup_failed" = 0 ] || exit 6
