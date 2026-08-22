# Real-bus throughput bench: the same 9-instruction kernel as main.roc,
# blitted into Ps1 RAM and executed with wait-state accounting live.
# Emulated cycles/s (instruction + wait cycles) against the 33.87 MHz
# line is the number that gates ≥ 1.00x per the ps1-cpu-verification
# spec; host steps/s is printed for the copy-churn diagnosis.
#
#   roc build check/bench/ps1.roc --output=/tmp/bench_ps1 && /tmp/bench_ps1 [N]
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
    ps1: "../../package/main.roc",
}

import pf.OsStr
import pf.Stdout
import pf.Utc
import ps1.Cpu
import ps1.Bus

kernel : List(U8)
kernel = [
    0x2421_0001, 0x0041_1021, 0x0044_1824, 0x8C05_0100,
    0x0028_302B, 0x0041_3826, 0xAC02_0104, 0x1420_FFF8,
    0x0002_4CC3,
].fold([], |acc, w| acc.append(w.to_u8_wrap()).append(w.shr_zf_wrap(8).to_u8_wrap()).append(w.shr_zf_wrap(16).to_u8_wrap()).append(w.shr_zf_wrap(24).to_u8_wrap()))

parse_n : List(OsStr) -> U64
parse_n = |args| {
    raw = (args.get(1) ?? OsStr.from_str("")).display().to_utf8().fold(0.U64, |acc, c| if c >= 48 and c <= 57 { acc.times_wrap(10).plus(c.minus(48).to_u64()) } else { acc })
    if raw == 0 { 5_000_000 } else { raw }
}

run : Cpu, Bus, List(List(U8)), U64 -> { cpu : Cpu, bus : Bus, ram : List(List(U8)) }
run = |cpu0, bus0, ram0, n| {
    var cpu = cpu0
    var bus = bus0
    var ram = ram0
    var k = 0.U64
    while k < n {
        r = Cpu.step(cpu, bus, ram)
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

r3000_hz : U64
r3000_hz = 33_868_800

main! : List(OsStr) => Try({}, _)
main! = |args| {
    n = parse_n(args)
    bus0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    page0 = kernel.concat(List.repeat(0, 0x1000 - kernel.len()))
    ram0 = [page0].concat(List.repeat(List.repeat(0, 0x1000), 0x1FF))
    warmup = run(Cpu.init(0x8000_0000), bus0, ram0, 1000.plus(n % 2))
    if warmup.cpu.pc.bitwise_and(0x1FFF_FFFF) >= 0x24 {
        Stdout.line!("BENCH KERNEL DIVERGED: pc=${warmup.cpu.pc.to_str()}")?
        Err(KernelDiverged)
    } else {
        t0 = Utc.now!()
        result = run(Cpu.init(0x8000_0000), bus0, ram0, n)
        t1 = Utc.now!()
        elapsed_ns = (t1.minus_wrap(t0)).to_u64_wrap()
        if elapsed_ns == 0 {
            Stdout.line!("elapsed 0ns?")?
            Err(ClockBroken)
        } else {
            steps_s = n.times_wrap(1_000_000_000) // elapsed_ns
            cps = result.cpu.cycles.times_wrap(1_000_000_000) // elapsed_ns
            ratio_pct = cps.times_wrap(100) // r3000_hz
            frac = ratio_pct % 100
            frac_str = if frac < 10 { "0${frac.to_str()}" } else { frac.to_str() }
            Stdout.line!("instructions:      ${n.to_str()}")?
            Stdout.line!("emulated cycles:   ${result.cpu.cycles.to_str()} (waits included)")?
            Stdout.line!("elapsed:           ${(elapsed_ns // 1_000_000).to_str()} ms")?
            Stdout.line!("host steps/s:      ${steps_s.to_str()}")?
            Stdout.line!("emulated cycles/s: ${cps.to_str()}")?
            Stdout.line!("vs 33.87 MHz PSX:  ${(ratio_pct // 100).to_str()}.${frac_str}x")?
            if cps >= r3000_hz.times_wrap(2) {
                Stdout.line!("verdict: GO (>= 2.00x)")
            } else if cps >= r3000_hz {
                Stdout.line!("verdict: PERF-FIRST (>= 1.00x, < 2.00x)")
            } else {
                Stdout.line!("verdict: BELOW REAL TIME (< 1.00x floor)")?
                Err(BelowRealTime)
            }
        }
    }
}
