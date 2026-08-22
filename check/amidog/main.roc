# Runner for Amidog's on-console CPU tests: sideload the PS-EXE, run
# with a step budget (VBlank heartbeat + scripted pad in the loop),
# capture kernel-vector TTY output, and gate on the test's own verdict.
# Any kernel call our trap does not implement is enumerated loudly and
# fails the run.
#
# VERDICT (reverse-engineered from psxtest_cpu, see the change's design
# notes): the final "Result: %08x" is an OR of per-group flag words.
# Bits 0x1 and 0x100 are set on the golden-log MATCH paths (they mean
# the compare streams ran); failures set 0x8/0x800 and print per-op
# detail lines. "Result: 00000101" is therefore the all-pass signature.
#
# EXCLUDED: psxtest_cpx — its output (menu launched via the scripted
# START press) is dominated by coprocessor semantics: LWC2/SWC2 and
# COP2 want the GTE to execute (no exception with SR.CU2 set), and
# LWC0/1/3+SWC0/1/3 want SR.CU-gated no-exception behavior. The GTE is
# its own upcoming change; re-admit cpx there.
#
#   roc build check/amidog/main.roc --output=/tmp/amidog
#   /tmp/amidog check/amidog/data/psxtest_cpu.exe 800000000
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
    ps1: "../../package/main.roc",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import ps1.Bus
import ps1.Cpu
import ps1.Exe

# spec: exclusions print their reason at run time; this list only shrinks
excluded : List({ name : Str, reason : Str })
excluded = [
    {
        name: "psxtest_cpx.exe",
        reason: "dominated by coprocessor semantics: LWC2/SWC2/COP2 want the GTE executing (no exception with SR.CU2 set) and LWC0/1/3+SWC0/1/3 want SR.CU-gated no-exception behavior — re-admit with the GTE change",
    },
]

parse_n : List(OsStr), U64, U64 -> U64
parse_n = |args, idx, default| {
    raw = (args.get(idx) ?? OsStr.from_str("")).display().to_utf8().fold(0.U64, |acc, c| if c >= 48 and c <= 57 { acc.times_wrap(10).plus(c.minus(48).to_u64()) } else { acc })
    if raw == 0 { default } else { raw }
}

run : Cpu, Bus, List(List(U8)), U64 -> { cpu : Cpu, bus : Bus, ram : List(List(U8)), steps : U64 }
run = |cpu0, bus0, ram0, budget| {
    var cpu = cpu0
    var bus = bus0
    var ram = ram0
    var k = 0.U64
    # VBlank heartbeat: raise I_STAT bit 0 once per NTSC frame's worth of
    # CPU cycles so frame-wait polls (and the tests' delay loops) advance
    var next_vblank = 564_480.U64
    var going = Bool.True
    while going {
        r = Cpu.step(cpu, bus, ram)
        cpu = r.cpu
        bus = r.bus
        if r.st1_size != 0 {
            ram = Cpu.store_ram(ram, r.st1_size, r.st1_addr, r.st1_val)
            ram = Cpu.store_ram(ram, r.st2_size, r.st2_addr, r.st2_val)
        } else {}
        if cpu.cycles >= next_vblank {
            bus = bus.raise_irq(0)
            next_vblank = next_vblank.plus(564_480)
        } else {}
        cpu = Cpu.set_irq2(cpu, bus.irq2())
        k = k.plus(1)
        if k >= budget {
            going = Bool.False
        } else {}
    }
    { cpu: cpu, bus: bus, ram: ram, steps: k }
}

hex : U32 -> Str
hex = |v| {
    digit = |d| if d < 10 { d.plus(48) } else { d.plus(87) }
    var out = List.with_capacity(8)
    var shift = 28.U8
    var going = Bool.True
    while going {
        out = out.append(digit(v.shr_zf_wrap(shift).bitwise_and(15).to_u8_wrap()))
        if shift == 0 {
            going = Bool.False
        } else {
            shift = shift.minus(4)
        }
    }
    Str.from_utf8(out) ?? "????????"
}

show_unknowns! = |calls, i|
    match calls.get(i) {
        Err(_) => Ok({})
        Ok(u) => {
            Stdout.line!("  unhandled kernel call: table ${hex(u.table)} fn ${hex(u.fn)}")?
            show_unknowns!(calls, i.plus(1))
        }
    }

# the tests print per-suite results and a final total; failures show
# "err" counts — gate on "0 errors"-style verdicts once output is known
contains : Str, Str -> Bool
contains = |haystack, needle| haystack.split_on(needle).len() > 1

base_name : Str -> Str
base_name = |path| {
    parts = path.split_on("/")
    parts.get(parts.len().minus_wrap(1)) ?? path
}

exclusion_reason : Str -> Try(Str, [NotExcluded])
exclusion_reason = |name|
    excluded.fold(Err(NotExcluded), |acc, e|
        match acc {
            Ok(r) => Ok(r)
            Err(_) => if e.name == name { Ok(e.reason) } else { Err(NotExcluded) }
        })

main! : List(OsStr) => Try({}, _)
main! = |args| {
    path = args.get(1) ?? OsStr.from_str("check/amidog/data/psxtest_cpu.exe")
    match exclusion_reason(base_name(Path.from_os_str(path).display())) {
        Ok(reason) => {
            Stdout.line!("${base_name(Path.from_os_str(path).display())}: EXCLUDED — ${reason}")?
            return Ok({})
        }

        Err(_) => {}
    }
    budget = parse_n(args, 2, 800_000_000)
    bytes = Path.from_os_str(path).read_bytes!()?
    bus0 = Bus.ps1(List.repeat(0, 0x80000), Bool.True)
    loaded = Exe.load(bus0, bytes)?
    result = run(loaded.cpu, loaded.bus, loaded.ram, budget)
    tty = Str.from_utf8(result.bus.tty_bytes()) ?? "<non-utf8 tty>"
    Stdout.line!("--- tty (${result.bus.tty_bytes().len().to_str()} bytes) ---")?
    Stdout.line!(tty)?
    Stdout.line!("--- end tty; steps ${result.steps.to_str()}, final pc ${hex(result.cpu.pc)} ---")?
    unknowns = result.bus.tty_unknown_calls()
    if unknowns.len() > 0 {
        Stdout.line!("KERNEL CALLS MISSING (${unknowns.len().to_str()}):")?
        show_unknowns!(unknowns, 0.U64)?
        Err(UnhandledKernelCalls)
    } else if contains(tty, "Result: 00000101") {
        Stdout.line!("amidog: ok — Result 00000101 is the all-pass signature (fail bits 0x8/0x800 absent)")
    } else {
        Stdout.line!("amidog: verdict not recognized — inspect tty above")?
        Err(NoVerdict)
    }
}
