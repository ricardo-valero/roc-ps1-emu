import /Bus
import /Mips
import /Bit

# MIPS R3000A processor core: state in, state out, no effects. One
# architectural instruction per step against a pluggable Bus.
#
# The R3000's two hazards are explicit state:
#   branch — Slot({take, target}) means the instruction ABOUT to execute
#   sits in a branch delay slot; after it runs, PC commits to `target`
#   when `take`, else falls through. Every branch/jump (taken or not)
#   arms this for the next instruction.
#   load — Pending({reg, val}) lands at the END of the next instruction:
#   that instruction reads the stale register file, its own write to the
#   same register wins (cancellation), a second load to the same register
#   supersedes, and LWL/LWR read through the pending value as their merge
#   base. Pending loads land even when the instruction takes an exception
#   (verified against the SingleStepTests vectors).
#
# Exception entry (matching ares' r3000, which generated the vectors):
# CAUSE keeps everything but [31:28] and excode; BD (31) = victim in a
# delay slot, bit 30 = that branch was taken, CE (29:28) = low two bits
# of the primary opcode field, TAR captures the branch target on a
# delay-slot exception. EPC = victim - 4 in a slot, else victim. SR
# pushes its 3-level mode/IE stack; RFE pops it. Vector by SR.BEV.
Cpu := {
    r1 : U32,
    r2 : U32,
    r3 : U32,
    r4 : U32,
    r5 : U32,
    r6 : U32,
    r7 : U32,
    r8 : U32,
    r9 : U32,
    r10 : U32,
    r11 : U32,
    r12 : U32,
    r13 : U32,
    r14 : U32,
    r15 : U32,
    r16 : U32,
    r17 : U32,
    r18 : U32,
    r19 : U32,
    r20 : U32,
    r21 : U32,
    r22 : U32,
    r23 : U32,
    r24 : U32,
    r25 : U32,
    r26 : U32,
    r27 : U32,
    r28 : U32,
    r29 : U32,
    r30 : U32,
    r31 : U32,
    pc : U32,
    hi : U32,
    lo : U32,
    sr : U32,
    cause : U32,
    epc : U32,
    badvaddr : U32,
    tar : U32,
    branch : [NoBranch, Slot({ take : Bool, target : U32 })],
    load : [NoLoad, Pending({ reg : U64, val : U32 })],
    cycles : U64,
}.{
    init : U32 -> Cpu
    init = |pc| {
        r1: 0,
        r2: 0,
        r3: 0,
        r4: 0,
        r5: 0,
        r6: 0,
        r7: 0,
        r8: 0,
        r9: 0,
        r10: 0,
        r11: 0,
        r12: 0,
        r13: 0,
        r14: 0,
        r15: 0,
        r16: 0,
        r17: 0,
        r18: 0,
        r19: 0,
        r20: 0,
        r21: 0,
        r22: 0,
        r23: 0,
        r24: 0,
        r25: 0,
        r26: 0,
        r27: 0,
        r28: 0,
        r29: 0,
        r30: 0,
        r31: 0,
        pc: pc,
        hi: 0,
        lo: 0,
        sr: 0,
        cause: 0,
        epc: 0,
        badvaddr: 0,
        tar: 0,
        branch: NoBranch,
        load: NoLoad,
        cycles: 0,
    }

    get : Cpu, U64 -> U32
    get = |cpu, i|
        match i {
            1 => cpu.r1
            2 => cpu.r2
            3 => cpu.r3
            4 => cpu.r4
            5 => cpu.r5
            6 => cpu.r6
            7 => cpu.r7
            8 => cpu.r8
            9 => cpu.r9
            10 => cpu.r10
            11 => cpu.r11
            12 => cpu.r12
            13 => cpu.r13
            14 => cpu.r14
            15 => cpu.r15
            16 => cpu.r16
            17 => cpu.r17
            18 => cpu.r18
            19 => cpu.r19
            20 => cpu.r20
            21 => cpu.r21
            22 => cpu.r22
            23 => cpu.r23
            24 => cpu.r24
            25 => cpu.r25
            26 => cpu.r26
            27 => cpu.r27
            28 => cpu.r28
            29 => cpu.r29
            30 => cpu.r30
            31 => cpu.r31
            _ => 0
        }

    set_r : Cpu, U64, U32 -> Cpu
    set_r = |cpu, i, v|
        match i {
            1 => { ..cpu, r1: v }
            2 => { ..cpu, r2: v }
            3 => { ..cpu, r3: v }
            4 => { ..cpu, r4: v }
            5 => { ..cpu, r5: v }
            6 => { ..cpu, r6: v }
            7 => { ..cpu, r7: v }
            8 => { ..cpu, r8: v }
            9 => { ..cpu, r9: v }
            10 => { ..cpu, r10: v }
            11 => { ..cpu, r11: v }
            12 => { ..cpu, r12: v }
            13 => { ..cpu, r13: v }
            14 => { ..cpu, r14: v }
            15 => { ..cpu, r15: v }
            16 => { ..cpu, r16: v }
            17 => { ..cpu, r17: v }
            18 => { ..cpu, r18: v }
            19 => { ..cpu, r19: v }
            20 => { ..cpu, r20: v }
            21 => { ..cpu, r21: v }
            22 => { ..cpu, r22: v }
            23 => { ..cpu, r23: v }
            24 => { ..cpu, r24: v }
            25 => { ..cpu, r25: v }
            26 => { ..cpu, r26: v }
            27 => { ..cpu, r27: v }
            28 => { ..cpu, r28: v }
            29 => { ..cpu, r29: v }
            30 => { ..cpu, r30: v }
            31 => { ..cpu, r31: v }
            _ => cpu
        }

    # exception codes
    exc_adel : U32
    exc_adel = 4
    exc_ades : U32
    exc_ades = 5
    exc_sys : U32
    exc_sys = 8
    exc_bp : U32
    exc_bp = 9
    exc_ri : U32
    exc_ri = 10
    exc_cpu : U32
    exc_cpu = 11
    exc_ovf : U32
    exc_ovf = 12

    # Fused step: dispatch assigns `var` deltas and the final Cpu record is
    # built exactly once — the two-phase exec/finish structure with its Out
    # record measured as the dominant per-instruction cost (see the
    # ps1-cpu-perf change notes). wrote_i 0 doubles as "no write" ($zero
    # writes are discarded); load_i 32 means "no pending load".
    step : Cpu, Bus -> { cpu : Cpu, bus : Bus }
    step = |cpu, bus0|
        if cpu.pc.bitwise_and(3) != 0 {
            take_exception(land_all(cpu), bus0, 0, exc_adel, Badv(cpu.pc))
        } else {
            f = bus0.fetch32(cpu.pc)
            op = f.val
            bus_in = f.bus
            var wrote_i = 0.U64
            var wrote_v = 0.U32
            var load_i = 32.U64
            var load_v = 0.U32
            var br_arm = Bool.False
            var br_take = Bool.False
            var br_target = 0.U32
            var new_hi = cpu.hi
            var new_lo = cpu.lo
            var new_sr = cpu.sr
            var new_cause = cpu.cause
            var has_exc = Bool.False
            var exc_code = 0.U32
            var exc_badv = 0.U32
            var has_badv = Bool.False
            o = Mips.op6(op)
            rs_i = Mips.rs(op)
            rt_i = Mips.rt(op)
            rd_i = Mips.rd(op)
            a = get(cpu, rs_i)
            b = get(cpu, rt_i)
            si = Mips.simm(op)
            slot_addr =
                match cpu.branch {
                    Slot(sb) => if sb.take { sb.target } else { cpu.pc.plus_wrap(4) }
                    NoBranch => cpu.pc.plus_wrap(4)
                }
            bus1 = match o {
                0 =>
                    match Mips.funct(op) {
                        0 => { # SLL
                            wrote_i = rd_i
                            wrote_v = b.shl_wrap(Mips.sa(op))
                            bus_in
                        }

                        2 => { # SRL
                            wrote_i = rd_i
                            wrote_v = b.shr_zf_wrap(Mips.sa(op))
                            bus_in
                        }

                        3 => { # SRA
                            wrote_i = rd_i
                            wrote_v = sra(b, Mips.sa(op))
                            bus_in
                        }

                        4 => { # SLLV
                            wrote_i = rd_i
                            wrote_v = b.shl_wrap(a.bitwise_and(31).to_u8_wrap())
                            bus_in
                        }

                        6 => { # SRLV
                            wrote_i = rd_i
                            wrote_v = b.shr_zf_wrap(a.bitwise_and(31).to_u8_wrap())
                            bus_in
                        }

                        7 => { # SRAV
                            wrote_i = rd_i
                            wrote_v = sra(b, a.bitwise_and(31).to_u8_wrap())
                            bus_in
                        }

                        8 => { # JR
                            br_arm = Bool.True
                            br_take = Bool.True
                            br_target = a
                            bus_in
                        }

                        9 => { # JALR
                            wrote_i = rd_i
                            wrote_v = slot_addr.plus_wrap(4)
                            br_arm = Bool.True
                            br_take = Bool.True
                            br_target = a
                            bus_in
                        }

                        12 => { # SYSCALL
                            has_exc = Bool.True
                            exc_code = exc_sys
                            bus_in
                        }

                        13 => { # BREAK
                            has_exc = Bool.True
                            exc_code = exc_bp
                            bus_in
                        }

                        16 => { # MFHI
                            wrote_i = rd_i
                            wrote_v = cpu.hi
                            bus_in
                        }

                        17 => { # MTHI
                            new_hi = a
                            bus_in
                        }

                        18 => { # MFLO
                            wrote_i = rd_i
                            wrote_v = cpu.lo
                            bus_in
                        }

                        19 => { # MTLO
                            new_lo = a
                            bus_in
                        }

                        24 => { # MULT
                            hl = Mips.mult_signed(a, b)
                            new_hi = hl.hi
                            new_lo = hl.lo
                            bus_in
                        }

                        25 => { # MULTU
                            hl = Mips.mult_unsigned(a, b)
                            new_hi = hl.hi
                            new_lo = hl.lo
                            bus_in
                        }

                        26 => { # DIV
                            hl = Mips.div_signed(a, b)
                            new_hi = hl.hi
                            new_lo = hl.lo
                            bus_in
                        }

                        27 => { # DIVU
                            hl = Mips.div_unsigned(a, b)
                            new_hi = hl.hi
                            new_lo = hl.lo
                            bus_in
                        }

                        32 => { # ADD
                            sum = a.plus_wrap(b)
                            if Mips.add_overflows(a, b, sum) {
                                has_exc = Bool.True
                                exc_code = exc_ovf
                            } else {
                                wrote_i = rd_i
                                wrote_v = sum
                            }
                            bus_in
                        }

                        33 => { # ADDU
                            wrote_i = rd_i
                            wrote_v = a.plus_wrap(b)
                            bus_in
                        }

                        34 => { # SUB
                            diff = a.minus_wrap(b)
                            if Mips.sub_overflows(a, b, diff) {
                                has_exc = Bool.True
                                exc_code = exc_ovf
                            } else {
                                wrote_i = rd_i
                                wrote_v = diff
                            }
                            bus_in
                        }

                        35 => { # SUBU
                            wrote_i = rd_i
                            wrote_v = a.minus_wrap(b)
                            bus_in
                        }

                        36 => { # AND
                            wrote_i = rd_i
                            wrote_v = a.bitwise_and(b)
                            bus_in
                        }

                        37 => { # OR
                            wrote_i = rd_i
                            wrote_v = a.bitwise_or(b)
                            bus_in
                        }

                        38 => { # XOR
                            wrote_i = rd_i
                            wrote_v = a.bitwise_xor(b)
                            bus_in
                        }

                        39 => { # NOR
                            wrote_i = rd_i
                            wrote_v = a.bitwise_or(b).bitwise_not()
                            bus_in
                        }

                        42 => { # SLT
                            wrote_i = rd_i
                            wrote_v = if Mips.lt_signed(a, b) { 1 } else { 0 }
                            bus_in
                        }

                        43 => { # SLTU
                            wrote_i = rd_i
                            wrote_v = if a < b { 1 } else { 0 }
                            bus_in
                        }

                        _ => {
                            has_exc = Bool.True
                            exc_code = exc_ri
                            bus_in
                        }
                    }

                1 => { # REGIMM: BLTZ/BGEZ (+AL); link is unconditional
                    ge = rt_i.bitwise_and(1) == 1
                    br_arm = Bool.True
                    br_take = if ge { a < 0x8000_0000 } else { a >= 0x8000_0000 }
                    br_target = Mips.branch_target(op, slot_addr)
                    if rt_i.bitwise_and(0x1E) == 0x10 {
                        wrote_i = 31
                        wrote_v = slot_addr.plus_wrap(4)
                    } else {}
                    bus_in
                }

                2 => { # J
                    br_arm = Bool.True
                    br_take = Bool.True
                    br_target = Mips.jump_target(op, slot_addr)
                    bus_in
                }

                3 => { # JAL
                    wrote_i = 31
                    wrote_v = slot_addr.plus_wrap(4)
                    br_arm = Bool.True
                    br_take = Bool.True
                    br_target = Mips.jump_target(op, slot_addr)
                    bus_in
                }

                4 => { # BEQ
                    br_arm = Bool.True
                    br_take = a == b
                    br_target = Mips.branch_target(op, slot_addr)
                    bus_in
                }

                5 => { # BNE
                    br_arm = Bool.True
                    br_take = a != b
                    br_target = Mips.branch_target(op, slot_addr)
                    bus_in
                }

                6 => { # BLEZ
                    br_arm = Bool.True
                    br_take = a == 0 or a >= 0x8000_0000
                    br_target = Mips.branch_target(op, slot_addr)
                    bus_in
                }

                7 => { # BGTZ
                    br_arm = Bool.True
                    br_take = a != 0 and a < 0x8000_0000
                    br_target = Mips.branch_target(op, slot_addr)
                    bus_in
                }

                8 => { # ADDI
                    sum = a.plus_wrap(si)
                    if Mips.add_overflows(a, si, sum) {
                        has_exc = Bool.True
                        exc_code = exc_ovf
                    } else {
                        wrote_i = rt_i
                        wrote_v = sum
                    }
                    bus_in
                }

                9 => { # ADDIU
                    wrote_i = rt_i
                    wrote_v = a.plus_wrap(si)
                    bus_in
                }

                10 => { # SLTI
                    wrote_i = rt_i
                    wrote_v = if Mips.lt_signed(a, si) { 1 } else { 0 }
                    bus_in
                }

                11 => { # SLTIU
                    wrote_i = rt_i
                    wrote_v = if a < si { 1 } else { 0 }
                    bus_in
                }

                12 => { # ANDI
                    wrote_i = rt_i
                    wrote_v = a.bitwise_and(Mips.imm(op))
                    bus_in
                }

                13 => { # ORI
                    wrote_i = rt_i
                    wrote_v = a.bitwise_or(Mips.imm(op))
                    bus_in
                }

                14 => { # XORI
                    wrote_i = rt_i
                    wrote_v = a.bitwise_xor(Mips.imm(op))
                    bus_in
                }

                15 => { # LUI
                    wrote_i = rt_i
                    wrote_v = Mips.imm(op).shl_wrap(16)
                    bus_in
                }

                16 => # COP0
                    match rs_i {
                        0 => { # MFC0 (load-delayed)
                            load_i = rt_i
                            load_v = cop0_read(cpu, rd_i)
                            bus_in
                        }

                        4 =>
                            match rd_i { # MTC0
                                12 => {
                                    new_sr = b
                                    bus_in
                                }

                                13 => {
                                    new_cause = cpu.cause.bitwise_and(0xFFFF_FCFF).bitwise_or(b.bitwise_and(0x0000_0300))
                                    bus_in
                                }

                                                _ => bus_in # other cop0 registers: ignored for now
                            }

                        16 =>
                            if Mips.funct(op) == 16 { # RFE
                                new_sr = cpu.sr.bitwise_and(0xFFFF_FFF0).bitwise_or(cpu.sr.shr_zf_wrap(2).bitwise_and(0x0F))
                                bus_in
                            } else {
                                has_exc = Bool.True
                                exc_code = exc_ri
                                bus_in
                            }

                        _ => {
                            has_exc = Bool.True
                            exc_code = exc_ri
                            bus_in
                        }
                    }

                18 => { # COP2: GTE arrives in its own change
                    has_exc = Bool.True
                    exc_code = exc_cpu
                    bus_in
                }

                32 => { # LB
                    rr = bus_in.read(1, a.plus_wrap(si))
                    load_i = rt_i
                    load_v = Bit.sext8(rr.val)
                    rr.bus
                }

                33 => { # LH
                    va = a.plus_wrap(si)
                    if va.bitwise_and(1) != 0 {
                        has_exc = Bool.True
                        exc_code = exc_adel
                        has_badv = Bool.True
                        exc_badv = va
                        bus_in
                    } else {
                        rr = bus_in.read(2, va)
                        load_i = rt_i
                        load_v = Bit.sext16(rr.val)
                        rr.bus
                    }
                }

                34 => { # LWL: read the (sh+1) bytes ending at va (1-2 accesses)
                    va = a.plus_wrap(si)
                    sh = va.bitwise_and(3)
                    aligned = va.bitwise_and(0xFFFF_FFFC)
                    merge_base =
                        match cpu.load {
                            Pending(p) => if p.reg == rt_i { p.val } else { b }
                            NoLoad => b
                        }
                    got =
                        if sh == 0 {
                            rr = bus_in.read(1, va)
                            { bus: rr.bus, data: rr.val.bitwise_and(0xFF) }
                        } else if sh == 1 {
                            rr = bus_in.read(2, aligned)
                            { bus: rr.bus, data: rr.val.bitwise_and(0xFFFF) }
                        } else if sh == 2 {
                            r1 = bus_in.read(2, aligned)
                            r2 = r1.bus.read(1, aligned.plus_wrap(2))
                            { bus: r2.bus, data: r1.val.bitwise_and(0xFFFF).bitwise_or(r2.val.bitwise_and(0xFF).shl_wrap(16)) }
                        } else {
                            rr = bus_in.read(4, aligned)
                            { bus: rr.bus, data: rr.val }
                        }
                    load_i = rt_i
                    load_v = Mips.lwl_merge(merge_base, got.data, sh)
                    got.bus
                }

                35 => { # LW
                    va = a.plus_wrap(si)
                    if va.bitwise_and(3) != 0 {
                        has_exc = Bool.True
                        exc_code = exc_adel
                        has_badv = Bool.True
                        exc_badv = va
                        bus_in
                    } else {
                        rr = bus_in.read(4, va)
                        load_i = rt_i
                        load_v = rr.val
                        rr.bus
                    }
                }

                36 => { # LBU
                    rr = bus_in.read(1, a.plus_wrap(si))
                    load_i = rt_i
                    load_v = rr.val.bitwise_and(0xFF)
                    rr.bus
                }

                37 => { # LHU
                    va = a.plus_wrap(si)
                    if va.bitwise_and(1) != 0 {
                        has_exc = Bool.True
                        exc_code = exc_adel
                        has_badv = Bool.True
                        exc_badv = va
                        bus_in
                    } else {
                        rr = bus_in.read(2, va)
                        load_i = rt_i
                        load_v = rr.val.bitwise_and(0xFFFF)
                        rr.bus
                    }
                }

                38 => { # LWR: read the (4-sh) bytes starting at va (1-2 accesses)
                    va = a.plus_wrap(si)
                    sh = va.bitwise_and(3)
                    merge_base =
                        match cpu.load {
                            Pending(p) => if p.reg == rt_i { p.val } else { b }
                            NoLoad => b
                        }
                    got =
                        if sh == 0 {
                            rr = bus_in.read(4, va)
                            { bus: rr.bus, data: rr.val }
                        } else if sh == 1 {
                            r1 = bus_in.read(1, va)
                            r2 = r1.bus.read(2, va.plus_wrap(1))
                            { bus: r2.bus, data: r1.val.bitwise_and(0xFF).bitwise_or(r2.val.bitwise_and(0xFFFF).shl_wrap(8)) }
                        } else if sh == 2 {
                            rr = bus_in.read(2, va)
                            { bus: rr.bus, data: rr.val.bitwise_and(0xFFFF) }
                        } else {
                            rr = bus_in.read(1, va)
                            { bus: rr.bus, data: rr.val.bitwise_and(0xFF) }
                        }
                    load_i = rt_i
                    load_v = Mips.lwr_merge(merge_base, got.data, sh)
                    got.bus
                }

                40 => bus_in.write(1, a.plus_wrap(si), b) # SB

                41 => { # SH
                    va = a.plus_wrap(si)
                    if va.bitwise_and(1) != 0 {
                        has_exc = Bool.True
                        exc_code = exc_ades
                        has_badv = Bool.True
                        exc_badv = va
                        bus_in
                    } else {
                        bus_in.write(2, va, b)
                    }
                }

                42 => { # SWL: store rt's top (sh+1) bytes ending at va (1-2 accesses)
                    va = a.plus_wrap(si)
                    sh = va.bitwise_and(3)
                    aligned = va.bitwise_and(0xFFFF_FFFC)
                    if sh == 0 {
                        bus_in.write(1, va, b.shr_zf_wrap(24))
                    } else if sh == 1 {
                        bus_in.write(2, aligned, b.shr_zf_wrap(16))
                    } else if sh == 2 {
                        bus_in.write(2, aligned, b.shr_zf_wrap(8)).write(1, aligned.plus_wrap(2), b.shr_zf_wrap(24))
                    } else {
                        bus_in.write(4, aligned, b)
                    }
                }

                43 => { # SW
                    va = a.plus_wrap(si)
                    if va.bitwise_and(3) != 0 {
                        has_exc = Bool.True
                        exc_code = exc_ades
                        has_badv = Bool.True
                        exc_badv = va
                        bus_in
                    } else {
                        bus_in.write(4, va, b)
                    }
                }

                46 => { # SWR: store rt's bottom (4-sh) bytes starting at va (1-2 accesses)
                    va = a.plus_wrap(si)
                    sh = va.bitwise_and(3)
                    if sh == 0 {
                        bus_in.write(4, va, b)
                    } else if sh == 1 {
                        bus_in.write(1, va, b).write(2, va.plus_wrap(1), b.shr_zf_wrap(8))
                    } else if sh == 2 {
                        bus_in.write(2, va, b)
                    } else {
                        bus_in.write(1, va, b)
                    }
                }

                50 => { # LWC2
                    has_exc = Bool.True
                    exc_code = exc_cpu
                    bus_in
                }

                58 => { # SWC2
                    has_exc = Bool.True
                    exc_code = exc_cpu
                    bus_in
                }

                _ => {
                    has_exc = Bool.True
                    exc_code = exc_ri
                    bus_in
                }
            }
            if has_exc {
                take_exception(land_all(cpu), bus1, op, exc_code, if has_badv { Badv(exc_badv) } else { NoBadv })
            } else {
                new_pc =
                    match cpu.branch {
                        Slot(bh) => if bh.take { bh.target } else { cpu.pc.plus_wrap(4) }
                        NoBranch => cpu.pc.plus_wrap(4)
                    }
                landed =
                    match cpu.load {
                        NoLoad => cpu
                        Pending(p) =>
                            if p.reg == wrote_i or p.reg == load_i {
                                cpu
                            } else {
                                set_r(cpu, p.reg, p.val)
                            }
                    }
                written = if wrote_i == 0 { landed } else { set_r(landed, wrote_i, wrote_v) }
                {
                    cpu: { ..written,
                        pc: new_pc,
                        hi: new_hi,
                        lo: new_lo,
                        sr: new_sr,
                        cause: new_cause,
                        branch: if br_arm { Slot({ take: br_take, target: br_target }) } else { NoBranch },
                        load: if load_i < 32 { Pending({ reg: load_i, val: load_v }) } else { NoLoad },
                        cycles: cpu.cycles.plus(1),
                    },
                    bus: bus1,
                }
            }
        }

    # pending load lands unconditionally (exception path; a faulting
    # instruction wrote nothing and loaded nothing)
    land_all : Cpu -> Cpu
    land_all = |cpu|
        match cpu.load {
            NoLoad => cpu
            Pending(p) => set_r(cpu, p.reg, p.val)
        }

    take_exception : Cpu, Bus, U32, U32, [NoBadv, Badv(U32)] -> { cpu : Cpu, bus : Bus }
    take_exception = |cpu, bus, op, code, badv| {
        slot_info =
            match cpu.branch {
                Slot(b) => { slot: Bool.True, take: b.take, target: b.target }
                NoBranch => { slot: Bool.False, take: Bool.False, target: 0 }
            }
        bd = if slot_info.slot { 0x8000_0000 } else { 0 }
        bt = if slot_info.slot and slot_info.take { 0x4000_0000 } else { 0 }
        ce = op.shr_zf_wrap(26).bitwise_and(3).shl_wrap(28)
        new_cause =
            cpu.cause.bitwise_and(0x0FFF_FF83)
                .bitwise_or(bd)
                .bitwise_or(bt)
                .bitwise_or(ce)
                .bitwise_or(code.shl_wrap(2))
        new_sr = cpu.sr.bitwise_and(0xFFFF_FFC0).bitwise_or(cpu.sr.shl_wrap(2).bitwise_and(0x3F))
        vector = if cpu.sr.bitwise_and(0x0040_0000) != 0 { 0xBFC0_0180 } else { 0x8000_0080 }
        new_badv =
            match badv {
                Badv(a) => a
                NoBadv => cpu.badvaddr
            }
        {
            cpu: { ..cpu,
                pc: vector,
                sr: new_sr,
                cause: new_cause,
                epc: if slot_info.slot { cpu.pc.minus_wrap(4) } else { cpu.pc },
                badvaddr: new_badv,
                tar: if slot_info.slot { slot_info.target } else { cpu.tar },
                branch: NoBranch,
                load: NoLoad,
                cycles: cpu.cycles.plus(1),
            },
            bus: bus,
        }
    }

    cop0_read : Cpu, U64 -> U32
    cop0_read = |cpu, reg|
        match reg {
            6 => cpu.tar
            8 => cpu.badvaddr
            12 => cpu.sr
            13 => cpu.cause
            14 => cpu.epc
            15 => 0x0000_0002 # PRId: R3000A as found in the PSX
            _ => 0
        }

    # arithmetic shift right: ~(~v >> n) sign-fills without variable masks
    sra : U32, U8 -> U32
    sra = |v, n|
        if v >= 0x8000_0000 {
            v.bitwise_not().shr_zf_wrap(n).bitwise_not()
        } else {
            v.shr_zf_wrap(n)
        }
}

# helper: run one instruction over a Vector bus from a bare state
run1 = |pc, regs, op, reads| {
    seeded = regs.fold({ cpu: Cpu.init(pc), i: 0.U64 }, |st, v| { cpu: st.cpu.set_r(st.i, v), i: st.i.plus(1) })
    Cpu.step(seeded.cpu, Bus.vector(op, pc, reads))
}

# SRA sign-fills; SLL/SRL do not
expect Cpu.sra(0x8000_0000, 4) == 0xF800_0000
expect Cpu.sra(0x0800_0000, 4) == 0x0080_0000

# ADDIU + sign-extended immediate; $zero write discarded
expect {
    r = run1(0x1000, [0, 5], 0x2422_FFFF, []) # ADDIU r2, r1, -1
    z = run1(0x1000, [0, 5], 0x2420_FFFF, []) # ADDIU r0, r1, -1
    r.cpu.get(2) == 4 and r.cpu.pc == 0x1004 and z.cpu.get(0) == 0
}

# ADD overflow traps (rd untouched), ADDU wraps
expect {
    ovf = run1(0x1000, [0, 0x7FFF_FFFF, 1], 0x0022_1820, []) # ADD r3, r1, r2
    ok = run1(0x1000, [0, 0x7FFF_FFFF, 1], 0x0022_1821, []) # ADDU r3, r1, r2
    ovf.cpu.pc == 0x8000_0080
    and ovf.cpu.epc == 0x1000
    and ovf.cpu.cause.bitwise_and(0x7C) == 48 # excode 12
    and ovf.cpu.get(3) == 0
    and ok.cpu.get(3) == 0x8000_0000
}

# branch delay slot: taken BNE commits after the next instruction
expect {
    b = run1(0x1000, [0, 1, 2], 0x1422_0010, []) # BNE r1, r2, +0x10
    step2 = Cpu.step(b.cpu, Bus.vector(0x0000_0000, 0x1004, [])) # delay slot: NOP (SLL r0)
    b.cpu.pc == 0x1004
    and b.cpu.branch == Slot({ take: Bool.True, target: 0x1044 })
    and step2.cpu.pc == 0x1044
    and step2.cpu.branch == NoBranch
}

# JAL links pc+8 and the delay slot executes before the jump
expect {
    j = run1(0x2000, [], 0x0C00_1000, []) # JAL 0x4000
    j.cpu.get(31) == 0x2008 and j.cpu.branch == Slot({ take: Bool.True, target: 0x0000_4000 })
}

# load delay: stale read in the slot, value lands one instruction later
expect {
    l = run1(0x1000, [0, 0x50], 0x8C22_0000, [0xAB]) # LW r2, 0(r1)
    mid = Cpu.step(l.cpu, Bus.vector(0x0044_1825, 0x1004, [])) # OR r3, r2, r4 — stale r2
    mid2 = Cpu.step(mid.cpu, Bus.vector(0x0000_0000, 0x1008, []))
    l.cpu.get(2) == 0 # not yet visible
    and mid.cpu.get(3) == 0 # read the stale zero
    and mid.cpu.get(2) == 0xAB # landed after the slot instruction
    and mid2.cpu.get(2) == 0xAB
}

# delay-slot write to the same register wins over the pending load
expect {
    l = run1(0x1000, [0, 0x50], 0x8C22_0000, [0xAB]) # LW r2
    w = Cpu.step(l.cpu, Bus.vector(0x2402_0007, 0x1004, [])) # ADDIU r2, r0, 7
    w.cpu.get(2) == 7
}

# LWL reads through a pending load to the same register and re-enters the pipe
expect {
    l = run1(0x1000, [0, 0x50], 0x8C22_0000, [0x0000_00AB]) # LW r2 <- 0xAB
    lwl = Cpu.step(l.cpu, Bus.vector(0x8822_0007, 0x1004, [0x1122_3344])) # LWL r2, 7(r1): vaddr 0x57, sh 3
    done = Cpu.step(lwl.cpu, Bus.vector(0x0000_0000, 0x1008, []))
    lwl.cpu.get(2) == 0 # still in the pipe
    and lwl.cpu.load == Pending({ reg: 2, val: 0x1122_3344 }) # sh 3: whole word
    and done.cpu.get(2) == 0x1122_3344
}

# exception in a taken delay slot: BD + bit30 set, EPC = branch, TAR = target
expect {
    b = run1(0x1000, [0, 1, 2], 0x1422_0010, []) # taken BNE
    f = Cpu.step(b.cpu, Bus.vector(0x8C22_0001, 0x1004, [])) # LW r2, 1(r1): misaligned
    f.cpu.pc == 0x8000_0080
    and f.cpu.epc == 0x1000
    and f.cpu.cause.bitwise_and(0xC000_0000) == 0xC000_0000
    and f.cpu.cause.bitwise_and(0x7C) == 16 # AdEL
    and f.cpu.tar == 0x1044
    and f.cpu.badvaddr == 2
}

# SYSCALL vectors with excode 8; RFE pops the SR stack
expect {
    s = run1(0x1000, [], 0x0000_000C, [])
    withsr = { ..Cpu.init(0x3000), sr: 0x0000_0C } # bits set after a push
    rfe = Cpu.step(withsr, Bus.vector(0x4200_0010, 0x3000, [])) # RFE
    s.cpu.pc == 0x8000_0080
    and s.cpu.cause.bitwise_and(0x7C) == 32
    and s.cpu.sr.bitwise_and(0x3F) == 0 # push from zero stays zero
    and rfe.cpu.sr.bitwise_and(0x0F) == 0x03 # popped one level
}

# MFC0 is load-delayed; MTC0 writes SR
expect {
    withsr = { ..Cpu.init(0x1000), sr: 0x1234_5678 }
    m = Cpu.step(withsr, Bus.vector(0x4002_6000, 0x1000, [])) # MFC0 r2, sr
    m2 = Cpu.step(m.cpu, Bus.vector(0x0000_0000, 0x1004, []))
    w = run1(0x1000, [0, 0xFFFF_FFFF], 0x4081_6000, []) # MTC0 r1 -> sr
    m.cpu.get(2) == 0 and m2.cpu.get(2) == 0x1234_5678 and w.cpu.sr == 0xFFFF_FFFF
}

# COP2 raises coprocessor-unusable with CE = 2
expect {
    g = run1(0x1000, [], 0x4A00_0001, []) # COP2 op
    g.cpu.pc == 0x8000_0080
    and g.cpu.cause.bitwise_and(0x7C) == 44 # excode 11
    and g.cpu.cause.bitwise_and(0x3000_0000) == 0x2000_0000 # CE = 2
}
