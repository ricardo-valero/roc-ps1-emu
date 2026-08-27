# Verification slices

Each subdirectory is a pure-Roc verification slice: Roc apps runnable from
the devshell with plain `roc` invocations — no nix build harnesses, shell
wrappers, or non-Roc glue. Slices arrive with the change that gates on
them (see ROADMAP.md); a slice that needs external data ships a
`fetch.roc` that downloads it into its own `data/` directory.

Planned slices, in roadmap order:

- `single-step/` — SingleStepTests/r3000 JSON gate for the CPU
- `amidog/` — Amidog psxtest_cpu / psxtest_cpx / psxtest_gte PS-EXEs
- `gte-fuzz/` — the GTE's vector gate: upstream's hardware capture of
  1,150 full 64-register input/output cases, driven straight against
  `Gte.roc` with no CPU or console in the way (see the slice's header
  for the provenance chain that licenses the capture as ground truth)
- `ps1-tests/` — JaCzekanski ps1-tests EXEs; GPU tests diff VRAM dumps
  against hardware-captured references (the frozen-digest workflow)
- `boot/` — OpenBIOS boot-to-shell gate
- `frame/` — frozen framebuffer digests for game scenes
- `probe/` — scripted-input headless runner (diagnosis, not a gate)
- `bench/` — game-shaped workload benchmark for perf work
