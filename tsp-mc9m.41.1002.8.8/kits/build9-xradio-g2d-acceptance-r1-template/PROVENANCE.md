# Provenance

- Acceptance owner: `tsp-mc9m.41.1002.8.8`
- Platform pin: `3e9bda124b7bd3579600579d0468890c839d62ca`
- Image pin: `dc3637f774e304f5a42a22f948bdd6d54608f259`
- Kernel pin: `45b87a7d` (linear merge content: xradio #92 plus G2D MBUS
  `c71231b2`)
- Published image input: Build 9 owned-image-build run `38357560250`, raw
  SHA-256 `406aba39e725f3c65a396ac2f8a0a1b0e96f9cacd9b245bc5d5bb543994b1255`,
  descriptor SHA-256
  `825994d8c42f03a9a2e8f60cf3f5f0a14dc80707dee52bb2992e8ab642acbba3`.
  The generator still requires the raw as an explicit input and embeds it into
  every generated kit.
- G2D acceptance source:
  `/home/matt/recovery/tsp-mc9m.41.923.56/kits/g2d-postmerge-image-acceptance-r1-template`,
  manifest SHA-256
  `730aefb67e125ae49674674c0d93e26353a644eec556060cc63e5480ed341792`.
  The payload is copied byte-for-byte; its SHA-256 is
  `2c2c5f1f67e7ed2943a1df6afb7dbf3f37a265e5b8a85b1dc821c9a478fbd9f5`.
- Network transport helper: automation tree
  `dcee1dfc258091984e70e62305c2c86e5544efae`, file SHA-256
  `932cbb0be9a7265e48ff6136a35e37cc009b5673d308107f52fc41f6ff13ff0e`.
- Network-only seed pattern and three seed tools: automation PR #1440 exact
  head `04a8bd0cb2b98d1761d5b4886b6e8d7b88fc5fe0`. They are copied into the
  recovery template so generation is hermetic; their use remains behind the
  published-raw preflight and the explicit sealing step.
- DUT binary proof uses the published Build 9 raw above and passes 26/26
  absolute image-side programs. The generated seed preparer also passes
  against the real r19 consumed-seed source and the published Build 9
  descriptor without reading secrets or staging a handle.

No file in this template is a sealed seed, staged handle, queue row, device
receipt, or device result.
