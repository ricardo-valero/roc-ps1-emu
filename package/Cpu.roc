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
    r : List(U32),
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
        r: List.repeat(0, 32),
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
    get = |cpu, i| if i == 0 { 0 } else { cpu.r.get(i) ?? 0 }

    set_r : Cpu, U64, U32 -> Cpu
    set_r = |cpu, i, v| if i == 0 { cpu } else { { ..cpu, r: cpu.r.set(i, v) ?? cpu.r } }

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

    step : Cpu, Bus -> { cpu : Cpu, bus : Bus }
    step = |cpu, bus0|
        if cpu.pc.bitwise_and(3) != 0 {
            # fetch address error: no fetch happens, no opcode for CE
            take_exception(cpu, bus0, 0, exc_adel, Badv(cpu.pc))
        } else {
            f = bus0.fetch32(cpu.pc)
            out = exec(cpu, f.bus, f.val)
            match out.exc {
                Exc(e) => {
                    landed = land_pending(cpu, NoWrite, NoLoad)
                    take_exception(landed, out.bus, f.val, e.code, e.badv)
                }

                NoExc => finish(cpu, out)
            }
        }

    # pending load lands unless the instruction wrote or re-loaded the register
    land_pending : Cpu, [NoWrite, Wrote(U64, U32)], [NoLoad, Pending({ reg : U64, val : U32 })] -> Cpu
    land_pending = |cpu, wrote, new_load|
        match cpu.load {
            NoLoad => cpu
            Pending(p) => {
                blocked_w =
                    match wrote {
                        Wrote(wi, _) => wi == p.reg
                        NoWrite => Bool.False
                    }
                blocked_l =
                    match new_load {
                        Pending(n) => n.reg == p.reg
                        NoLoad => Bool.False
                    }
                if blocked_w or blocked_l { cpu } else { cpu.set_r(p.reg, p.val) }
            }
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

    # single record construction per step: the fleet's perf lesson is that
    # chained { ..cpu } spread-copies dominate the per-instruction cost
    finish : Cpu, _ -> { cpu : Cpu, bus : Bus }
    finish = |cpu, out| {
        new_pc =
            match cpu.branch {
                Slot(b) => if b.take { b.target } else { cpu.pc.plus_wrap(4) }
                NoBranch => cpu.pc.plus_wrap(4)
            }
        r1 =
            match cpu.load {
                NoLoad => cpu.r
                Pending(p) => {
                    blocked_w =
                        match out.wrote {
                            Wrote(wi, _) => wi == p.reg
                            NoWrite => Bool.False
                        }
                    blocked_l =
                        match out.new_load {
                            Pending(n) => n.reg == p.reg
                            NoLoad => Bool.False
                        }
                    if blocked_w or blocked_l or p.reg == 0 { cpu.r } else { cpu.r.set(p.reg, p.val) ?? cpu.r }
                }
            }
        r2 =
            match out.wrote {
                Wrote(wi, wv) => if wi == 0 { r1 } else { r1.set(wi, wv) ?? r1 }
                NoWrite => r1
            }
        hilo =
            match out.hilo {
                SetHiLo(h, l) => { hi: h, lo: l }
                KeepHiLo => { hi: cpu.hi, lo: cpu.lo }
            }
        src =
            match out.cop0 {
                SetSr(v) => { sr: v, cause: cpu.cause }
                SetCause(v) => { sr: cpu.sr, cause: cpu.cause.bitwise_and(0xFFFF_FCFF).bitwise_or(v.bitwise_and(0x0000_0300)) }
                Rfe => { sr: cpu.sr.bitwise_and(0xFFFF_FFF0).bitwise_or(cpu.sr.shr_zf_wrap(2).bitwise_and(0x0F)), cause: cpu.cause }
                KeepCop0 => { sr: cpu.sr, cause: cpu.cause }
            }
        {
            cpu: { ..cpu,
                r: r2,
                pc: new_pc,
                hi: hilo.hi,
                lo: hilo.lo,
                sr: src.sr,
                cause: src.cause,
                branch: out.new_branch,
                load: out.new_load,
                cycles: cpu.cycles.plus(1),
            },
            bus: out.bus,
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

    # one instruction: returns deltas for finish/step to resolve
    exec : Cpu, Bus, U32 -> _
    exec = |cpu, bus, op| {
        none = { bus: bus, wrote: NoWrite, new_load: NoLoad, new_branch: NoBranch, hilo: KeepHiLo, cop0: KeepCop0, exc: NoExc }
        o = Mips.op6(op)
        rs_i = Mips.rs(op)
        rt_i = Mips.rt(op)
        rd_i = Mips.rd(op)
        a = cpu.get(rs_i)
        b = cpu.get(rt_i)
        si = Mips.simm(op)
        zi = Mips.imm(op)
        # branch/jump targets and link addresses are relative to where the
        # delay slot actually is: pc+4 normally, the pending destination
        # inside a taken delay slot (pinned by the in-slot vector cases)
        slot_addr =
            match cpu.branch {
                Slot(sb) => if sb.take { sb.target } else { cpu.pc.plus_wrap(4) }
                NoBranch => cpu.pc.plus_wrap(4)
            }
        link = slot_addr.plus_wrap(4)
        btarget = Mips.branch_target(op, slot_addr)
        vaddr = a.plus_wrap(si)
        # pending value reads through for LWL/LWR merges
        merge_base =
            match cpu.load {
                Pending(p) => if p.reg == rt_i { p.val } else { b }
                NoLoad => b
            }
        match o {
            0 =>
                match Mips.funct(op) {
                    0 => { ..none, wrote: Wrote(rd_i, b.shl_wrap(Mips.sa(op))) } # SLL
                    2 => { ..none, wrote: Wrote(rd_i, b.shr_zf_wrap(Mips.sa(op))) } # SRL
                    3 => { ..none, wrote: Wrote(rd_i, sra(b, Mips.sa(op))) } # SRA
                    4 => { ..none, wrote: Wrote(rd_i, b.shl_wrap(a.bitwise_and(31).to_u8_wrap())) } # SLLV
                    6 => { ..none, wrote: Wrote(rd_i, b.shr_zf_wrap(a.bitwise_and(31).to_u8_wrap())) } # SRLV
                    7 => { ..none, wrote: Wrote(rd_i, sra(b, a.bitwise_and(31).to_u8_wrap())) } # SRAV
                    8 => { ..none, new_branch: Slot({ take: Bool.True, target: a }) } # JR
                    9 => { ..none, wrote: Wrote(rd_i, link), new_branch: Slot({ take: Bool.True, target: a }) } # JALR
                    12 => { ..none, exc: Exc({ code: exc_sys, badv: NoBadv }) } # SYSCALL
                    13 => { ..none, exc: Exc({ code: exc_bp, badv: NoBadv }) } # BREAK
                    16 => { ..none, wrote: Wrote(rd_i, cpu.hi) } # MFHI
                    17 => { ..none, hilo: SetHiLo(a, cpu.lo) } # MTHI
                    18 => { ..none, wrote: Wrote(rd_i, cpu.lo) } # MFLO
                    19 => { ..none, hilo: SetHiLo(cpu.hi, a) } # MTLO
                    24 => { ..none, hilo: hilo_of(Mips.mult_signed(a, b)) } # MULT
                    25 => { ..none, hilo: hilo_of(Mips.mult_unsigned(a, b)) } # MULTU
                    26 => { ..none, hilo: hilo_of(Mips.div_signed(a, b)) } # DIV
                    27 => { ..none, hilo: hilo_of(Mips.div_unsigned(a, b)) } # DIVU
                    32 => { # ADD
                        sum = a.plus_wrap(b)
                        if Mips.add_overflows(a, b, sum) { { ..none, exc: Exc({ code: exc_ovf, badv: NoBadv }) } } else { { ..none, wrote: Wrote(rd_i, sum) } }
                    }

                    33 => { ..none, wrote: Wrote(rd_i, a.plus_wrap(b)) } # ADDU
                    34 => { # SUB
                        diff = a.minus_wrap(b)
                        if Mips.sub_overflows(a, b, diff) { { ..none, exc: Exc({ code: exc_ovf, badv: NoBadv }) } } else { { ..none, wrote: Wrote(rd_i, diff) } }
                    }

                    35 => { ..none, wrote: Wrote(rd_i, a.minus_wrap(b)) } # SUBU
                    36 => { ..none, wrote: Wrote(rd_i, a.bitwise_and(b)) } # AND
                    37 => { ..none, wrote: Wrote(rd_i, a.bitwise_or(b)) } # OR
                    38 => { ..none, wrote: Wrote(rd_i, a.bitwise_xor(b)) } # XOR
                    39 => { ..none, wrote: Wrote(rd_i, a.bitwise_or(b).bitwise_not()) } # NOR
                    42 => { ..none, wrote: Wrote(rd_i, if Mips.lt_signed(a, b) { 1 } else { 0 }) } # SLT
                    43 => { ..none, wrote: Wrote(rd_i, if a < b { 1 } else { 0 }) } # SLTU
                    _ => { ..none, exc: Exc({ code: exc_ri, badv: NoBadv }) }
                }

            1 => { # REGIMM: BLTZ/BGEZ (+AL); link is unconditional
                ge = rt_i.bitwise_and(1) == 1
                taken = if ge { a < 0x8000_0000 } else { a >= 0x8000_0000 }
                with_branch = { ..none, new_branch: Slot({ take: taken, target: btarget }) }
                if rt_i.bitwise_and(0x1E) == 0x10 {
                    { ..with_branch, wrote: Wrote(31, link) }
                } else {
                    with_branch
                }
            }

            2 => { ..none, new_branch: Slot({ take: Bool.True, target: Mips.jump_target(op, slot_addr) }) } # J
            3 => { ..none, wrote: Wrote(31, link), new_branch: Slot({ take: Bool.True, target: Mips.jump_target(op, slot_addr) }) } # JAL
            4 => { ..none, new_branch: Slot({ take: a == b, target: btarget }) } # BEQ
            5 => { ..none, new_branch: Slot({ take: a != b, target: btarget }) } # BNE
            6 => { ..none, new_branch: Slot({ take: a == 0 or a >= 0x8000_0000, target: btarget }) } # BLEZ
            7 => { ..none, new_branch: Slot({ take: a != 0 and a < 0x8000_0000, target: btarget }) } # BGTZ
            8 => { # ADDI
                sum = a.plus_wrap(si)
                if Mips.add_overflows(a, si, sum) { { ..none, exc: Exc({ code: exc_ovf, badv: NoBadv }) } } else { { ..none, wrote: Wrote(rt_i, sum) } }
            }

            9 => { ..none, wrote: Wrote(rt_i, a.plus_wrap(si)) } # ADDIU
            10 => { ..none, wrote: Wrote(rt_i, if Mips.lt_signed(a, si) { 1 } else { 0 }) } # SLTI
            11 => { ..none, wrote: Wrote(rt_i, if a < si { 1 } else { 0 }) } # SLTIU
            12 => { ..none, wrote: Wrote(rt_i, a.bitwise_and(zi)) } # ANDI
            13 => { ..none, wrote: Wrote(rt_i, a.bitwise_or(zi)) } # ORI
            14 => { ..none, wrote: Wrote(rt_i, a.bitwise_xor(zi)) } # XORI
            15 => { ..none, wrote: Wrote(rt_i, zi.shl_wrap(16)) } # LUI
            16 => # COP0
                match rs_i {
                    0 => { ..none, new_load: Pending({ reg: rt_i, val: cop0_read(cpu, rd_i) }) } # MFC0 (load-delayed)
                    4 =>
                        match rd_i { # MTC0
                            12 => { ..none, cop0: SetSr(b) }
                            13 => { ..none, cop0: SetCause(b) }
                            _ => none # other cop0 registers: ignored for now
                        }

                    16 => if Mips.funct(op) == 16 { { ..none, cop0: Rfe } } else { { ..none, exc: Exc({ code: exc_ri, badv: NoBadv }) } }
                    _ => { ..none, exc: Exc({ code: exc_ri, badv: NoBadv }) }
                }

            18 => { ..none, exc: Exc({ code: exc_cpu, badv: NoBadv }) } # COP2: GTE arrives in its own change
            32 => { # LB
                rr = bus.read(1, vaddr)
                { ..none, bus: rr.bus, new_load: Pending({ reg: rt_i, val: Bit.sext8(rr.val) }) }
            }

            33 => # LH
                if vaddr.bitwise_and(1) != 0 {
                    { ..none, exc: Exc({ code: exc_adel, badv: Badv(vaddr) }) }
                } else {
                    rr = bus.read(2, vaddr)
                    { ..none, bus: rr.bus, new_load: Pending({ reg: rt_i, val: Bit.sext16(rr.val) }) }
                }

            34 => { # LWL: read the (sh+1) bytes ending at vaddr (1-2 accesses)
                sh = vaddr.bitwise_and(3)
                aligned = vaddr.bitwise_and(0xFFFF_FFFC)
                got =
                    if sh == 0 {
                        rr = bus.read(1, vaddr)
                        { bus: rr.bus, data: rr.val.bitwise_and(0xFF) }
                    } else if sh == 1 {
                        rr = bus.read(2, aligned)
                        { bus: rr.bus, data: rr.val.bitwise_and(0xFFFF) }
                    } else if sh == 2 {
                        r1 = bus.read(2, aligned)
                        r2 = r1.bus.read(1, aligned.plus_wrap(2))
                        { bus: r2.bus, data: r1.val.bitwise_and(0xFFFF).bitwise_or(r2.val.bitwise_and(0xFF).shl_wrap(16)) }
                    } else {
                        rr = bus.read(4, aligned)
                        { bus: rr.bus, data: rr.val }
                    }
                { ..none, bus: got.bus, new_load: Pending({ reg: rt_i, val: Mips.lwl_merge(merge_base, got.data, sh) }) }
            }

            35 => # LW
                if vaddr.bitwise_and(3) != 0 {
                    { ..none, exc: Exc({ code: exc_adel, badv: Badv(vaddr) }) }
                } else {
                    rr = bus.read(4, vaddr)
                    { ..none, bus: rr.bus, new_load: Pending({ reg: rt_i, val: rr.val }) }
                }

            36 => { # LBU
                rr = bus.read(1, vaddr)
                { ..none, bus: rr.bus, new_load: Pending({ reg: rt_i, val: rr.val.bitwise_and(0xFF) }) }
            }

            37 => # LHU
                if vaddr.bitwise_and(1) != 0 {
                    { ..none, exc: Exc({ code: exc_adel, badv: Badv(vaddr) }) }
                } else {
                    rr = bus.read(2, vaddr)
                    { ..none, bus: rr.bus, new_load: Pending({ reg: rt_i, val: rr.val.bitwise_and(0xFFFF) }) }
                }

            38 => { # LWR: read the (4-sh) bytes starting at vaddr (1-2 accesses)
                sh = vaddr.bitwise_and(3)
                got =
                    if sh == 0 {
                        rr = bus.read(4, vaddr)
                        { bus: rr.bus, data: rr.val }
                    } else if sh == 1 {
                        r1 = bus.read(1, vaddr)
                        r2 = r1.bus.read(2, vaddr.plus_wrap(1))
                        { bus: r2.bus, data: r1.val.bitwise_and(0xFF).bitwise_or(r2.val.bitwise_and(0xFFFF).shl_wrap(8)) }
                    } else if sh == 2 {
                        rr = bus.read(2, vaddr)
                        { bus: rr.bus, data: rr.val.bitwise_and(0xFFFF) }
                    } else {
                        rr = bus.read(1, vaddr)
                        { bus: rr.bus, data: rr.val.bitwise_and(0xFF) }
                    }
                { ..none, bus: got.bus, new_load: Pending({ reg: rt_i, val: Mips.lwr_merge(merge_base, got.data, sh) }) }
            }

            40 => { ..none, bus: bus.write(1, vaddr, b) } # SB
            41 => # SH
                if vaddr.bitwise_and(1) != 0 {
                    { ..none, exc: Exc({ code: exc_ades, badv: Badv(vaddr) }) }
                } else {
                    { ..none, bus: bus.write(2, vaddr, b) }
                }

            42 => { # SWL: store rt's top (sh+1) bytes ending at vaddr (1-2 accesses)
                sh = vaddr.bitwise_and(3)
                aligned = vaddr.bitwise_and(0xFFFF_FFFC)
                if sh == 0 {
                    { ..none, bus: bus.write(1, vaddr, b.shr_zf_wrap(24)) }
                } else if sh == 1 {
                    { ..none, bus: bus.write(2, aligned, b.shr_zf_wrap(16)) }
                } else if sh == 2 {
                    { ..none, bus: bus.write(2, aligned, b.shr_zf_wrap(8)).write(1, aligned.plus_wrap(2), b.shr_zf_wrap(24)) }
                } else {
                    { ..none, bus: bus.write(4, aligned, b) }
                }
            }

            43 => # SW
                if vaddr.bitwise_and(3) != 0 {
                    { ..none, exc: Exc({ code: exc_ades, badv: Badv(vaddr) }) }
                } else {
                    { ..none, bus: bus.write(4, vaddr, b) }
                }

            46 => { # SWR: store rt's bottom (4-sh) bytes starting at vaddr (1-2 accesses)
                sh = vaddr.bitwise_and(3)
                if sh == 0 {
                    { ..none, bus: bus.write(4, vaddr, b) }
                } else if sh == 1 {
                    { ..none, bus: bus.write(1, vaddr, b).write(2, vaddr.plus_wrap(1), b.shr_zf_wrap(8)) }
                } else if sh == 2 {
                    { ..none, bus: bus.write(2, vaddr, b) }
                } else {
                    { ..none, bus: bus.write(1, vaddr, b) }
                }
            }

            50 => { ..none, exc: Exc({ code: exc_cpu, badv: NoBadv }) } # LWC2
            58 => { ..none, exc: Exc({ code: exc_cpu, badv: NoBadv }) } # SWC2
            _ => { ..none, exc: Exc({ code: exc_ri, badv: NoBadv }) }
        }
    }

    hilo_of = |hl| SetHiLo(hl.hi, hl.lo)

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
