# Roadmap

Emulation-first, one gated change at a time, toward **Crash Team Racing
(NTSC-U) playable in the ray frontend**. Ordering is deliberate — notes
say why when it isn't obvious. Specs and change history live in the
shared OpenSpec root (`ps1-` prefix); this file is the at-a-glance view,
ticked as changes archive.

## Done

- [x] **Dev environment** — Nix devshell with the fleet's pinned Roc
  nightly, sibling `package/` + `check/` skeleton, resource conventions
  (OpenBIOS for gates, US disc canonical).

- [x] **CPU core + verification** — R3000A interpreter: full MIPS I
  ISA, load/branch delay slots (targets and links relative to the
  actual delay-slot address), COP0 exceptions (which the vectors DO
  cover, README caveat notwithstanding). Gated by SingleStepTests/r3000:
  55,000/55,000 cases across all 55 files, no exclusions, plus a
  throughput bench (0.44x — see CPU perf below).

- [x] **CPU perf** — 0.44x → 0.63x (21.4M steps/s, above the GBA
  core's accepted final in host throughput): fused single-build step,
  flat registers (won its rematch on the fused structure), SSA bus
  threading; losers measured and reverted. Floor committed at 0.55x;
  ≥ 1.00x arrives with the bus change's wait-state cycle accounting
  (GBA precedent: 1.08x flat → 2.6x real bus). Decode cache is the
  known lever beyond that.

## Next

- [ ] **Memory bus + EXE sideload** — memory map (RAM, scratchpad,
  BIOS window, I/O stubs), IRQ controller skeleton, PS-EXE loader.
  Sideloading is the key move: the entire test corpus (Amidog,
  ps1-tests) is PS-EXEs, so every later subsystem gates without any
  CD-ROM emulation.
- [ ] **DMA + timers + interrupts** — 7 DMA channels including OT
  chain-following, root counters, IRQ delivery. Gated by ps1-tests
  DMA/timer EXEs. Root counter 1 (hblank) accuracy lands here — CTR
  measures real time with it.
- [ ] **GPU core** — command FIFO + software rasterizer into 1 MB VRAM.
  Gated by ps1-tests VRAM dumps diffed against hardware-captured
  references (the house frozen-digest workflow, upstream-supplied).
  Known dragons: mask bits, texture cache, drawing offset/clip.
- [ ] **GTE** — fixed-point vector coprocessor. Gated by Amidog
  psxtest_gte + ps1-tests gte-fuzz. Pure math; no JSON tests exist yet.
- [ ] **BIOS boot** — OpenBIOS LLE to logo and shell; trace-diff
  against PCSX-Redux replaces a nestest-style golden log.
- [ ] **CD-ROM core** — controller state machine, bin/cue reading,
  deterministic seek/read latency (calibrating to hardware-realistic
  timing is a recorded open question — digests need determinism either
  way). Gate: ps1-tests CD EXEs, then boot a real disc to menu.
- [ ] **Play app (ray)** — CTR boots, menus navigate, a race starts,
  silent. Uses the roc-ray fork (file-io branch) for disc reading.
- [ ] **SPU core** — 24 ADPCM voices, volumes, per-level reverb.
  Gated by ps1-tests SPU EXEs.
- [ ] **SPU XA streaming** — the CTR-critical half, split out
  deliberately: XA ADPCM sector filtering, SPU IRQ on the CD-audio
  capture buffer, decoded-data readback (the behavior that forced the
  ePSXe-era "SPU IRQ hack").
- [ ] **CTR acceptance** — Adventure mode race with sound; frozen
  digest scenes via a probe-style scripted-input harness; play-test.

## Later

- [ ] **Memory card** — saves (a current Beetle CTR save-corruption
  bug marks this as subtler than it looks).
- [ ] **DualShock analog + rumble** — CTR supports both.
- [ ] **MDEC** — FMV decode; deferred until a needed FMV is identified.
- [ ] **Multitap** — 3–4 player battle/versus modes.
- [ ] **roc-web frontend** — needs a chunked/async disc-read story
  (~700 MB bin vs the wasm32 heap); a platform-vision question.
- [ ] **Accuracy long tail** — CPU pipeline niceties, GPU timing,
  cache isolation, whatever the excluded-test list accumulates.
