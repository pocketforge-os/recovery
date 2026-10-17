#!/usr/bin/env python3
"""render.py -- data.json -> fleet-board.html (one self-contained page, data embedded).

The page starts with <title>, <link>, <style>, then content and one inline
<script>; the publish wrapper supplies doctype/head/body. No fetches at view
time: everything is rendered here from data.json, and the JSON itself is
embedded for view-source debugging and for the in-browser "page age" ticker.
"""
import datetime as dt
import html
import json
import os
import sys

BOARD = os.environ.get("FB_BOARD_DIR") or os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(BOARD, "data.json")
OUT = os.path.join(BOARD, "fleet-board.html")
VELOCITY = os.path.join(BOARD, "velocity.json")

FONTS = ("https://fonts.googleapis.com/css2?family=Archivo:wdth,wght@75..100,400..700"
         "&family=JetBrains+Mono:wght@400;600&display=swap")

KIND_LABEL = {"merge_ready": "MERGE_READY", "handback": "HANDBACK", "boot_ready": "BOOT_READY",
              "device": "DEVICE", "blocked": "BLOCKED", "stale": "STALE", "undriven": "UNDRIVEN",
              "dispatchable": "UNBLOCKED", "budget": "BUDGET"}
KIND_SEV = {"merge_ready": "crit", "handback": "crit", "boot_ready": "crit", "device": "crit",
            "undriven": "crit", "budget": "crit", "blocked": "warn", "stale": "warn", "dispatchable": "info"}
CLS_SEV = {"needs": "crit", "waiting": "warn", "running": "good", "unknown": "muted", "released": "muted"}
STATE_SEV = {"HANDBACK": "crit", "BOOT_READY": "crit", "BLOCKED": "warn", "IDLE": "crit", "QUESTION": "crit",
             "MERGE_READY": "crit", "CI_WAIT": "warn", "WAITING": "warn", "CONTINUE": "good", "NONE": "muted"}


def e(s):
    return html.escape("" if s is None else str(s), quote=True)


def mono(s, cls=""):
    return f'<code class="id {cls}">{e(s)}</code>' if s else '<span class="dim">–</span>'


def fmt_age(s):
    if s is None:
        return "?"
    s = int(s)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        return f"{s // 3600}h{(s % 3600) // 60:02d}"
    return f"{s / 86400:.1f}d"


def short_ts(ts):
    """2026-10-11T01:58:39Z -> 10-11 01:58Z"""
    if not ts:
        return "–"
    try:
        return ts[5:16].replace("T", " ") + "Z"
    except Exception:
        return ts


def pill(text, sev):
    return f'<span class="pill pill-{sev}">{e(text)}</span>'


def chip(text, sev):
    return f'<span class="chip chip-{sev}">{e(text)}</span>'


def pr_cell(ref, prs):
    if not ref:
        return '<span class="dim">–</span>'
    p = prs.get(ref) or {}
    if p.get("error"):
        return f'{mono(ref)} <span class="dim">gh error</span>'
    st = p.get("state")
    url = p.get("url")
    label = f'<a class="id" href="{e(url)}">{e(ref)}</a>' if url else mono(ref)
    if st == "MERGED":
        return label + " " + chip("MERGED", "good")
    if st == "CLOSED":
        return label + " " + chip("CLOSED", "muted")
    c = p.get("checks") or {}
    if p.get("merge_ready"):
        ci = chip("CI green · approved", "good")
    elif c.get("failed"):
        ci = chip(f"CI RED {c['failed']}/{c['total']}", "crit")
    elif c.get("pending"):
        ci = chip(f"CI {c['success']}/{c['total']}", "warn")
    elif c.get("total"):
        rv = p.get("review") or "no review"
        ci = chip(f"CI green · {rv.lower().replace('_', ' ')}", "warn" if rv != "APPROVED" else "good")
    else:
        ci = chip("no checks", "muted")
    return label + " " + ci


def section(id_, title, count, body, note="", open_=True):
    cnt = f'<span class="count">{count}</span>' if count is not None else ""
    nt = f'<span class="note">{e(note)}</span>' if note else ""
    return (f'<details class="sec" id="{id_}"{" open" if open_ else ""}>'
            f'<summary><h2>{e(title)}</h2>{cnt}{nt}<span class="tog" aria-hidden="true"></span></summary>'
            f'<div class="sec-body">{body}</div></details>')


def render_needs(d):
    items = d["needs"]
    if not items:
        return '<p class="empty">Nothing is waiting on gpu-14. Every lane has a live driver or a running turn, the device queue is moving, and no in-scope bead is stale.</p>'
    out = ['<ol class="needs">']
    for n in items:
        sev = KIND_SEV.get(n["kind"], "warn")
        ids = []
        if n.get("lane"):
            ids.append(f'<span class="lbl">lane</span>{mono(n["lane"])}')
        if n.get("bead"):
            ids.append(f'<span class="lbl">bead</span>{mono(n["bead"])}')
        if n.get("run"):
            ids.append(f'<span class="lbl">run</span>{mono(n["run"])}')
        if n.get("pr"):
            ids.append(f'<span class="lbl">pr</span>{pr_cell(n["pr"], d["prs"])}')
        if not ids:
            ids.append(mono(n["id"]) if not n.get("count") else f'<a href="#stale">{n["count"]} beads in the Stale beads table</a>')
        title = e(n.get("bead_title") or "")
        out.append(
            f'<li class="need sev-{sev}" data-filter="{e(n["kind"])} {e(n["id"])} {e(n.get("bead"))} {e(n.get("lane"))} {e(n.get("reason"))} {title}">'
            f'<div class="need-head">{pill(KIND_LABEL.get(n["kind"], n["kind"]), sev)}'
            f'<span class="age" title="since {e(n.get("since"))}">{e(fmt_age(n.get("age_s")))}</span></div>'
            f'<div class="need-ids">{" ".join(ids)}</div>'
            + (f'<div class="need-title">{title}</div>' if title else "")
            + f'<div class="need-reason">{e(n["reason"])}</div>'
            f'<div class="need-next">{e(n["next"])}</div>'
            '</li>')
    out.append("</ol>")
    return "".join(out)


def render_lanes(d):
    lanes = d["lanes"]
    if not lanes:
        return '<p class="empty">No lane logs modified in the window.</p>'
    rows = []
    for ln in lanes:
        ls = ln.get("last_status") or {}
        st = ls.get("state")
        cls = ln["cls"]
        state_pill = pill({"needs": "NEEDS gpu-14", "waiting": "waiting", "running": "running",
                           "unknown": "unknown"}.get(cls, cls), CLS_SEV.get(cls, "muted"))
        if ln.get("kind"):
            state_pill += " " + chip(KIND_LABEL.get(ln["kind"], ln["kind"]), KIND_SEV.get(ln["kind"], "warn"))
        last = ls.get("raw") or ("" if st else (ln.get("last_line") or "")[21:])
        model = ln.get("model") or "?"
        rt = ln.get("runtime") or "?"
        rs = ln.get("run_state") or "?"
        rs_note = ""
        if ln.get("run_checked_at") and not ln.get("run_fresh"):
            rs_note = f' <span class="dim" title="run.status as of {e(ln["run_checked_at"])}">(as of {e(short_ts(ln["run_checked_at"]))})</span>'
        if ln.get("run_error"):
            rs_note += f' <span class="dim" title="{e(ln["run_error"])}">!</span>'
        drv = chip(f'driver {len(ln.get("driver_pids") or [])}', "good") if ln.get("driver_alive") else chip("no driver", "crit" if cls == "needs" else "muted")
        rec = ln.get("reconciler_alive")
        rec_c = "" if rec in (None, True) else " " + chip("reconciler dead", "crit")
        na = ln.get("native_activity_age_s")
        na_c = f'<span class="dim">act {e(fmt_age(na))}</span>' if na is not None else ""
        bead = ln.get("bead")
        bead_cell = mono(bead) + (f'<div class="sub">{e((ln.get("bead_title") or "")[:90])}</div>' if ln.get("bead_title") else "")
        rows.append(
            f'<tr class="row-{cls}" data-filter="{e(ln["lane"])} {e(bead)} {e(ln.get("run"))} {e(st)} {e(cls)} {e(ln.get("kind"))} {e(model)} {e(ln.get("pr"))} {e(ln.get("bead_title"))}">'
            f'<td><span class="stripe stripe-{CLS_SEV.get(cls, "muted")}"></span>{mono(ln["lane"], "lane")}<div class="sub">{mono(ln.get("run"))}</div></td>'
            f'<td>{bead_cell}</td>'
            f'<td><span class="model">{e(model)}</span><div class="sub">{e(rt)} · run {e(rs)}{rs_note}</div></td>'
            f'<td>{state_pill}<div class="sub">{e(ln.get("cls_reason") or "")}</div></td>'
            f'<td class="status-cell">{(pill(st, STATE_SEV.get(st, "muted")) + " ") if st else ""}<span class="raw">{e(last[:220])}</span></td>'
            f'<td class="num" title="last status {e(ls.get("ts") or ln.get("last_event_at"))}">{e(fmt_age(ln.get("status_age_s")))}</td>'
            f'<td>{drv}{rec_c}<div class="sub">{na_c}</div></td>'
            f'<td>{pr_cell(ln.get("pr"), d["prs"])}</td>'
            '</tr>')
    hidden = d["summary"].get("lanes_released_hidden", 0)
    foot = f'<p class="fine">{hidden} lane(s) with released runs are hidden. Run state comes from pf-task run.status; "(as of …)" marks a cached answer when this refresh\'s pf-task budget ran out.</p>' if hidden else ""
    return ('<div class="scroll"><table class="grid lanes"><thead><tr>'
            '<th>Lane / run</th><th>Bead</th><th>Model · runtime</th><th>Board state</th><th>Last status line</th>'
            '<th class="num">Age</th><th>Driver</th><th>PR · CI</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table></div>" + foot)


def bead_row(b, extra=""):
    pr = b.get("priority")
    return (f'<tr data-filter="{e(b["id"])} {e(b["title"])} {e(b.get("parent"))} {e(b.get("tier"))}">'
            f'<td>{mono(b["id"])}</td><td class="num">{"P" + str(pr) if pr is not None else "–"}</td>'
            f'<td>{e(b.get("tier") or "–")}</td><td>{e(b["title"])}{"" if b.get("recent", True) else " " + chip("backlog", "muted")}'
            f'<div class="sub">{e(b.get("type") or "")} · under {mono(b.get("parent"))} {e((b.get("parent_title") or "")[:60])}</div></td>'
            f'<td class="num">{e(short_ts(b.get("updated_at")))}</td>{extra}</tr>')


# gpu-14 2026-10-11: cap long tables so the published page stays small; full lists stay in data.json.
STALE_ROWS = 30
PARALLEL_ROWS = 30
CHAIN_ROWS = 12


def render_dispatchable(d):
    disp = d["dispatchable"]
    parts = []
    nu = disp["newly_unblocked"]
    parts.append(f'<h3>Newly unblocked <span class="count">{len(nu)}</span></h3>')
    if nu:
        rows = []
        for b in nu:
            by = " ".join(mono(x) for x in b.get("unblocked_by", []))
            rows.append(bead_row(b, f'<td>{by}<div class="sub">closed {e(short_ts(b.get("unblocked_at")))}</div></td>'))
        parts.append('<div class="scroll"><table class="grid"><thead><tr><th>Bead</th><th class="num">P</th><th>Tier</th><th>Title</th><th class="num">Updated</th><th>Unblocked by</th></tr></thead><tbody>'
                     + "".join(rows) + "</tbody></table></div>")
    else:
        parts.append(f'<p class="empty">No ready bead had a blocker close in the last {d["thresholds"]["NEWLY_UNBLOCKED_H"]} h.</p>')
    par = disp["parallel"]
    parts.append(f'<h3>Can start in parallel now <span class="count">{disp.get("parallel_recent_total", disp["parallel_total"])}</span>'
                 f'<span class="note">bd ready, in scope, open, no lane, not a container type, touched within {d["thresholds"].get("RECENT_DAYS", 14)} days; '
                 f'{disp["parallel_total"]} ready in all, {disp["parallel_shown"]} shown (recent first, then priority)</span></h3>')
    if par:
        parts.append('<div class="scroll"><table class="grid"><thead><tr><th>Bead</th><th class="num">P</th><th>Tier</th><th>Title</th><th class="num">Updated</th></tr></thead><tbody>'
                     + "".join(bead_row(b) for b in par[:PARALLEL_ROWS]) + "</tbody></table></div>")
        if len(par) > PARALLEL_ROWS:
            parts.append(f'<details class="more"><summary>{len(par) - PARALLEL_ROWS} more shown-ready beads</summary><p class="idlist">'
                         + " ".join(mono(x["id"]) for x in par[PARALLEL_ROWS:]) + "</p></details>")
        rest = disp.get("parallel_rest_ids") or []
        if rest:
            parts.append(f'<details class="more"><summary>{len(rest)} more ready beads (older or lower priority)</summary><p class="idlist">'
                         + " ".join(mono(x) for x in rest) + "</p></details>")
    else:
        parts.append('<p class="empty">Nothing ready without a lane.</p>')
    ch = disp["chains"]
    parts.append(f'<h3>Sequenced: what landing unblocks <span class="count">{disp["chains_total"]}</span>'
                 f'<span class="note">open blockers in scope and the beads they hold; {len(ch)} shown by fan-out</span></h3>')
    if ch:
        lis = []
        for c in ch[:CHAIN_ROWS]:
            b = c["blocker"]
            lane = f' {chip("lane " + b["lane"], "good")}' if b.get("lane") else ""
            stc = chip(b["status"], {"in_progress": "good", "open": "warn", "blocked": "warn"}.get(b["status"], "muted"))
            deps = "".join(
                f'<li>{mono(x["id"])} {chip(x["status"], "muted")} <span class="t">{e(x["title"][:110])}</span></li>'
                for x in c["dependents"])
            lis.append(f'<li class="chain" data-filter="{e(b["id"])} {e(b["title"])} {" ".join(x["id"] for x in c["dependents"])}">'
                       f'<div class="chain-head">{mono(b["id"])} {stc}{lane} <span class="t">{e(b["title"][:120])}</span></div>'
                       f'<ul class="chain-deps">{deps}</ul></li>')
        parts.append('<ul class="chains">' + "".join(lis) + "</ul>")
    else:
        parts.append('<p class="empty">No open blocker holds another in-scope bead.</p>')
    return "".join(parts)


def render_device(d):
    dev = d["device"]
    parts = []
    r = dev.get("running")
    runner = chip("runner alive", "good") if dev["runner_alive"] else chip("runner not running", "crit" if dev["pending_count"] else "muted")
    kit = chip("direct-boot.sh live", "good") if dev["kit_running"] else ""
    if dev.get("halted"):
        parts.append(f'<div class="banner banner-crit"><strong>Queue HALTED</strong> {e(dev.get("halt_line"))} <span class="dim">({e(short_ts(dev.get("halt_at")))})</span></div>')
    if r:
        parts.append(f'<div class="running"><div class="running-head">{pill("RUNNING", "good")} {mono(r["name"], "lane")}'
                     f'<span class="age">{e(fmt_age(r["elapsed_s"]))}</span></div>'
                     f'<div class="sub">started {e(r["started_at"])} · receipt {mono(r.get("receipt"))}</div>'
                     f'<div class="sub">{runner} {kit}</div></div>')
    else:
        last_kind = "empty" if (dev.get("last_line") or "").find("QUEUE empty") >= 0 else ""
        parts.append(f'<div class="running idle"><div class="running-head">{pill("IDLE", "muted")} <span class="t">bench has no step running</span></div>'
                     f'<div class="sub">{runner} {kit} · {e(dev["pending_count"])} pending · {e(dev["held_count"])} held (#) · {e(dev["done_count"])} done</div>'
                     + (f'<div class="sub">last line: <span class="raw">{e(dev.get("last_line"))}</span></div>' if dev.get("last_line") else "") + "</div>")
    nx = dev.get("next") or []
    parts.append(f'<h3>Next on the bench <span class="count">{dev["pending_count"]}</span><span class="note">strictly serial; {len(nx)} shown</span></h3>')
    if nx:
        rows = "".join(
            f'<tr data-filter="{e(n["name"])} {e(n["path"])}"><td class="num">{n["position"]}</td><td>{mono(n["name"], "lane")}</td>'
            f'<td>{chip(n["type"], "muted")}</td><td><span class="raw">{e(n["path"])}</span>'
            f'<div class="sub">{e(n.get("manifest") if n.get("manifest") not in (None, "-") else "")} {mono((n.get("sha") or "")[:12]) if n.get("sha") not in (None, "-") else ""} {e(n.get("args") or "")}</div></td></tr>'
            for n in nx)
        parts.append('<div class="scroll"><table class="grid"><thead><tr><th class="num">#</th><th>Step</th><th>Type</th><th>Path · seal · args</th></tr></thead><tbody>' + rows + "</tbody></table></div>")
    else:
        parts.append('<p class="empty">queue.tsv is exhausted; nothing pending.</p>')
    res = dev.get("results") or []
    parts.append(f'<h3>Recent results <span class="count">{len(res)}</span><span class="note">last {d["thresholds"]["RESULTS_SHOW"]} within {d["thresholds"]["RESULTS_WINDOW_H"]} h, newest first</span></h3>')
    if res:
        rows = []
        for ev in res:
            if ev["kind"] == "result":
                v = chip(ev.get("verdict") or "?", ev.get("cls", "muted"))
                det = e((ev.get("stage") and f"stage={ev['stage']} ") or "") + e((ev.get("detail") or "")[:160])
            elif ev["kind"] == "halt":
                v = chip("HALT", "crit")
                det = e(ev["text"][:160])
            else:
                v = chip("SKIP", "warn")
                det = e(ev["text"][:160])
            rows.append(f'<tr data-filter="{e(ev.get("name"))} {e(ev.get("verdict"))} {e(ev["text"])}"><td class="num">{e(short_ts(ev["ts"]))}</td>'
                        f'<td>{mono(ev.get("name"), "lane")}</td><td>{v}</td><td><span class="raw">{det}</span></td></tr>')
        parts.append('<div class="scroll"><table class="grid"><thead><tr><th class="num">When</th><th>Step</th><th>Verdict</th><th>Detail</th></tr></thead><tbody>' + "".join(rows) + "</tbody></table></div>")
    else:
        parts.append('<p class="empty">No results logged.</p>')
    return "".join(parts)


def render_stale(d):
    st = d["stale"]
    parts = []
    if st:
        rows = "".join(
            f'<tr data-filter="{e(s["id"])} {e(s["title"])} {e(s.get("parent"))}"><td>{mono(s["id"])}</td>'
            f'<td class="num">{e(fmt_age(s["age_s"]))}</td><td>{e(s.get("tier") or "–")}</td><td>{e(s["title"])}'
            f'<div class="sub">under {mono(s.get("parent"))} · assignee {e(s.get("assignee") or "–")} · {e(s.get("comment_count"))} comments</div></td>'
            f'<td class="num">{e(short_ts(s.get("updated_at")))}</td><td class="num">{e(short_ts(s.get("last_comment_at")))}</td></tr>'
            for s in st[:STALE_ROWS])
        parts.append('<div class="scroll"><table class="grid"><thead><tr><th>Bead</th><th class="num">Idle</th><th>Tier</th><th>Title</th><th class="num">Updated</th><th class="num">Last comment</th></tr></thead><tbody>' + rows + "</tbody></table></div>")
        if len(st) > STALE_ROWS:
            parts.append(f'<details class="more"><summary>{len(st) - STALE_ROWS} more stale beads (oldest first in data.json)</summary><p class="idlist">'
                         + " ".join(mono(x["id"]) for x in st[STALE_ROWS:]) + "</p></details>")
    else:
        parts.append(f'<p class="empty">No in-scope in_progress bead without a lane has gone {d["thresholds"]["STALE_BEAD_H"]} h without an update or comment (within the {d["thresholds"]["STALE_LOOKBACK_H"]} h lookback).</p>')
    li = d.get("long_idle") or {}
    if li.get("count"):
        parts.append(f'<details class="more"><summary>{li["count"]} in_progress beads in scope untouched for more than {d["thresholds"]["STALE_LOOKBACK_H"] // 24} days (not alarmed; comments not checked)</summary>'
                     f'<p class="idlist">{" ".join(mono(x) for x in li["ids"])}</p></details>')
    return "".join(parts)


def render_owner(d):
    o = d["owner_asks"]
    if o.get("error"):
        return f'<p class="empty">Could not read the owner-questions file: {e(o["error"])}</p>'
    if not o["items"]:
        return '<p class="empty">No live asks.</p>'
    return '<ol class="asks">' + "".join(
        f'<li data-filter="{e(i["title"])}"><span class="asknum">Q{i["num"]}</span> {e(i["title"])}</li>' for i in o["items"]) + "</ol>"


def render_footer(d):
    th = d["thresholds"]
    errs = d.get("errors") or []
    parts = []
    if errs:
        parts.append(f'<h3>Source errors <span class="count">{len(errs)}</span></h3><ul class="errs">'
                     + "".join(f'<li>{mono(x["source"])} <span class="raw">{e(x["error"])}</span></li>' for x in errs) + "</ul>")
    keys = ["LANE_LOG_WINDOW_H", "PFTASK_BUDGET_S", "PFTASK_TIMEOUT_S", "BUSY_IDLE_ALARM_MIN", "BUSY_NO_SIGNAL_ALARM_MIN",
            "HANDBACK_WITH_DRIVER_GRACE_MIN", "KIT_STUCK_H", "STALE_BEAD_H", "STALE_LOOKBACK_H", "NEWLY_UNBLOCKED_H",
            "RESULTS_SHOW", "RESULTS_WINDOW_H", "NEXT_SHOW", "PARALLEL_SHOW", "CHAINS_SHOW"]
    ths = " ".join(f'<span class="th"><span class="lbl">{e(k)}</span>{mono(th.get(k))}</span>' for k in keys if k in th)
    roots = " ".join(mono(r) for r in d.get("campaign_roots", []))
    parts.append(f'<p class="fine">Scope roots: {roots}</p>')
    parts.append(f'<p class="fine thresholds">Thresholds: {ths}</p>')
    parts.append(f'<p class="fine">Sources: bd list --all / bd ready / bd comments (stale candidates only); lane drive logs + ps + admission files + pf-task run.status (primary-key lookups, sequential, budgeted); gh pr view for referenced PRs; queue.tsv / queue.done / device-queue.txt; gpu14-owner-questions.md. Collected on {e(d.get("host"))} in {e(d.get("runtime_s"))} s. Generated by /home/matt/recovery/gpu14/fleet-board/refresh.sh.</p>')
    return "".join(parts)


CSS = r"""
:root {
  --paper: #f3f5f4; --surface: #ffffff; --raised: #e9edeb; --rule: #d3dad8; --rule-2: #e2e7e5;
  --ink: #15191c; --ink-2: #48535d; --muted: #7a858f; --dim: #9aa4ad;
  --accent: #1f5fa8; --accent-ink: #184b86; --focus: #1f5fa8;
  --crit: #c93434; --crit-ink: #9f2626; --crit-bg: #fbe9e9;
  --warn: #d9950a; --warn-ink: #7a5200; --warn-bg: #fbf1dc;
  --good: #1d8f2e; --good-ink: #176e25; --good-bg: #e4f4e6;
  --info: #1f5fa8; --info-ink: #184b86; --info-bg: #e5eefa;
  --neu: #5f6b76; --neu-ink: #48535d; --neu-bg: #eceff1;
  --shadow: 0 1px 0 rgba(21,25,28,.06);
  --sans: "Archivo", "Helvetica Neue", Arial, sans-serif;
  --mono: "JetBrains Mono", "SFMono-Regular", Menlo, Consolas, monospace;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    color-scheme: dark;
    --paper: #111417; --surface: #191e22; --raised: #21282d; --rule: #2e373e; --rule-2: #272f35;
    --ink: #e6eaed; --ink-2: #aeb8c1; --muted: #7f8a94; --dim: #5f6a74;
    --accent: #7fb0ff; --accent-ink: #9cc3ff; --focus: #7fb0ff;
    --crit: #e4555a; --crit-ink: #ff8c8c; --crit-bg: #3a1d1f;
    --warn: #e0a62a; --warn-ink: #f2c75a; --warn-bg: #3a2e14;
    --good: #3cb256; --good-ink: #6fd683; --good-bg: #16301c;
    --info: #7fb0ff; --info-ink: #9cc3ff; --info-bg: #16263a;
    --neu: #8a959f; --neu-ink: #aeb8c1; --neu-bg: #262d33;
    --shadow: none;
  }
}
:root[data-theme="dark"] {
  color-scheme: dark;
  --paper: #111417; --surface: #191e22; --raised: #21282d; --rule: #2e373e; --rule-2: #272f35;
  --ink: #e6eaed; --ink-2: #aeb8c1; --muted: #7f8a94; --dim: #5f6a74;
  --accent: #7fb0ff; --accent-ink: #9cc3ff; --focus: #7fb0ff;
  --crit: #e4555a; --crit-ink: #ff8c8c; --crit-bg: #3a1d1f;
  --warn: #e0a62a; --warn-ink: #f2c75a; --warn-bg: #3a2e14;
  --good: #3cb256; --good-ink: #6fd683; --good-bg: #16301c;
  --info: #7fb0ff; --info-ink: #9cc3ff; --info-bg: #16263a;
  --neu: #8a959f; --neu-ink: #aeb8c1; --neu-bg: #262d33;
  --shadow: none;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--paper); color: var(--ink); font: 14px/1.45 var(--sans); -webkit-text-size-adjust: 100%; }
.wrap { max-width: 1320px; margin: 0 auto; padding: 0 clamp(16px, 2.5vw, 32px); padding-block: 14px 48px; }
a { color: var(--accent-ink); text-decoration: none; }
a:hover { text-decoration: underline; }
:focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; }
h1, h2, h3 { margin: 0; text-wrap: balance; font-weight: 600; letter-spacing: -0.01em; }
h1 { font-size: 22px; font-variation-settings: "wdth" 88; letter-spacing: -0.015em; }
h2 { font-size: 16px; }
h3 { font-size: 13px; text-transform: uppercase; letter-spacing: .06em; color: var(--ink-2); font-variation-settings: "wdth" 85; margin: 18px 0 8px; display: flex; flex-wrap: wrap; gap: 8px 10px; align-items: baseline; }
code, .id, .raw, .model, .asknum { font-family: var(--mono); font-size: 12px; font-variant-numeric: tabular-nums; }
.id { color: var(--ink); background: var(--raised); padding: 1px 5px; border-radius: 3px; white-space: nowrap; }
.id.lane { font-weight: 600; }
a.id { color: var(--accent-ink); }
.raw { color: var(--ink-2); word-break: break-word; }
.dim { color: var(--dim); }
.sub { color: var(--muted); font-size: 12px; margin-top: 2px; }
.sub .id { font-size: 11px; }
.num { font-variant-numeric: tabular-nums; text-align: right; white-space: nowrap; }
.t { color: var(--ink-2); }
.lbl { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: .06em; margin-right: 4px; }
.count { font-family: var(--mono); font-size: 12px; color: var(--ink-2); background: var(--raised); padding: 1px 7px; border-radius: 10px; font-variant-numeric: tabular-nums; }
.note { color: var(--muted); font-size: 12px; font-weight: 400; text-transform: none; letter-spacing: 0; font-variation-settings: "wdth" 100; }

/* masthead */
.mast { display: flex; flex-wrap: wrap; gap: 10px 20px; align-items: center; justify-content: space-between; padding-bottom: 12px; border-bottom: 2px solid var(--ink); }
.mast .brand { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px 14px; }
.mast .brand .who { color: var(--muted); font-size: 13px; font-variation-settings: "wdth" 90; }
.mast .meta { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; font-size: 12px; color: var(--ink-2); }
.mast .meta .gen { font-family: var(--mono); font-variant-numeric: tabular-nums; }
#page-age { font-family: var(--mono); font-variant-numeric: tabular-nums; padding: 2px 8px; border-radius: 10px; background: var(--good-bg); color: var(--good-ink); border: 1px solid var(--good); }
#page-age.old { background: var(--warn-bg); color: var(--warn-ink); border-color: var(--warn); }
#page-age.stale { background: var(--crit-bg); color: var(--crit-ink); border-color: var(--crit); }
.filter { display: flex; align-items: center; gap: 6px; }
.filter input { font: 13px var(--mono); padding: 5px 8px; border: 1px solid var(--rule); border-radius: 4px; background: var(--surface); color: var(--ink); min-width: 200px; }
.filter input::placeholder { color: var(--dim); }

/* summary strip */
.strip { display: grid; grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); gap: 10px; margin: 16px 0 10px; }
.tile { background: var(--surface); border: 1px solid var(--rule); border-top: 3px solid var(--neu); padding: 10px 12px 9px; box-shadow: var(--shadow); min-width: 0; }
.tile .k { font-size: 11px; text-transform: uppercase; letter-spacing: .07em; color: var(--muted); font-variation-settings: "wdth" 85; }
.tile .v { font-size: 30px; font-weight: 600; line-height: 1.1; margin-top: 4px; letter-spacing: -0.02em; }
.tile .v.small { font-size: 16px; font-family: var(--mono); font-weight: 600; margin-top: 10px; word-break: break-all; }
.tile .d { font-size: 12px; color: var(--ink-2); margin-top: 4px; }
.tile.t-crit { border-top-color: var(--crit); } .tile.t-crit .v { color: var(--crit-ink); }
.tile.t-warn { border-top-color: var(--warn); } .tile.t-warn .v { color: var(--warn-ink); }
.tile.t-good { border-top-color: var(--good); } .tile.t-good .v { color: var(--good-ink); }
.tile.t-info { border-top-color: var(--info); }

/* pills & chips: state in form, semantic colors separate from the accent */
.pill, .chip { display: inline-block; font-family: var(--mono); font-size: 11px; line-height: 1; padding: 4px 7px; border-radius: 3px; white-space: nowrap; vertical-align: middle; font-variant-numeric: tabular-nums; }
.pill { font-weight: 600; letter-spacing: .02em; border: 1px solid transparent; }
.pill-crit { background: var(--crit); color: #fff; border-color: var(--crit); }
.pill-warn { background: var(--warn-bg); color: var(--warn-ink); border-color: var(--warn); }
.pill-good { background: var(--good-bg); color: var(--good-ink); border-color: var(--good); }
.pill-info { background: var(--info-bg); color: var(--info-ink); border-color: var(--info); }
.pill-muted { background: var(--neu-bg); color: var(--neu-ink); border-color: var(--rule); }
.chip { border: 1px solid var(--rule); color: var(--ink-2); background: var(--surface); }
.chip-crit { border-color: var(--crit); color: var(--crit-ink); }
.chip-warn { border-color: var(--warn); color: var(--warn-ink); }
.chip-good { border-color: var(--good); color: var(--good-ink); }
.chip-info { border-color: var(--info); color: var(--info-ink); }
.chip-muted { color: var(--muted); }
.chip-neutral { color: var(--muted); }

/* sections */
.sec { margin-top: 18px; border-top: 1px solid var(--rule); }
.sec > summary { list-style: none; cursor: pointer; display: flex; flex-wrap: wrap; align-items: center; gap: 10px; padding: 12px 0 8px; }
.sec > summary::-webkit-details-marker { display: none; }
.sec > summary .tog { margin-left: auto; width: 10px; height: 10px; border-right: 2px solid var(--muted); border-bottom: 2px solid var(--muted); transform: rotate(45deg); transition: transform .15s; }
.sec:not([open]) > summary .tog { transform: rotate(-45deg); }
.sec-body { padding-bottom: 6px; }
.empty { color: var(--muted); margin: 6px 0; }
.fine { color: var(--muted); font-size: 12px; margin: 8px 0 0; }
.thresholds .th { display: inline-block; margin: 2px 10px 2px 0; }
details.more { margin-top: 8px; }
details.more > summary { cursor: pointer; color: var(--accent-ink); font-size: 13px; }
.idlist { line-height: 1.9; }

/* needs list */
.needs { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; grid-template-columns: repeat(auto-fill, minmax(min(100%, 380px), 1fr)); }
.need { position: relative; background: var(--surface); border: 1px solid var(--rule); border-left-width: 5px; padding: 10px 12px 10px 14px; box-shadow: var(--shadow); min-width: 0; }
.need.sev-crit { border-left-color: var(--crit); }
.need.sev-warn { border-left-color: var(--warn); }
.need.sev-info { border-left-color: var(--info); }
.need-head { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
.age { font-family: var(--mono); font-size: 12px; color: var(--ink-2); font-variant-numeric: tabular-nums; }
.need-ids { display: flex; flex-wrap: wrap; gap: 4px 12px; margin-top: 8px; align-items: center; }
.need-title { margin-top: 6px; color: var(--ink-2); font-size: 13px; }
.need-reason { margin-top: 6px; }
.need-next { margin-top: 6px; padding-top: 6px; border-top: 1px dashed var(--rule-2); font-size: 13px; color: var(--ink-2); }
.need-next::before { content: "next"; font-size: 10px; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); margin-right: 8px; }

/* tables */
.scroll { overflow-x: auto; -webkit-overflow-scrolling: touch; border: 1px solid var(--rule); background: var(--surface); }
table.grid { border-collapse: collapse; width: 100%; min-width: 640px; font-size: 13px; }
table.grid th { text-align: left; font-size: 11px; text-transform: uppercase; letter-spacing: .06em; color: var(--muted); font-weight: 600; padding: 8px 10px; border-bottom: 1px solid var(--rule); background: var(--raised); white-space: nowrap; font-variation-settings: "wdth" 85; }
table.grid th.num { text-align: right; }
table.grid td { padding: 8px 10px; border-bottom: 1px solid var(--rule-2); vertical-align: top; }
table.grid tr:last-child td { border-bottom: 0; }
table.lanes { min-width: 1080px; }
table.lanes td:first-child { position: relative; padding-left: 14px; }
.stripe { position: absolute; left: 0; top: 0; bottom: 0; width: 4px; }
.stripe-crit { background: var(--crit); } .stripe-warn { background: var(--warn); } .stripe-good { background: var(--good); } .stripe-muted { background: var(--rule); }
.status-cell .raw { display: inline-block; max-width: 420px; }
tr.row-needs td { background: color-mix(in srgb, var(--crit-bg) 45%, var(--surface)); }
tr.row-unknown td { background: color-mix(in srgb, var(--raised) 60%, var(--surface)); }

/* chains */
.chains { list-style: none; margin: 0; padding: 0; display: grid; gap: 8px; }
.chain { background: var(--surface); border: 1px solid var(--rule); padding: 8px 12px; }
.chain-head { display: flex; flex-wrap: wrap; gap: 6px 8px; align-items: center; }
.chain-deps { list-style: none; margin: 6px 0 0; padding: 0 0 0 14px; border-left: 2px solid var(--rule); display: grid; gap: 4px; }
.chain-deps li { display: flex; flex-wrap: wrap; gap: 6px 8px; align-items: center; font-size: 13px; }
.chain-deps li::before { content: "↳"; color: var(--muted); }

/* device */
.banner { padding: 10px 12px; border: 1px solid var(--rule); margin-bottom: 10px; }
.banner-crit { border-color: var(--crit); background: var(--crit-bg); color: var(--crit-ink); }
.running { background: var(--surface); border: 1px solid var(--rule); border-left: 5px solid var(--good); padding: 10px 12px; }
.running.idle { border-left-color: var(--rule); }
.running-head { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; }
.running-head .age { margin-left: auto; }

/* owner asks, errors */
.asks { margin: 0; padding-left: 0; list-style: none; display: grid; gap: 6px; }
.asks li { padding: 6px 10px; background: var(--surface); border: 1px solid var(--rule); }
.asknum { color: var(--muted); margin-right: 6px; }
.errs { margin: 0; padding-left: 18px; color: var(--ink-2); font-size: 13px; }
.errs li { margin: 3px 0; }

/* filter hiding */
[hidden] { display: none !important; }
tr[hidden] { display: none !important; }

/* velocity (tsp-mc9m.41.1030.18): inline SVG, page palette, scrolls like the tables at phone width */
.vel-legend { display: flex; flex-wrap: wrap; gap: 4px 16px; color: var(--muted); font-size: 12px; margin: 2px 0 6px; }
.vel-key { display: inline-block; width: 16px; height: 3px; background: var(--k); margin-right: 6px; vertical-align: middle; }
.vel-key.dash { background: repeating-linear-gradient(90deg, var(--k) 0 4px, transparent 4px 7px); }
.vel { padding: 6px 8px; }
.vel svg { display: block; width: 100%; min-width: 600px; height: auto; }
.vel-wow { margin: 4px 0 6px; color: var(--ink-2); font-size: 13px; }

@media (max-width: 600px) {
  h1 { font-size: 19px; }
  .tile .v { font-size: 24px; }
  .filter input { min-width: 140px; }
  .mast { gap: 8px 12px; }
}
@media (prefers-reduced-motion: reduce) {
  * { transition: none !important; animation: none !important; }
}
"""

JS = r"""
(function () {
  var data = null;
  try { data = JSON.parse(document.getElementById('fleet-data').textContent); } catch (e) {}
  var gen = data && data.generated_epoch ? data.generated_epoch * 1000 : null;
  var el = document.getElementById('page-age');
  function fmt(s) {
    s = Math.max(0, Math.floor(s));
    if (s < 60) return s + 's';
    if (s < 3600) return Math.floor(s / 60) + 'm';
    if (s < 86400) return Math.floor(s / 3600) + 'h' + ('0' + Math.floor((s % 3600) / 60)).slice(-2);
    return (s / 86400).toFixed(1) + 'd';
  }
  function tick() {
    if (!gen || !el) return;
    var s = (Date.now() - gen) / 1000;
    el.textContent = 'generated ' + fmt(s) + ' ago';
    el.className = s > 3 * 3600 ? 'stale' : (s > 45 * 60 ? 'old' : '');
    el.title = s > 45 * 60 ? 'This board is older than one refresh cycle; gpu-14 may not have republished.' : 'Refreshed about every 20 minutes during active work.';
  }
  tick(); setInterval(tick, 15000);
  var q = document.getElementById('filter');
  var items = Array.prototype.slice.call(document.querySelectorAll('[data-filter]'));
  function apply() {
    var v = (q.value || '').trim().toLowerCase();
    var terms = v ? v.split(/\s+/) : [];
    items.forEach(function (it) {
      var hay = (it.getAttribute('data-filter') || '').toLowerCase();
      var ok = terms.every(function (t) { return hay.indexOf(t) >= 0; });
      it.hidden = !ok;
    });
    document.getElementById('filter-note').textContent = terms.length ? (items.filter(function (i) { return !i.hidden; }).length + ' of ' + items.length + ' rows match') : '';
  }
  if (q) { q.addEventListener('input', apply); }
})();
"""


def vel_svg(days, label):
    """One inline SVG: opened/closed 7-day means (left axis) + backlog dashed (right axis)."""
    W, H = 720, 210
    ML, MR, MT, MB = 34, 34, 8, 22
    iw, ih = W - ML - MR, H - MT - MB
    n = len(days)
    rate_max = max(max(d["opened_ma7"], d["closed_ma7"]) for d in days) or 1.0
    bl_max = max(d["backlog"] for d in days) or 1

    def x(i):
        return ML + iw * i / max(n - 1, 1)

    def yr(v):
        return MT + ih * (1 - v / rate_max)

    def yb(v):
        return MT + ih * (1 - v / bl_max)

    def pts(key, yf):
        return " ".join(f"{x(i):.1f},{yf(d[key]):.1f}" for i, d in enumerate(days))

    p = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="{e(label)}">']
    for k in range(5):
        v = rate_max * k / 4
        yy = yr(v)
        p.append(f'<line x1="{ML}" y1="{yy:.1f}" x2="{W - MR}" y2="{yy:.1f}" stroke="var(--rule)"/>')
        p.append(f'<text x="{ML - 5}" y="{yy + 3:.1f}" text-anchor="end" font-size="10" fill="var(--muted)">{v:.1f}</text>')
    p.append(f'<text x="{W - MR + 5}" y="{MT + 9}" font-size="10" fill="var(--warn)">{bl_max}</text>')
    p.append(f'<text x="{W - MR + 5}" y="{H - MB + 3:.1f}" font-size="10" fill="var(--warn)">0</text>')
    for i in range(0, n, 7):
        p.append(f'<text x="{x(i):.1f}" y="{H - 6}" text-anchor="middle" font-size="10" fill="var(--muted)">{days[i]["date"][5:]}</text>')
    p.append(f'<polyline fill="none" stroke="var(--info)" stroke-width="2" points="{pts("opened_ma7", yr)}"/>')
    p.append(f'<polyline fill="none" stroke="var(--good)" stroke-width="2" points="{pts("closed_ma7", yr)}"/>')
    p.append(f'<polyline fill="none" stroke="var(--warn)" stroke-width="1.5" stroke-dasharray="4 3" points="{pts("backlog", yb)}"/>')
    p.append("</svg>")
    return "".join(p)


def vel_wow(name, w):
    pct, l7, p7 = w.get("pct"), w.get("last7_closed", 0), w.get("prev7_closed", 0)
    if pct is None:
        txt = "no closes in the previous week to compare against"
    elif pct < 0:
        txt = f"closing {abs(pct):g}% slower than the week before"
    elif pct > 0:
        txt = f"closing {pct:g}% faster than the week before"
    else:
        txt = "close rate unchanged week over week"
    return f'<p class="vel-wow"><b>{e(name)}</b> — {l7} closes in the last 7 days vs {p7} the week before: {e(txt)}.</p>'


def render_velocity(d):
    """(body, count) for the Velocity section, or None when velocity.json is absent/unreadable
    (a velocity failure must never fail the board; refresh.sh prints the SOURCE_ERROR)."""
    try:
        v = json.load(open(VELOCITY))
        sa, sf = v["series"]["all"], v["series"]["ffb"]
        win = v["window"]
    except Exception:
        return None
    legend = ('<p class="vel-legend"><span><i class="vel-key" style="--k:var(--info)"></i>opened/day, 7-d mean</span>'
              '<span><i class="vel-key" style="--k:var(--good)"></i>closed/day, 7-d mean</span>'
              '<span><i class="vel-key dash" style="--k:var(--warn)"></i>backlog (right axis)</span></p>')
    body = [f'<p class="fine">Beads opened vs closed per UTC day, {e(win.get("start"))} … {e(win.get("end"))} '
            f'({len(sa["days"])} days); backlog = created to date minus closed to date. Source: bd list --all via velocity.py.</p>', legend]
    body.append("<h3>All beads (epics excluded)</h3>")
    body.append(vel_wow("all", sa["wow"]))
    body.append(f'<div class="scroll vel">{vel_svg(sa["days"], "all beads: opened and closed per day (7-day means) and backlog, last 60 days")}</div>')
    body.append(f'<h3>First Functional Build — descendants of {e(v.get("ffb_root", "tsp-mc9m.60.29"))}</h3>')
    body.append(vel_wow("ffb", sf["wow"]))
    body.append(f'<div class="scroll vel">{vel_svg(sf["days"], "FFB descendants: opened and closed per day (7-day means) and backlog, last 60 days")}</div>')
    return "".join(body), sum(x["closed"] for x in sa["days"])


def main():
    d = json.load(open(DATA))
    s = d["summary"]
    th = d["thresholds"]
    dev = s["device"]
    needs_sev = "crit" if s["needs"] else "good"
    nk = s.get("needs_by_kind") or {}
    kinds_txt = " · ".join(f"{KIND_LABEL.get(k, k).lower()} {v}" for k, v in nk.items() if v) or "nothing waiting"
    dev_v = dev["running"] or ("HALTED" if dev["halted"] else "idle")
    dev_sev = "crit" if dev["halted"] else ("good" if dev["running"] else ("warn" if dev["pending"] and not dev["runner_alive"] else "info"))
    tiles = [
        ("t-" + needs_sev, "Needs gpu-14", str(s["needs"]), kinds_txt, False),
        ("t-good" if s["lanes_running"] else "t-info", "Lanes running", str(s["lanes_running"]), f'of {s["lanes_total"]} live lanes · {s["lanes_needs"]} need gpu-14 · {s.get("lanes_unchecked", 0)} unchecked', False),
        ("t-warn" if s["lanes_waiting"] else "t-info", "Lanes waiting", str(s["lanes_waiting"]), "CI, device queue or a named blocker", False),
        ("t-info", "Dispatchable", str(s.get("dispatchable_recent", s["dispatchable"])), f'{s["newly_unblocked"]} newly unblocked · {s["dispatchable"] - s.get("dispatchable_recent", 0)} older backlog', False),
        ("t-" + dev_sev, "Device bench", dev_v, f'{dev["pending"]} queued · runner {"alive" if dev["runner_alive"] else "off"}', True),
        ("t-warn" if s["stale"] else "t-info", "Stale beads", str(s["stale"]), f'in_progress, no lane, > {th["STALE_BEAD_H"]} h quiet', False),
        ("t-info", "Owner asks", str(s["owner_asks"]), "live items in gpu14-owner-questions.md", False),
    ]
    strip = "".join(
        f'<div class="tile {cls}"><div class="k">{e(k)}</div><div class="v{" small" if small else ""}">{e(v)}</div><div class="d">{e(dd)}</div></div>'
        for cls, k, v, dd, small in tiles)
    gen = d["generated_at"]
    body = [f'<title>Fleet Board</title>\n<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
            f'<link rel="stylesheet" href="{FONTS}">\n<style>{CSS}</style>\n<div class="wrap">']
    body.append(
        '<header class="mast"><div class="brand"><h1>Fleet Board</h1><span class="who">gpu-14 · A133 / GE8300 campaign · lanes, beads, bench</span></div>'
        f'<div class="meta"><span class="gen" title="UTC">{e(gen)}</span><span id="page-age" aria-live="polite">generated</span>'
        '<label class="filter" for="filter"><span class="lbl">filter</span><input id="filter" type="search" placeholder="bead, lane, run, PR, token…" autocomplete="off"></label>'
        '<span id="filter-note" class="dim"></span></div></header>')
    body.append(f'<section class="strip" aria-label="summary">{strip}</section>')
    body.append(section("needs", "Needs gpu-14 now", s["needs"], render_needs(d),
                        "prioritized: merge-ready, handbacks, boot-ready kits, device, blocked, stale, undriven, newly unblocked"))
    vel = render_velocity(d)
    if vel is not None:
        body.append(section("velocity", "Velocity", vel[1], vel[0],
                            "opened vs closed per day (7-day means), backlog, week over week · last 60 UTC days"))
    body.append(section("lanes", "Lanes", s["lanes_total"], render_lanes(d),
                        f'managed worker runs with a drive log touched in the last {th["LANE_LOG_WINDOW_H"]} h; needs first, then unknown, waiting, running'))
    body.append(section("dispatch", "Dispatchable work", s["dispatchable"], render_dispatchable(d),
                        "bd ready in scope with no lane: parallel set, then what each landing unblocks"))
    body.append(section("device", "Device bench", dev["pending"], render_device(d),
                        "one A133 handheld, strictly serial: queue-runner.sh over queue.tsv"))
    body.append(section("stale", "Stale beads", s["stale"], render_stale(d),
                        f'in_progress, in scope, no lane, no update or comment for {th["STALE_BEAD_H"]} h', open_=bool(s["stale"])))
    body.append(section("owner", "Owner asks", s["owner_asks"], render_owner(d), "live items; defaults proceed without an answer", open_=False))
    body.append(section("about", "Sources and thresholds", len(d.get("errors") or []), render_footer(d),
                        "every number above comes from a live read; nothing is remembered between refreshes except released run ids",
                        open_=bool(d.get("errors"))))
    body.append("</div>")
    # gpu-14 2026-10-11: the inline script needs only the generation time; the full data stays in data.json.
    payload = json.dumps({"generated_at": d.get("generated_at"), "generated_epoch": d.get("generated_epoch")}, separators=(",", ":")).replace("<", "\\u003c").replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    body.append(f'<script id="fleet-data" type="application/json">{payload}</script>')
    body.append(f"<script>{JS}</script>\n")
    out = "\n".join(body)
    tmp = OUT + ".new"
    with open(tmp, "w") as f:
        f.write(out)
    os.replace(tmp, OUT)
    print(f"RENDER ok path={OUT} bytes={len(out.encode())} generated_at={gen}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
