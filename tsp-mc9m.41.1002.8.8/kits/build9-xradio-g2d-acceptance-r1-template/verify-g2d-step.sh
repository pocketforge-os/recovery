#!/bin/sh
set -eu
LC_ALL=C

stdout=${1:?verified-step-stdout}; result=${2:?pulled-acceptance-result}
invalid() { printf 'BUILD9_G2D_PREDICATE state=INVALID reason=%s\n' "$1"; exit 65; }
if [ ! -f "$stdout" ] || [ -L "$stdout" ]; then invalid stdout_unreadable; fi
if [ ! -f "$result" ] || [ -L "$result" ]; then invalid result_unreadable; fi
[ "$(wc -l <"$stdout" | tr -d ' ')" = 4 ] || invalid stdout_line_count
count=$(grep -Ec '^PF_KIT_TRANSPORT state=complete .* outcome=pass ' "$stdout") || count=0
[ "$count" = 3 ] || invalid transport_complete_count
count=$(grep -Ec '^PF_KIT_TRANSPORT state=complete transport=ssh direction=push operation=push sequence=20 files=1 bytes=[0-9]+ outcome=pass persistent_mutation=false receipt=push-20.json interface=[^ ]+ source=[0-9.]+$' "$stdout") || count=0
[ "$count" = 1 ] || invalid transport_push
count=$(grep -Ec '^PF_KIT_TRANSPORT state=complete transport=ssh direction=push-exec operation=push-exec sequence=21 files=1 bytes=[0-9]+ outcome=pass persistent_mutation=false receipt=push-exec-21.json interface=[^ ]+ source=[0-9.]+$' "$stdout") || count=0
[ "$count" = 1 ] || invalid transport_push_exec
count=$(grep -Ec '^PF_KIT_TRANSPORT state=complete transport=ssh direction=pull operation=pull sequence=22 files=3 bytes=[0-9]+ outcome=pass persistent_mutation=false receipt=pull-22.json interface=[^ ]+ source=[0-9.]+$' "$stdout") || count=0
[ "$count" = 1 ] || invalid transport_pull
[ "$(tail -n 1 "$stdout")" = 'BUILD9_G2D_STEP state=PASS transport=network-only payload=push execution=push-exec results=pull' ] || invalid final_step_line
grep -Fx 'DEVICE_PROOF verdict=PASS image_dtb=owned identity=pass rotate90=pass cpu_reference=match latency_errors=0 irq_delta=positive iommu_fault_delta=0' "$result" >/dev/null || invalid device_proof
printf 'BUILD9_G2D_PREDICATE state=PASS transport_lines=3 final_line=pass device_proof=pass\n'
