# Pure-Roc runner for the SingleStepTests r3000 vectors.
#
#   roc build check/single-step/main.roc --output /tmp/sstep
#   /tmp/sstep check/single-step/data/*.json.bin
#
# Each case: build the core from the vector's initial state (registers,
# HI/LO, EPC/TAR/CAUSE, in-flight branch and load delay state), run
# exactly one step over the replay bus (the fetch at opcode_addr returns
# the opcode; data reads pop the vector's documented values), then diff —
# all 32 GPRs, HI/LO, PC, EPC, TAR, CAUSE, the outgoing branch/load delay
# state, and the ordered memory trace on (kind, size, addr, val). SR and
# BadVaddr are absent from the vectors (SR seeds as 0; exceptions vector
# to 0x80000080). Upstream caveats: ares-generated, flat memory, and
# per-cycle numbering beyond effect order is advisory.
#
# Exclusions (printed at run time, reasons required, list only shrinks):
# none yet.
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
    ps1: "../../package/main.roc",
    chk: "../lib/main.roc",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import chk.Vectors
import ps1.Cpu
import ps1.Bus
import ps1.Gte

excluded : List({ name : Str, reason : Str })
excluded = []

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

# vector cycle actions -> our bus trace kinds
kind_of_actions : U32 -> U8
kind_of_actions = |a|
    match a {
        4 => 0 # instruction fetch
        1 => 1 # data read
        2 => 2 # data write
        _ => 255
    }

from_vector_state : _ -> Cpu
from_vector_state = |s| {
    var cpu = Cpu.init(s.pc)
    var i = 1.U64
    while i < 32 {
        cpu = Cpu.set_r(cpu, i, s.r.get(i) ?? 0)
        i = i.plus(1)
    }
    { ..cpu,
        hi: s.hi,
        lo: s.lo,
        epc: s.epc,
        tar: s.tar,
        cause: s.cause,
        branch: if s.br.slot { Slot({ take: s.br.take, target: s.br.target }) } else { NoBranch },
        load: if s.ld.reg == 0xFFFF_FFFF { NoLoad } else { Pending({ reg: s.ld.reg.to_u64(), val: s.ld.val }) },
    }
}

# run one test case; empty list = pass, else mismatch descriptions
run_case : { name : Str, opcode : U32, opcode_addr : U32, initial : _, final : _, cycles : List(_) } -> List(Str)
run_case = |test| {
    data_reads = test.cycles.fold([], |acc, c| if c.actions == 1 { acc.append(c.val) } else { acc })
    cpu = from_vector_state(test.initial)
    bus = Bus.vector(test.opcode, test.opcode_addr, data_reads)
    out = Cpu.step(cpu, bus, [], Gte.init({}))
    fin = test.final
    var problems = []
    var i = 0.U64
    while i < 32 {
        e = fin.r.get(i) ?? 0
        a = out.cpu.get(i)
        if e != a {
            problems = problems.append("r[${i.to_str()}]: expected ${hex(e)}, got ${hex(a)}")
        }
        i = i.plus(1)
    }
    scalar = |label, e, a| if e != a { ["${label}: expected ${hex(e)}, got ${hex(a)}"] } else { [] }
    problems = problems
        .concat(scalar("pc", fin.pc, out.cpu.pc))
        .concat(scalar("hi", fin.hi, out.cpu.hi))
        .concat(scalar("lo", fin.lo, out.cpu.lo))
        .concat(scalar("epc", fin.epc, out.cpu.epc))
        .concat(scalar("tar", fin.tar, out.cpu.tar))
        .concat(scalar("cause", fin.cause, out.cpu.cause))
    got_br =
        match out.cpu.branch {
            Slot(b) => { target: b.target, slot: Bool.True, take: b.take }
            NoBranch => { target: 0.U32, slot: Bool.False, take: Bool.False }
        }
    expect_br = if fin.br.slot { fin.br } else { { target: 0.U32, slot: Bool.False, take: Bool.False } }
    if got_br != expect_br {
        problems = problems.append("branch: expected slot=${if expect_br.slot { "1" } else { "0" }} take=${if expect_br.take { "1" } else { "0" }} target=${hex(expect_br.target)}, got slot=${if got_br.slot { "1" } else { "0" }} take=${if got_br.take { "1" } else { "0" }} target=${hex(got_br.target)}")
    } else {}
    got_ld =
        match out.cpu.load {
            Pending(p) => { reg: p.reg.to_u32_wrap(), val: p.val }
            NoLoad => { reg: 0xFFFF_FFFF.U32, val: 0.U32 }
        }
    expect_ld = if fin.ld.reg == 0xFFFF_FFFF { { reg: 0xFFFF_FFFF.U32, val: 0.U32 } } else { fin.ld }
    if got_ld != expect_ld {
        problems = problems.append("load: expected reg=${hex(expect_ld.reg)} val=${hex(expect_ld.val)}, got reg=${hex(got_ld.reg)} val=${hex(got_ld.val)}")
    } else {}
    # fetch/read entries are synthesized from the step's intent fields
    # (reads never mutate the bus any more); only writes trace in the bus
    fetch_trace =
        if test.initial.pc.bitwise_and(3) == 0 {
            [{ kind: 0.U8, size: 4.U8, addr: test.initial.pc, val: if test.initial.pc == test.opcode_addr { test.opcode } else { test.initial.pc } }]
        } else {
            []
        }
    rd1_trace = if out.rd1_size != 0 { [{ kind: 1.U8, size: out.rd1_size, addr: out.rd1_addr, val: out.rd1_val }] } else { [] }
    rd2_trace = if out.rd2_size != 0 { [{ kind: 1.U8, size: out.rd2_size, addr: out.rd2_addr, val: out.rd2_val }] } else { [] }
    trace = fetch_trace.concat(rd1_trace).concat(rd2_trace).concat(out.bus.trace())
    if trace.len() != test.cycles.len() {
        problems = problems.append("trace: expected ${test.cycles.len().to_str()} accesses, got ${trace.len().to_str()}")
    } else {
        var k = 0.U64
        while k < trace.len() {
            got = trace.get(k) ?? { kind: 255, size: 0, addr: 0, val: 0 }
            want = test.cycles.get(k) ?? { actions: 0, size: 0, addr: 0, val: 0 }
            if got.kind != kind_of_actions(want.actions) or got.size.to_u32() != want.size or got.addr != want.addr or got.val != want.val {
                problems = problems.append("trace[${k.to_str()}]: expected actions=${want.actions.to_str()} size=${want.size.to_str()} addr=${hex(want.addr)} val=${hex(want.val)}, got kind=${got.kind.to_str()} size=${got.size.to_str()} addr=${hex(got.addr)} val=${hex(got.val)}")
            } else {}
            k = k.plus(1)
        }
    }
    problems
}

show_lines! = |lines, i|
    match lines.get(i) {
        Err(_) => Ok({})
        Ok(p) => {
            Stdout.line!("    ${p}")?
            show_lines!(lines, i.plus(1))
        }
    }

run_tests! = |name, tests, idx, failed, shown|
    match tests.get(idx) {
        Err(_) => Ok(failed)
        Ok(test) => {
            problems = run_case(test)
            if problems.is_empty() {
                run_tests!(name, tests, idx.plus(1), failed, shown)
            } else {
                if shown < 5 {
                    Stdout.line!("  ${test.name} (case ${idx.to_str()}, opcode ${hex(test.opcode)}):")?
                    show_lines!(problems, 0.U64)?
                } else {
                    Ok({})?
                }
                run_tests!(name, tests, idx.plus(1), failed.plus(1), shown.plus(1))
            }
        }
    }

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

run_file! = |path_os| {
    name = base_name(Path.from_os_str(path_os).display())
    match exclusion_reason(name) {
        Ok(reason) => {
            Stdout.line!("${name}: EXCLUDED — ${reason}")?
            Ok({ total: 0.U64, failed: 0.U64 })
        }

        Err(_) => {
            bytes = Path.from_os_str(path_os).read_bytes!()?
            tests = Vectors.parse_file(bytes)?
            failed = run_tests!(name, tests, 0.U64, 0.U64, 0.U64)?
            if failed == 0 {
                Stdout.line!("${name}: ok (${tests.len().to_str()} cases)")?
            } else {
                Stdout.line!("${name}: FAILED ${failed.to_str()}/${tests.len().to_str()} cases")?
            }
            Ok({ total: tests.len(), failed: failed })
        }
    }
}

run_files! = |args, idx, acc|
    match args.get(idx) {
        Err(_) => Ok(acc)
        Ok(path_os) => {
            r = run_file!(path_os)?
            run_files!(args, idx.plus(1), { total: acc.total.plus(r.total), failed: acc.failed.plus(r.failed) })
        }
    }

main! : List(OsStr) => Try({}, _)
main! = |args| {
    totals = run_files!(args, 1, { total: 0.U64, failed: 0.U64 })?
    if totals.total == 0 {
        Stdout.line!("no vector files given — pass check/single-step/data/*.json.bin")?
        Err(NoInput)
    } else if totals.failed == 0 {
        Stdout.line!("single-step: ok — ${totals.total.to_str()} cases across the given files")
    } else {
        Stdout.line!("single-step: FAILED — ${totals.failed.to_str()}/${totals.total.to_str()} cases")?
        Err(CasesFailed)
    }
}
