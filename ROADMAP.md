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

- [x] **Memory bus + EXE sideload** — Ps1 bus variant with the RAM
  paged OUTSIDE the bus (the compiler's four "poison laws" against
  in-place list updates are documented in the change's design as-built,
  with the val-only read API and store/read intents they forced),
  scratchpad, BIOS window, wait-state accounting, I_STAT/I_MASK with
  CAUSE.IP2 mirror + delivery, SR.IsC, PS-EXE sideloader, kernel-vector
  TTY trap (putchar/puts/mini-printf/FlushCache) and idle-GPU/pad
  stubs. Gated by Amidog psxtest_cpu — green (Result 00000101 = the
  all-pass signature, convention reverse-engineered); psxtest_cpx
  excluded until the GTE change (coprocessor semantics). Real-bus bench
  1.79x (≥ 1.00x floor); flat floor re-recorded 0.30x for the heavier
  step shape.

## Next

- [x] **DMA + timers + interrupts** — Psx.roc console layer born
  (clock, VBlank source, single-slot timer scheduling, DMA kicks, IP2
  mirror — all drivers are thin callers); root counters as lazy cycle
  anchors (sysclock//8/hblank/dotclock, read-cleared reached flags as
  ack intents, event-scheduled IRQs); 7-channel DMA register file with
  OTC (ch6) live and device channels fail-loud; kernel trap grew the
  psn00b surface (C0 vector, HookEntryInt dispatch trio, critical-
  section syscalls, SR=0x401 sideload seed). Gated by ps1-tests
  hardware logs: access-time GREEN (wait table calibrated — and the
  i-cache reality re-recorded the bench floor at 0.30x honest cycles;
  the GBA wait-state precedent does not transfer, decode cache is the
  standing lever), otc-test GREEN, timers GREEN minus per-row
  sync-mode exclusions (blanking widths = GPU timing); dpcr excluded
  (SPU observable).
- [x] **GPU core** — VRAM as a driver-owned flat list beside the RAM
  pages; GP0/GP1 command processing with live GPUSTAT; transfers with
  mask-bit semantics; DMA channel 2 (block + linked-list, looping
  chains hang like hardware); and a software rasterizer ported
  faithfully from Mednafen's algorithm — TEN VRAM references BIT-EXACT
  (triangle, quad, clipping, rectangles, texture-flip,
  texture-overflow, uv-interpolation, clut-cache with the real CLUT
  cache quirks, transparency, vram-to-vram-overlap with the 128-pixel
  chunk FIFO). The dragons all showed up and were slain by the
  references: mask bits, CLUT cache staleness, drawing offset/clip,
  overlap copies. Line rasterizer implemented (its test EXE needs the
  GTE). The two-loop console shape kept the bench at 0.33x.
- [x] **GTE** — fixed-point vector coprocessor: the 64-register file
  with its access asymmetries (sign-extension, the SXY FIFO's
  push-on-write, IRGB/ORGB packing, LZCR), all 22 opcodes, the 44-bit
  MAC pipeline with saturation and FLAG, the UNR reciprocal divide, and
  the documented hardware bugs (MVMVA's far-color truncation, the
  garbage matrix and vector). CPU side: COP2 dispatch with real SR.CU
  gating across all four coprocessor slots, GTE state driver-owned and
  reached by val-only reads plus intents. Gated by a NEW pure-Roc
  vector slice over upstream's hardware capture — **1,150/1,150 cases
  bit-identical across all 64 registers, no exclusions** — plus
  gte/test-all running the same cases on-console (proving the dispatch
  path) and ps1-tests `lines` re-admitted, its VRAM reference now
  BIT-EXACT (the eleventh). Four things the documentation does not say,
  found by the capture: the MAC accumulator WRAPS at 44 bits with the
  flag taken before wrapping; the far-color difference truncates to 32
  bits AFTER the shift; RTPT runs the depth-cue step only on the last
  vertex; SZ3 comes from the raw accumulator and feeds the divide.
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
