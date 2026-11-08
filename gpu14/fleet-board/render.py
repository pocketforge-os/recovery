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
              "dispatchable": "UNBLOCKED", "budget": "BUDGET", "host": "HOST"}
# host: laptop hygiene and shared checkouts pf-shared-refresh keeps skipping (tsp-mc9m.60.29.84.24)
KIND_SEV = {"merge_ready": "crit", "handback": "crit", "boot_ready": "crit", "device": "crit",
            "undriven": "crit", "budget": "crit", "host": "crit", "blocked": "warn", "stale": "warn",
            "dispatchable": "info"}
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
        return '<p class="empty">Nothing is waiting on gpu-16: no host or quota alarm, no merge-ready PR and no stale in-scope bead. Lane handbacks show in the Lanes table.</p>'
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


def render_reclassified(d, key):
    rows = []
    for source in d.get(key) or []:
        row = dict(source)
        if row.get("attributed_lane"):
            row["lane"] = row["attributed_lane"]
            row["reason"] = f'owned by live ancestor lane {row["attributed_lane"]}: {row.get("reason") or ""}'
        elif key == "blocked":
            bs = ", ".join(x.get("id") or "?" for x in row.get("blockers") or [])
            row["reason"] = f'blocked by {bs}: {row.get("reason") or ""}'
        elif key == "preserved":
            row["reason"] = f'{row.get("preserve_reason")} (until {row.get("preserve_until")}): {row.get("reason") or ""}'
        elif key == "mechanical":
            row["reason"] = f'{row.get("mechanical_reason")}: {row.get("reason") or ""}'
        elif key in ("waiting_owner_attended", "waiting_bench", "blocked_by_bead", "closed_live_run"):
            row["reason"] = (f'owner {row.get("waiting_owner") or "unknown"}: '
                             f'{row.get("waiting_reason") or row.get("preserve_reason") or "waiting"}; '
                             f'{row.get("reason") or ""}')
        rows.append(row)
    clone = dict(d)
    clone["needs"] = rows
    return render_needs(clone)


G16_SEV = {"WORKING": "good", "DONE": "good", "HANDBACK": "warn", "IDLE": "warn", "WAITING": "warn",
           "BLOCKED": "crit", "FAILED": "crit"}
LIVE_SEV = {"working": "good", "idle": "warn", "released": "muted", "unknown": "muted"}


def render_lanes(d):
    """2026-11-02 (tsp-mc9m.60.29.84.14): one row per gpu-16 runs/active.tsv lane (collect.collect_g16_lanes)."""
    lanes = d["lanes"]
    rel = d.get("released_runs") or []
    rel_txt = ('<p class="fine">Released (not shown): '
               + ", ".join(f'{mono(r.get("lane"), "lane")} {mono(r.get("run"))}' for r in rel) + "</p>") if rel else ""
    if not lanes:
        return '<p class="empty">runs/active.tsv lists no live lane.</p>' + rel_txt
    rows = []
    for ln in lanes:
        ls = ln.get("last_status") or {}
        verdict = ls.get("verdict")
        cls = ln["cls"]
        live = ln.get("state") or "unknown"
        sev = CLS_SEV.get(cls, "muted") if cls == "needs" else LIVE_SEV.get(live, "crit")
        state_pill = pill(live, sev)
        if ln.get("stale_quota"):
            state_pill += " " + chip("stale quota (.84.11)", "muted")
        rs = ln.get("run_state") or "?"
        rs_note = f' <span class="dim" title="{e(ln["run_error"])}">!</span>' if ln.get("run_error") else ""
        model = ln.get("model") or "?"
        bead = ln.get("bead")
        bead_cell = mono(bead) + (f'<div class="sub">{e((ln.get("bead_title") or "")[:90])}</div>' if ln.get("bead_title") else "")
        st_cell = ((pill(verdict, G16_SEV.get(verdict, "muted")) + " ") if verdict else "") + \
            (f'<span class="raw">{e((ls.get("raw") or "")[:240])}</span>' if ls else '<span class="dim">no G16 status line in this run\'s receipts</span>')
        if ls and not ls.get("newest"):
            st_cell += '<div class="sub">a newer receipt of this run carries no status line</div>'
        age_tip = (f'{ls.get("receipt")} at {ls.get("ts")} ({ls.get("age_src")})' if ls.get("ts")
                   else f'{ls.get("receipt") or "no receipt"}: time unknown (not the last turn, not the newest log line)')
        mp, mt = ln.get("messages_pending"), ln.get("messages_total")
        ru = ln.get("receipts_unacked") or 0
        inbox = f'{e(mp if mp is not None else "?")} pending <span class="dim">/ {e(mt if mt is not None else "?")}</span>'
        inbox += f'<div class="sub">{chip(f"{ru} receipt(s) unacked", "warn") if ru else "receipts acked"}</div>'
        alive = [n for n, k in (("controller", "controller_alive"), ("reconciler", "reconciler_alive")) if ln.get(k) is False]
        na = ln.get("native_activity_age_s")
        rt_sub = (f'{e(ln.get("runtime") or "?")} · run {e(rs)}{rs_note}'
                  + (f' · act {e(fmt_age(na))}' if na is not None else "")
                  + ("".join(" " + chip(f"{n} dead", "crit") for n in alive)))
        rows.append(
            f'<tr class="row-{cls}" data-filter="{e(ln["lane"])} {e(bead)} {e(ln.get("run"))} {e(verdict)} {e(live)} {e(cls)} {e(model)} {e(ln.get("pr"))} {e(ln.get("bead_title"))}">'
            f'<td><span class="stripe stripe-{sev}"></span>{mono(ln["lane"], "lane")}<div class="sub">{mono(ln.get("run"))} · home {e(ln.get("home") or "?")}</div></td>'
            f'<td>{bead_cell}</td>'
            f'<td><span class="model">{e(model)}</span><div class="sub">{rt_sub}</div></td>'
            f'<td>{state_pill}<div class="sub">{e(ln.get("cls_reason") or "")}</div></td>'
            f'<td class="status-cell">{st_cell}</td>'
            f'<td class="num" title="{e(age_tip)}">{e(fmt_age(ln.get("status_age_s")))}'
            + (f'<div class="sub">{e(ls.get("age_src"))}</div>' if ls.get("age_src") else "") + '</td>'
            f'<td>{inbox}</td>'
            f'<td>{pr_cell(ln.get("pr"), d["prs"])}</td>'
            '</tr>')
    return ('<div class="scroll"><table class="grid lanes"><thead><tr>'
            '<th>Lane / run · home</th><th>Bead</th><th>Model · runtime</th><th>Live state</th><th>Last G16 status line</th>'
            '<th class="num">Age</th><th>Inbox</th><th>PR · CI</th></tr></thead><tbody>'
            + "".join(rows) + "</tbody></table></div>"
            + '<p class="fine">Live state: pf-task run.status (busy = working; awaiting_release = idle, or working while the last '
              'status says WORKING). A run pf-task still reports <code>blocked</code> on a kept usage-limit message after it '
              'completed a turn past that quota episode is shown idle/working with a stale-quota chip (.84.11). Age = the last '
              'status line\'s turn end, or the receipts log time when it is the newest line.</p>' + rel_txt)


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
    """2026-11-02 (tsp-mc9m.60.29.84.14): BENCH + pf-kit-window-runner + the BENCH queue (collect.collect_bench).
    The window queue (window-queue.sh) and the kits queue (queue-runner.sh) are retired."""
    dev = d["device"]
    parts = []
    run = dev.get("runner") or {}
    if run.get("error"):
        rchip = chip("runner unit unreadable", "crit")
    else:
        rchip = chip(f'{run.get("unit")} {run.get("active")}/{run.get("sub")}', "good" if run.get("active") == "active" else "crit")
    rsub = (f'{rchip} deployed {mono(run.get("deployed"))} · pid {e(run.get("pid") or "–")} · since {e(run.get("since") or "?")}'
            + (f' · <span class="raw">{e(run.get("error"))}</span>' if run.get("error") else ""))
    if run.get("active") not in (None, "active"):
        parts.append(f'<div class="banner banner-crit"><strong>pf-kit-window-runner is {e(run.get("active"))}</strong> no kit window can open</div>')
    b = dev.get("bench")
    rep = dev.get("reported") or {}
    rep_txt = " · ".join(f'{e(k)}={mono(v.get("value"))}' + (f' <span class="dim">({e(v.get("receipts_back"))} receipts back)</span>' if v.get("receipts_back") else "")
                         for k, v in ((k, rep.get(k)) for k in ("runner", "dut", "place")) if v) or '<span class="dim">no runner=/dut=/place= in BENCH\'s recent status lines</span>'
    bd_ = dev.get("boundary")
    bnd = (f' · typed boundary DUT {mono(bd_.get("dut"))} place {mono(bd_.get("place"))} <span class="dim">({e(bd_.get("file"))}, {e(short_ts(bd_.get("at")))})</span>'
           if bd_ else "")
    if b:
        ls = b.get("last_status") or {}
        live = b.get("state") or "unknown"
        sev = "crit" if b.get("cls") == "needs" else LIVE_SEV.get(live, "crit")
        vd = ls.get("verdict")
        parts.append(
            f'<div class="running{"" if live == "working" else " idle"}"><div class="running-head">{pill("BENCH " + live, sev)} '
            f'{mono(b.get("run"), "lane")} <span class="dim">home {e(b.get("home"))} · bead</span> {mono(b.get("bead"))}'
            + (" " + chip("stale quota (.84.11)", "muted") if b.get("stale_quota") else "")
            + f'<span class="age" title="{e(ls.get("ts"))} ({e(ls.get("age_src"))})">{e(fmt_age(b.get("status_age_s")))}</span></div>'
            f'<div class="sub">{(pill(vd, G16_SEV.get(vd, "muted")) + " ") if vd else ""}<span class="raw">{e((ls.get("raw") or "no G16_BENCH_STATUS line")[:300])}</span></div>'
            f'<div class="sub">BENCH reported: {rep_txt}{bnd}</div>'
            f'<div class="sub">{rsub} · inbox {e(b.get("messages_pending"))} pending / {e(b.get("messages_total"))}</div></div>')
    else:
        parts.append(f'<div class="running idle"><div class="running-head">{pill("NO BENCH LANE", "crit")} <span class="t">runs/active.tsv has no live BENCH row</span></div>'
                     f'<div class="sub">{rsub}</div></div>')
    wins = dev.get("windows") or []
    wopen = dev.get("windows_open") or []
    for w in wopen:
        parts.append(f'<div class="sub">{chip("window " + w.get("state", "?"), "good")} {mono((w.get("gen") or "")[:8], "lane")} '
                     f'{e(w.get("purpose") or "")} {e(w.get("lane") or "")} · requested {e(short_ts(w.get("requested_at")))}'
                     + (f' · opened {e(short_ts(w.get("opened_at")))} · deadline {e(short_ts(w.get("deadline")))}' if w.get("opened_at") else "") + "</div>")
    q = dev.get("queue") or []
    waiting = sum(1 for r in q if not r.get("answered"))
    parts.append(f'<h3>BENCH queue <span class="count">{waiting}</span><span class="note">each lane\'s latest request relayed to BENCH in the last '
                 f'{e(d["thresholds"].get("BENCH_QUEUE_WINDOW_H"))} h (relay-sent.json) and whether BENCH relayed a result back; {len(q)} lanes</span></h3>')
    if dev.get("sent_error"):
        parts.append(f'<p class="empty">relay-sent.json unreadable: {e(dev["sent_error"])}</p>')
    elif q:
        rows = []
        for r in q:
            a = r.get("answer")
            if a:
                st = a.get("state")
                res = (f'{chip("answered", "good")} {chip(st, typed_sev(st)) if st else ""} <span class="raw">{e(os.path.basename(a.get("file") or ""))}</span>'
                       f'<div class="sub">{e(short_ts(a.get("at")))}' + (f' · reason {e(a.get("reason"))}' if a.get("reason") else "")
                       + (f' · cause {e(a.get("typed_cause"))}' if a.get("typed_cause") else "")
                       + (f' · {r["answers_after"]} relays back since' if r.get("answers_after", 0) > 1 else "") + "</div>")
            else:
                res = chip("no result back yet", "warn")
            rows.append(
                f'<tr data-filter="{e(r.get("lane"))} {e(r.get("cluster"))} {e(r.get("request_file"))} {"answered" if a else "waiting"}">'
                f'<td>{mono(r.get("lane") or r.get("from"), "lane")}<div class="sub">from {e(r.get("from"))}</div></td>'
                f'<td><span class="raw" title="{e(r.get("request"))}">{e(r.get("request_file"))}</span><div class="sub">{mono((r.get("request_sha256") or "")[:12])}</div></td>'
                f'<td class="num">{e(short_ts(r.get("relayed_at")))}<div class="sub">{e(fmt_age(r.get("age_s")))} ago</div></td>'
                f'<td>{res}</td></tr>')
        parts.append('<div class="scroll"><table class="grid"><thead><tr><th>Lane</th><th>Request</th><th class="num">Relayed</th><th>Result back</th></tr></thead><tbody>'
                     + "".join(rows) + "</tbody></table></div>")
    else:
        parts.append('<p class="empty">No request was relayed to BENCH in the window.</p>')
    parts.append(f'<h3>Kit windows <span class="count">{len(wopen)}</span><span class="note">pf-kit-window-runner generations requested in the last '
                 f'{e(d["thresholds"].get("BENCH_QUEUE_WINDOW_H"))} h, newest first; {len(wins)} of {e(dev.get("windows_total", len(wins)))} shown</span></h3>')
    if wins:
        rows = "".join(
            f'<tr data-filter="{e(w.get("gen"))} {e(w.get("purpose"))} {e(w.get("lane"))} {e(w.get("state"))}">'
            f'<td class="num">{e(short_ts(w.get("requested_at")))}</td><td>{mono((w.get("gen") or "")[:8], "lane")}</td>'
            f'<td>{e(w.get("purpose") or "–")}<div class="sub">{e(w.get("lane") or "")}</div></td>'
            f'<td>{chip(w.get("state") or "?", "good" if w.get("open") else ("crit" if "failed" in (w.get("state") or "") or "not finalized" in (w.get("state") or "") else "muted"))}'
            f'<div class="sub">{e(w.get("outcome") or "")}</div></td>'
            f'<td class="num">{e(short_ts(w.get("opened_at")))}<div class="sub">deadline {e(short_ts(w.get("deadline")))}</div></td></tr>'
            for w in wins)
        parts.append('<div class="scroll"><table class="grid"><thead><tr><th class="num">Requested</th><th>Gen</th><th>Purpose · lane</th><th>State · outcome</th><th class="num">Opened</th></tr></thead><tbody>'
                     + rows + "</tbody></table></div>")
    else:
        parts.append('<p class="empty">No kit window was requested in the window.</p>')
    return "".join(parts)


def typed_sev(state):
    s = (state or "").upper()
    return ("good" if s in ("PASS", "OK", "SUCCESS", "CLEAN", "DONE") else ("warn" if s in ("REFUSED", "SKIPPED", "WAITING", "PARTIAL")
            else ("muted" if not s or s == "UNCLASSIFIED" else "crit")))


def render_results(d):
    """2026-11-02 (tsp-mc9m.60.29.84.14): typed outcomes of the last 24 h. 2026-11-08 (tsp-hqm1p.181): kit-window close records plus the
    BENCH-RESULT / DEPLOY-RECEIPT files; a source that yielded no row while windows closed is a visible WARN, not an empty-looking section."""
    r = (d.get("device") or {}).get("results") or {}
    parts = []
    if r.get("error"):
        parts.append(f'<p class="empty">Typed results unreadable: {e(r["error"])}</p>')
    warns = r.get("warns") or []
    for w in warns:
        n = w.get("windows_closed") or 0
        parts.append(f'<div class="banner banner-warn"><strong>Result source empty but {e(n)} window{"" if n == 1 else "s"} closed</strong> '
                     f'in the last {e(r.get("window_h"))} h: {e(w.get("text"))}.</div>')
    groups = r.get("groups") or []
    if groups:
        rows = "".join(
            f'<tr data-filter="{e(g["kind"])} {e(g["state"])} {e(g["reason"])} {e(g["typed_cause"])} {e(" ".join(g.get("lanes") or []))}">'
            f'<td class="num">{e(g["count"])}</td><td>{chip(g["state"], g.get("sev") or typed_sev(g["state"]))}</td>'
            f'<td><span class="raw">{e(g["reason"])}</span></td><td><span class="raw">{e(g["typed_cause"])}</span></td>'
            f'<td>{e(g["kind"])}</td><td>{" ".join(mono(x, "lane") for x in (g.get("lanes") or [])[:4]) or "–"}</td>'
            f'<td class="num">{e(short_ts(g.get("latest_at")))}</td></tr>'
            for g in groups)
        parts.append('<div class="scroll"><table class="grid"><thead><tr><th class="num">n</th><th>State</th><th>Reason</th><th>Typed cause</th>'
                     '<th>Kind</th><th>Lanes</th><th class="num">Latest</th></tr></thead><tbody>' + rows + "</tbody></table></div>")
        items = r.get("items") or []
        rows = "".join(
            f'<tr data-filter="{e(it.get("file"))} {e(it.get("lane"))} {e(it.get("state"))} {e(it.get("reason"))}">'
            f'<td class="num">{e(short_ts(it.get("at")))}</td><td>{mono(it.get("lane") or it.get("lane_hint"), "lane")}</td>'
            f'<td>{chip(it.get("state") or "–", typed_sev(it.get("state")))}</td>'
            f'<td><span class="raw" title="{e(it.get("path"))}">{e(it.get("file"))}</span><div class="sub">{e(it.get("reason") or "")}'
            + (f' · {e(it.get("typed_cause"))}' if it.get("typed_cause") else "")
            + (f' · lane reason {e(it.get("lane_reason"))}' if it.get("lane_reason") else "") + '</div></td></tr>'
            for it in items)
        parts.append(f'<details class="more"><summary>{len(items)} of {e(r.get("total"))} result files, newest first</summary>'
                     '<div class="scroll"><table class="grid"><thead><tr><th class="num">At</th><th>Lane</th><th>State</th><th>File · reason · cause</th></tr></thead><tbody>'
                     + rows + "</tbody></table></div></details>")
    elif not r.get("error") and not warns:
        parts.append(f'<p class="empty">No typed result in the last {e(r.get("window_h"))} h.</p>')
    kinds = " · ".join(f'{e(n)} {e(k)}' for k, n in sorted((r.get("by_kind") or {}).items(), key=lambda kv: -kv[1]))
    parts.append(f'<p class="fine">Kit windows: the close record (terminal.json, a failed boot-open, a failed runner) of the generations under {mono(r.get("windows_root"))} '
                 f'closed in the last {e(r.get("window_h"))} h; State = the window\'s End, FAILED / FAILED_DIRTY when a step failed, Typed cause = the failing steps. '
                 f'Files: *BENCH-RESULT*.txt (lane notes, State from the Outcome line), BENCH-RESULT*.json (v1: Outcome, Failure.Error) and DEPLOY-RECEIPT*.txt under '
                 f'{mono(r.get("root"))} (depth {e(r.get("depth"))}) modified in the last {e(r.get("window_h"))} h. Grouped by State / Reason / TypedCause. '
                 f'Lane = the lane BENCH relayed the file to, else the window\'s lane or the file\'s own lane or discriminator. '
                 f'{e(r.get("windows_closed", 0))} windows closed in the window' + (f' · rows: {kinds}' if kinds else '') + '.</p>')
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


# 2026-10-20 (tsp-mc9m.41.1030.55): beads another coordinator drives are not the board owner's to act on; each gets
# its own muted group instead of a row in "Needs".
def render_owned(d, who):
    rows = [o for o in d.get("owned") or [] if o.get("assignee") == who]
    if not rows:
        return f'<p class="empty">No in-scope bead without a lane is assigned to {e(who)}.</p>'
    body = "".join(
        f'<tr data-filter="{e(o["id"])} {e(o["title"])} {e(o.get("parent"))} {e(who)}"><td>{mono(o["id"])}</td>'
        f'<td class="num">{e(fmt_age(o.get("age_s")))}</td><td>{e(o.get("status"))}</td><td>{e(o.get("tier") or "–")}</td>'
        f'<td>{e(o["title"])}<div class="sub">under {mono(o.get("parent"))} · assignee {e(who)}</div></td>'
        f'<td class="num">{e(short_ts(o.get("updated_at")))}</td></tr>'
        for o in rows[:STALE_ROWS])
    more = (f'<details class="more"><summary>{len(rows) - STALE_ROWS} more (data.json owned)</summary><p class="idlist">'
            + " ".join(mono(o["id"]) for o in rows[STALE_ROWS:]) + "</p></details>") if len(rows) > STALE_ROWS else ""
    return ('<div class="scroll"><table class="grid"><thead><tr><th>Bead</th><th class="num">Idle</th><th>Status</th>'
            '<th>Tier</th><th>Title</th><th class="num">Updated</th></tr></thead><tbody>' + body + "</tbody></table></div>" + more)


def render_owner(d):
    """2026-11-02 (tsp-mc9m.60.29.84.14): open tickets in the owner intake (pf-owner-intake.sh list)."""
    o = d["owner_asks"]
    ids = ", ".join(o.get("ids") or []) or "?"
    head = ""
    if o.get("error"):
        head = f'<p class="empty">Owner intake unreadable: {e(o["error"])}</p>'
    if not o["items"]:
        return head + (f'<p class="empty">No open tickets in the owner intake (ids {e(ids)}; {e(o.get("listed", 0))} listed, '
                       f'{e(o.get("resolved", 0))} resolved).</p>' if not o.get("error") else "")
    rows = "".join(
        f'<tr data-filter="{e(i.get("ticket"))} {e(i.get("status"))} {e(i.get("bead"))} {e(i.get("title"))}">'
        f'<td>{mono(i.get("ticket"))}<div class="sub">{e(i.get("id"))}</div></td>'
        f'<td>{chip(i.get("status") or "?", "crit" if i.get("status") in ("pending", "stranded") else "warn")}</td>'
        f'<td class="num">{e(i.get("round"))}</td><td>{mono(i.get("bead"))}</td><td>{e(i.get("title") or "")}</td></tr>'
        for i in o["items"])
    return head + ('<div class="scroll"><table class="grid"><thead><tr><th>Ticket</th><th>Status</th><th class="num">Round</th>'
                   '<th>Bead</th><th>Bead title</th></tr></thead><tbody>' + rows + "</tbody></table></div>"
                   + f'<p class="fine">pf-owner-intake.sh list --id {e(ids)}: {e(o.get("listed", 0))} tickets, {e(o.get("resolved", 0))} resolved (hidden).</p>')


# 2026-10-20 (gpu-14): hardware & driver rows, tier priorities, open backlog (collect.py build_hardware/collect_backlog).
HW_STATE_ORDER = ("Working", "Partial", "Detected", "Broken", "Untested", "Parked", "HW-limit", "Deferred")
HW_STATE_SEV = {"Working": "good", "Partial": "warn", "Detected": "info", "Broken": "crit", "Untested": "warn",
                "Parked": "muted", "HW-limit": "muted", "Deferred": "muted"}
BEAD_STATUS_SEV = {"closed": "good", "in_progress": "info", "open": "muted", "blocked": "warn", "deferred": "muted",
                   "missing": "crit"}
HW_FLAG = {"unowned": ("unowned", "crit", "not Working/HW-limit/Parked/Deferred and no lane, lane-queue entry, queued kit or batch mate covers it"),
           "no_anchor": ("no anchor", "crit", "no anchor bead: file one and add it to hardware-rows.json"),
           "anchor_closed": ("anchor closed", "warn", "every anchor bead is closed but the row is not Working: post an HW_ROW"),
           "evidence_old": ("evidence old", "warn", "evidence older than the threshold: post a fresh HW_ROW")}
LANES_SHOW = 3


def hw_tally_line(tally, flags=None, seeded=None, total=None):
    parts = [pill(f"{s} {tally[s]}", HW_STATE_SEV.get(s, "muted")) for s in HW_STATE_ORDER if tally.get(s)]
    parts += [pill(f"{s} {n}", "muted") for s, n in tally.items() if n and s not in HW_STATE_ORDER]
    for f, n in (flags or {}).items():
        if n and f in HW_FLAG:
            parts.append(chip(f"{HW_FLAG[f][0]} {n}", HW_FLAG[f][1]))
    if seeded is not None and total:
        parts.append(f'<span class="dim">{seeded} of {total} still on the 10-18 seed (no HW_ROW yet)</span>')
    return '<p class="tally">' + " ".join(parts) + "</p>"


def anchor_cell(r):
    if not r.get("anchor_status"):
        return chip("no anchor", "crit")
    return " ".join(f'{mono(a["id"])} {chip(a["status"], BEAD_STATUS_SEV.get(a["status"], "muted"))}' for a in r["anchor_status"])


def open_cell(r):
    top = "".join(f'<li>{mono(b["id"])} {chip(b["status"], BEAD_STATUS_SEV.get(b["status"], "muted"))} '
                  f'<span class="t">{"P" + str(b["priority"]) + " · " if b.get("priority") is not None else ""}{e((b.get("title") or "")[:70])}</span></li>'
                  for b in r.get("open_top") or [])
    more = r.get("open_count", 0) - len(r.get("open_top") or [])
    return (f'<div class="sub">anchor {anchor_cell(r)}</div>'
            f'<div><span class="count">{r.get("open_count", 0)}</span> <span class="dim">open under it</span></div>'
            + (f'<ul class="toplist">{top}</ul>' if top else "")
            + (f'<div class="sub">+{more} more</div>' if more > 0 else ""))


# 2026-11-05 (tsp-hqm1p.100): how collect.py linked a kit window's bead to a row (window_links)
WINDOW_VIA = {"bead": "the window's bead is the row's anchor or sits under it",
              "named": "the window's bead declares the row's anchor as its one target row",
              "comment": "the row's anchor bead comments name this window (its generation or its package)",
              "cluster": "the lane cluster that owns the row ran the window (the window carries no row list; it may never have touched this row)"}


def window_line(r):
    """The latest kit-window result derived for the row, beside (never instead of) the HW_ROW state."""
    if not r.get("window_at"):
        return ""
    res = r.get("window_result") or "?"
    tip = (f'Derived from the kit-window runner: {r.get("window_source") or ""} ({r.get("window_purpose") or "?"}, '
           f'{r.get("window_reason") or "?"}). Link: {WINDOW_VIA.get(r.get("window_via"), r.get("window_via"))}. '
           f'It is evidence a window ran, not a state change; the state is the latest HW_ROW.')
    return (f'<div class="sub" title="{e(tip)}">window {e(short_ts(r.get("window_at")))} '
            f'{pill(res, "good" if res == "ok" else "crit")} gen {e((r.get("window_generation") or "?")[:8])} '
            f'{mono(r.get("window_bead"))} · via {e(r.get("window_via") or "?")} '
            f'<span class="dim">({e(r.get("window_ok_n", 0))} ok / {e(r.get("window_fail_n", 0))} fail)</span></div>')


def lane_window_line(r):
    """A window a lane owning the row ran, with nothing tying it to this row (cluster tier): dim, no outcome colour."""
    if not r.get("lane_window_at"):
        return ""
    n = int(r.get("lane_window_ok_n") or 0) + int(r.get("lane_window_fail_n") or 0)
    tip = (f'A lane that owns this row ran a kit-window ({r.get("lane_window_source") or ""}; {r.get("lane_window_purpose") or "?"}). '
           f'The window\'s bead neither sits under the row nor declares it as its target, so it may never have tested it: '
           f'its outcome ({r.get("lane_window_result") or "?"}, {r.get("lane_window_reason") or "?"}) is not evidence for this row, '
           f'and it is not counted in rows with new evidence. {n} such closed window{"s" if n != 1 else ""} in the lookback.')
    return (f'<div class="sub dim" title="{e(tip)}">lane window {e(short_ts(r.get("lane_window_at")))} '
            f'gen {e((r.get("lane_window_generation") or "?")[:8])} {mono(r.get("lane_window_bead"))} · cluster only</div>')


def window_summary_line(hw):
    """Headline under the hardware tally: rows whose latest window is tied to them, and (apart) rows that only had a lane window."""
    if not hw or "rows_with_window" not in hw:
        return ""
    d = round((hw.get("windows_lookback_h") or 0) / 24)
    return (f'<p class="fine">Device windows, last {e(d)} d: <strong>{e(hw.get("rows_with_window", 0))} rows</strong> have a closed window '
            f'whose bead sits under the row or declares it. Apart, lane windows (cluster only): '
            f'<strong>{e(hw.get("rows_with_lane_window", 0))} rows</strong> had a window run by a lane that owns them, none tied to the row, '
            f'so it is not row evidence.</p>')


def kit_line(k):
    """periph-g2 (kit 2ae0453e, queued #4): a window-queue kit covering the row (collect.row_kits)."""
    where = "in window now" if k.get("active") else f'queued #{k.get("position")}'
    via = "" if k.get("via") == "package" else f' · via {k.get("via")}'
    tip = (f'{k.get("label") or ""} {k.get("pkg") or ""}: '
           + (f'open kit window held by {k.get("bead")}: {WINDOW_VIA.get(k.get("via"))}' if k.get("via") in WINDOW_VIA
              else f'the package names {k.get("bead")}' if k.get("via") == "package"
              else f'{k.get("bead")} comments name this kit (path family or generation)' if k.get("via") == "comment"
              else f'{k.get("bead")} shares {k.get("via")} and the package names it'))
    return (f'<div title="{e(tip)}">{mono(k.get("lane"), "lane")} '
            f'<span class="dim">(kit {e((k.get("gen") or "?")[:8])}, {e(where)}{e(via)})</span></div>')


def lanes_cell(lanes, queued, kits=(), batch_lanes=()):
    kit_lanes = {k.get("lane") for k in kits}
    lanes = [l for l in lanes if l not in kit_lanes]   # a lane shown with its kit is not repeated
    out = " ".join(mono(l, "lane") for l in lanes[:LANES_SHOW])
    if len(lanes) > LANES_SHOW:
        out += f' <span class="dim" title="{e(" ".join(lanes))}">+{len(lanes) - LANES_SHOW}</span>'
    out += "".join(kit_line(k) for k in kits[:2])
    if len(kits) > 2:
        out += f'<div class="sub" title="{e(" ".join(k.get("lane") or "?" for k in kits[2:]))}">+{len(kits) - 2} more kits</div>'
    if batch_lanes:
        out += '<div class="sub">' + ", ".join(f'{e(x["lane"])} ({e(x["via"])}: {e(x["bead"])})' for x in batch_lanes[:2]) + "</div>"
    if queued:
        q = ", ".join(f'{e(x["lane"])} ({e(x["bead"])})' for x in queued[:2]) + (f" +{len(queued) - 2}" if len(queued) > 2 else "")
        out += f'<div class="sub">queued: {q}</div>'
    return out or '<span class="dim">–</span>'


def hw_row_html(r, second):
    st = r.get("state") or "?"
    if r.get("state_source") == "hw_row":
        src = f'HW_ROW {e(short_ts(r.get("evidence_at")))}' + (f' · {e(r.get("evidence_by"))}' if r.get("evidence_by") else "")
    else:
        src = f'seed {e((r.get("seed_at") or "")[5:10])}'
    ev = r.get("evidence") or ""
    build = f'build {e(r["build"])}' if r.get("build") else '<span class="dim">no build named</span>'
    flags = " ".join(chip(HW_FLAG[f][0], HW_FLAG[f][1]).replace('<span ', f'<span title="{e(HW_FLAG[f][2])}" ', 1)
                     for f in r.get("flags") or [] if f in HW_FLAG)
    ff = " ".join(HW_FLAG[f][0] for f in r.get("flags") or [] if f in HW_FLAG)
    return (f'<tr data-filter="{e(r.get("id"))} {e(r.get("name"))} {e(r.get("subsystem") or r.get("area"))} {e(st)} '
            f'{e(" ".join(r.get("anchor") or []))} {e(" ".join(r.get("lanes") or []))} '
            f'{e(" ".join(k.get("lane") or "" for k in r.get("kits") or []))} {e(ff)}">'
            f'<td><strong>{e(r.get("name"))}</strong><div class="sub">'
            + " · ".join(x for x in (e(r.get("subsystem") or ""), e(r.get("scope") or ""), mono(r.get("id"))) if x)
            + '</div></td>'
            f'<td>{second}</td>'
            f'<td>{pill(st, HW_STATE_SEV.get(st, "muted"))}<div class="sub">{src}</div></td>'
            f'<td class="evid"><span class="evtext"{(" title=" + chr(34) + e(ev[:600]) + chr(34)) if len(ev) > 180 else ""}>{e(ev[:180])}{"…" if len(ev) > 180 else ""}</span>'
            f'<div class="sub">{build}</div>{window_line(r)}{lane_window_line(r)}</td>'
            f'<td class="opencell">{open_cell(r)}</td>'
            f'<td>{lanes_cell(r.get("lanes") or [], r.get("queued") or [], r.get("kits") or [], r.get("batch_lanes") or [])}</td>'
            f'<td class="num">{e(short_ts(r.get("last_activity")))}<div class="sub">{e(fmt_age(r.get("last_activity_age_s")))} ago</div></td>'
            f'<td>{flags or "<span class=dim>–</span>"}</td></tr>')


def render_hardware(d):
    hw = d.get("hardware") or {}
    rows = hw.get("rows") or []
    if not rows:
        why = hw.get("error") or "no rows (see Sources and thresholds for errors)"
        return f'<p class="empty">Hardware rows unavailable: {e(why)}</p>'
    seeded = sum(1 for r in rows if r.get("state_source") == "seed")
    head = ('<thead><tr><th>Block</th><th>{second}</th><th>State</th><th>Evidence · build</th><th>Open beads</th>'
            '<th>Lane</th><th class="num">Last activity</th><th>Flags</th></tr></thead>')
    body = "".join(hw_row_html(r, f'{e(r.get("driver") or "–")}<div class="sub">{chip(r.get("driver_source") or "?", "neutral")}</div>')
                   for r in rows)
    parts = [hw_tally_line(hw.get("tally") or {}, hw.get("flags"), seeded, len(rows)), window_summary_line(hw),
             '<div class="scroll"><table class="grid hw">' + head.format(second="Driver · source") + "<tbody>" + body + "</tbody></table></div>"]
    pr = d.get("priorities") or {}
    goals = pr.get("goals") or []
    if goals:
        parts.append(f'<h3>Tier priorities <span class="count">{sum(len(g.get("rows") or []) for g in goals)}</span></h3>')
        parts.append(hw_tally_line(pr.get("tally") or {}, pr.get("flags")))
        gb = []
        for g in goals:
            tier = f'Tier {g["tier"]}' if g.get("tier") else "Not tiered"
            ga = (" · goal " + " ".join(f'{mono(a["id"])} {chip(a["status"], BEAD_STATUS_SEV.get(a["status"], "muted"))}'
                                        for a in g.get("anchor_status") or [])) if g.get("anchor_status") else ""
            gl = g.get("lanes") or []
            gt = " ".join(pill(f"{s} {g['tally'][s]}", HW_STATE_SEV.get(s, "muted")) for s in HW_STATE_ORDER if (g.get("tally") or {}).get(s))
            gb.append(f'<tr class="grp" data-filter="{e(g.get("id"))} {e(g.get("name"))} {e(tier)}"><td colspan="8">'
                      f'<div class="grp-head"><span class="lbl">{e(tier)}</span><strong>{e(g.get("name"))}</strong>{ga}'
                      f'<span class="dim">{g.get("open_count", 0)} open under goal · {len(gl)} lane{"s" if len(gl) != 1 else ""}</span> {gt}</div>'
                      f'<div class="sub">{e(g.get("why") or "")}</div></td></tr>')
            gb += [hw_row_html(r, e(r.get("area") or "–")) for r in g.get("rows") or []]
        parts.append('<div class="scroll"><table class="grid hw">' + head.format(second="Area") + "<tbody>" + "".join(gb) + "</tbody></table></div>")
    parts.append(f'<p class="fine">Rows: {mono(hw.get("source"))}. State = the latest <code>HW_ROW state=&lt;S&gt; build=&lt;N&gt; evidence=&lt;text&gt;</code> '
                 f'comment on an anchor bead (optional <code>row=&lt;id&gt;</code>), else the 10-18 seed. Evidence old after '
                 f'{e(hw.get("evidence_old_d"))} d. Lane = a live lane on the anchor or a descendant (its bead, a row its cluster bead lists under ## Rows, or its latest '
                 f'lane-queue pop); queued = a lane-queue line; kit = a window-queue kit whose package names the anchor or a descendant, '
                 f'or that the anchor\'s comments name (path family or generation), or a <code>batch:&lt;slug&gt;</code> mate\'s lane or kit '
                 f'({e(hw.get("kits_scanned", 0))} kit-window requests and queued kits checked). Window = the latest closed kit-window result '
                 f'whose bead is the anchor or sits under it, declares it as its one target row (<code>row &lt;id&gt;</code> / '
                 f'<code>evidence to</code> in the bead text), or is named by an anchor comment (generation or package path), shown with its ok/fail; '
                 f'{e(hw.get("windows_lookback_h", 0))} h back; {e(hw.get("windows_unmapped", 0))} windows reached no row. Lane window = a window '
                 f'whose bead only sits in a cluster that lists the row ({e(hw.get("windows_lane_only", 0))} windows): shown dim, no outcome, and '
                 f'never counted as row evidence. Neither changes the state. '
                 f'{e(hw.get("comments_fetched", 0))} anchor comment lists re-read this refresh.</p>')
    return "".join(parts)


def render_backlog(d):
    b = d.get("backlog")
    if not b:
        return '<p class="empty">Backlog unavailable (bd list failed; see Sources and thresholds).</p>'
    n = lambda v: f'{v:,}' if v else '<span class="dim">–</span>'
    ot, p0, p1, old, na = b["open_total"], b["p0"], b["p1"], b["older_14d"], b["areas_total"]
    parts = ['<p class="tally">' + " ".join([
        pill(f"{ot:,} open", "info"), pill(f"P0 {p0}", "crit" if p0 else "muted"), pill(f"P1 {p1}", "warn" if p1 else "muted"),
        chip(f"{old:,} older than 14 d", "warn" if old else "muted"), f'<span class="dim">{na:,} areas</span>']) + "</p>"]
    hdr = "".join(f'<th class="num">{e(x)}</th>' for x in b["buckets"])
    rows = "".join(f'<tr data-filter="{e(a["area"])}"><td>{mono(a["area"])}</td><td class="num">{n(a["total"])}</td>'
                   f'<td class="num">{n(a["p0"])}</td><td class="num">{n(a["p1"])}</td>'
                   + "".join(f'<td class="num">{n(c)}</td>' for c in a["counts"]) + "</tr>" for a in b["areas"])
    o = b.get("other") or {}
    if o.get("areas"):
        rows += (f'<tr><td><span class="dim">{o["areas"]:,} other areas</span></td><td class="num">{n(o["total"])}</td>'
                 f'<td class="num">{n(o["p0"])}</td><td class="num">{n(o["p1"])}</td>'
                 + "".join(f'<td class="num">{n(c)}</td>' for c in o["counts"]) + "</tr>")
    rows += (f'<tr class="tot"><td>All open</td><td class="num">{n(b["open_total"])}</td><td class="num">{n(b["p0"])}</td>'
             f'<td class="num">{n(b["p1"])}</td>' + "".join(f'<td class="num">{n(c)}</td>' for c in b["totals"]) + "</tr>")
    parts.append('<div class="scroll"><table class="grid backlog"><thead><tr><th>Area</th><th class="num">Open</th>'
                 f'<th class="num">P0</th><th class="num">P1</th>{hdr}</tr></thead><tbody>{rows}</tbody></table></div>')
    bt = b.get("batches") or []
    parts.append(f'<h3>Batches <span class="count">{len(bt)}</span></h3>')
    if not bt:
        parts.append('<p class="empty">No batches labelled yet (bd label <code>batch:&lt;slug&gt;</code>).</p>')
    else:
        brow = "".join(
            f'<tr data-filter="batch:{e(g["batch"])}"><td>{mono("batch:" + g["batch"])}</td><td class="num">{n(g["total"] - g["closed"])}</td>'
            f'<td class="num">{n(g["open"])}</td><td class="num">{n(g["in_progress"])}</td><td class="num">{n(g["blocked"])}</td>'
            f'<td class="num">{n(g["closed"])}</td><td><ul class="toplist">'
            + "".join(f'<li>{mono(x["id"])} {chip(x["status"], BEAD_STATUS_SEV.get(x["status"], "muted"))} <span class="t">{e(x["title"][:70])}</span></li>' for x in g.get("top") or [])
            + "</ul></td></tr>" for g in bt)
        parts.append('<div class="scroll"><table class="grid"><thead><tr><th>Batch</th><th class="num">Not closed</th><th class="num">Open</th>'
                     '<th class="num">In progress</th><th class="num">Blocked</th><th class="num">Closed</th><th>Top items</th></tr></thead>'
                     f'<tbody>{brow}</tbody></table></div>')
    parts.append('<p class="fine">Every bead with status open, all scopes (in_progress beads are in Lanes, Stale and Owned). '
                 'Age from created_at; area = the id cut to two segments. Batches count every status.</p>')
    return "".join(parts)


def render_footer(d):
    th = d["thresholds"]
    errs = d.get("errors") or []
    parts = []
    if errs:
        parts.append(f'<h3>Source errors <span class="count">{len(errs)}</span></h3><ul class="errs">'
                     + "".join(f'<li>{mono(x["source"])} <span class="raw">{e(x["error"])}</span></li>' for x in errs) + "</ul>")
    keys = ["BENCH_QUEUE_WINDOW_H", "WINDOWS_SHOW", "BENCH_KV_RECEIPTS", "TYPED_RESULTS_WINDOW_H", "TYPED_RESULTS_DEPTH",
            "TYPED_RESULTS_SHOW", "OWNER_INTAKE_TIMEOUT_S", "STALE_BEAD_H", "STALE_LOOKBACK_H", "NEWLY_UNBLOCKED_H",
            "PARALLEL_SHOW", "CHAINS_SHOW", "HW_EVIDENCE_OLD_D", "HW_COMMENTS_BUDGET_S", "BACKLOG_AREAS_SHOW"]
    ths = " ".join(f'<span class="th"><span class="lbl">{e(k)}</span>{mono(th.get(k))}</span>' for k in keys if k in th)
    roots = " ".join(mono(r) for r in d.get("campaign_roots", []))
    parts.append(f'<p class="fine">Scope roots: {roots}</p>')
    parts.append(f'<p class="fine thresholds">Thresholds: {ths}</p>')
    parts.append(f'<p class="fine">Sources: bd list --all / bd ready / bd comments (stale candidates, and hardware-row anchors when their comment count moves); hardware-rows.json; gpu-16 runs/active.tsv + pf-task run.status per run on its home (read-only) + runs/receipts-&lt;NAME&gt;.jsonl (G16 status lines); gh pr view for referenced PRs; shared-refresh.json (pf-shared-refresh checkout status); systemctl --user show pf-kit-window-runner.service, kit-windows/, runs/relay-sent.json and typed kit-window close records and BENCH-RESULT / DEPLOY-RECEIPT files; pf-owner-intake.sh list. The window queue, queue.tsv and gpu14-owner-questions.md are retired and not read. Collected on {e(d.get("host"))} in {e(d.get("runtime_s"))} s. Generated by /home/matt/recovery/gpu14/fleet-board/refresh.sh.</p>')
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
.banner-warn { border-color: var(--warn); background: var(--warn-bg); color: var(--warn-ink); }
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
/* rtl scroller: at phone width the chart opens scrolled to the newest days; the svg itself stays ltr */
.vel { padding: 6px 8px; direction: rtl; }
.vel svg { display: block; width: 100%; min-width: 600px; height: auto; direction: ltr; }
.vel-wow { margin: 4px 0 6px; color: var(--ink-2); font-size: 13px; }

/* hardware & drivers, tier priorities, open backlog (2026-10-20) */
.tally { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin: 4px 0 10px; }
table.hw { min-width: 1280px; }
table.hw td:nth-child(2) { max-width: 230px; }
table.hw td.evid { min-width: 280px; max-width: 380px; }
.evtext { color: var(--ink-2); font-size: 12.5px; line-height: 1.4; word-break: break-word; }
table.hw td.opencell { min-width: 250px; max-width: 340px; }
.toplist { list-style: none; margin: 4px 0 0; padding: 0; display: grid; gap: 3px; font-size: 12px; }
.toplist li { line-height: 1.5; }
.toplist .chip { padding: 2px 5px; font-size: 10px; }
.opencell .sub .chip, .opencell .sub .id { font-size: 10px; }
tr.grp td { background: var(--raised); border-top: 2px solid var(--rule); }
.grp-head { display: flex; flex-wrap: wrap; gap: 6px 10px; align-items: center; }
table.backlog { min-width: 620px; }
table.backlog tr.tot td { font-weight: 600; border-top: 2px solid var(--rule); background: var(--raised); }

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
    el.title = s > 45 * 60 ? 'This board is older than one refresh cycle; the pf-fleet-board timer may have stopped.' : 'Refreshed every 15 minutes by pf-fleet-board.timer.';
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
    """(body, count) for the Velocity section, or None when velocity.json is absent/unreadable, or older
    than this refresh's data.json (a failed velocity step must never show a previous snapshot as current;
    refresh.sh prints the SOURCE_ERROR). Both generated_at stamps are UTC %Y-%m-%dT%H:%M:%SZ."""
    try:
        v = json.load(open(VELOCITY))
        sa, sf = v["series"]["all"], v["series"]["ffb"]
        win = v["window"]
        if str(v["generated_at"]) < str(d["generated_at"]):
            return None
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


RUNNER_FLEET_TOOL = os.environ.get("FB_RUNNER_FLEET_TOOL",
                                   os.path.expanduser("~/.local/libexec/pf-runner-fleet-status/pf-runner-fleet-status.py"))
# 2026-10-20 (tsp-73epc.2.2.2): the status file is overridable (hermetic tests) and is read here too, so a missing,
# unreadable or old status.json renders stale whatever the installed tool version says.
RUNNER_FLEET_STATUS = os.environ.get("FB_RUNNER_FLEET_STATUS",
                                     os.path.expanduser("~/.local/state/pf-runner-fleet-status/status.json"))
RUNNER_FLEET_STALE_S = 7200     # checked_at older than 2 h is stale


def render_runner_fleet():
    """tsp-73epc.2.2.2: the runner-fleet section from pf-runner-fleet-status status.json (zero LLM).
    The tool renders stale/missing as level "stale"; a tool failure is shown as stale too, never omitted."""
    import subprocess
    import time
    try:
        r = subprocess.run([sys.executable, RUNNER_FLEET_TOOL, "board", "--status", RUNNER_FLEET_STATUS],
                           capture_output=True, text=True, timeout=30)
        if r.returncode != 0:   # a failed tool is never a fresh result, whatever it printed (review 5589706893)
            raise RuntimeError(f"tool exit {r.returncode}")
        out = json.loads(r.stdout)
        body, count, level, note = out["body"], out["count"], out["level"], out["note"]
    except Exception as exc:
        return (f'<p class="empty">{pill("stale", "crit")} runner fleet status unavailable: {e(type(exc).__name__)}</p>',
                0, "stale", "stale: renderer failed")
    try:
        with open(RUNNER_FLEET_STATUS) as f:
            age = time.time() - float(json.load(f)["checked_at"])
    except Exception:
        age = None
    if level != "stale" and (age is None or age > RUNNER_FLEET_STALE_S):
        why = "status.json missing or unreadable" if age is None else f"last check {fmt_age(age)} ago"
        body = (f'<p class="empty">{pill("stale", "crit")} runner fleet status is stale: {e(why)}; '
                f'the tool reported {e(level)}.</p>' + body)
        level, note = "stale", f"stale: {why}"
    return body, count, level, note


def device_tile(dev):
    """Device bench tile -> (severity, value, detail). 2026-11-02: BENCH + pf-kit-window-runner; the window queue is
    retired."""
    if dev.get("halted"):
        sev, v = "crit", "RUNNER DOWN"
    elif dev.get("kit_running"):
        sev, v = "good", f'window {(dev.get("running") or "?")[:28]}'
    else:
        sev, v = ("warn" if dev.get("pending") else "info"), "idle"
    dd = (f'{dev.get("pending", 0)} of {dev.get("queue_total", 0)} requests without a result · BENCH {dev.get("bench_state") or "?"}'
          + (f' ({dev["bench_verdict"]})' if dev.get("bench_verdict") else "") + f' · {dev.get("results_24h", 0)} results 24 h')
    if dev.get("results_warn"):   # tsp-hqm1p.181: a blank result source is visible on the tile, not only inside the section
        dd += f' · {dev["results_warn"]} result source{"" if dev["results_warn"] == 1 else "s"} empty while windows closed'
        sev = "warn" if sev == "info" else sev
    return sev, v, dd


def main():
    d = json.load(open(DATA))
    s = d["summary"]
    th = d["thresholds"]
    dev = s["device"]
    needs_sev = "crit" if s["needs"] else "good"
    nk = s.get("needs_by_kind") or {}
    kinds_txt = " · ".join(f"{KIND_LABEL.get(k, k).lower()} {v}" for k, v in nk.items() if v) or "nothing waiting"
    dev_sev, dev_v, dev_d = device_tile(dev)
    tiles = [
        ("t-" + needs_sev, "Needs gpu-16", str(s["needs"]), kinds_txt, False),
        ("t-good" if s["lanes_running"] else "t-info", "Lanes working", str(s["lanes_running"]),
         f'of {s["lanes_total"]} active.tsv lanes · {s["lanes_needs"]} need gpu-16 · {s.get("lanes_unknown", 0)} unknown', False),
        ("t-warn" if s["lanes_waiting"] else "t-info", "Lanes idle", str(s["lanes_waiting"]),
         f'turn ended, gpu-16 sends next · {s.get("lanes_stale_quota", 0)} stale quota', False),
        ("t-info", "Dispatchable", str(s.get("dispatchable_recent", s["dispatchable"])), f'{s["newly_unblocked"]} newly unblocked · {s["dispatchable"] - s.get("dispatchable_recent", 0)} older backlog', False),
        ("t-" + dev_sev, "Device bench", dev_v, dev_d, True),
        ("t-warn" if s["stale"] else "t-info", "Stale beads", str(s["stale"]), f'in_progress, no lane, > {th["STALE_BEAD_H"]} h quiet', False),
        ("t-warn" if s["owner_asks"] else "t-info", "Owner asks", str(s["owner_asks"]), "open tickets in the owner intake", False),
    ]
    strip = "".join(
        f'<div class="tile {cls}"><div class="k">{e(k)}</div><div class="v{" small" if small else ""}">{e(v)}</div><div class="d">{e(dd)}</div></div>'
        for cls, k, v, dd, small in tiles)
    gen = d["generated_at"]
    body = [f'<title>Fleet Board</title>\n<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>\n'
            f'<link rel="stylesheet" href="{FONTS}">\n<style>{CSS}</style>\n<div class="wrap">']
    body.append(
        '<header class="mast"><div class="brand"><h1>Fleet Board</h1><span class="who">gpu-16 · A133 / GE8300 campaign · lanes, beads, bench</span></div>'
        f'<div class="meta"><span class="gen" title="UTC">{e(gen)}</span><span id="page-age" aria-live="polite">generated</span>'
        '<label class="filter" for="filter"><span class="lbl">filter</span><input id="filter" type="search" placeholder="bead, lane, run, PR, token…" autocomplete="off"></label>'
        '<span id="filter-note" class="dim"></span></div></header>')
    body.append(f'<section class="strip" aria-label="summary">{strip}</section>')
    body.append(section("needs", "Needs gpu-16 now", s["needs"], render_needs(d),
                        "prioritized: merge-ready, handbacks, boot-ready kits, device and host, blocked, stale, undriven, newly unblocked"))
    body.append(section("waiting-owner-attended", "WAITING · owner-attended",
                        len(d.get("waiting_owner_attended") or []),
                        render_reclassified(d, "waiting_owner_attended"),
                        "owner: device acceptance needs an attended session", open_=False))
    body.append(section("waiting-bench", "WAITING · bench/device hold", len(d.get("waiting_bench") or []),
                        render_reclassified(d, "waiting_bench"),
                        "owner shown per row; implementation/deploy complete, device proof pending", open_=False))
    body.append(section("blocked-by-bead", "WAITING · blocked by bead", len(d.get("blocked_by_bead") or []),
                        render_reclassified(d, "blocked_by_bead"),
                        "owner is the named open repair bead", open_=False))
    body.append(section("closed-live-run", "WAITING · closed bead with live run",
                        len(d.get("closed_live_run") or []), render_reclassified(d, "closed_live_run"),
                        "preserved evidence run; owner and expiry shown", open_=False))
    body.append(section("blocked", "BLOCKED claims", len(d.get("blocked") or []), render_reclassified(d, "blocked"),
                        "open dependencies from the same bd list snapshot; waiting, not stale", open_=False))
    body.append(section("lane-attributed", "Lane-attributed claims", len(d.get("lane_attributed") or []),
                        render_reclassified(d, "lane_attributed"),
                        "owned by the nearest ancestor with a live lane", open_=False))
    body.append(section("preserved", "PRESERVED runs", len(d.get("preserved") or []),
                        render_reclassified(d, "preserved"),
                        "committed run id, reason and expiry; intentional, not undriven", open_=False))
    body.append(section("mechanical", "Mechanical completion", len(d.get("mechanical") or []),
                        render_reclassified(d, "mechanical"),
                        "merged PRs awaiting guarded release/close; future paths auto-close", open_=False))
    body.append(section("stale-summary", "Stale summary", len(d.get("stale_summary") or []),
                        render_reclassified(d, "stale_summary"),
                        "aggregate only; individual orphan decisions remain in Needs", open_=False))
    hw = d.get("hardware")
    if hw is not None:
        body.append(section("hardware", "Hardware & drivers", len(hw.get("rows") or []), render_hardware(d),
                            "one row per block, then the tier priorities · state from HW_ROW comments on the anchor bead, else the 10-18 seed"))
    for who, cnt in (s.get("owned") or {}).items():
        body.append(section(f"owned-{who}", f"Owned by {who}", cnt, render_owned(d, who),
                            f"in scope, no lane, assignee {who}: theirs to drive, not gpu-16 needs", open_=False))
    vel = render_velocity(d)
    if vel is not None:
        body.append(section("velocity", "Velocity", vel[1], vel[0],
                            "opened vs closed per day (7-day means), backlog, week over week · last 60 UTC days"))
    rf_body, rf_count, rf_level, rf_note = render_runner_fleet()
    body.append(section("runner-fleet", f"Runner fleet · {rf_level}", rf_count, rf_body, rf_note,
                        open_=rf_level != "ok"))
    body.append(section("lanes", "Lanes", s["lanes_total"], render_lanes(d),
                        "gpu-16 managed runs, one row per runs/active.tsv lane; needs first, then unknown, idle, working"))
    body.append(section("dispatch", "Dispatchable work", s["dispatchable"], render_dispatchable(d),
                        "bd ready in scope with no lane: parallel set, then what each landing unblocks"))
    body.append(section("device", "Device bench", dev.get("pending", 0), render_device(d),
                        "one A133 handheld, strictly serial: the BENCH lane drives pf-kit-window-runner; queue = each lane's latest request to BENCH"))
    body.append(section("results", "Bench results (typed, 24 h)", dev.get("results_24h", 0), render_results(d),
                        "kit-window close records and BENCH-RESULT / DEPLOY-RECEIPT files grouped by State / Reason / TypedCause"
                        + (f' · WARN: {dev["results_warn"]} result source(s) empty while windows closed' if dev.get("results_warn") else "")))
    body.append(section("stale", "Stale in-progress beads", s["stale"], render_stale(d),
                        f'in_progress, in scope, no lane, no update or comment for {th["STALE_BEAD_H"]} h', open_=bool(s["stale"])))
    if "backlog" in d:
        bl = d.get("backlog") or {}
        body.append(section("backlog", "Open backlog", bl.get("open_total"), render_backlog(d),
                            "status open, all scopes: age bucket × area, P0/P1, batch:<slug> labels", open_=False))
    body.append(section("owner", "Owner asks", s["owner_asks"], render_owner(d), "open tickets in the owner intake; resolved tickets hidden",
                        open_=bool(s["owner_asks"])))
    body.append(section("about", "Sources and thresholds", len(d.get("errors") or []), render_footer(d),
                        "every number above comes from a live read; only hardware-row comment caches persist between refreshes",
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
