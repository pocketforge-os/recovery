# Build 9 xradio + G2D acceptance

This is an unsealed, unqueued generator. Run `prepare-kit.py` only after the
published Build 9 raw SHA-256 is known. The generated kit is bound to that raw
and refuses missing, malformed, or different values before seed, node, or DUT
actions. It performs one kit-resume boot: whole-image FelBoot/write/readback,
stock in-tree xradio network proof, unchanged G2D predicates, then canonical
graceful close with VBUS-first power safety.

All test bytes and results use `pf-kit-transport.py` over authenticated Wi-Fi.
DutExec carries only the bounded bootstrap needed to learn the fresh host key.
There is no ExtraBootArgs field, module swap, insmod, USB data leg, serial bulk,
seal, seed handle, or queue mutation in this template.

Before sealing: run `test-prepare-kit.sh`; run `dut-binary-check.sh` against the
published Build 9 image for every entry in generated `DUT-COMMANDS`; run the
generated `smoke.sh`; then follow generated `RUNBOOK.md`.

Exact remaining work for gpu-14 with published owned-image-build `38357560250`:

1. Read `RawSHA256` from the published `ImageSource.json`; independently hash
   `Image.img` and require equality.
2. Generate the one accepted instance:
   `./prepare-kit.py --image-sha256 "$raw" --output <new-build9-kit-path>`,
   where `raw=406aba39e725f3c65a396ac2f8a0a1b0e96f9cacd9b245bc5d5bb543994b1255`.
   Do not reuse an output directory or substitute another raw.
3. Verify the generated `SHA256SUMS`, run generated `smoke.sh`, and run
   `test-dut-binaries.sh <Build9-Image.img>` (the provisional Build 8 result is
   PASS, 26/26; Build 9 is still mandatory).
4. Set the merged/deployed automation checkout and an external recovery run
   root, then execute generated `RUNBOOK.md`: seal the fresh network-only seed,
   queue only `boot-open`, wait for its write/readback predicates, queue
   `bootstrap`, wait, queue `network`, wait, queue `g2d`, wait, delete the
   ephemeral SSH key, and queue `close`.
5. Accept only all exact PASS predicates plus terminal `CLOSED` with teardown
   order `vbus-off, graceful-poweroff, force-off, psu-off, power-zero, reap,
   lease-release, place-free`, every status `pass`.

No repository PR is required for this recovery-only kit template.
