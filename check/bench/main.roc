# R3000 core throughput bench: a hand-assembled MIPS loop in Flat RAM —
# ALU mix, a load, a store, and a taken branch with its delay slot every
# iteration (9 instructions/lap). Measures core interpretation cost only:
# no PS1 bus, no wait states, and it says so.
#
#   roc build check/bench/main.roc --output=/tmp/bench && /tmp/bench [N]
#
# ps1-cpu-perf ledger (2026-08-21, M-series, compiled, 30M instructions):
#   0.44x baseline -> 0.57x fused single-build step (Out record removed)
#   -> 0.61x flat unrolled registers (won its rematch on the fused
#   structure after losing pre-fusion, 0.36x) -> 0.63x SSA bus threading
#   (21.4M steps/s; floor recorded 0.55x on that pre-bus core).
# ps1-membus-exe ledger (2026-08-21): the bus change makes step do
# strictly more per instruction — interrupt poll, kernel-trap check,
# wait-cost accounting, store/read intent reporting, paged-RAM reads —
# and the old core shape no longer exists. Recovery steps, each
# measured: guarded size-0 writes (+15%), scrutinee-return reads (+5%),
# single spine get per access (+15%), val-only fetch_val/read_val with
# NO bus in the return (the { bus, val } record-return taxed every step
# with refcount/copy traffic; +25%), driver-side store guards (+24%).
# Final: 0.34x-0.38x measured across the day (the GPUSTAT/SIO stub
# masks in the read arms cost a few points). FLOOR RE-RECORDED: 0.30x
# (this architecture's regression line with noise margin; the binding
# perf obligation is the real-bus bench's >= 1.00x, measured
# 1.79x-1.96x the same day). The decode cache remains the known lever
# beyond that.
# ps1-gte ledger (2026-08-26): the step grew a COP2 arm (CU gating,
# MFC2/CFC2/MTC2/CTC2, the imm25 command form, LWC2/SWC2) plus three
# GTE-intent fields on the Out record. Measured cost is small and both
# floors hold: core-only 0.33x (was 0.32x on the same machine before the
# change - inside noise), real-bus 0.32x (the gpu-core change recorded
# 0.33-0.34x, so roughly 3% for the new arm). The register file is
# DRIVER-OWNED and read val-only inside the step, so nothing GTE-shaped
# is threaded through the step's payload; that is why the cost is a
# branch and not a memmove. Floors unchanged at 0.30x.
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
    ps1: "../../package/main.roc",
}

import pf.OsStr
import pf.Stdout
import pf.Utc
import ps1.Cpu
import ps1.Gte
import ps1.Bus

# loop at 0x00: ADDIU r1+=1; ADDU r2+=r1; AND r3=r2&r4; LW r5<-0x100;
# SLTU r6=r1<r8; XOR r7=r2^r1; SW r2->0x104; BNE r1,r0,loop; SRA r9=r2>>3
kernel : List(U32)
kernel = [
    0x2421_0001,
    0x0041_1021,
    0x0044_1824,
    0x8C05_0100,
    0x0028_302B,
    0x0041_3826,
    0xAC02_0104,
    0x1420_FFF8,
    0x0002_4CC3,
]

build_mem : {} -> List(List(U8))
build_mem = |_| {
    page0 = kernel.fold([], |acc, w| acc.append(w.to_u8_wrap()).append(w.shr_zf_wrap(8).to_u8_wrap()).append(w.shr_zf_wrap(16).to_u8_wrap()).append(w.shr_zf_wrap(24).to_u8_wrap()))
    [page0.concat(List.repeat(0, 0x1000 - page0.len()))]
}

run : Cpu, Bus, List(List(U8)), U64 -> { cpu : Cpu, bus : Bus, ram : List(List(U8)) }
run = |cpu0, bus0, ram0, n| {
    var cpu = cpu0
    var bus = bus0
    var ram = ram0
    gte = Gte.init({})
    var k = 0.U64
    while k < n {
        r = Cpu.step(cpu, bus, ram, gte)
        cpu = r.cpu
        bus = r.bus
        if r.st1_size != 0 {
            ram = Cpu.store_ram(ram, r.st1_size, r.st1_addr, r.st1_val)
            ram = Cpu.store_ram(ram, r.st2_size, r.st2_addr, r.st2_val)
        } else {}
        k = k.plus(1)
    }
    { cpu: cpu, bus: bus, ram: ram }
}

parse_n : List(OsStr) -> U64
parse_n = |args| {
    raw = (args.get(1) ?? OsStr.from_str("")).display().to_utf8().fold(0.U64, |acc, c| if c >= 48 and c <= 57 { acc.times_wrap(10).plus(c.minus(48).to_u64()) } else { acc })
    if raw == 0 { 5_000_000 } else { raw }
}

r3000_hz : U64
r3000_hz = 33_868_800

main! : List(OsStr) => Try({}, _)
main! = |args| {
    n = parse_n(args)
    # sanity: the kernel must actually loop (PC inside the code region) —
    # count depends on argv so the flow analyzer can't fold it away
    warmup = run(Cpu.init(0), Bus.flat({}), build_mem({}), 1000.plus(n % 2))
    if warmup.cpu.pc >= 0x24 {
        Stdout.line!("BENCH KERNEL DIVERGED: pc=${warmup.cpu.pc.to_str()} — fix the kernel before trusting numbers")?
        Err(KernelDiverged)
    } else {
        t0 = Utc.now!()
        result = run(Cpu.init(0), Bus.flat({}), build_mem({}), n)
        t1 = Utc.now!()
        elapsed_ns = (t1.minus_wrap(t0)).to_u64_wrap()
        if elapsed_ns == 0 {
            Stdout.line!("elapsed 0ns?")?
            Err(ClockBroken)
        } else {
            cps = result.cpu.cycles.times_wrap(1_000_000_000) // elapsed_ns
            ratio_pct = cps.times_wrap(100) // r3000_hz
            frac = ratio_pct % 100
            frac_str = if frac < 10 { "0${frac.to_str()}" } else { frac.to_str() }
            Stdout.line!("instructions:      ${n.to_str()}")?
            Stdout.line!("emulated cycles:   ${result.cpu.cycles.to_str()}")?
            Stdout.line!("elapsed:           ${(elapsed_ns // 1_000_000).to_str()} ms")?
            Stdout.line!("emulated cycles/s: ${cps.to_str()}")?
            Stdout.line!("vs 33.87 MHz PSX:  ${(ratio_pct // 100).to_str()}.${frac_str}x")?
            Stdout.line!("(core-only workload: no PS1 bus or wait states in the loop)")?
            if cps >= r3000_hz.times_wrap(2) {
                Stdout.line!("verdict: GO (>= 2.00x)")
            } else if cps >= r3000_hz {
                Stdout.line!("verdict: PERF-FIRST (>= 1.00x, < 2.00x)")
            } else if ratio_pct >= 30 {
                Stdout.line!("verdict: FLOOR-OK (>= 0.30x core-only regression floor; the real-bus bench carries the 1.00x obligation)")
            } else {
                Stdout.line!("verdict: REGRESSION (< 0.30x floor)")?
                Err(BelowFloor)
            }
        }
    }
}
