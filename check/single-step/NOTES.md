# SingleStepTests r3000 — format and execution-model notes

Findings from inspecting https://github.com/SingleStepTests/r3000
(default branch `main`, tests under `v1/`) and hand-decoding real cases,
2026-08-21. These resolve the design's open questions; the runner and
core are built against this. The vectors were generated from ares'
interpreter (fork `ares_r3000_ssts`), so they encode ares' understanding
of the R3000 — divergences we accepted are marked "ares-ism" below.

## Files

55 vector files, `v1/<NAME>.json.bin`, ~0.43 MB each (~23 MB total),
1,000 cases per file, one file per instruction. `SHL.json.bin` is a
misnamed **SH** (store halfword) — its opcodes decode as SH. `BCondZ`
covers the whole REGIMM group. No COP0-transfer (MFC0/MTC0/RFE) or GTE
files exist; exception *sources* ARE covered (address errors, overflow,
SYSCALL, BREAK) despite the README's "exceptions have been disabled"
caveat — that caveat only means generation didn't restrict alignment.

## Binary format — parse it directly, no transcoding

No magic word. All little-endian:

```
file   := num_tests u32, test*
test   := name[51: len byte + ascii, zero-padded],
          opcode u32, opcode_addr u32,
          state(initial), state(final), cycles
state  := R[32] u32, hi, lo, EPC, TAR, CAUSE, PC,
          branch { target u32, slot u32, take u32 },
          load   { reg i32 (-1 = none), val u32 }        (172 bytes)
cycles := n u32, n x { val i64, actions u32, addr i64, sz u32 } (24 B each)
```

CAUTION: upstream's transcode_json.py swaps the group names in its JSON
output — the `{target, slot, take}` group is the BRANCH delay state and
the `{reg, val}` group is the LOAD delay state (verified: the {reg, val}
group lands in R[reg]). Cycle `actions`: 4 = instruction fetch, 1 = data
read, 2 = data write; addr/val fit U32. SR and BadVaddr are absent from
the state — SR seeds as 0 and exceptions vector to 0x80000080.

## Execution model (pinned by hand-decoded cases)

- **One architectural instruction per test** ("run 4 cycles" is pipeline
  framing). Initial states include in-flight branch and load delay state;
  final states carry the outgoing hazards.
- **Branch state** {slot, take, target}: the instruction at PC executes
  in a delay slot when slot=1; afterwards PC commits to target when
  take=1, else falls through. Every branch (taken or NOT) arms
  slot=1/take for the next instruction.
- **Targets and links are relative to the actual delay-slot address**:
  pc+4 normally, but a branch/jump executing inside a *taken* delay slot
  computes its target (and JAL/JALR/BcondZAL link = slot+4) from the
  pending jump's destination.
- **Load delay** {reg, val}: lands at the end of the next instruction.
  That instruction reads the stale file; its own write to the register
  wins; a second load to the same register supersedes; LWL/LWR read
  through the pending value as merge base; the pending load lands even
  when the instruction takes an exception.
- **Exceptions**: EPC = victim (or victim−4 with CAUSE.BD set in a
  slot); TAR captures the pending branch target on a delay-slot
  exception; CAUSE keeps all bits except [31:28] and excode[6:2]:
  BD(31), bit30 = branch-was-taken (ares-ism), CE[29:28] = low two bits
  of the primary opcode field (ares-ism — real hardware defines CE only
  for CpU), excode. Vector 0x80000080 (SR seeds 0, so BEV=0).
- **Bus traces**: fetch {sz4, PC, opcode}; scalar loads/stores use the
  raw address with the full register value on stores ("the CPU sends the
  whole 32-bit value; the bus picks"); reads return values whose low
  `sz` bytes are the data. **Unaligned ops split 3-byte accesses**:
  LWL/SWL touch the (sh+1) bytes ending at vaddr as [sz2 at aligned +
  sz1 at aligned+2] when sh=2 (single access otherwise: sz1/sz2/sz4 for
  sh 0/1/3); LWR/SWR touch the (4−sh) bytes from vaddr as [sz1 at vaddr
  + sz2 at vaddr+1] when sh=1 (sz4/sz2/sz1 for sh 0/2/3). Store values
  are shifted so the meaningful bytes sit at the bottom.
- **JR to a misaligned target does not fault at the JR** — the AdEL
  would belong to the target's fetch, outside the test window.

## Gate policy

Final state (GPRs, HI/LO, PC, EPC, TAR, CAUSE, outgoing branch/load
state) and the ordered trace on (kind, size, addr, val) all gate. SR and
BadVaddr are not compared (absent upstream); their behavior is covered
by core expects now and the Amidog EXEs later. Suspicious failures are
cross-checked against psx-spx before conforming the core to ares.

Result at first full run after the fixes above: **55,000/55,000 pass, no
exclusions.**
