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
  The payload is derived from that template, replacing only
  `pf-v4l2-rotate` with the source-owned helper below; its SHA-256 is
  `d93f822eadecc90cebaf4ed6acc9c6422e154ddd292b419284a0ee380c28ae5a`.
- G2D helper source baseline: pocketforge-automation
  `f254513fb52b2afcaface69e74df7311bf638c36`,
  `tests/hil-regress/tools/pf-v4l2-rotate/pf-v4l2-rotate.c`. The local,
  source-owned derivative removes the external `xz` process, emits a plain
  deterministic ustar archive, separates latency errors from other failures,
  and records the original sample index plus errno/timeout kind. Source
  SHA-256 is `0dcf2ed6656450488e4ec7a3973de8745336a8837275df79d6f1c6d08974c8d0`;
  the AArch64 helper SHA-256 is
  `5a184a5aaa848dc4078cae6503821fb03cbb5c05f27d35a616dbb471e853ef1d`.
  It was built twice byte-identically with the project AArch64 container
  definition SHA-256
  `7e427c4844c5e8cbed52a0cef16426f0127e7642dda0a7a57e46e9677738fb9e`;
  its newest required glibc symbol is `GLIBC_2.34`.
- Network transport helper: vendored temporary candidate requested by the
  owner while its automation PR is pending, file SHA-256
  `230901fd1b65d750dc4614852c6442fe0f004f05c26cf310677b3f11ceeb84f0`.
  It includes route-source inference, pull `test --`, and typed stderr fixes.
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
