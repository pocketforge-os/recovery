# On-device recovery surface contract

The on-device recovery surface is a CPU/fbdev consumer of durable recovery state. It
is not the launcher, does not depend on the launcher, and does not describe the host
unbricking scripts elsewhere in this repository.

## Condition input

The input is a durable `RecoveryRequired` record containing:

- `failure`: a typed failure (`BootVerification`, `UpdateVerification`, or
  `SystemIntegrity`) and its typed context;
- `occurred_at`: the producer's RFC 3339 timestamp; and
- `evidence`: a durable URI or content-addressed pointer to supporting evidence.

The surface does not infer a failure from presentation text. Producers persist the
typed record before the surface is invoked.

## Action capabilities

Each known action has a typed `Capability`:

- `Available { action, label }` may create an activation token and may be presented as
  an actionable control.
- `Unavailable { action, reason }` cannot create an activation token. It may be shown
  explicitly with its truthful reason or omitted entirely; it must never be a dead
  control.

`OtaUpdate` is available only when the OTA path is reachable. `FelRecovery` is the
recovery floor when OTA is not reachable. Moving, removing, swapping, or reflashing an
SD card is not an action in this contract and must never be presented as a recovery
step.

## Results

Every offered action returns a typed `ActionResult`. OTA reports started, completed,
or failed (with evidence). FEL reports instructions shown, recovery detected, or
failed (with evidence). Presentation derives customer copy from these states and must
not claim success, availability, or progress that the typed state does not establish.

The UI emits only a typed `RecoveryIntent`; an authority outside this crate performs
any OTA or FEL work and returns a typed `ActionResult`. This surface does not implement
OTA, FEL, rollback, slot switching, factory reset, reflash, settings, app catalog, or
image packaging.

## Rendering boundary

The `offscreen` module renders the complete minimal surface into a deterministic,
pure-CPU RGBA buffer with source-owned embedded type. The committed fixture hashes
cover the condition receipt, both capability states, and a typed result. Run
`scripts/check-launcher-absent.sh`; no launcher or theme dependency is permitted.
