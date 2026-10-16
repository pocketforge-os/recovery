import sys; sys.path.insert(0, "/home/matt/recovery/gpu14")
from lane_routine import verdict, parse_status

ROUTINE = """Approved the exact-head hermetic A133 build once.

LANE tsp-mc9m.60.7 STATUS 2026-09-27T16:00:40Z
DONE: Approved worker permission 527266f51ea54c538f597a405ee30adf:1 for the scoped full kernel gate.
IN-FLIGHT: Firmware-timing worker is validating rebased head e8b61dda2ef2 over W2 merge 95a1f6fb.
INTEGRATION REQUESTS: None new; next request will contain the merged firmware-timing kernel SHA.
BENCH REQUESTS: Radio Wi-Fi association/scan plus Bluetooth hci0/btmgmt remains pending after the USB safety hold clears.
BLOCKERS / OWNER QUESTIONS: None.
NEXT: Await the managed worker's terminal result or blocker."""
INTEG = ROUTINE.replace("INTEGRATION REQUESTS: None new; next request will contain the merged firmware-timing kernel SHA.",
                        "INTEGRATION REQUESTS: gpu-14: kernel pin 95a1f6fb0446286aeda8ec63e611f70dd8e6669e; merge image#130.")
NONE_BUT_GPU14 = ROUTINE.replace("INTEGRATION REQUESTS: None new; next request will contain the merged firmware-timing kernel SHA.",
                        "INTEGRATION REQUESTS: None immediately. gpu-14 must dispatch the heavyweight W7 gate after the paired RTC handoff.")
BLOCKER = ROUTINE.replace("BLOCKERS / OWNER QUESTIONS: None.", "BLOCKERS / OWNER QUESTIONS: No product blocker; current issue is build-infrastructure transport.")
OWNERQ = ROUTINE.replace("BLOCKERS / OWNER QUESTIONS: None.", "BLOCKERS / OWNER QUESTIONS: None for gpu-14; owner must pick the runner host.")
TRUNC = ROUTINE.split("INTEGRATION REQUESTS")[0]
TWO_BLOCKS = "LANE x STATUS\nINTEGRATION REQUESTS: gpu-14 merge #1\nBENCH REQUESTS: None\nBLOCKERS / OWNER QUESTIONS: None\n\n" + ROUTINE

bench_prev = {"bench": "Radio Wi-Fi association/scan plus Bluetooth hci0/btmgmt remains pending after the USB safety hold clears.", "blockers": "None."}
ok = 0
def check(name, got, want):
    global ok
    print(("PASS " if got[0] == want else "FAIL ") + name, got[0], got[1]); ok += (got[0] == want)

check("routine, standing bench seen before", verdict(ROUTINE, bench_prev), True)
check("routine text but bench NEW (no history) wakes", verdict(ROUTINE, None), False)
check("integration request wakes", verdict(INTEG, bench_prev), False)
check("'None immediately. gpu-14 must...' wakes", verdict(NONE_BUT_GPU14, bench_prev), False)
check("new non-None blocker wakes", verdict(BLOCKER, bench_prev), False)
check("same blocker as last turn is routine", verdict(BLOCKER, {**bench_prev, "blockers": "No product blocker; current issue is build-infrastructure transport."}), True)
check("owner question wakes", verdict(OWNERQ, bench_prev), False)
check("truncated text (no integration line) wakes", verdict(TRUNC, bench_prev), False)
check("empty text wakes", verdict("", bench_prev), False)
check("last of two blocks is scored", verdict(TWO_BLOCKS, bench_prev), True)
check("standing integration request identical to last is routine", verdict(INTEG, {**bench_prev, "integration": "gpu-14: kernel pin 95a1f6fb0446286aeda8ec63e611f70dd8e6669e; merge image#130."}), True)
check("integration request CHANGED from last wakes", verdict(INTEG, {**bench_prev, "integration": "gpu-14: kernel pin 6d86d65e."}), False)
LANEBLK = ROUTINE.replace("BLOCKERS / OWNER QUESTIONS: None.", "BLOCKERS / OWNER QUESTIONS: PR #1045 review blocks because interrupted cleanup can strand dot-prefixed full trees outside future inventory. PR #1043 remains blocked on `$\"rm\"` command detection. No owner question.")
LANEBLK_G = LANEBLK.replace("No owner question.", "gpu-14 must decide the runner host. No owner question.")
LANEBLK_O = LANEBLK.replace("No owner question.", "No owner question for the lane; the owner must approve the relocation.")
check("lane-internal blocker with 'No owner question' is routine", verdict(LANEBLK, bench_prev), True)
check("blocker mentioning gpu-14 wakes even with 'No owner question'", verdict(LANEBLK_G, bench_prev), False)
check("blocker with a second owner mention wakes", verdict(LANEBLK_O, bench_prev), False)
BT1 = ROUTINE.replace("INTEGRATION REQUESTS: None new; next request will contain the merged firmware-timing kernel SHA.", "INTEGRATION REQUESTS: STANDING: pin db5bfd13. PENDING: `.40` will provide SHAs.")
check("same standing line minus backticks is routine", verdict(BT1, {**bench_prev, "integration": "STANDING: pin db5bfd13. PENDING: .40 will provide SHAs."}), True)
CONFG4 = """W7 review done.

LANE tsp-mc9m.41.984 STATUS 2026-09-28T02:29:05Z

DONE:
- Reviewed automation `672067ce` exactly; GitHub approval `5333350440`.

INTEGRATION REQUESTS:
- None until W7’s final typed handoff.

BENCH REQUESTS:
- None.

BLOCKERS / OWNER QUESTIONS:
- No owner question.

NEXT:
- Reproduce and independently review W7’s final exact head.

FANOUT 2/8
MESSAGES 17/100"""
check("bullet-list block, all None, is routine (real CONF g4 02:29Z)", verdict(CONFG4, None), True)
check("bullet-list: None then a real request in bullet 2 wakes", verdict(CONFG4.replace("- None until W7’s final typed handoff.", "- None for W7.\n- Merge platform#211 now."), None), False)
check("bullet-list: request bullet mentioning gpu-14 wakes", verdict(CONFG4.replace("- None until W7’s final typed handoff.", "- gpu-14: dispatch fidelity at 7a1b2c3d."), None), False)
check("bullet-list: empty label followed directly by next label wakes", verdict(CONFG4.replace("- None until W7’s final typed handoff.\n", ""), None), False)
check("bullet-list: owner question bullet wakes", verdict(CONFG4.replace("- No owner question.", "- The owner must pick the runner host."), None), False)
# 2026-10-02: colonless headers + split BLOCKERS / OWNER QUESTIONS (real FLEET g3 06:38Z turn).
FLEETG3 = """Same-run continuation dispatched once.

LANE tsp-mc9m.41.984.47 STATUS 2026-10-02T06:38:00Z
DONE
- Renewed GO recorded in checkpoint revision 6.
IN-FLIGHT
- tsp-a2223c941d146831700d -> run pft-2bdf2106ccc93d973b29e26b; delivery queued.
INTEGRATION REQUESTS
- None.
BENCH REQUESTS
- None.
BLOCKERS
- None.
OWNER QUESTIONS
- None.
NEXT
- Await the service-delivered terminal result or blocker.
MESSAGE BUDGET
- 3/100"""
check("colonless split block, all None, is routine (real FLEET g3)", verdict(FLEETG3, None), True)
check("split: a real OWNER QUESTIONS item wakes", verdict(FLEETG3.replace("OWNER QUESTIONS\n- None.", "OWNER QUESTIONS\n- The owner must approve the runner host."), None), False)
check("split: a real BLOCKERS item wakes", verdict(FLEETG3.replace("BLOCKERS\n- None.", "BLOCKERS\n- Golden build failed at the builder."), None), False)
check("split: OWNER QUESTIONS header missing wakes", verdict(FLEETG3.replace("OWNER QUESTIONS\n- None.\n", ""), None), False)
check("colonless: integration request bullet wakes", verdict(FLEETG3.replace("INTEGRATION REQUESTS\n- None.", "INTEGRATION REQUESTS\n- RELOOK pocketforge-automation#1176 4e32703d"), None), False)
check("colonless: same-line value after a space mentioning gpu-14 wakes", verdict(FLEETG3.replace("INTEGRATION REQUESTS\n- None.", "INTEGRATION REQUESTS none pending; gpu-14 retains #1160"), None), False)
print(f"{ok}/27")
sys.exit(0 if ok == 27 else 1)
