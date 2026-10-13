# G2D post-merge image acceptance preregistration

## Fixed inputs

The kernel fix is merged to `device/a133` as
`c71231b296fdffd7dda7cf8d3621f849547ed2df`. The helper is the merged
`pocketforge-automation` implementation from
`f254513fb52b2afcaface69e74df7311bf638c36`. The image is supplied only when
this template is sealed; its raw SHA-256 and `ImageSource.json` are bound into
the sealed request. No candidate DTB, overlay, module, or kernel is installed.

## Predictions

- The image-owned live DT has `clock-names = "bus", "mod", "mbus"` and six
  clock cells on `/soc/clock-controller@6480000`. Missing or duplicate inputs
  fail before any G2D job.
- The `sun8i-rotate` node enumerates exactly once and V4L2 compliance succeeds.
- The real helper accepts the driver's adjusted buffer counts, completes the
  identity and rotate90 cases, and records `latency_errors=0`.
- The identity and rotate90 outputs have zero mismatches against the CPU
  reference. Their output SHA-256 values equal their independently fixed CPU
  reference SHA-256 values. The remaining five transform rows must also pass;
  they are retained as stronger regression coverage.
- `/proc/interrupts` advances for `64a8000.rotate`, while the IOMMU master-5
  fault-message count remains unchanged at zero.

## Run gates

The run passes only if the sealed manifest, exact image digest and descriptor,
FAT payload digest, and seed request agree; every DutExec command is at most
4096 bytes and every step is at most 300 seconds; the image-owned DT gate
passes; identity and rotate90 each report zero per-pixel differences plus an
output/reference checksum match; the seven-transform final result passes;
latency errors are zero; rotate IRQ delta is positive; and IOMMU master-5 fault
delta is zero. Diagnostics-before and diagnostics-after are independent steps,
so a bounded helper timeout cannot suppress IRQ, IOMMU, dmesg, clock, reset, or
register evidence.

## Counterfactual

The exact Build 8 image is a dry-run fixture only. Its original image-owned DT
lacks `mbus`, so a device run would fail the image DT gate. r8 proved the one
changed variable: adding the MBUS input made the identity job complete in 8 ms,
advanced the rotate IRQ by 2, left IOMMU master-5 fault delta at 0, and replaced
the sentinel with all 921,600 gradient pixels. The post-merge image must now
reproduce that result from its own DTB, without the r7/r8 candidate swap.
