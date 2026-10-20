#!/usr/bin/env python3
"""gpu-14 lane supervisor: deterministic wait + bounded pf_task MCP auto-approval.

Waits on one managed pf-task run. While the run is permission_blocked, approves
("once") ONLY Codex MCP tool-call elicitations whose serverName is exactly
"pf_task" (the run's own role/owner-run-scoped control MCP; the pf-task server
enforces scope). Every approval is appended to an audit log. Anything else
exits so the coordinator (gpu-14) wakes and decides, with a DISTINCT reason:

  exit 0  TURN_END      run left busy/blocked state (turn ended, terminal, etc.)
  exit 3  FOREIGN       a permission request that is not a pf_task MCP tool call
  exit 4  UNREADABLE    evidence could not be read/parsed after retries
  exit 5  ID_ABSENT     a permission id from the wait result is absent from evidence
  exit 6  WAIT_ERROR    work.wait returned something unparseable/refused
  exit 7  BUDGET        approval budget exhausted (runaway guard)
  exit 9  STATE_UNHANDLED a state the loop does not model persisted > UNKNOWN_STATE_SECONDS
  exit 11 COMPLETED_UNRECORDED  a completed turn in the artifact log that pf-task never recorded
  exit 8  WEDGED        turn_timeout interrupt set and rollout idle > WEDGE_SECONDS (tsp-mwo3a)
  exit 10 DEAD_CONTROLLER run.status says controller_alive=false twice in a row (tsp-hqm1p.42)

Lesson applied (memory fail-closed-guard-can-fail-for-the-wrong-reason): parse
the fully paged, sha256-pinned evidence as JSON; never scan a fixed window.
"""
import json
import os
import subprocess
import sys
import time

def _resolved_home(run_id):
    resolver = os.environ.get(
        "PF_TASK_RUN_HOME_RESOLVER", "/home/matt/recovery/gpu14/pf-task-run-home")
    try:
        result = subprocess.run(
            [resolver, "resolve", run_id], capture_output=True, text=True,
            timeout=float(os.environ.get("PF_TASK_RUN_HOME_RESOLVE_TIMEOUT", "320")))
        value = json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        raise SystemExit(f"SUPERVISOR_REFUSED reason=run_home_unreadable detail={exc}") from exc
    required = ("control_home", "pf_task", "host_config")
    if result.returncode or not isinstance(value, dict) or any(
            not isinstance(value.get(key), str) or not value[key] for key in required):
        raise SystemExit(
            f"SUPERVISOR_REFUSED reason=run_home_unresolved rc={result.returncode}")
    return value


if len(sys.argv) < 2:
    raise SystemExit("SUPERVISOR_REFUSED reason=run_id_missing")
RUN_HOME = _resolved_home(sys.argv[1])
HOME = RUN_HOME["control_home"]
PF_TASK_BIN = RUN_HOME["pf_task"]
ENV = dict(os.environ, PF_TASK_HOST_CONFIG=RUN_HOME["host_config"])
BUSY_POLL_SECONDS = float(os.environ.get("PF_LANE_SUPERVISOR_BUSY_POLL_SECONDS", "5"))
if os.environ.get("PF_LANE_SUPERVISOR_HOME_CHECK_ONLY") == "1":
    print(json.dumps({"control_home": HOME, "pf_task": PF_TASK_BIN,
                      "host_config": ENV["PF_TASK_HOST_CONFIG"]}, sort_keys=True))
    raise SystemExit(0)

import re
import shlex
CMD_WRAP = re.compile(r"^/bin/bash -lc '([^']*)'$")
META = set(";&|`$()<>\\\n\"'*?{}[]!~")
ALLOWED_PREFIXES = [
    ["pf-wt", "create"],
    ["gh", "pr", "view"], ["gh", "pr", "list"], ["gh", "pr", "checks"], ["gh", "pr", "create"],
    ["pf-automation-tool", "pf-codex-worker.sh", "--review-only"],
    # 2026-09-28: pf-pr-merge.sh removed from this role-agnostic list. It let WORKER runs merge
    # and ignored the runtime/launcher window. Merges are now coordinator-only via
    # lane_gated_merge / lane_gated_merge_drive in command_allowed (all 50 historical uses matched).
]


GIT_COMMIT_RE = re.compile(r'git commit( -m "[^"$`\\\\!\n]*")+')
CWD_GIT_READ = {"status", "log", "diff", "merge-base", "rev-parse", "show", "branch", "fetch"}



fn_logged = {}



AUTOCONT_DIR = "/home/matt/recovery/gpu14/autocontinue"
AUTOCONT_MAX = 2


def _last_turn_timeout_interrupt(run_id):
    """Turn id of the run's LAST turn when it ended status=interrupted at the per-turn bound
    (durationMs >= 3_500_000 of the 3600 s schema ceiling), else None. Reads only the tail of
    the newest artifact event log."""
    import glob, json as _json
    files = sorted(glob.glob(f"{HOME}/artifacts/{run_id}/*.jsonl"), key=os.path.getmtime)
    if not files:
        return None
    with open(files[-1], "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - 400_000))
        tail = fh.read().decode("utf-8", "replace").splitlines()
    for line in reversed(tail):
        if '"turn/completed"' not in line:
            continue
        try:
            turn = _json.loads(line)["message"]["params"]["turn"]
        except Exception:
            return None
        if turn.get("status") == "interrupted" and (turn.get("durationMs") or 0) >= 3_500_000:
            return turn.get("id")
        return None
    return None


def _last_completed_turn(run_id):
    """(turn_id, path) when the run's newest artifact log ends with turn/completed status=completed;
    the agent's final message is saved to autocontinue/<run>.final.txt. Else None."""
    import glob, json as _json
    files = sorted(glob.glob(f"{HOME}/artifacts/{run_id}/*.jsonl"), key=os.path.getmtime)
    if not files:
        return None
    with open(files[-1], "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - 600_000))
        tail = fh.read().decode("utf-8", "replace").splitlines()
    for line in reversed(tail):
        if '"turn/completed"' not in line:
            continue
        try:
            turn = _json.loads(line)["message"]["params"]["turn"]
        except Exception:
            return None
        if turn.get("status") != "completed":
            return None
        text = "\n".join(it.get("text", "") for it in turn.get("items", []) if it.get("type") == "agentMessage")
        os.makedirs(AUTOCONT_DIR, exist_ok=True)
        path = os.path.join(AUTOCONT_DIR, f"{run_id}.final.txt")
        with open(path, "w") as out:
            out.write(text)
        return (turn.get("id"), path)
    return None


def _artifact_idle_s(run_id):
    """Seconds since the run's newest artifact log was written, or None when there is none."""
    import glob
    files = glob.glob(f"{HOME}/artifacts/{run_id}/*.jsonl")
    if not files:
        return None
    return time.time() - max(os.path.getmtime(f) for f in files)


def _autocontinue(run_id, turn_id):
    """Send one bounded continuation for a turn-timeout interrupt. Returns 'sent', 'done', or 'exhausted'."""
    os.makedirs(AUTOCONT_DIR, exist_ok=True)
    path = os.path.join(AUTOCONT_DIR, run_id)
    seen = open(path).read().split() if os.path.exists(path) else []
    if turn_id in seen:
        return "done"
    if len(seen) >= AUTOCONT_MAX:
        return "exhausted"
    text = ("gpu-14 supervisor (automatic, tsp-mc9m.41.984.49 stopgap): your previous turn was INTERRUPTED "
            "by the per-turn time bound (3600 s), mid-work. Continue from your last step: check `git status` "
            "in your worktree, finish the in-progress change, run its tests, commit and push. If the rest "
            "cannot finish in one more turn, commit a coherent checkpoint, push, record progress on your bead, "
            "and say what remains. Either way END this turn with your status block "
            "(DONE / HEAD / PR / CI / TESTS / BLOCKERS / NEXT FOR gpu-14). Standing rules unchanged.")
    r = pf("run.send", {"run_id": run_id, "key": f"autocont-{turn_id}", "text": text}, 120)
    with open(path, "a") as fh:
        fh.write(turn_id + "\n")
    with open(os.path.join(AUTOCONT_DIR, "log"), "a") as fh:
        fh.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} run={run_id} turn={turn_id} "
                 f"n={len(seen)+1} send={json.dumps(r)[:160]}\n")
    return "sent"

def _runtime_proc_alive(run_id):
    """True when a `pf-task ... runtime <run_id>` host process exists (ground-truth liveness)."""
    import glob
    for c in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            with open(c, "rb") as fh:
                argv = fh.read().split(b"\0")
        except OSError:
            continue
        if b"runtime" in argv and run_id.encode() in argv and any(a.endswith(b"pf-task") for a in argv):
            return True
        # OpenCode runs have no `pf-task runtime` host: the session lives in an `opencode serve`
        # process whose per-run MCP helper is `pf-task ... --owner-run <run_id> mcp`. A live helper
        # under a live opencode parent is a live runtime (2026-09-30: pft-2d61a894 false DEAD).
        if b"--owner-run" in argv and run_id.encode() in argv:
            try:
                ppid = open(c.replace("cmdline", "stat")).read().rsplit(")", 1)[1].split()[1]
                with open(f"/proc/{ppid}/cmdline", "rb") as fh:
                    parent = fh.read()
            except (OSError, IndexError):
                continue
            if b"opencode" in parent:
                return True
    return False

def run_role(run_id):
    import sqlite3
    try:
        db = sqlite3.connect(f"file:{HOME}/journal.sqlite3?mode=ro", uri=True, timeout=30)
        r = db.execute("SELECT json_extract(body,'$.request.role') FROM records WHERE kind='run' AND id=?",
                       (run_id,)).fetchone()
        db.close()
        return r[0] if r else None
    except Exception:
        return None


LANE_BD_HEREDOC = re.compile(r"(?:/home/matt/\.local/bin/)?bd(?: -C /home/matt/mission-control)? comment "
                             r"(tsp-[A-Za-z0-9.]+) --stdin <<'([A-Za-z0-9_]+)'\n(.*)\n\2\s*", re.S)


RO_GIT_OPS = {"fetch", "merge-base", "rev-parse", "status", "log", "show", "diff", "ls-remote", "rev-list", "cat-file"}
# 2026-09-27 ~23:05Z: lanes pin a PR head before reviewing it:
#   head="$(gh api repos/pocketforge-os/<repo>/pulls/<n> --jq .head.sha)"
#   test "$head" = "<40-hex>"
# These two whole-line shapes are the ONLY `$` uses accepted; any other `$` still rejects.
RO_HEAD_ASSIGN = re.compile(r'^([a-z_][a-z0-9_]*)="\$\(gh api repos/pocketforge-os/[A-Za-z0-9._-]+/pulls/[0-9]+ --jq \.head\.sha\)"$')
RO_HEAD_TEST = re.compile(r'^test "\$([a-z_][a-z0-9_]*)" = "[0-9a-f]{40}"$')


def lane_readonly_verify_allowed(cmd):
    """2026-09-27 ~21:10Z: lanes verify merges/heads with multi-line read-only scripts
    (`set -euo pipefail` then `git -C /home/matt/wt/... <read-op>` and `gh api repos/...` GETs).
    Allowed ONLY if every non-set line is one such command; any `$`, backtick, redirect, `;`,
    `&`, pipe or unknown argv rejects the whole script (fail closed -> gpu-14 decides)."""
    try:
        outer = shlex.split(cmd or "")
    except ValueError:
        return False, "ro:unparseable"
    if len(outer) != 3 or outer[0] != "/bin/bash" or outer[1] not in ("-lc", "-c"):
        return False, "ro:not_bash_c"
    inner = outer[2]
    if "`" in inner:
        return False, "ro:expansion"
    lines = [ln.strip() for ln in inner.split("\n") if ln.strip()]
    if not lines:
        return False, "ro:empty"
    assigned, rest = set(), []
    for ln in lines:
        ma, mt = RO_HEAD_ASSIGN.match(ln), RO_HEAD_TEST.match(ln)
        if ma:
            assigned.add(ma.group(1))
        elif mt and mt.group(1) in assigned:
            continue
        else:
            rest.append(ln)
    if any("$" in ln for ln in rest):
        return False, "ro:expansion"
    lines = rest
    if not lines:
        return False, "ro:only_head_check"
    body = [ln for ln in lines if ln not in ("set -euo pipefail", "set -eu", "set -e")]
    if not body:
        return False, "ro:only_set"
    for ln in body:
        lx = shlex.shlex(ln, posix=True, punctuation_chars=True)
        lx.whitespace_split = True
        try:
            a = list(lx)
        except ValueError:
            return False, "ro:line_unparseable"
        if any(t and set(t) <= set("();<>|&") for t in a):
            return False, "ro:operator"
        if len(a) >= 4 and a[0] == "git" and a[1] == "-C":
            path = a[2]
            if not path.startswith("/home/matt/wt/") or ".." in path.split("/"):
                return False, "ro:git_path"
            if a[3] not in RO_GIT_OPS:
                return False, "ro:git_op:" + a[3]
            continue
        if len(a) >= 3 and a[0] == "gh" and a[1] == "api":
            if not a[2].startswith("repos/pocketforge-os/"):
                return False, "ro:gh_api_path"
            rest = a[3:]
            i = 0
            while i < len(rest):
                if rest[i] in ("--jq", "-q"):
                    i += 2
                    continue
                if rest[i] == "--paginate":
                    i += 1
                    continue
                return False, "ro:gh_api_flag:" + rest[i]
            continue
        if len(a) >= 3 and a[0] == "gh" and a[1] == "pr" and a[2] in ("view", "list", "checks"):
            if any(t in ("--web", "-w") for t in a):
                return False, "ro:gh_pr_web"
            continue
        return False, "ro:argv:" + (a[0] if a else "")
    return True, "lane_readonly_verify"



# 2026-09-28: `pf-wt rm <bead>` after a worker's release woke gpu-14 five times in one session, and each time the
# manual check was identical and mechanical. Approve it ONLY when that check passes, for every bead in a pure
# `pf-wt rm` chain:
#   - every pf-task run whose worktree lives under /home/matt/wt/<bead>/ is `released`, and there is at least one;
#   - every repo worktree in the set is clean (`git status --porcelain` empty) and its HEAD is an ancestor of the
#     fetched origin default branch (preservation proof for a git worktree).
# Anything else (dirty, unreleased, unlanded, unknown default, other commands) stays FOREIGN and wakes gpu-14.
WT_RM_BEAD = re.compile(r"^tsp-[a-z0-9]+(?:\.[a-z0-9-]+)*$")


def _wt_rm_beads(cmd):
    try:
        o = shlex.split(cmd or "")
    except ValueError:
        return None
    if not (len(o) == 3 and o[0] == "/bin/bash" and o[1] in ("-lc", "-c")):
        return None
    beads = []
    for seg in o[2].split("&&"):
        try:
            a = shlex.split(seg)
        except ValueError:
            return None
        if len(a) != 3 or a[0] != "pf-wt" or a[1] != "rm" or not WT_RM_BEAD.match(a[2]):
            return None
        beads.append(a[2])
    return beads or None


def _git_default_ref(repo):
    r = subprocess.run(["git", "-C", repo, "symbolic-ref", "--quiet", "refs/remotes/origin/HEAD"],
                       capture_output=True, text=True, timeout=30)
    ref = r.stdout.strip()
    if r.returncode == 0 and ref.startswith("refs/remotes/origin/"):
        return "origin/" + ref[len("refs/remotes/origin/"):]
    for cand in ("origin/main", "origin/master"):
        if subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", cand],
                          capture_output=True, timeout=30).returncode == 0:
            return cand
    return None


def _release_preserved_paths(run):
    """Paths a released run's receipt KEPT (bundle preservation or worktree_retention), else []."""
    retained = run.get("release_worktree") if isinstance(run.get("release_worktree"), dict) else {}
    disposition = run.get("release_disposition") if isinstance(run.get("release_disposition"), dict) else {}
    if retained.get("retention") != "kept" and not isinstance(disposition.get("preservation"), dict):
        return []
    paths = [str(run.get("request", {}).get("worktree") or "")]
    paths += [str(item.get("path") or "") for item in retained.get("kept_paths") or [] if isinstance(item, dict)]
    return [path for path in paths if path]


def verified_wt_rm_allowed(cmd, runs_loader=None, wt_root="/home/matt/wt"):
    beads = _wt_rm_beads(cmd)
    if not beads:
        return False, "wtrm:not_pure_pf_wt_rm"
    if runs_loader is None:
        def runs_loader():
            import sqlite3
            db = sqlite3.connect("file:" + HOME + "/journal.sqlite3?mode=ro", uri=True, timeout=30)
            try:
                return [json.loads(b) for (b,) in db.execute("SELECT body FROM records WHERE kind='run'")]
            finally:
                db.close()
    runs = runs_loader()
    for bead in beads:
        base = os.path.join(wt_root, bead) + os.sep
        # 2026-10-20 (tsp-mc9m.41.1030.42): a release that kept its tree (bundle-only HEAD, or an explicit
        # keep) must never be swept, even once HEAD lands; only the owner/coordinator removes it by hand.
        kept = [r.get("run_id") for r in runs
                if any(p == base[:-1] or p.startswith(base) for p in _release_preserved_paths(r))]
        if kept:
            return False, f"wtrm:release_preserved:{bead}:{kept[0]}"
        owners = [r for r in runs if str(r.get("request", {}).get("worktree") or "").startswith(base)]
        if not owners:
            return False, f"wtrm:no_run_owns:{bead}"
        live = [r["run_id"] for r in owners if r.get("state") != "released"]
        if live:
            return False, f"wtrm:unreleased:{bead}:{live[0]}"
        setdir = os.path.join(wt_root, bead)
        if not os.path.isdir(setdir):
            return False, f"wtrm:no_set_dir:{bead}"
        repos = [os.path.join(setdir, d) for d in sorted(os.listdir(setdir))
                 if os.path.exists(os.path.join(setdir, d, ".git"))]
        if not repos:
            return False, f"wtrm:no_repos:{bead}"
        for repo in repos:
            st = subprocess.run(["git", "-C", repo, "status", "--porcelain"], capture_output=True, text=True, timeout=60)
            if st.returncode != 0 or st.stdout.strip():
                return False, f"wtrm:dirty:{repo}"
            subprocess.run(["git", "-C", repo, "fetch", "-q", "origin"], capture_output=True, timeout=120)
            dref = _git_default_ref(repo)
            if not dref:
                return False, f"wtrm:unknown_default:{repo}"
            if subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", "HEAD", dref],
                              capture_output=True, timeout=60).returncode != 0:
                return False, f"wtrm:head_not_in_{dref}:{repo}"
    return True, "verified_wt_rm:" + ",".join(beads)

def lane_gh_read_allowed(cmd):
    """2026-09-28: coordinator lanes run gh from /home/matt/wt (bot token; the owner keyring token
    is invalid) and have no bead worktree, so the own-bead wt rules never apply. Allow exactly ONE
    read-only gh command: `gh run view`, `gh pr view|checks|diff`, or a non-mutation `gh api graphql`
    query, against pocketforge-os repos. No pipe, no chain, no shell expansion."""
    try:
        outer = shlex.split(cmd or "")
    except ValueError:
        return False, "ghr:unparseable"
    if len(outer) != 3 or outer[0] != "/bin/bash" or outer[1] not in ("-lc", "-c"):
        return False, "ghr:not_bash_c"
    inner = outer[2].strip()
    if "\n" in inner or has_live_expansion(inner):
        return False, "ghr:shape"
    lx = shlex.shlex(inner, posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    try:
        a = list(lx)
    except ValueError:
        return False, "ghr:unparseable_inner"
    if any(t and set(t) <= set("();<>|&") for t in a):
        return False, "ghr:operator"  # an UNQUOTED shell operator; quoted jq pipes are fine
    if a[:1] != ["gh"] or len(a) < 3:
        return False, "ghr:not_gh"
    def repo_ok(v):
        return re.fullmatch(r"pocketforge-os/[A-Za-z0-9_.-]+", v) is not None
    def opts_ok(rest, allowed_valued, allowed_flags):
        j = 0; seen_repo = False
        while j < len(rest):
            t = rest[j]
            if t in allowed_flags:
                j += 1
            elif t in allowed_valued and j + 1 < len(rest):
                if t == "--repo":
                    if not repo_ok(rest[j + 1]):
                        return False
                    seen_repo = True
                elif t in ("--job",) and not re.fullmatch(r"[0-9]+", rest[j + 1]):
                    return False
                elif t == "--json" and not re.fullmatch(r"[A-Za-z,]+", rest[j + 1]):
                    return False
                j += 2
            else:
                return False
        return seen_repo
    if a[1] == "run" and a[2] == "view" and len(a) >= 4 and re.fullmatch(r"[0-9]+", a[3]):
        if opts_ok(a[4:], {"--repo", "--job", "--json", "--jq", "-q"}, {"--log", "--log-failed", "--verbose", "-v"}):
            return True, "lane_gh_run_view"
        return False, "ghr:run_view_opts"
    if a[1] == "pr" and a[2] in ("view", "checks", "diff") and len(a) >= 4 and re.fullmatch(r"[0-9]+", a[3]):
        if opts_ok(a[4:], {"--repo", "--json", "--jq", "-q"}, {"--name-only", "--patch"}):
            return True, "lane_gh_pr_" + a[2]
        return False, "ghr:pr_opts"
    if a[1:3] == ["api", "graphql"]:
        rest, q, j = a[3:], None, 0
        while j < len(rest):
            if rest[j] in ("-f", "-F", "--raw-field", "--field") and j + 1 < len(rest):
                kv = rest[j + 1]
                if kv.startswith("query="):
                    q = kv[len("query="):]
                elif not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./-]+", kv):
                    return False, "ghr:graphql_var"
                j += 2
            elif rest[j] in ("--jq", "-q") and j + 1 < len(rest):
                j += 2
            elif rest[j] == "--paginate":
                j += 1
            else:
                return False, "ghr:graphql_opt"
        if q is None or "mutation" in q.lower() or not re.match(r"\s*(query\b|\{)", q):
            return False, "ghr:graphql_not_readonly_query"
        if not re.search(r'owner:\s*\\?"pocketforge-os\\?"', q):
            return False, "ghr:graphql_owner"
        return True, "lane_gh_graphql_read"
    return False, "ghr:not_allowlisted"


# 2026-09-28 INCIDENT (tsp-f3fm msg 01M3M5X0PXZF0NV2CZ05V7ETED): image
# tests/test-session-authority-systemd.sh runs a --privileged systemd container whose getty
# took tty2 from X and killed the owner's GNOME session on matt-laptop (07:19:30Z). Nothing a
# lane asks may run it until the redesigned harness lands. Also refuse any --privileged container
# booting /sbin/init. This is a hard deny ahead of every allow rule, so it wakes gpu-14.
_INCIDENT_DENY = ("test-session-authority-systemd",)


def _incident_denied(cmd):
    c = cmd or ""
    if any(tok in c for tok in _INCIDENT_DENY):
        return True
    return "--privileged" in c and "/sbin/init" in c


# 2026-10-01: lanes create Mission Control worktrees through the AGENTS.md path. Approve ONLY the exact shape
# `bd worktree create /home/matt/wt/mc-<slug> --branch <branch>` (coordinator role, path must not exist yet,
# never main/master). Anything else stays FOREIGN and wakes gpu-14.
BD_WT_PATH = re.compile(r"^/home/matt/wt/mc-[a-z0-9][a-z0-9.-]{0,80}$")
BD_WT_BRANCH = re.compile(r"^[a-z0-9][a-z0-9./-]{0,100}$")


def bd_worktree_create_allowed(cmd):
    try:
        o = shlex.split(cmd or "")
        if not (len(o) == 3 and o[0] == "/bin/bash" and o[1] in ("-lc", "-c")):
            return False, "bdwt:shape"
        a = shlex.split(o[2])
    except ValueError:
        return False, "bdwt:parse"
    if len(a) != 6 or a[:3] != ["bd", "worktree", "create"] or a[4] != "--branch":
        return False, "bdwt:shape"
    if not BD_WT_PATH.match(a[3]) or ".." in a[3] or os.path.exists(a[3]):
        return False, "bdwt:path"
    if not BD_WT_BRANCH.match(a[5]) or ".." in a[5] or a[5] in ("main", "master"):
        return False, "bdwt:branch"
    return True, "bdwt:create"


def command_allowed(cmd, cwd=None, run_id=None):
    if _incident_denied(cmd):
        return False, "denied:session-authority-harness-incident"
    ok, why = _command_allowed_legacy(cmd, cwd)
    if ok:
        return ok, why
    if run_id and run_role(run_id) == "coordinator" and cwd and \
            (str(cwd) == "/home/matt/wt" or str(cwd).startswith("/home/matt/wt/") or str(cwd) == "/home/matt/mission-control") \
            and ".." not in str(cwd):
        okg, whyg = lane_gh_read_allowed(cmd)
        if okg:
            return True, whyg
    if run_id and run_role(run_id) == "coordinator" and _wt_rm_beads(cmd):
        return verified_wt_rm_allowed(cmd)
    if run_id and run_role(run_id) == "coordinator":
        okb, whyb = bd_worktree_create_allowed(cmd)
        if okb:
            return True, whyb
    if run_id and run_role(run_id) == "coordinator":
        okr, whyr = lane_readonly_verify_allowed(cmd)
        if okr:
            return True, whyr
    # 15:40Z: lanes merge ONLY through the executable gate, which itself enforces checks,
    # exact-head review identity and SHA pinning. Exactly one PR ref, nothing else.
    if run_id and run_role(run_id) == "coordinator":
        try:
            o = shlex.split(cmd or "")
            inner_a = shlex.split(o[2]) if len(o) == 3 and o[0] == "/bin/bash" and o[1] in ("-lc", "-c") else None
        except ValueError:
            inner_a = None
        # 2026-09-28: the default-apps serialization window (runtime/launcher merges routed to gpu-14)
        # CLOSED at 22:28Z: platform#214 merged 6d05d921 and the step-7 build passed (artifact 007b3308).
        # Empty tuple: str.startswith(()) is False, so no repo is excluded.
        WINDOW_REPOS = ()
        if inner_a and len(inner_a) == 3 and inner_a[:2] == ["pf-automation-tool", "pf-pr-merge.sh"] and \
                re.fullmatch(r"pocketforge-os/[A-Za-z0-9_.-]+#[0-9]+", inner_a[2]) and not inner_a[2].startswith(WINDOW_REPOS):
            return True, "lane_gated_merge"
        # pf-pr-drive.sh is the same executable gate (checks, exact-head review identity, SHA pinning)
        # plus polling; --resolve-thread (a GitHub mutation) stays manual.
        if inner_a and inner_a[:2] == ["pf-automation-tool", "pf-pr-drive.sh"]:
            rest_d = inner_a[2:]
            if rest_d in (["--help"], ["-h"]):
                return True, "lane_pr_drive_help"
            if len(rest_d) >= 2 and rest_d[0] == "--timeout" and re.fullmatch(r"[0-9]{1,5}", rest_d[1]):
                rest_d = rest_d[2:]
            if len(rest_d) == 1 and re.fullmatch(r"pocketforge-os/[A-Za-z0-9_.-]+#[0-9]+", rest_d[0]) \
                    and not rest_d[0].startswith(WINDOW_REPOS):
                return True, "lane_gated_merge_drive"
    # 2026-09-28 23:3xZ: a coordinator lane repoints a MERGED worker branch's gone upstream to the
    # default branch before its verified release (3 manual approvals for .984.16/.984.18). Local
    # tracking config only: exactly one tsp-* branch argument, only origin/main or origin/device/a133,
    # cwd inside a /home/matt/wt worktree.
    if run_id and run_role(run_id) == "coordinator" and cwd and str(cwd).startswith("/home/matt/wt/") \
            and ".." not in str(cwd):
        try:
            o_u = shlex.split(cmd or "")
            in_u = shlex.split(o_u[2]) if len(o_u) == 3 and o_u[0] == "/bin/bash" and o_u[1] in ("-lc", "-c") else None
        except ValueError:
            in_u = None
        if in_u and len(in_u) == 4 and in_u[:2] == ["git", "branch"] and \
                in_u[2] in ("--set-upstream-to=origin/main", "--set-upstream-to=origin/device/a133") and \
                re.fullmatch(r"tsp-[A-Za-z0-9.]+", in_u[3]):
            return True, "lane_branch_upstream_default"
    # Sub-coordinator lanes: read-only Beads queries on any bead, `;`/`&&`-separated.
    if run_id and run_role(run_id) == "coordinator" and cwd and \
            (str(cwd).startswith("/home/matt/wt/") or str(cwd) == "/home/matt/mission-control") and ".." not in str(cwd):
        try:
            outer = shlex.split(cmd or "")
        except ValueError:
            outer = []
        if len(outer) == 3 and outer[0] == "/bin/bash" and outer[1] in ("-lc", "-c") and not has_live_expansion(outer[2]):
            lx = shlex.shlex(unquoted_newlines_to_semicolons(outer[2]), posix=True, punctuation_chars=True)
            lx.whitespace_split = True
            try:
                toks = list(lx)
            except ValueError:
                toks = None
            if toks:
                segs, cur, okk = [], [], True
                for t in toks:
                    if t and set(t) <= set("();<>|&"):
                        if t not in ("&&", ";", "|"):
                            okk = False; break
                        segs.append(cur); cur = ["|"] if t == "|" else []
                    else:
                        cur.append(t)
                segs.append(cur)
                # a pipe may only feed `jq <filter>` (no file-reading/writing options)
                for sg in segs:
                    if sg[:1] == ["|"]:
                        if not (len(sg) >= 3 and sg[1] == "jq" and
                                not any(t in ("-f", "--from-file", "--rawfile", "--slurpfile", "-L") for t in sg[2:])):
                            okk = False
                segs = [sg for sg in segs if sg[:1] != ["|"]]
                BD_READ = {"show", "lint", "list", "ready", "comments", "memories", "where", "prime", "blocked", "children"}

                def _lane_bd_ok(sg):
                    if not sg or sg[0] not in ("bd", "/home/matt/.local/bin/bd") or len(sg) < 2:
                        return False
                    if any(t.startswith("--db") for t in sg):
                        return False
                    if sg[1] in BD_READ:
                        return True
                    # claiming a bead in its own scope (field-replacing updates stay manual)
                    return len(sg) == 4 and sg[1] == "update" and re.fullmatch(r"tsp-[A-Za-z0-9.]+", sg[2]) \
                        and sg[3] == "--claim"
                if okk and all(_lane_bd_ok(sg) for sg in segs if sg):
                    return True, "lane_bd_read_or_claim"
    # Sub-coordinator lanes comment on beads in their scope; a QUOTED heredoc delimiter
    # means bash performs no expansion in the body.
    if run_id and run_role(run_id) == "coordinator":
        try:
            outer = shlex.split(cmd or "")
        except ValueError:
            outer = []
        if len(outer) == 3 and outer[0] == "/bin/bash" and outer[1] in ("-lc", "-c"):
            m_h = LANE_BD_HEREDOC.fullmatch(outer[2].strip())
            if m_h and ("\n" + m_h.group(2) + "\n") not in ("\n" + m_h.group(3) + "\n"):
                return True, "lane_bd_comment_heredoc:" + m_h.group(1)
    if run_id and cwd == "/home/matt/mission-control":
        # bead bookkeeping from the MC checkout: only the printf|bd-comment shape, and
        # only for the run's own bead (its worktree root); evaluated as if in that root.
        root = run_worktree_root(run_id)
        if root:
            ok3, why3 = wt_git_chain_allowed(cmd, root, bd_only=True)
            if ok3:
                return True, "mc_cwd:" + why3
    ok2, why2 = wt_git_chain_allowed(cmd, cwd)
    return (True, why2) if ok2 else (False, why + "|" + why2)


WT_GIT_ARGV_READ = {"status", "log", "diff", "merge-base", "rev-parse", "show", "fetch", "rev-list", "ls-files", "cat-file", "blame"}


WT_READ_TOOLS = {"cat", "head", "tail", "ls", "wc", "sha256sum", "stat", "file", "grep", "rg",
                 "echo", "printf", "pwd", "nl", "find", "sed"}
FIND_BAD = {"-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"}


def wt_read_segment_ok(a):
    """Read-only inspection inside the worktree: relative paths only (no `/`, `~`, `..`),
    so nothing outside the worker's own tree reaches the model; no writing options."""
    tool, args = a[0], a[1:]
    for t in args:
        if not t.startswith("-") and (t.startswith("/") or t.startswith("~") or ".." in t):
            return False, "wt:read_path_outside"
    if tool == "find":
        if any(t in FIND_BAD for t in args):
            return False, "wt:find_writing"
    elif tool == "sed":
        opts = [t for t in args if t.startswith("-")]
        scripts = [t for t in args if not t.startswith("-")][:1]
        # 14:40Z: multi-range prints like '418,487p;742,765p' are still pure line-range reads
        if opts != ["-n"] or not scripts or not re.fullmatch(r"[0-9]+(,[0-9]+)?p(;[0-9]+(,[0-9]+)?p)*", scripts[0]):
            return False, "wt:sed_shape"
    elif tool == "rg":
        if any(t.startswith(("--pre", "--search-zip", "-z")) for t in args):
            return False, "wt:rg_exec"
    return True, "read"


PATCH_PATH_RE = re.compile(r"\*\*\* (?:Add File|Update File|Delete File|Move to): ([^\"\n\\\\]+)")


def run_worktree_root(run_id):
    import sqlite3
    try:
        db = sqlite3.connect(f"file:{HOME}/journal.sqlite3?mode=ro", uri=True, timeout=30)
        wt = db.execute("SELECT json_extract(body,'$.request.worktree') FROM records WHERE kind='run' AND id=?",
                        (run_id,)).fetchone()
        db.close()
    except Exception:
        return None
    if not wt or not wt[0] or not str(wt[0]).startswith("/home/matt/wt/") or ".." in str(wt[0]):
        return None
    parts = str(wt[0])[len("/home/matt/wt/"):].split("/")
    return "/home/matt/wt/" + parts[0] + "/" if parts and parts[0] else None


def run_worktree_cwd(run_id):
    import sqlite3
    try:
        db = sqlite3.connect(f"file:{HOME}/journal.sqlite3?mode=ro", uri=True, timeout=30)
        wt = db.execute("SELECT json_extract(body,'$.request.worktree') FROM records WHERE kind='run' AND id=?",
                        (run_id,)).fetchone()
        db.close()
        return str(wt[0]) if wt and wt[0] else None
    except Exception:
        return None


def file_change_allowed(run_id, thread_id):
    """A fileChange approval carries no paths. Read the thread's rollout (read-only), take
    the LAST tool call, and require it to be an apply_patch whose every Add/Update/Delete/
    Move path is absolute and under this run's own /home/matt/wt/<bead>/ root. A dynamic
    or unparseable patch yields no paths and is refused."""
    import glob
    root = run_worktree_root(run_id)
    if not root:
        return False, "no_worktree_root", []
    if not thread_id or not re.fullmatch(r"[0-9a-f-]{36}", str(thread_id)):
        return False, "bad_thread_id", []
    files = glob.glob(f"/home/matt/.codex/sessions/*/*/*/rollout-*-{thread_id}.jsonl")
    if len(files) != 1:
        return False, f"rollout_count:{len(files)}", []
    last = None
    with open(files[0], "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - 4_000_000))
        for raw in fh.read().splitlines():
            try:
                rec = json.loads(raw)
            except Exception:
                continue
            pl = rec.get("payload") or {}
            if pl.get("type") in ("custom_tool_call", "function_call"):
                last = pl
    if not last:
        return False, "no_tool_call", []
    body = str(last.get("input") or last.get("arguments") or "")
    body = body.replace("\\n", "\n") if "*** Begin Patch\\n" in body else body
    if "*** Begin Patch" not in body:
        return False, "last_call_not_patch", []
    raw = [x.strip() for x in PATCH_PATH_RE.findall(body)]
    if not raw:
        return False, "no_paths", []
    # relative patch paths resolve against the run's own cwd (request.worktree)
    base = run_worktree_cwd(run_id)
    paths = []
    # 15:00Z keys worker: JS exec cells build patches as `*** Add File: ${root}rel/path`.
    # Accept ONLY the `${root}` template when the cell binds root exactly once to a string
    # literal inside this run's own worktree root; any other interpolation stays refused.
    js_root = None
    if any("${root}" in x for x in raw):
        binds = re.findall(r"\b(?:const|let|var)\s+root\s*=\s*([\"'])([^\"'$`]+)\1", body)
        assigns = re.findall(r"(?<![=!<>.\w])root\s*=(?!=)", body)
        if len(binds) == 1 and len(assigns) == 1 and binds[0][1].startswith(root) and ".." not in binds[0][1]:
            js_root = binds[0][1]
            raw = [x.replace("${root}", js_root) for x in raw]
    for x in raw:
        if "'" in x or "$" in x or "`" in x:
            return False, "path_quote", raw
        full = os.path.normpath(x if x.startswith("/") else os.path.join(base or "/nonexistent", x))
        paths.append(full)
        if not (full + "/").startswith(root) and not full.startswith(root):
            return False, "path_outside_root:" + root, paths
    # a patch built from non-literal pieces could hide paths: require every header to be literal
    if body.count("*** ") > 0 and len(re.findall(r"\*\*\* (?:Add File|Update File|Delete File|Move to):", body)) != len(raw):
        return False, "nonliteral_patch_header", paths
    return True, f"patch_in_root:{len(paths)}", paths


PIPE_SINKS = {"head", "tail", "wc", "grep", "rg", "sed", "sort", "uniq", "cut", "nl"}


def pipe_sink_ok(a):
    if a in (["sha256sum"], ["sha256sum", "-"]):
        return True, "sink_sha256_stdin"  # 13:45Z CONN: `git show <ref>:<path> | sha256sum`
    if a in (["git", "patch-id"], ["git", "patch-id", "--stable"]):
        return True, "sink_patch_id"  # 14:15Z VPU replacement: change-set equivalence proof
    if not a or a[0] not in PIPE_SINKS:
        return False, "wt:pipe_sink"
    if a[0] in ("sort", "uniq", "cut"):
        # flags only (uniq/sort can name an output file positionally or via -o)
        if any(not t.startswith("-") for t in a[1:]) and a[0] != "cut":
            return False, "wt:pipe_sink_positional"
        if any(t.startswith(("-o", "--output", "--compress-program")) for t in a[1:]):
            return False, "wt:pipe_sink_output"
        if a[0] == "cut" and any(not t.startswith("-") and not re.fullmatch(r"[0-9,.-]+", t) for t in a[1:]):
            return False, "wt:pipe_sink_positional"
        return True, "sink"
    return wt_read_segment_ok(a)


def no_pr_for_branch(cwd):
    """True only when the worktree's current non-default branch has NO pull request in
    any state on its origin repo (read via gh; any error refuses)."""
    try:
        br = subprocess.run(["git", "-C", str(cwd), "rev-parse", "--abbrev-ref", "HEAD"],
                            capture_output=True, text=True, timeout=30).stdout.strip()
        url = subprocess.run(["git", "-C", str(cwd), "remote", "get-url", "origin"],
                             capture_output=True, text=True, timeout=30).stdout.strip()
    except Exception:
        return False, "git_error"
    if not br or br in ("HEAD", "main", "master") or br.startswith("device/"):
        return False, "branch:" + (br or "unknown")
    m = re.search(r"github\.com[:/]([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?$", url)
    if not m or not m.group(1).startswith("pocketforge-os/"):
        return False, "remote"
    r = subprocess.run(["gh", "pr", "list", "--repo", m.group(1), "--head", br, "--state", "all", "--json", "number"],
                       capture_output=True, text=True, timeout=60)
    try:
        prs = json.loads(r.stdout)
    except Exception:
        return False, "gh_unreadable"
    if r.returncode != 0 or prs:
        return False, f"pr_exists:{[x.get('number') for x in prs] if isinstance(prs, list) else prs}"
    return True, "no_pr"


def unquoted_newlines_to_semicolons(inner):
    out, in_sq, in_dq, i = [], False, False, 0
    while i < len(inner):
        ch = inner[i]
        if in_sq:
            in_sq = ch != "'"
        elif ch == "\\":
            out.append(inner[i:i + 2]); i += 2; continue
        elif ch == "'" and not in_dq:
            in_sq = True
        elif ch == '"':
            in_dq = not in_dq
        elif ch == "\n" and not in_dq:
            out.append(" ; "); i += 1; continue
        out.append(ch); i += 1
    return "".join(out).strip().rstrip(";").strip()


def has_live_expansion(inner):
    """True if `$` or a backtick appears anywhere bash would expand it: i.e. outside a
    single-quoted span. Inside '...' bash treats everything literally."""
    in_sq = in_dq = False
    i = 0
    while i < len(inner):
        ch = inner[i]
        if in_sq:
            if ch == "'":
                in_sq = False
        elif ch == "\\":
            i += 2
            continue
        elif ch == "'" and not in_dq:
            in_sq = True
        elif ch == '"':
            in_dq = not in_dq
        elif ch in "$`":
            return True
        i += 1
    return in_sq or in_dq  # unbalanced quoting: refuse


THREAD_MUTATIONS = {
    "addPullRequestReviewThreadReply": re.compile(r"mutation\(\$(\w+):ID!,\s*\$(\w+):String!\)\s*\{\s*addPullRequestReviewThreadReply\(input:\s*\{\s*pullRequestReviewThreadId:\s*\$\1,\s*body:\s*\$\2\s*\}\)\s*\{[A-Za-z{} ]*\}\s*\}"),
    "resolveReviewThread": re.compile(r"mutation\(\$(\w+):ID!\)\s*\{\s*resolveReviewThread\(input:\s*\{\s*threadId:\s*\$\1\s*\}\)\s*\{[A-Za-z{} ]*\}\s*\}"),
}


def own_branch(ref, own_bead):
    """The worker's own bead branch, or its clean -vN replacement branch (14:36Z VPU option b)."""
    return bool(ref) and re.fullmatch(re.escape(own_bead) + r"(?:-v[0-9]+)?", ref) is not None


def thread_mutation_ok(args, own_bead):
    """Reply to / resolve a review thread, only on the worker's OWN open PR (thread's PR head
    branch == own bead), with a fixed mutation document shape and literal variables."""
    q, fields, j = None, {}, 0
    while j < len(args):
        if args[j] in ("-f", "-F", "--raw-field", "--field") and j + 1 < len(args):
            kv = args[j + 1]
            k, _, v = kv.partition("=")
            if k == "query":
                q = v
            elif re.fullmatch(r"\w+", k) and k not in fields:
                fields[k] = v
            else:
                return False, "wt:thread_var"
            j += 2
        elif args[j] in ("--jq", "-q") and j + 1 < len(args):
            j += 2
        else:
            return False, "wt:thread_arg"
    if not q:
        return False, "wt:thread_shape"
    kind, mm = None, None
    for k, rx in THREAD_MUTATIONS.items():
        mm = rx.fullmatch(q.strip())
        if mm:
            kind = k
            break
    if not kind:
        return False, "wt:thread_mutation_not_allowed"
    names = [g for g in mm.groups() if g]
    if set(fields) != set(names):
        return False, "wt:thread_vars_mismatch"
    vid = fields.get(names[0], "")
    if not re.fullmatch(r"PRRT_[A-Za-z0-9_-]+", vid):
        return False, "wt:thread_id"
    if len(names) > 1 and fields[names[1]].startswith("@") and \
            not re.fullmatch(r"@/tmp/[A-Za-z0-9_.-]+\.(?:md|txt)", fields[names[1]]):
        return False, "wt:thread_body_file"  # 14:30Z: a /tmp md/txt reply body is allowed (apostrophes)
    look = ('query{node(id:"%s"){... on PullRequestReviewThread{pullRequest{headRefName state '
            'repository{nameWithOwner}}}}}' % vid)
    r = subprocess.run(["gh", "api", "graphql", "-f", "query=" + look], capture_output=True, text=True, timeout=60)
    try:
        pr = json.loads(r.stdout)["data"]["node"]["pullRequest"]
    except Exception:
        return False, "wt:thread_lookup_failed"
    if not own_branch(pr.get("headRefName"), own_bead) or pr.get("state") != "OPEN" or \
            not pr.get("repository", {}).get("nameWithOwner", "").startswith("pocketforge-os/"):
        return False, "wt:thread_not_own_open_pr"
    return True, "gh_thread_" + kind


def wt_git_chain_allowed(cmd, cwd, bd_only=False):
    """Quote-aware route for git-only `&&` chains run in the worker's own worktree
    (either `/bin/bash -lc '...'` or `/bin/bash -lc "..."`). Refuses any `$` or backtick
    anywhere (no expansion inside double quotes), any operator but `&&`, and any argv
    outside: git add <relative paths>; read-only git; git commit (-m MSG)+; push of a
    non-default HEAD; git rebase origin/<default> (non-interactive)."""
    import shlex
    in_wt = bool(cwd) and str(cwd).startswith("/home/matt/wt/") and ".." not in str(cwd)
    if not in_wt:
        return False, "wt:not_in_wt"
    try:
        outer = shlex.split(cmd or "")
    except ValueError:
        return False, "wt:unparseable"
    if len(outer) != 3 or outer[0] != "/bin/bash" or outer[1] not in ("-lc", "-c"):
        return False, "wt:not_bash_c"
    inner = outer[2]
    own = str(cwd)[len("/home/matt/wt/"):].split("/")[0]
    # 14:05Z keys worker: `apply_patch <<'PATCH' ... PATCH` then an optional ordinary chain.
    # The quoted-heredoc body is file content, never shell; the FIRST line equal to the
    # delimiter ends it. Every patch header path must lie under the worker's own root.
    if inner.startswith("apply_patch <<'PATCH'\n"):
        body_lines, rest_lines, ended = [], [], False
        for ln in inner.split("\n")[1:]:
            if not ended and ln == "PATCH":
                ended = True
                continue
            (rest_lines if ended else body_lines).append(ln)
        if not ended or not body_lines or body_lines[0] != "*** Begin Patch" or body_lines[-1] != "*** End Patch":
            return False, "wt:apply_patch_shape"
        root = "/home/matt/wt/" + own + "/"
        for ln in body_lines:
            m_h = re.match(r"\*\*\* (Add File|Update File|Delete File|Move to): (.*)$", ln)
            if not m_h:
                continue
            pth = m_h.group(2).strip()
            if ".." in pth.split("/") or not (pth.startswith(root) or not pth.startswith("/")):
                return False, "wt:apply_patch_path_outside_own_root"
        rest = "\n".join(rest_lines).strip()
        if not rest:
            return True, "wt_apply_patch_own_root"
        ok_r, why_r = wt_git_chain_allowed("/bin/bash -lc " + shlex.quote(rest), cwd, bd_only)
        return ok_r, "wt_apply_patch_own_root+" + why_r
    if has_live_expansion(inner):
        return False, "wt:expansion_char"
    m_in = re.fullmatch(r"(?:/home/matt/\.local/bin/)?bd(?: -C /home/matt/mission-control)? comment (\S+) --stdin < (/tmp/[A-Za-z0-9_.-]+\.(?:md|txt))", inner.strip())
    if m_in:
        if m_in.group(1) == own:
            return True, "wt_bd_comment_own_from_tmp_md"
        return False, "wt:bd_comment_not_own"
    inner = unquoted_newlines_to_semicolons(inner)
    lx = shlex.shlex(inner, posix=True, punctuation_chars=True)
    lx.whitespace_split = True
    try:
        toks = list(lx)
    except ValueError:
        return False, "wt:unparseable_inner"
    segs, cur = [], []
    for t in toks:
        if t and set(t) <= set("();<>|&"):
            if t not in ("&&", "|", ";"):  # `;` like `&&`: every segment is independently checked
                return False, "wt:operator:" + t
            segs.append(cur); cur = []
            if t == "|":
                cur.append("|")  # marks: this segment receives a pipe
        else:
            cur.append(t)
    segs.append(cur)
    # The worker's own bead is the /home/matt/wt/<bead>/ path segment.
    own_bead = str(cwd)[len("/home/matt/wt/"):].split("/")[0]
    reasons = []
    for i, a in enumerate(segs):
        piped_in = bool(a) and a[0] == "|"
        if piped_in:
            a = a[1:]
        pipes_out = i + 1 < len(segs) and segs[i + 1][:1] == ["|"]
        if pipes_out and not piped_in and len(a) >= 3 and a[0] == "printf" and a[1] in ("%s\n", "%s\\n"):
            nxt = segs[i + 1][1:]
            if nxt[:3] == ["bd", "-C", "/home/matt/mission-control"]:
                nxt = ["bd"] + nxt[3:]
            if nxt == ["bd", "comment", own_bead, "--stdin"]:
                reasons.append("printf|")
                continue
        if piped_in:
            if a[:3] == ["bd", "-C", "/home/matt/mission-control"]:
                a = ["bd"] + a[3:]
            if a == ["bd", "comment", own_bead, "--stdin"] and not pipes_out and segs[i - 1][:1] != ["|"] \
                    and (segs[i - 1] or [""])[0] == "printf":
                reasons.append("bd_comment_own")
                continue
            ok, why = pipe_sink_ok(a)
            if bd_only:
                return False, "wt:bd_only"
            if not ok:
                return False, why
            reasons.append("|" + a[0])
            continue
        if pipes_out:
            # read-only source feeding read-only filters
            if bd_only:
                return False, "wt:bd_only"
            if a and a[0] in WT_READ_TOOLS:
                ok, why = wt_read_segment_ok(a)
                if not ok:
                    return False, why
            elif not (len(a) >= 2 and a[0] == "git" and a[1] in WT_GIT_ARGV_READ and a[1] != "fetch"
                      and not any(t.startswith(("--output", "--ext-diff", "--upload-pack", "--exec")) for t in a[2:])):
                return False, "wt:pipe_source"
            reasons.append(a[0] + "|")
            continue
        if a[:1] == ["/home/matt/.local/bin/bd"]:
            a = ["bd"] + a[1:]
        b = ["bd"] + a[3:] if a[:3] == ["bd", "-C", "/home/matt/mission-control"] else a
        if b in (["bd", "where"], ["bd", "prime"], ["bd", "show", own_bead], ["bd", "show", own_bead, "--json"]):
            reasons.append("bd_read_own")
            continue
        if b == ["bd", "comment", own_bead, "--stdin"]:
            reasons.append("bd_comment_own")
            continue
        if bd_only:
            return False, "wt:bd_only"
        if a[:3] == ["bd", "-C", "/home/matt/mission-control"]:
            a = ["bd"] + a[3:]
        if a in (["bd", "show", own_bead], ["bd", "show", own_bead, "--json"]):
            reasons.append("bd_show_own")
            continue
        if len(a) >= 3 and a[0] == "chmod" and a[1] in ("+x", "755", "0755", "a+x", "u+x"):
            if any(t.startswith("-") or t.startswith("/") or ".." in t for t in a[2:]):
                return False, "wt:chmod_path"
            reasons.append("chmod+x")
            continue
        if a[:1] == ["env"]:
            a = a[1:]
        SAFE_ENV = (r"PYTHONPYCACHEPREFIX=/tmp/[A-Za-z0-9_.-]+", r"PYTHONDONTWRITEBYTECODE=1", r"LC_ALL=C", r"TZ=UTC")
        while a and any(re.fullmatch(rx, a[0]) for rx in SAFE_ENV):
            a = a[1:]
        if a[:1] in (["GIT_EDITOR=true"],) and a[1:3] == ["git", "rebase"]:
            a = a[1:]
        # 14:55Z CAP g2 reviewer reproduction: bounded arm64 kernel builds in a kernel-sunxi worktree
        # 15:00Z: DT binding schema checks for named binding files
        if a and a[0] == "make" and re.search(r"/home/matt/wt/[^/]+/kernel-sunxi-[0-9.x]+/?$", str(cwd)) and \
                all(re.fullmatch(r"DT_SCHEMA_FILES=Documentation/devicetree/bindings/[A-Za-z0-9_,./-]+\.yaml", t) or
                    t in ("dt_binding_check", "dtbs_check", "ARCH=arm64", "CHECK_DTBS=y", "CROSS_COMPILE=aarch64-linux-gnu-") or
                    re.fullmatch(r"-j[0-9]{1,2}", t) or re.fullmatch(r"(?:[a-z0-9_]+/)*[a-z0-9_.-]+\.dtb", t)
                    for t in a[1:]) and any(t in ("dt_binding_check", "dtbs_check") or t.endswith(".dtb") for t in a[1:]) \
                and not any(".." in t for t in a):
            reasons.append("kernel_dt_check")
            continue
        if a[:2] == ["make", "ARCH=arm64"] and re.search(r"/home/matt/wt/[^/]+/kernel-sunxi-[0-9.x]+/?$", str(cwd)) and \
                all(t == "CROSS_COMPILE=aarch64-linux-gnu-" or re.fullmatch(r"-j[0-9]{1,2}", t) or
                    re.fullmatch(r"[a-z0-9_]+_defconfig|modules_prepare|olddefconfig|dtbs|Image|modules", t) or
                    re.fullmatch(r"M=[a-z0-9_]+(?:/[a-z0-9_-]+)*", t) or
                    re.fullmatch(r"(?:[a-z0-9_]+/)*[a-z0-9_.-]+(?:\.dtb|/)", t) or
                    re.fullmatch(r"(?:[a-z0-9_-]+/)+[a-z0-9_-]+\.(?:o|ko)", t)
                    for t in a[2:]) and not any(".." in t for t in a):
            reasons.append("kernel_make")
            continue
        if a in (["set", "-e"], ["set", "-eu"], ["set", "-euo", "pipefail"], ["set", "-o", "pipefail"]):
            reasons.append("shell_errexit")  # 14:25Z VPU: `set -e` newline-prefixed test chains
            continue
        if a[:3] == ["python3", "-m", "py_compile"] and len(a) > 3 and \
                not any(t.startswith("-") or t.startswith("/") or ".." in t for t in a[3:]):
            reasons.append("py_compile")
            continue
        if len(a) == 2 and a[0] == "bash" and ".." not in a[1] and \
                re.fullmatch(r"(scripts/tests|tests)/(?:[A-Za-z0-9_./-]*-test|(?:[A-Za-z0-9_.-]+/)*test-[A-Za-z0-9_.-]+)\.sh", a[1]):
            reasons.append("hermetic_test_sh")
            continue
        # 13:45Z display worker: repo tool self-tests, e.g.
        # python3 tests/vision-reviewer/tools/check-pattern-cv.py --self-test --camera-sim --corpus tests/vision-reviewer/patterns
        if len(a) >= 3 and a[0] == "python3" and a[2] == "--self-test" and \
                re.fullmatch(r"tests/[A-Za-z0-9_.-]+/tools/[A-Za-z0-9_.-]+\.py", a[1]) and \
                all(re.fullmatch(r"--[a-z][a-z0-9-]*", t) or
                    (re.fullmatch(r"tests/[A-Za-z0-9_./-]+", t) and ".." not in t) for t in a[3:]):
            reasons.append("repo_tool_self_test")
            continue
        if a[:1] == ["./scripts/pf-test"]:
            a = ["scripts/pf-test"] + a[1:]
        if a == ["scripts/pf-test", "verify", "--all"]:
            reasons.append("pf_test_verify_all")
            continue
        if len(a) == 3 and a[:2] == ["bash", "-n"] and not a[2].startswith(("/", "-")) and ".." not in a[2]:
            reasons.append("bash_syntax_check")
            continue
        # 15:55Z VPU worker: hermetic test scripts executed directly (no `bash` prefix)
        if len(a) == 1 and ".." not in a[0] and \
                re.fullmatch(r"(?:\./)?(scripts/tests|tests)/(?:[A-Za-z0-9_./-]*-test|(?:[A-Za-z0-9_.-]+/)*test-[A-Za-z0-9_.-]+)\.sh", a[0]):
            reasons.append("hermetic_test_sh_exec")
            continue
        if len(a) == 2 and a[0] == "bash" and re.fullmatch(r"(?:\./)?tests/pf-test/[A-Za-z0-9_.-]+/collector-test", a[1]):
            a = a[1:]  # 14:35Z keys worker: `bash tests/pf-test/<name>/collector-test`
        if len(a) == 1 and re.fullmatch(r"(?:\./)?tests/pf-test/[A-Za-z0-9_.-]+/collector-test", a[0]):
            reasons.append("collector_test")
            continue
        if len(a) == 4 and a[:2] == ["scripts/pf-test", "assert"] and re.fullmatch(r"[A-Za-z0-9_.-]+", a[2]) \
                and re.fullmatch(r"tests/pf-test/[A-Za-z0-9_./-]+", a[3]) and ".." not in a[3]:
            reasons.append("pf_test_assert_fixture")
            continue
        if len(a) == 3 and a[:2] == ["scripts/pf-test", "verify"] and re.fullmatch(r"[A-Za-z0-9_.-]+", a[2]):
            reasons.append("pf_test_verify")
            continue
        if a[:3] in (["gh", "pr", "view"], ["gh", "pr", "checks"], ["gh", "pr", "list"], ["gh", "pr", "diff"]) \
                and not any(t in ("--web", "-w") for t in a[3:]):
            reasons.append("gh_pr_read")
            continue
        if a[:3] == ["gh", "pr", "create"]:
            # opening the work order's PR: pocketforge-os repo, default base, the worker's own branch
            opts, j, ok = {}, 3, True
            while j < len(a):
                k = a[j]
                if k in ("--repo", "--base", "--head", "--title", "--body-file", "--body") and j + 1 < len(a):
                    opts[k] = a[j + 1]; j += 2
                elif k in ("--fill-first",):
                    j += 1
                else:
                    ok = False; break
            if not ok:
                return False, "wt:gh_pr_create_option"
            if "--repo" not in opts:  # gh infers the repo from the worktree's origin
                url = subprocess.run(["git", "-C", str(cwd), "remote", "get-url", "origin"],
                                     capture_output=True, text=True, timeout=30).stdout.strip()
                mm = re.search(r"github\.com[:/](pocketforge-os/[A-Za-z0-9_.-]+?)(?:\.git)?$", url)
                if mm:
                    opts["--repo"] = mm.group(1)
            if not opts.get("--repo", "").startswith("pocketforge-os/") or \
                    opts.get("--base") not in ("main", "device/a133") or \
                    not re.fullmatch(re.escape(own_bead) + r"(?:-v[0-9]+)?", opts.get("--head") or ""):
                return False, "wt:gh_pr_create_target"  # 14:35Z: own bead branch or its -vN replacement
            bf = opts.get("--body-file")
            if bf is not None and not re.fullmatch(r"/tmp/[A-Za-z0-9_.-]+\.md", bf):
                return False, "wt:gh_pr_create_body_file"
            reasons.append("gh_pr_create")
            continue
        if a[:3] == ["gh", "pr", "edit"] and len(a) >= 6 and re.fullmatch(r"[0-9]+", a[3]):
            rest = a[4:]
            opts = {}
            while rest:
                if rest[0] in ("--body", "--body-file", "--title", "--repo") and len(rest) >= 2:
                    opts[rest[0]] = rest[1]; rest = rest[2:]
                else:
                    return False, "wt:gh_pr_edit_option"
            if "--body-file" in opts and not re.fullmatch(r"/tmp/[A-Za-z0-9_.-]+\.(?:md|txt)", opts["--body-file"]):
                return False, "wt:gh_pr_edit_body_file"
            repo = opts.get("--repo")
            if not repo:
                url = subprocess.run(["git", "-C", str(cwd), "remote", "get-url", "origin"],
                                     capture_output=True, text=True, timeout=30).stdout.strip()
                mm = re.search(r"github\.com[:/](pocketforge-os/[A-Za-z0-9_.-]+?)(?:\.git)?$", url)
                repo = mm.group(1) if mm else ""
            if not repo.startswith("pocketforge-os/"):
                return False, "wt:gh_pr_edit_repo"
            hv = subprocess.run(["gh", "pr", "view", a[3], "--repo", repo, "--json", "headRefName,state"],
                                capture_output=True, text=True, timeout=60)
            try:
                hj = json.loads(hv.stdout)
            except Exception:
                return False, "wt:gh_pr_edit_unreadable"
            if not own_branch(hj.get("headRefName"), own_bead) or hj.get("state") != "OPEN":
                return False, "wt:gh_pr_edit_not_own_open_pr"
            reasons.append("gh_pr_edit_own")
            continue
        if a[:4] in (["gh", "api", "--method", "POST"], ["gh", "api", "-X", "POST"]) and len(a) >= 7:
            # REST reply to a review comment on the worker's OWN open PR; literal body only
            mm = re.fullmatch(r"repos/(pocketforge-os/[A-Za-z0-9_.-]+)/pulls/([0-9]+)/comments/([0-9]+)/replies", a[4])
            rest = a[5:]
            kept, k = [], 0
            while k < len(rest):
                if rest[k] in ("--jq", "-q") and k + 1 < len(rest):
                    k += 2; continue
                kept.append(rest[k]); k += 1
            if not mm or kept[:1] not in (["-f"], ["--raw-field"]) or len(kept) != 2 or not kept[1].startswith("body=") \
                    or kept[1].startswith("body=@"):
                return False, "wt:gh_post_shape"
            hv = subprocess.run(["gh", "pr", "view", mm.group(2), "--repo", mm.group(1), "--json", "headRefName,state"],
                                capture_output=True, text=True, timeout=60)
            try:
                hj = json.loads(hv.stdout)
            except Exception:
                return False, "wt:gh_post_unreadable"
            if not own_branch(hj.get("headRefName"), own_bead) or hj.get("state") != "OPEN":
                return False, "wt:gh_post_not_own_open_pr"
            reasons.append("gh_reply_own_pr")
            continue
        # 13:55Z display worker: `gh api <endpoint> -X PATCH ...` (endpoint before the method)
        if len(a) >= 5 and a[:2] == ["gh", "api"] and a[3:5] in (["-X", "PATCH"], ["--method", "PATCH"]):
            a = a[:2] + a[3:5] + [a[2]] + a[5:]
        if a[:4] == ["gh", "api", "--method", "PATCH"] or a[:4] == ["gh", "api", "-X", "PATCH"]:
            # own open PR's title/body only (gh pr edit is broken on this host)
            rest = a[4:]
            if len(rest) < 3 or not re.fullmatch(r"repos/(pocketforge-os/[A-Za-z0-9_.-]+)/pulls/([0-9]+)", rest[0]):
                return False, "wt:gh_patch_endpoint"
            mm = re.fullmatch(r"repos/(pocketforge-os/[A-Za-z0-9_.-]+)/pulls/([0-9]+)", rest[0])
            fields = rest[1:]
            # --jq filters only shape gh's own output; drop them wherever they appear
            kept, k = [], 0
            while k < len(fields):
                if fields[k] in ("--jq", "-q") and k + 1 < len(fields):
                    k += 2
                    continue
                kept.append(fields[k]); k += 1
            fields = kept
            def _field_ok(flag, val):
                if flag in ("-f", "--raw-field"):
                    return val.startswith(("body=", "title="))
                if flag in ("-F", "--field"):  # typed field: only body read from a /tmp markdown file
                    return re.fullmatch(r"body=@/tmp/[A-Za-z0-9_.-]+\.(?:md|txt)", val) is not None
                return False
            if len(fields) % 2 or not all(_field_ok(fields[i], fields[i + 1]) for i in range(0, len(fields), 2)):
                return False, "wt:gh_patch_fields"
            hv = subprocess.run(["gh", "pr", "view", mm.group(2), "--repo", mm.group(1), "--json", "headRefName,state"],
                                capture_output=True, text=True, timeout=60)
            try:
                hj = json.loads(hv.stdout)
            except Exception:
                return False, "wt:gh_patch_unreadable"
            if not own_branch(hj.get("headRefName"), own_bead) or hj.get("state") != "OPEN":
                return False, "wt:gh_patch_not_own_open_pr"
            reasons.append("gh_patch_own_pr")
            continue
        if a[:3] == ["gh", "api", "graphql"] and any(t.startswith("query=mutation") for t in a[3:]):
            ok_m, why_m = thread_mutation_ok(a[3:], own_bead)
            if not ok_m:
                return False, why_m
            reasons.append(why_m)
            continue
        if a[:3] == ["gh", "api", "graphql"]:
            # read-only GraphQL: exactly one `query` document (never a mutation) plus scalar variables
            rest, q, ok = a[3:], None, True
            j = 0
            while j < len(rest):
                if rest[j] in ("-f", "-F", "--raw-field", "--field") and j + 1 < len(rest):
                    kv = rest[j + 1]
                    if kv.startswith("query="):
                        q = kv[len("query="):]
                    elif not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=[A-Za-z0-9_./-]+", kv):
                        ok = False
                    j += 2
                elif rest[j] in ("--jq", "-q") and j + 1 < len(rest):
                    j += 2
                elif rest[j] == "--paginate":
                    j += 1
                else:
                    ok = False; break
            if not ok or q is None:
                return False, "wt:gh_graphql_shape"
            qs = q.lstrip()
            if "mutation" in q.lower() or "subscription" in q.lower() or not (qs.startswith("query") or qs.startswith("{")):
                return False, "wt:gh_graphql_not_query"
            reasons.append("gh_graphql_query")
            continue
        if a[:2] == ["gh", "api"]:
            # read-only REST GET on pocketforge-os repos: no method override, no body fields
            rest = a[2:]
            bad = {"-X", "--method", "-f", "-F", "--field", "--raw-field", "--input", "--hostname"}
            if any(t in bad or t.startswith(("--method=", "-X", "--field=", "--raw-field=", "--input=")) for t in rest):
                return False, "wt:gh_api_write"
            ep = [t for i, t in enumerate(rest) if not t.startswith("-") and (i == 0 or rest[i - 1] not in ("-H", "--header", "--jq", "-q", "--template", "-t"))]
            if len(ep) != 1 or not ep[0].startswith("repos/pocketforge-os/") or ep[0].startswith("repos/pocketforge-os/../"):
                return False, "wt:gh_api_endpoint"
            reasons.append("gh_api_get")
            continue
        if a and a[0] in WT_READ_TOOLS:
            ok, why = wt_read_segment_ok(a)
            if not ok:
                return False, why
            reasons.append(a[0])
            continue
        if len(a) >= 3 and a[:2] == ["git", "-C"]:
            # `git -C <path>` only into the worker's own /home/matt/wt/<bead>/ tree
            if not (a[2].rstrip("/") + "/").startswith("/home/matt/wt/" + own_bead + "/") or ".." in a[2]:
                return False, "wt:git_C_outside_own_root"
            a = ["git"] + a[3:]
        if len(a) < 2 or a[0] != "git":
            return False, "wt:non_git_segment"
        sub, rest = a[1], a[2:]
        if sub == "add":
            if not rest or any(t.startswith("-") or t.startswith("/") or ".." in t for t in rest):
                return False, "wt:git_add_option_or_path"
        elif sub == "merge-tree":
            # 2026-09-28 CAP g3 review prep: a merge-conflict probe. `--write-tree` writes tree/blob
            # objects only (no ref, index or worktree change). Exactly two ref operands, only
            # output-shaping flags; the legacy three-argument (base) form stays manual.
            flags = [t for t in rest if t.startswith("-")]
            refs = [t for t in rest if not t.startswith("-")]
            if "--write-tree" not in flags or not set(flags) <= {"--write-tree", "--name-only", "--messages", "--no-messages", "-z"} \
                    or len(refs) != 2 or any(not re.fullmatch(r"[A-Za-z0-9_./^~@{}-]+", r) or ".." in r for r in refs):
                return False, "wt:git_merge_tree_shape"
        elif sub in WT_GIT_ARGV_READ:
            if any(t.startswith(("--output", "--ext-diff", "--upload-pack", "--exec")) for t in rest):
                return False, "wt:git_writing_option"
        elif sub == "commit":
            if rest[:1] == ["--amend"]:  # local rewrite of the worker's own tip; force-push is gated separately
                rest = rest[1:]
                if rest == ["--no-edit"]:
                    msg = subprocess.run(["git", "-C", str(cwd), "log", "-1", "--format=%B"],
                                         capture_output=True, text=True, timeout=30).stdout
                    if not msg or "signed-off-by" in msg.lower():
                        return False, "wt:git_amend_keeps_signoff_or_unreadable"
                    reasons.append("commit_amend_no_edit")
                    continue
            if len(rest) < 2 or len(rest) % 2 or any(rest[i] != "-m" for i in range(0, len(rest), 2)):
                return False, "wt:git_commit_shape"
            if any("signed-off-by" in rest[i].lower() for i in range(1, len(rest), 2)):
                return False, "wt:git_commit_signoff"  # agents never add Signed-off-by (AGENTS.md)
        elif sub == "push":
            if rest == ["origin", "HEAD:" + own_bead]:
                rest = ["origin", "HEAD"]  # explicit refspec to the worker's own bead-named branch
            if rest in (["origin", own_bead], ["-u", "origin", own_bead]):
                # 16:00Z CONF g2: pushing the bead branch by name == HEAD push when it is checked out
                cur = subprocess.run(["git", "-C", str(cwd), "rev-parse", "--abbrev-ref", "HEAD"],
                                     capture_output=True, text=True, timeout=30).stdout.strip()
                if cur == own_bead:
                    rest = ["-u", "origin", "HEAD"] if rest[0] == "-u" else ["origin", "HEAD"]
            forced = rest in (["--force-with-lease", "origin", "HEAD"], ["--force-with-lease", "-u", "origin", "HEAD"],
                              ["-u", "--force-with-lease", "origin", "HEAD"])
            if not forced and rest not in ([], ["-u", "origin", "HEAD"], ["origin", "HEAD"], ["--set-upstream", "origin", "HEAD"]):
                return False, "wt:git_push_shape"
            if forced:
                # work order: force-push only your own unreviewed branch, only before any PR exists
                ok_np, why_np = no_pr_for_branch(cwd)
                if not ok_np:
                    return False, "wt:force_push:" + why_np
            br = subprocess.run(["git", "-C", str(cwd), "rev-parse", "--abbrev-ref", "HEAD"],
                                capture_output=True, text=True, timeout=30).stdout.strip()
            if not br or br in ("HEAD", "main", "master") or br.startswith("device/"):
                return False, f"wt:git_push_branch:{br or 'unknown'}"
        elif sub == "switch":
            # create/select a local branch (optionally tracking an origin branch); never discards work
            if any(t in ("--discard-changes", "-f", "--force", "-C") for t in rest):
                return False, "wt:git_switch_force"
            if not (len(rest) == 1 and re.fullmatch(r"[A-Za-z0-9_./-]+", rest[0])) and \
                    not (len(rest) == 4 and rest[0] == "-c" and rest[2] == "--track" and rest[3].startswith("origin/")) and \
                    not (len(rest) == 3 and rest[0] == "-c" and rest[2].startswith("origin/")):
                return False, "wt:git_switch_shape"
        elif sub == "checkout":
            # conflict resolution only: pick a side for named relative paths
            if len(rest) < 3 or rest[0] not in ("--ours", "--theirs") or rest[1] != "--" or \
                    any(t.startswith("-") or t.startswith("/") or ".." in t for t in rest[2:]):
                return False, "wt:git_checkout_shape"
        elif sub == "remote":
            if rest not in (["get-url", "origin"], ["-v"], []):
                return False, "wt:git_remote_shape"
        elif sub == "ls-remote":
            if len(rest) > 3 or any(t.startswith("--upload-pack") or t.startswith("--exec") for t in rest):
                return False, "wt:git_ls_remote_shape"
        elif sub == "update-index":
            if not rest or rest[0] != "--chmod=+x" or len(rest) < 2 or \
                    any(t.startswith("-") or t.startswith("/") or ".." in t for t in rest[1:]):
                return False, "wt:git_update_index_shape"
        elif sub == "rebase":
            if rest not in (["origin/main"], ["origin/device/a133"], ["--continue"], ["--abort"], ["--skip"]):
                return False, "wt:git_rebase_shape"
        elif sub == "branch":
            # 14:15Z W6: tracking config for the worker's OWN bead branch, or plain listing
            if rest not in ([], ["-a"], ["-r"], ["-vv"], ["--show-current"],
                            ["--set-upstream-to=origin/" + own_bead], ["-u", "origin/" + own_bead]):
                return False, "wt:git_branch_shape"
        elif sub == "merge":
            # 14:15Z VPU replacement order: squash an approved head (full or abbreviated sha) into
            # the index of the current (non-default) branch; --abort to back out
            # 2026-10-01: fast-forward a fresh worktree to its default branch (AGENTS.md step after bd worktree create)
            if not (rest == ["--abort"] or rest in (["--ff-only", "origin/main"], ["--ff-only", "origin/device/a133"]) or
                    (len(rest) == 2 and rest[0] == "--squash" and
                                            re.fullmatch(r"[0-9a-f]{7,40}", rest[1]))):
                return False, "wt:git_merge_shape"
        elif sub == "patch-id":
            if rest not in ([], ["--stable"]):
                return False, "wt:git_patch_id_shape"
        elif sub == "clone":
            # 2026-10-02 CAP g6: read-only inspection copy of an org PR branch. Exactly
            # `clone --depth 1 --branch <ref> git@github.com:pocketforge-os/<repo>.git /tmp/<dir>/repo`;
            # no other options (no --config/-c/--template/--upload-pack), target under a fresh /tmp dir.
            if not (len(rest) == 6 and rest[0] == "--depth" and rest[1] == "1" and rest[2] == "--branch"
                    and re.fullmatch(r"[A-Za-z0-9._/-]{1,120}", rest[3]) and not rest[3].startswith("-")
                    and ".." not in rest[3]
                    and re.fullmatch(r"git@github\.com:pocketforge-os/[A-Za-z0-9._-]{1,80}\.git", rest[4])
                    and re.fullmatch(r"/tmp/[A-Za-z0-9._-]{1,80}/repo", rest[5]) and ".." not in rest[5]):
                return False, "wt:git_clone_shape"
        else:
            return False, "wt:git_sub:" + sub
        reasons.append(sub)
    return True, "wt_git_chain[" + ",".join(reasons) + "]"


def _command_allowed_legacy(cmd, cwd=None):
    """Return (ok, reason). A single wrapped command, or an `&&` chain whose every
    segment is individually allowlisted; no other shell metacharacters. git push/fetch
    with -C under /home/matt/wt/; cwd-scoped read-only git (+ fetch) and
    `scripts/pf-test verify --all` only when the request cwd is under /home/matt/wt/."""
    m = CMD_WRAP.match(cmd or "")
    if not m:
        return False, "not_single_bash_lc"
    inner = m.group(1)
    segments = [seg.strip() for seg in inner.split(" && ")]
    if len(segments) > 1:
        reasons = []
        for seg in segments:
            ok, why = command_allowed("/bin/bash -lc '" + seg + "'", cwd)
            if not ok:
                return False, "chain:" + why
            reasons.append(why)
        return True, "chain[" + ",".join(reasons) + "]"
    in_wt = bool(cwd) and str(cwd).startswith("/home/matt/wt/") and ".." not in str(cwd)
    # WIP-preservation commits in the worker's own worktree (2026-09-27 10:20Z: six
    # resumed CAP workers were told to commit before anything else). Messages are
    # double-quoted literals with no expansion characters; no amend/-a/--no-verify.
    if in_wt and GIT_COMMIT_RE.fullmatch(inner) and "signed-off-by" not in inner.lower():
        return True, "git_commit_cwd_wt"
    bad = sorted(set(ch for ch in inner if ch in META))
    if bad:
        return False, f"metachar:{''.join(bad)}"
    toks = inner.split()
    if in_wt and len(toks) >= 3 and toks[:2] == ["git", "add"]:
        if any(t.startswith("-") or t.startswith("/") or ".." in t for t in toks[2:]):
            return False, "git_add_option_or_path"
        return True, "git_add_cwd_wt"
    if in_wt and len(toks) >= 2 and toks[0] == "git" and toks[1] in CWD_GIT_READ:
        if any(t.startswith("--output") or t.startswith("--ext-diff") or t.startswith("--upload-pack") for t in toks[2:]):
            return False, "git_writing_option"
        if toks[1] == "branch" and any(t.startswith("-") and t not in ("-a", "-r", "-v", "-vv", "--show-current", "--list") for t in toks[2:]):
            return False, "git_branch_mutating"
        return True, "git_" + toks[1] + "_cwd_wt"
    if in_wt and toks[:2] == ["git", "push"] and toks[2:] in ([], ["-u", "origin", "HEAD"], ["origin", "HEAD"],
                                                              ["--set-upstream", "origin", "HEAD"]):
        br = subprocess.run(["git", "-C", str(cwd), "rev-parse", "--abbrev-ref", "HEAD"],
                            capture_output=True, text=True, timeout=30).stdout.strip()
        if not br or br in ("HEAD", "main", "master") or br.startswith("device/"):
            return False, f"git_push_branch:{br or 'unknown'}"
        return True, "git_push_head_cwd_wt:" + br
    # Read-only docker image queries (2026-09-28: the RTC worker needed three separate manual
    # approvals for `docker image ls` variants while checking its build image). Only ls/inspect
    # and `docker images`, with plain-character arguments; nothing that runs, pulls or removes.
    if in_wt and (toks[:3] in (["docker", "image", "ls"], ["docker", "image", "inspect"]) or toks[:2] == ["docker", "images"]):
        rest = toks[3:] if toks[1] == "image" else toks[2:]
        if all(re.fullmatch(r"[-A-Za-z0-9_=:./@,]+", t) for t in rest):
            return True, "docker_image_read_cwd_wt"
        return False, "docker_image_read_arg"
    if in_wt and toks == ["scripts/pf-test", "verify", "--all"]:
        return True, "pf_test_verify_all_cwd_wt"
    if in_wt and len(toks) == 2 and toks[0] == "bash" and re.fullmatch(r"scripts/tests/[A-Za-z0-9_.-]+-test\.sh", toks[1]):
        return True, "hermetic_test_script_cwd_wt"
    if any(tok.startswith("#") for tok in toks):
        return False, "comment_token"
    for pre in ALLOWED_PREFIXES:
        if toks[:len(pre)] == pre:
            return True, "prefix:" + " ".join(pre)
    if len(toks) >= 4 and toks[0] == "git" and toks[1] == "-C" and toks[2].startswith("/home/matt/wt/") \
            and ".." not in toks[2] and toks[3] in ("push", "fetch"):
        if toks[3] == "push" and any(t in ("--force", "-f", "--force-with-lease", "--delete", "-d", "--mirror") or t.startswith("+") for t in toks[4:]):
            return False, "git_push_forceful"
        if toks[3] == "push" and any(t in ("main", "master") or t.endswith(":main") or t.endswith(":master") or t.startswith("device/") or ":device/" in t for t in toks[4:]):
            return False, "git_push_default_branch"
        return True, "git_" + toks[3] + "_in_wt"
    return False, "not_allowlisted"


WAKE_STATES = {"failed", "stopped", "released", "crashed", "error", "blocked", "refused", "terminal_failure", "interrupted", "cancelled"}
UNKNOWN_STATE_SECONDS = 600
WEDGE_SECONDS = 1800  # 600 false-fired on a lane blocked in a long MCP wait (2026-09-27 08:15Z)
BUSY_STATES = {"busy", "admitted", "runtime_accepted", "queued", "submitted_unconfirmed", "pending"}
RECON_DEAD_S = 300  # OpenCode reconciler dead AND the native session idle for this long -> rc 12


def _codex_turn_complete_idle(session_id, min_idle=60):
    """True if the Codex rollout for `session_id` ends with a task_complete newer than its last task_started
    and has been quiet for `min_idle` s; False if a turn is still open; None if no single rollout is found.
    2026-10-16 (sduhs3 pft-b9b58d29): reconciler_alive=false, task_complete at 13:18:48Z, run stayed `busy`
    and this supervisor only noticed via the 1800 s COMPLETED_UNRECORDED path (~30 min on the top lane)."""
    import glob
    files = glob.glob(os.path.expanduser(f"~/.codex/sessions/*/*/*/rollout-*-{session_id}.jsonl")) if session_id else []
    if len(files) != 1:
        return None
    f = files[0]
    try:
        if time.time() - os.path.getmtime(f) < min_idle:
            return False
        with open(f, "rb") as fh:
            fh.seek(max(0, os.path.getsize(f) - 262144))
            tail = fh.read().decode("utf-8", "replace")
    except OSError:
        return None
    done, started = tail.rfind('"type":"task_complete"'), tail.rfind('"type":"task_started"')
    return done > started and done >= 0


def _opencode_native_idle(worktree, session_id):
    """True if the OpenCode server whose cwd is `worktree` reports `session_id` idle, False if busy,
    None when no such server answers. 2026-10-11 (pft-a405e5ec, pft-fbb8a23d): the run's reconciler
    died, the native turn ended with a status line, and pf-task kept the run `busy` for 1-2.5 h."""
    import urllib.request
    for d in os.listdir("/proc"):
        if not d.isdigit():
            continue
        try:
            argv = open(f"/proc/{d}/cmdline", "rb").read().split(b"\0")
            if b"serve" not in argv or not any(a.endswith(b"opencode") for a in argv) or b"--port" not in argv:
                continue
            if os.readlink(f"/proc/{d}/cwd") != worktree:
                continue
            port = int(argv[argv.index(b"--port") + 1])
        except Exception:
            continue
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/session/status", timeout=10) as r:
                return session_id not in json.load(r)
        except Exception:
            return None
    return None


def _foreign_dump(run_id, pid, params):
    """Write a refused request's full params for the coordinator to read; never fails the supervisor."""
    try:
        d = "/home/matt/recovery/gpu14/foreign"; os.makedirs(d, exist_ok=True)
        f = os.path.join(d, f"{run_id}-{str(pid).replace(':', '_')}.json")
        with open(f, "w") as fh:
            fh.write(json.dumps({"cwd": params.get("cwd"), "command": params.get("command")}, indent=1))
        return f
    except Exception as e:  # noqa: BLE001
        return f"unwritten:{type(e).__name__}"


def pf(op, args, timeout=3700):
    # 2026-10-10: one 60 s run.status timeout (journal busy) raised TimeoutExpired and killed the
    # dbguser driver (DRIVER_EXIT supervisor_rc_1) while its run was healthy and busy. A timeout
    # is "no answer this time": return an unparseable-shaped dict so callers fall back as they do
    # for any unreadable reply (state_of() -> None -> use work.wait's state).
    try:
        r = subprocess.run([PF_TASK_BIN, "--home", HOME, "--role", "coordinator", op, json.dumps(args)],
                           capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        print(f"NOTE pf_timeout op={op} timeout_s={timeout}", flush=True)
        return {"status": "timeout", "op": op}
    try:
        return json.loads(r.stdout)
    except Exception:
        return {"status": "unparseable", "stdout": r.stdout[:500], "stderr": r.stderr[:500]}


def evidence(run_id):
    """Page 0 pins sha256 + total_bytes; remaining pages fetched concurrently so the
    pinned document is read inside ~1 s (it changes as runtime health updates)."""
    from concurrent.futures import ThreadPoolExecutor
    lim = 8192
    for attempt in range(12):
        d = pf("run.evidence", {"run_id": run_id, "source": "run", "limit": lim, "offset": 0}, 60)
        if "chunk" not in d:
            time.sleep(1 + attempt)
            continue
        sha, total = d.get("sha256"), d.get("total_bytes") or 0
        offs = list(range(lim, total, lim)) if d.get("truncated") else []
        with ThreadPoolExecutor(max_workers=8) as ex:
            pages = list(ex.map(lambda o: pf("run.evidence", {"run_id": run_id, "source": "run",
                                                               "limit": lim, "offset": o, "sha256": sha}, 60), offs))
        if any("chunk" not in pg for pg in pages):
            time.sleep(1 + attempt)
            continue
        buf = d["chunk"] + "".join(pg["chunk"] for pg in pages)
        try:
            return json.loads(buf)
        except Exception:
            time.sleep(1 + attempt)
    return None


def journal_permissions(run_id):
    """Read ONLY the run record's pending permissions from the pf-task journal,
    read-only (sqlite mode=ro, json_extract). run.evidence has no scoped view and
    the full run document reached 56 MB on the CAP lane (2026-09-27), which cannot
    be sha-pinned while the run is live. Approval still goes through run.permission,
    which the pf-task authority validates."""
    import sqlite3
    try:
        db = sqlite3.connect(f"file:{HOME}/journal.sqlite3?mode=ro", uri=True, timeout=30)
        row = db.execute("SELECT json_extract(body,'$.permissions') FROM records WHERE kind='run' AND id=?",
                         (run_id,)).fetchone()
        db.close()
    except Exception:
        return None
    if not row or row[0] is None:
        return None
    try:
        return {"permissions": json.loads(row[0])}
    except Exception:
        return None


ROUTINE_LOG = "/home/matt/recovery/gpu14/lane-routine.log"


def auto_ack_routine(run_id, rc):
    """ACK every unacked receipt iff ALL are routine lane turns. Returns (acked, reason).
    Reads each receipt's COMPLETE final text via run.evidence; fails toward waking gpu-14."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import lane_routine
        from full_result import final_text_fast
        first = pf("run.result", {"run_id": run_id, "offset": 0}, 120)
        total = first.get("total")
        if not isinstance(total, int):
            return False, "result_total_unreadable"
        unacked = []
        for off in range(total - 1, max(-1, total - 1 - (rc + 10)), -1):
            page = pf("run.result", {"run_id": run_id, "offset": off}, 120)
            r = (page.get("results") or [None])[0]
            if r and not r.get("acknowledged"):
                unacked.append(r)
        if len(unacked) != rc:
            return False, f"unacked_found={len(unacked)}_vs_count={rc}"
        last = lane_routine.load_last(run_id)
        scored = []
        for r in reversed(unacked):  # oldest first, so "last" advances in order
            tr = ((r.get("terminal_reason") or {}).get("text") or "")
            if r.get("outcome") != "completed" or tr != "codex_completed":
                return False, f"outcome={r.get('outcome')}/{tr}"
            text = final_text_fast(run_id, r["receipt"])
            ok, why, fields = lane_routine.verdict(text, last)
            lane_routine.save_last(run_id, fields)
            if not ok:
                return False, why
            last = fields
            scored.append((r["receipt"], fields))
        for receipt, fields in scored:
            a = pf("run.result", {"run_id": run_id, "ack_receipt": receipt}, 120)
            if a.get("ack_receipt") != receipt:
                return False, f"ack_failed:{json.dumps(a)[:120]}"
            with open(ROUTINE_LOG, "a") as fh:
                fh.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                     "run": run_id, "receipt": receipt, "verdict": "routine_auto_ack",
                                     "scored_lines": fields}) + "\n")
        return True, "routine"
    except Exception as e:  # any failure wakes gpu-14
        return False, f"classifier_error:{type(e).__name__}:{str(e)[:120]}"


def state_of(w):
    b = w.get("blocker") or {}
    return b.get("state") or w.get("state")


def main():
    run_id, gen, log = sys.argv[1], sys.argv[2], sys.argv[3]
    max_hours = float(sys.argv[4]) if len(sys.argv) > 4 else 6.0
    budget = int(sys.argv[5]) if len(sys.argv) > 5 else 400
    deadline = time.time() + max_hours * 3600
    approved = 0
    done_ids = set()
    # Seed from the audit log: ids already approved (by a prior supervisor OR manually by
    # gpu-14, logged with tool=command:manual-gpu14) must not re-trigger a FOREIGN exit
    # while the runtime has not yet cleared them (observed race 2026-09-27 10:05Z).
    # 14:45Z: gpu-14's hand approvals are also logged centrally in manual-approvals.jsonl
    for seed in (log, "/home/matt/recovery/gpu14/manual-approvals.jsonl"):
        try:
            for line in open(seed):
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if rec.get("run") == run_id and rec.get("id"):
                    done_ids.add(rec["id"])
        except FileNotFoundError:
            pass
    auto_acked = 0
    unknown_since = {}
    busy_since = None
    wait_crashes = 0
    recon_dead_since = None
    absent_strikes = 0
    dead_strikes = 0
    while time.time() < deadline:
        w = pf("work.wait", {"run_id": run_id, "generation": gen, "timeout_seconds": 300})
        if state_of(w) is None:
            # 2026-09-27 ~11:50Z: four supervisors died at once on a transient pf-task
            # start-up traceback (Control() init); pf-task was healthy seconds later. Retry
            # crashes with backoff; a refusal (a real answer) still exits at once.
            if w.get("status") == "unparseable" and wait_crashes < 6:
                wait_crashes += 1
                time.sleep(10 * wait_crashes)
                continue
            print(f"WAIT_ERROR run={run_id} crashes={wait_crashes} detail={json.dumps(w)[:1200]}")
            return 6
        wait_crashes = 0
        # work.wait can report permission_blocked with a null blocker (observed 2026-09-27
        # 06:25Z on 3 lanes; the lanes then hit turn_timeout). run.status carries the
        # authoritative blocker + permission ids, so always consult it.
        s = pf("run.status", {"run_id": run_id}, 60)
        if state_of(s) is not None:
            w = s
        st = state_of(w)
        # An unknown state's clock runs only while the run STAYS in it: a run that was 'pending'
        # hours ago and re-enters it (auto-continue delivery) must not trip the bound at once.
        for _k in [k for k in unknown_since if k != st]:
            del unknown_since[_k]
        if st is None:
            print(f"WAIT_ERROR run={run_id} detail={json.dumps(w)[:400]}")
            return 6
        # 2026-09-28: approvals submitted to a run whose -control session died come back
        # submitted_unconfirmed and are silently lost (tsp-hqm1p.42; CAP g3 re-asked
        # checkpoint.resume twice). Wake gpu-14 instead of approving into a dead controller.
        # Two consecutive readings, so a recover already in progress does not trigger it.
        if s.get("controller_alive") is False and _runtime_proc_alive(run_id):
            # 2026-09-30 05:50Z: run.status reported controller_alive=false for runs whose
            # `pf-task ... runtime <run_id>` host process (parent of the live codex app-server)
            # was alive and working; acting on it with `pf-task recover` killed a live turn
            # (ASTC run, log stopped 05:29:41Z). The runtime process is the ground truth.
            if not fn_logged.get(run_id):
                print(f"NOTE controller_alive_false_negative run={run_id} runtime_process=alive", flush=True)
                fn_logged[run_id] = True
            dead_strikes = 0
        elif s.get("controller_alive") is False:
            dead_strikes += 1
            if dead_strikes >= 2:
                print(f"DEAD_CONTROLLER run={run_id} state={st} approvals={approved} "
                      f"(run `pf-task recover`, then re-submit approvals logged since the death)")
                return 10
            time.sleep(5)
            continue
        dead_strikes = 0
        if st in BUSY_STATES:
            unavail = 0
            # Wedge detector (tsp-mwo3a): codex turn_timeout interrupt during a
            # code-mode exec leaves the run "busy" forever. Wake gpu-14 when the
            # interrupt blocker is set and the session rollout has not grown for
            # WEDGE_SECONDS. gpu-14 decides remediation; this never kills anything.
            btxt = (((w.get("blocker") or {}).get("blocker") or {}).get("text") or "")
            # 2026-09-27 11:35Z false positive: a run QUEUED for a new message still carries the
            # previous turn's interrupt text and an old rollout mtime. Only a run this supervisor
            # has itself watched in state "busy" for > WEDGE_SECONDS can be called wedged.
            if st != "busy":
                busy_since = None
            elif busy_since is None:
                busy_since = time.time()
            # 2026-10-11: OpenCode run whose pf-task reconciler died. pf-task never sees the native turn end;
            # a run.send restarts the reconciler. Wake the driver only once the native session is idle.
            sid = w.get("session_id") or ""
            if st == "busy" and sid.startswith("ses_") and w.get("reconciler_alive") is False:
                if recon_dead_since is None:
                    recon_dead_since = time.time()
                elif time.time() - recon_dead_since > RECON_DEAD_S:
                    wt = ((w.get("worktree") or {}).get("text") or "")
                    idle = _opencode_native_idle(wt, sid) if wt else None
                    if idle or (idle is None and time.time() - recon_dead_since > WEDGE_SECONDS):
                        print(f"RECONCILER_DEAD run={run_id} session={sid} native_idle={idle} "
                              f"dead_s={int(time.time() - recon_dead_since)} approvals={approved}")
                        return 12
            elif st == "busy" and sid and w.get("reconciler_alive") is False:
                # 2026-10-16: the same reconciler death on a Codex run. Wake the driver (rc 12 -> run.send
                # revives the reconciler) once the rollout shows the turn completed and went quiet.
                if recon_dead_since is None:
                    recon_dead_since = time.time()
                elif time.time() - recon_dead_since > RECON_DEAD_S and _codex_turn_complete_idle(sid):
                    print(f"RECONCILER_DEAD run={run_id} session={sid} runtime=codex native_idle=True "
                          f"dead_s={int(time.time() - recon_dead_since)} approvals={approved}")
                    return 12
            else:
                recon_dead_since = None
            if st == "busy" and busy_since is not None and time.time() - busy_since > WEDGE_SECONDS \
                    and btxt.startswith("turn_timeout: interrupt requested"):
                sid = w.get("session_id") or ""
                import glob
                files = glob.glob(os.path.expanduser(f"~/.codex/sessions/**/*{sid}*.jsonl"), recursive=True) if sid else []
                age = (time.time() - os.path.getmtime(files[0])) if files else None
                if age is not None and age > WEDGE_SECONDS:
                    done = _last_completed_turn(run_id)
                    if done:
                        # tsp-mc9m.41.984.49 class 2b (2026-09-30, 3 witnesses): after a turn-timeout
                        # interrupt request, a LATER turn completes normally but pf-task never records it
                        # (state stays busy, blocker keeps "turn_timeout: interrupt requested").
                        print(f"COMPLETED_UNRECORDED run={run_id} turn={done[0]} final_text={done[1]} approvals={approved}")
                        return 11
                    print(f"WEDGED run={run_id} session={sid} rollout_idle_s={int(age)} approvals={approved}")
                    return 8
            # 2026-09-30 witness 4 (pft-6633c15c, tsp-3rd3.17): the FIRST turn completed at 05:54Z with
            # no turn_timeout involved; pf-task recorded nothing (receipts 0, message still pending,
            # state busy), and this loop slept to supervisor_deadline because the check above requires
            # the interrupt text. Same verdict without that precondition, gated on this supervisor
            # having watched "busy" AND the artifact log being idle for > WEDGE_SECONDS.
            if st == "busy" and busy_since is not None and time.time() - busy_since > WEDGE_SECONDS \
                    and not btxt.startswith("turn_timeout: interrupt requested"):
                idle = _artifact_idle_s(run_id)
                if idle is not None and idle > WEDGE_SECONDS:
                    done = _last_completed_turn(run_id)
                    if done:
                        print(f"COMPLETED_UNRECORDED run={run_id} turn={done[0]} final_text={done[1]} "
                              f"variant=no_timeout artifact_idle_s={int(idle)} approvals={approved}")
                        return 11
            time.sleep(BUSY_POLL_SECONDS)
            continue
        if st == "unavailable":
            unavail = locals().get("unavail", 0) + 1
            if unavail < 30:
                time.sleep(10)  # transient during controller start/restart
                continue
            # 2026-10-11 (ctier pft-2d32e3d2): unavailable for 5 min with runtime alive but reconciler dead
            # (error TimeoutError) is the same OpenCode reconciler death as RECONCILER_DEAD: a run.send revives it.
            if w.get("reconciler_alive") is False and w.get("runtime_alive") is not False:
                print(f"RECONCILER_DEAD run={run_id} state=unavailable runtime_alive={w.get('runtime_alive')} approvals={approved}")
                return 12
            print(f"TURN_END run={run_id} state=unavailable_persistent approvals={approved}")
            return 0
        if st == "awaiting_release":
            # BUG FIXED 2026-09-27 09:36Z: this used run.result's DEFAULT page (oldest
            # receipts, all ACKed) and so never saw new unacked receipts -> 5 supervisors
            # slept for ~70 min while every run had unread receipts. Use run.status's
            # authoritative unacknowledged COUNT; fail closed (wake) if it is unreadable.
            tt = _last_turn_timeout_interrupt(run_id)
            if tt:
                ac = _autocontinue(run_id, tt)
                if ac == "sent":
                    print(f"NOTE autocontinue run={run_id} turn={tt}", flush=True)
                    time.sleep(10)
                    continue
                if ac == "exhausted":
                    print(f"TURN_END run={run_id} state=awaiting_release wake_reason=turn_timeout_repeated "
                          f"turn={tt} autocontinue_max={AUTOCONT_MAX} approvals={approved}")
                    return 0
            rc = (w.get("receipts") or {}).get("unacknowledged")
            if rc is None:
                print(f"TURN_END run={run_id} state=awaiting_release receipts_count_unreadable approvals={approved}")
                return 0
            if rc > 0:
                # 16:10Z: ACK routine lane turns here (lane_routine.verdict; any doubt wakes gpu-14).
                ok_routine, why_routine = auto_ack_routine(run_id, rc)
                if ok_routine:
                    auto_acked += rc
                    continue
                print(f"TURN_END run={run_id} state=awaiting_release unacked_count={rc} approvals={approved} "
                      f"auto_acked={auto_acked} wake_reason={why_routine}")
                return 0
            time.sleep(20)  # idle between turns; all receipts ACKed by gpu-14; keep watching
            continue
        if st in WAKE_STATES:
            print(f"TURN_END run={run_id} state={st} approvals_this_supervisor={approved}")
            return 0
        if st != "permission_blocked":
            # unknown/transitional state (e.g. pending, delivering): keep watching, but
            # BOUNDED: a state this loop does not understand must not hold gpu-14 asleep.
            first = unknown_since.setdefault(st, time.time())
            if time.time() - first > UNKNOWN_STATE_SECONDS:
                print(f"STATE_UNHANDLED run={run_id} state={st} for_s={int(time.time()-first)} approvals={approved}")
                return 9
            time.sleep(15)
            continue
        unknown_since.clear()
        wanted = [p.get("id", {}).get("text") if isinstance(p.get("id"), dict) else p.get("id")
                  for p in (w.get("blocker") or {}).get("permissions", [])]
        wanted = [pid for pid in wanted if pid not in done_ids]
        if not wanted:
            time.sleep(3)  # wait result lags our own just-submitted approval
            continue
        ev = journal_permissions(run_id) or evidence(run_id)
        if ev is None:
            print(f"UNREADABLE run={run_id} wanted={wanted}")
            return 4
        perms = {p.get("id"): p for p in ev.get("permissions", [])}
        for pid in wanted:
            p = perms.get(pid)
            if p is None:
                absent_strikes += 1
                if absent_strikes >= 5:
                    print(f"ID_ABSENT run={run_id} id={pid} present={list(perms)}")
                    return 5
                time.sleep(3)
                break
            absent_strikes = 0
            params = p.get("params") or {}
            meta = params.get("_meta") or {}
            if p.get("method") == "item/commandExecution/requestApproval":
                ok, why = command_allowed(params.get("command"), params.get("cwd"), run_id)
                if not ok:
                    # 2026-10-02: the 300-char cut hid the tail of a compound command (CAP g6 :10), so a
                    # judgement needed a second lookup. Keep the short line, and write the FULL request.
                    full = _foreign_dump(run_id, pid, params)
                    print(f"FOREIGN run={run_id} id={pid} method=commandExecution reason={why} "
                          f"cmd={str(params.get('command'))[:300]} full={full}")
                    return 3
                meta = {"tool_description": "command:" + why, "tool_params": params.get("command")}
            elif p.get("method") == "item/fileChange/requestApproval":
                ok, why, paths = file_change_allowed(run_id, params.get("threadId"))
                if not ok:
                    print(f"FOREIGN run={run_id} id={pid} method=fileChange reason={why} paths={paths[:6]}")
                    return 3
                meta = {"tool_description": "fileChange:" + why, "tool_params": paths}
            elif not (p.get("method") == "mcpServer/elicitation/request"
                    and params.get("serverName") == "pf_task"
                    and meta.get("codex_approval_kind") == "mcp_tool_call"):
                print(f"FOREIGN run={run_id} id={pid} method={p.get('method')} "
                      f"server={params.get('serverName')} kind={meta.get('codex_approval_kind')} "
                      f"msg={str(params.get('message'))[:300]}")
                return 3
            if approved >= budget:
                print(f"BUDGET run={run_id} approved={approved}")
                return 7
            r = pf("run.permission", {"run_id": run_id, "request_id": pid, "decision": "once"}, 120)
            approved += 1
            done_ids.add(pid)
            with open(log, "a") as fh:
                fh.write(json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                                     "run": run_id, "id": pid, "tool": meta.get("tool_description"),
                                     "params": meta.get("tool_params"), "result": r}) + "\n")
    print(f"TURN_END run={run_id} state=supervisor_deadline approvals={approved}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
