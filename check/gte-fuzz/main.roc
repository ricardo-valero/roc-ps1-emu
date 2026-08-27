# Pure-Roc runner for the GTE vector capture.
#
#   roc build check/gte-fuzz/main.roc --output /tmp/gtefuzz
#   /tmp/gtefuzz check/gte-fuzz/data/gte_valid_0xc0ffee_50.log
#
# PROVENANCE (this is the whole reason the file is trustworthy — record
# it, do not re-derive it): upstream ps1-tests ships
# gte-fuzz/gte_valid_0xc0ffee_50.log with no documented origin. The
# chain that licenses it as hardware ground truth is:
#   1. gte-fuzz/main.c seeds a Mersenne Twister with 0x00c0ffee, and for
#      each of 23 command groups x 50 samples writes all 64 GTE
#      registers with random words, runs the command, and reads all 64
#      back — printing `> r[n]` for the value WRITTEN and `< r[n]` for
#      the value READ.
#   2. gte/test-all was generated from exactly this run: its EXE was
#      confirmed to embed these cases, with input AND expected-output
#      word runs found byte-for-byte in the binary at the start, middle
#      and end of the range.
#   3. gte/test-all/psx.log records a real console running test-all with
#      `Passed tests: 1150 / Failed tests: 0`.
# Hardware therefore passes exactly these expected outputs.
#
# FORMAT: r[0..31] are the data registers (MFC2/MTC2), r[32..63] the
# control registers (CFC2/CTC2) — gte-fuzz/gte.s splits on `reg >= 32`.
# The `>` value is what was WRITTEN, so a case exercises the write path
# (widths, sign-extension, the SXYP push, the IRGB expansion) before the
# command ever runs. The command line decodes as gte.h's union: cmd bits
# 0-5, lm bit 10, cv bits 13-14, v bits 15-16, mx bits 17-18, sf bit 19.
#
# The `GTE 0x40 ---` group prints NO command line (main.c skips it for
# cmd 64), so the header is OPTIONAL — a parser that requires it drops
# 50 cases silently. Those 50 run no command at all, which makes them a
# pure register-file test.
#
# Exclusions (printed at run time, reasons required, list only shrinks):
# none — all 1,150 cases are in.
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
    ps1: "../../package/main.roc",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import ps1.Gte

excluded : List({ name : Str, reason : Str })
excluded = []

Case : {
    num : U64,
    cmd : U32,
    word : U32,
    has_cmd : Bool,
    inputs : List(U32),
    outputs : List(U32),
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

name_of : U32 -> Str
name_of = |c|
    match c {
        0x01 => "RTPS"
        0x06 => "NCLIP"
        0x0C => "OP"
        0x10 => "DPCS"
        0x11 => "INTPL"
        0x12 => "MVMVA"
        0x13 => "NCDS"
        0x14 => "CDP"
        0x16 => "NCDT"
        0x1B => "NCCS"
        0x1C => "CC"
        0x1E => "NCS"
        0x20 => "NCT"
        0x28 => "SQR"
        0x29 => "DCPL"
        0x2A => "DPCT"
        0x2D => "AVSZ3"
        0x2E => "AVSZ4"
        0x30 => "RTPT"
        0x3D => "GPF"
        0x3E => "GPL"
        0x3F => "NCCT"
        _ => "---"
    }

hexval : U8 -> U32
hexval = |c|
    if c >= 48 and c <= 57 {
        c.minus(48).to_u32()
    } else if c >= 97 and c <= 102 {
        c.minus(87).to_u32()
    } else if c >= 65 and c <= 70 {
        c.minus(55).to_u32()
    } else {
        0
    }

# the 8 hex digits ending at `end` (exclusive)
hex8 : List(U8), U64 -> U32
hex8 = |bytes, end| {
    var v = 0.U32
    var k = end.minus(8)
    while k < end {
        v = v.shl_wrap(4).bitwise_or(hexval(bytes.get(k) ?? 48))
        k = k.plus(1)
    }
    v
}

# decimal digits from `from` to `end`
dec : List(U8), U64, U64 -> U64
dec = |bytes, from, end| {
    var v = 0.U64
    var k = from
    while k < end {
        c = bytes.get(k) ?? 0
        if c >= 48 and c <= 57 { v = v.times_wrap(10).plus(c.minus(48).to_u64()) } else {}
        k = k.plus(1)
    }
    v
}

# `GTE 0xCC NAME (sf=D, lm=D, tx=D, vx=D, mx=D)` -> the COP2 command word
command_word : List(U8), U64, U64 -> { cmd : U32, word : U32 }
command_word = |bytes, from, end| {
    cmd = hexval(bytes.get(from.plus(6)) ?? 48).shl_wrap(4).bitwise_or(hexval(bytes.get(from.plus(7)) ?? 48))
    # the five operand digits follow the five '=' signs, in printf order
    var vals = []
    var k = from
    while k < end {
        if (bytes.get(k) ?? 0) == 61 {
            vals = vals.append((bytes.get(k.plus(1)) ?? 48).minus(48).to_u32())
        } else {}
        k = k.plus(1)
    }
    sf = vals.get(0) ?? 0
    lm = vals.get(1) ?? 0
    tx = vals.get(2) ?? 0
    vx = vals.get(3) ?? 0
    mx = vals.get(4) ?? 0
    word = cmd
        .bitwise_or(lm.shl_wrap(10))
        .bitwise_or(tx.shl_wrap(13))
        .bitwise_or(vx.shl_wrap(15))
        .bitwise_or(mx.shl_wrap(17))
        .bitwise_or(sf.shl_wrap(19))
    { cmd: cmd, word: word }
}

parse : List(U8) -> List(Case)
parse = |bytes| {
    n = bytes.len()
    var cases = []
    var started = Bool.False
    var num = 0.U64
    var cmd = 0x40.U32
    var word = 0.U32
    var has_cmd = Bool.False
    var inputs = []
    var outputs = []
    var i = 0.U64
    while i < n {
        var e = i
        while e < n and (bytes.get(e) ?? 10) != 10 {
            e = e.plus(1)
        }
        var stop = e
        if stop > i and (bytes.get(stop.minus(1)) ?? 0) == 13 { stop = stop.minus(1) } else {}
        c0 = bytes.get(i) ?? 0
        if c0 == 62 and stop.minus(i) > 8 {
            # '>' input word
            inputs = inputs.append(hex8(bytes, stop))
        } else if c0 == 60 and stop.minus(i) > 8 {
            # '<' output word
            outputs = outputs.append(hex8(bytes, stop))
        } else if c0 == 71 {
            # 'G' — the optional command line
            cw = command_word(bytes, i, stop)
            cmd = cw.cmd
            word = cw.word
            has_cmd = Bool.True
        } else if c0 == 84 {
            # 'T' — "Test N" starts a case; flush the previous one
            if started {
                cases = cases.append({ num: num, cmd: cmd, word: word, has_cmd: has_cmd, inputs: inputs, outputs: outputs })
            } else {}
            started = Bool.True
            num = dec(bytes, i.plus(5), stop)
            cmd = 0x40
            word = 0
            has_cmd = Bool.False
            inputs = []
            outputs = []
        } else {}
        i = e.plus(1)
    }
    if started {
        cases = cases.append({ num: num, cmd: cmd, word: word, has_cmd: has_cmd, inputs: inputs, outputs: outputs })
    } else {}
    cases
}

# run one case; empty list = pass, else per-register mismatch lines
run_case : Case -> List(Str)
run_case = |c| {
    var regs = Gte.init({})
    var i = 0.U64
    while i < 64 {
        regs = Gte.write(regs, i, c.inputs.get(i) ?? 0)
        i = i.plus(1)
    }
    if c.has_cmd { regs = Gte.command(regs, c.word) } else {}
    var problems = []
    var k = 0.U64
    while k < 64 {
        want = c.outputs.get(k) ?? 0
        got = Gte.read(regs, k)
        if want != got {
            slot = if k < 32 { "cop2d[${k.to_str()}]" } else { "cop2c[${k.minus(32).to_str()}]" }
            problems = problems.append("r[${k.to_str()}] ${slot}: expected ${hex(want)}, got ${hex(got)}")
        } else {}
        k = k.plus(1)
    }
    problems
}

describe : Case -> Str
describe = |c|
    if c.has_cmd {
        "case ${c.num.to_str()} GTE 0x${hex(c.cmd)} ${name_of(c.cmd)} (word ${hex(c.word)}, sf=${if Gte.sf_of(c.word) { "1" } else { "0" }}, lm=${if Gte.lm_of(c.word) { "1" } else { "0" }}, cv=${Gte.cv_of(c.word).to_str()}, v=${Gte.vv_of(c.word).to_str()}, mx=${Gte.mx_of(c.word).to_str()})"
    } else {
        "case ${c.num.to_str()} GTE 0x40 --- (no command — register round-trip only)"
    }

show_lines! = |lines, i, limit|
    if i >= limit {
        Stdout.line!("    ... ${lines.len().minus(i).to_str()} more registers differ")
    } else {
        match lines.get(i) {
            Err(_) => Ok({})
            Ok(p) => {
                Stdout.line!("    ${p}")?
                show_lines!(lines, i.plus(1), limit)
            }
        }
    }

# walk the cases, tallying per command group
run_cases! = |cases, idx, group, gtotal, gfail, total, failed, shown|
    match cases.get(idx) {
        Err(_) => {
            if gtotal > 0 {
                Stdout.line!("  0x${hex(group)} ${name_of(group)}: ${gtotal.minus(gfail).to_str()}/${gtotal.to_str()}${if gfail == 0 { " ok" } else { " FAILED" }}")?
            } else {}
            Ok({ total: total, failed: failed })
        }

        Ok(c) => {
            head =
                if c.cmd != group and gtotal > 0 {
                    Stdout.line!("  0x${hex(group)} ${name_of(group)}: ${gtotal.minus(gfail).to_str()}/${gtotal.to_str()}${if gfail == 0 { " ok" } else { " FAILED" }}")?
                } else {
                    {}
                }
            _ = head
            reset = c.cmd != group
            g0 = if reset { 0.U64 } else { gtotal }
            f0 = if reset { 0.U64 } else { gfail }
            problems = run_case(c)
            if problems.is_empty() {
                run_cases!(cases, idx.plus(1), c.cmd, g0.plus(1), f0, total.plus(1), failed, shown)
            } else {
                next_shown =
                    if shown < 8 {
                        Stdout.line!("  ${describe(c)}:")?
                        show_lines!(problems, 0.U64, 8.U64)?
                        shown.plus(1)
                    } else {
                        shown
                    }
                run_cases!(cases, idx.plus(1), c.cmd, g0.plus(1), f0.plus(1), total.plus(1), failed.plus(1), next_shown)
            }
        }
    }

base_name : Str -> Str
base_name = |path| {
    parts = path.split_on("/")
    parts.get(parts.len().minus_wrap(1)) ?? path
}

show_excluded! = |idx|
    match excluded.get(idx) {
        Err(_) => Ok({})
        Ok(e) => {
            Stdout.line!("EXCLUDED ${e.name}: ${e.reason}")?
            show_excluded!(idx.plus(1))
        }
    }

run_file! = |path_os| {
    name = base_name(Path.from_os_str(path_os).display())
    bytes = Path.from_os_str(path_os).read_bytes!()?
    cases = parse(bytes)
    Stdout.line!("${name}: ${cases.len().to_str()} cases")?
    run_cases!(cases, 0.U64, 0xFFFF.U32, 0.U64, 0.U64, 0.U64, 0.U64, 0.U64)
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
    show_excluded!(0.U64)?
    totals = run_files!(args, 1, { total: 0.U64, failed: 0.U64 })?
    if totals.total == 0 {
        Stdout.line!("no capture given — pass check/gte-fuzz/data/gte_valid_0xc0ffee_50.log")?
        Err(NoInput)
    } else if totals.failed == 0 {
        Stdout.line!("gte-fuzz: ok — ${totals.total.to_str()} cases")
    } else {
        Stdout.line!("gte-fuzz: FAILED — ${totals.failed.to_str()}/${totals.total.to_str()} cases")?
        Err(CasesFailed)
    }
}
