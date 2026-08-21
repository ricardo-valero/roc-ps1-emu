# Parser for the SingleStepTests r3000 .json.bin binary format — verified
# against upstream's transcode_json.py and a hand-decode of real cases
# (see check/single-step/NOTES.md). All fields little-endian; NO magic
# word — the file opens with the test count. Layout:
#
#   file  := num_tests u32, test*
#   test  := name[51: len byte + ascii], opcode u32, opcode_addr u32,
#            state(initial), state(final), cycles
#   state := R[32] u32, hi, lo, epc, tar, cause, pc,
#            branch { target u32, slot u32, take u32 },
#            load   { reg i32 (-1 = none), val u32 }          (172 bytes)
#   cycles := n u32, n x { val i64, actions u32, addr i64, sz u32 } (24 B)
#
# The transcoder's JSON names the branch group "load" and the load group
# "branch" — the binary order above is the semantic truth (verified: the
# {reg, val} group lands in R[reg], the {target, slot, take} group drives
# delay-slot commits). Cycle actions: 4 = instruction fetch, 1 = data
# read, 2 = data write; addr/val fit U32.

State : {
    r : List(U32),
    hi : U32,
    lo : U32,
    epc : U32,
    tar : U32,
    cause : U32,
    pc : U32,
    br : { target : U32, slot : Bool, take : Bool },
    ld : { reg : U32, val : U32 }, # reg 0xFFFFFFFF = no pending load
}

Cycle : { actions : U32, size : U32, addr : U32, val : U32 }

Test : {
    name : Str,
    opcode : U32,
    opcode_addr : U32,
    initial : State,
    final : State,
    cycles : List(Cycle),
}

Vectors := [].{
    u32le : List(U8), U64 -> U32
    u32le = |b, i|
        (b.get(i) ?? 0).to_u32()
            .bitwise_or((b.get(i.plus(1)) ?? 0).to_u32().shl_wrap(8))
            .bitwise_or((b.get(i.plus(2)) ?? 0).to_u32().shl_wrap(16))
            .bitwise_or((b.get(i.plus(3)) ?? 0).to_u32().shl_wrap(24))

    words : List(U8), U64, U64 -> List(U32)
    words = |b, i, n| {
        var out = List.with_capacity(n)
        var k = 0.U64
        while k < n {
            out = out.append(u32le(b, i.plus(k.times_wrap(4))))
            k = k.plus(1)
        }
        out
    }

    parse_state : List(U8), U64 -> State
    parse_state = |b, i| {
        v = words(b, i.plus(128), 11)
        {
            r: words(b, i, 32),
            hi: v.get(0) ?? 0,
            lo: v.get(1) ?? 0,
            epc: v.get(2) ?? 0,
            tar: v.get(3) ?? 0,
            cause: v.get(4) ?? 0,
            pc: v.get(5) ?? 0,
            br: {
                target: v.get(6) ?? 0,
                slot: (v.get(7) ?? 0) != 0,
                take: (v.get(8) ?? 0) != 0,
            },
            ld: {
                reg: v.get(9) ?? 0,
                val: v.get(10) ?? 0,
            },
        }
    }

    state_size : U64
    state_size = 172

    parse_test : List(U8), U64 -> { size : U64, test : Test }
    parse_test = |b, i| {
        name_len = (b.get(i) ?? 0).to_u64()
        name = Str.from_utf8(b.sublist({ start: i.plus(1), len: name_len })) ?? "?"
        p0 = i.plus(51)
        opcode = u32le(b, p0)
        opcode_addr = u32le(b, p0.plus(4))
        s0 = p0.plus(8)
        ini = parse_state(b, s0)
        fin = parse_state(b, s0.plus(state_size))
        cy_at = s0.plus(state_size.times_wrap(2))
        n = u32le(b, cy_at).to_u64()
        var cycles = List.with_capacity(n)
        var k = 0.U64
        while k < n {
            base = cy_at.plus(4).plus(k.times_wrap(24))
            cycles = cycles.append({
                actions: u32le(b, base.plus(8)),
                size: u32le(b, base.plus(20)),
                addr: u32le(b, base.plus(12)),
                val: u32le(b, base),
            })
            k = k.plus(1)
        }
        {
            size: 51.U64.plus(8).plus(state_size.times_wrap(2)).plus(4).plus(n.times_wrap(24)),
            test: { name: name, opcode: opcode, opcode_addr: opcode_addr, initial: ini, final: fin, cycles: cycles },
        }
    }

    parse_file : List(U8) -> Try(List(Test), [Truncated, ..])
    parse_file = |b| {
        n = u32le(b, 0).to_u64()
        var out = List.with_capacity(n)
        var i = 4.U64
        var k = 0.U64
        var bad = Bool.False
        while k < n {
            if i.plus(51) > b.len() {
                bad = Bool.True
                k = n
            } else {
                parsed = parse_test(b, i)
                out = out.append(parsed.test)
                i = i.plus(parsed.size)
                k = k.plus(1)
            }
        }
        if bad or out.len() != n {
            Err(Truncated)
        } else {
            Ok(out)
        }
    }
}

# hand-built single-test image round-trips
expect {
    name_field = [7.U8].concat("TEST $0".to_utf8()).concat(List.repeat(0, 43))
    w32 = |v| [v.to_u8_wrap(), U32.shr_zf_wrap(v, 8).to_u8_wrap(), U32.shr_zf_wrap(v, 16).to_u8_wrap(), U32.shr_zf_wrap(v, 24).to_u8_wrap()]
    state_bytes = |seed| {
        var out = []
        var k = 0.U32
        while k < 43 {
            out = out.concat(w32(seed.plus(k)))
            k = k.plus(1)
        }
        out
    }
    cyc = w32(0x0BAD_F00D.U32).concat(w32(0.U32)).concat(w32(4.U32)).concat(w32(0x1000.U32)).concat(w32(0.U32)).concat(w32(4.U32))
    file = w32(1.U32)
        .concat(name_field)
        .concat(w32(0xDEAD_BEEF.U32))
        .concat(w32(0x8000_1000.U32))
        .concat(state_bytes(100.U32))
        .concat(state_bytes(200.U32))
        .concat(w32(1.U32))
        .concat(cyc)
    match Vectors.parse_file(file) {
        Ok(tests) =>
            match tests.get(0) {
                Ok(t) =>
                    tests.len() == 1
                    and t.name == "TEST $0"
                    and t.opcode == 0xDEAD_BEEF
                    and t.opcode_addr == 0x8000_1000
                    and (t.initial.r.get(0) ?? 0) == 100
                    and (t.initial.r.get(31) ?? 0) == 131
                    and t.initial.r.len() == 32
                    and t.initial.hi == 132
                    and t.initial.lo == 133
                    and t.initial.epc == 134
                    and t.initial.tar == 135
                    and t.initial.cause == 136
                    and t.initial.pc == 137
                    and t.initial.br == { target: 138, slot: Bool.True, take: Bool.True }
                    and t.initial.ld == { reg: 141, val: 142 }
                    and t.final.pc == 237
                    and t.cycles == [{ actions: 4, size: 4, addr: 0x1000, val: 0x0BAD_F00D }]

                Err(_) => Bool.False
            }

        Err(_) => Bool.False
    }
}

expect Vectors.parse_file([]) == Ok([])
