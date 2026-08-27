import /Bus
import /Mips
import /Bit
import /Gte

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
    # RAM is PAGED (512 x 4 KB) and stores are NOT applied here: step
    # returns store-intent scalars and the DRIVER applies them to its
    # var-threaded pages via store_ram. Rationale: on this nightly, any
    # list that flows through a branchy record-returning function (this
    # one) loses in-place updates — every store clones it. Paging bounds
    # the unavoidable clone at ~8 KB (page + spine) instead of 2 MB; the
    # PS1's aligned accesses never cross a page. See Bus.roc's shape note
    # and the perf repro.
    # gte0 is READ-ONLY here (val-only, like the RAM pages): COP2 writes
    # and commands leave as INTENTS in gte_kind/gte_idx/gte_val for the
    # console layer to apply, so no register-file list is threaded
    # through the step's payload. gte_kind: 0 none, 1 register write, 2
    # command word.
    step : Cpu, Bus, List(List(U8)), List(U32) -> { cpu : Cpu, bus : Bus, st1_size : U8, st1_addr : U32, st1_val : U32, st2_size : U8, st2_addr : U32, st2_val : U32, rd1_size : U8, rd1_addr : U32, rd1_val : U32, rd2_size : U8, rd2_addr : U32, rd2_val : U32, ack_addr : U32, gte_kind : U8, gte_idx : U32, gte_val : U32 }
    step = |cpu, bus0, ram0, gte0|
        if cpu.sr.bitwise_and(1) == 1 and cpu.sr.bitwise_and(cpu.cause).bitwise_and(0xFF00) != 0 {
            # hardware interrupt, taken between instructions (excode 0);
            # branch-delay EPC/BD semantics come from take_exception
            t = take_exception(land_all(cpu), bus0, 0, 0, NoBadv)
            if Bus.trap_enabled(bus0) and Bus.hook(bus0) != 0 {
                # HLE BIOS dispatch (D5 trio): save the register file the
                # BIOS would park in its TCB, then longjmp into the
                # HookEntryInt jmp_buf ([ra, sp, fp, s0-s7, gp], v0 = 1).
                # B0:0x17 ReturnFromException restores and resumes at EPC.
                landed = land_all(cpu)
                var ctx = List.with_capacity(34)
                var ci = 1.U64
                while ci < 32 {
                    ctx = ctx.append(get(landed, ci))
                    ci = ci.plus(1)
                }
                ctx = ctx.append(landed.hi).append(landed.lo).append(t.cpu.epc)
                buf = Bus.hook(bus0)
                bw = |k| {
                    r = bus0.read_val(ram0, 4, buf.plus_wrap(k.times_wrap(4)), 0, cpu.cycles)
                    r.val
                }
                entered = { ..t.cpu,
                    r2: 1, # longjmp returns 1
                    r28: bw(11),
                    r29: bw(1),
                    r30: bw(2),
                    r31: bw(0),
                    r16: bw(3),
                    r17: bw(4),
                    r18: bw(5),
                    r19: bw(6),
                    r20: bw(7),
                    r21: bw(8),
                    r22: bw(9),
                    r23: bw(10),
                    pc: bw(0),
                }
                { cpu: entered, bus: Bus.set_exc_ctx(t.bus, ctx), st1_size: 0, st1_addr: 0, st1_val: 0, st2_size: 0, st2_addr: 0, st2_val: 0, rd1_size: 0, rd1_addr: 0, rd1_val: 0, rd2_size: 0, rd2_addr: 0, rd2_val: 0, ack_addr: 0, gte_kind: 0, gte_idx: 0, gte_val: 0 }
            } else {
                { cpu: t.cpu, bus: t.bus, st1_size: 0, st1_addr: 0, st1_val: 0, st2_size: 0, st2_addr: 0, st2_val: 0, rd1_size: 0, rd1_addr: 0, rd1_val: 0, rd2_size: 0, rd2_addr: 0, rd2_val: 0, ack_addr: 0, gte_kind: 0, gte_idx: 0, gte_val: 0 }
            }
        } else if kernel_trap_hit(cpu, bus0) {
            # A0/B0 kernel-vector TTY trap (sideload harness): capture the
            # call, return to $ra like the kernel would (see Bus.kernel_call)
            ppc = cpu.pc.bitwise_and(0x1FFF_FFFF)
            if ppc == 0xB0 and get(cpu, 9) == 0x17 {
                # ReturnFromException: restore the file saved at dispatch,
                # pop SR (RFE), resume at the interrupted EPC
                ctx = Bus.exc_ctx(bus0)
                var restored = cpu
                var i = 1.U64
                while i < 32 {
                    restored = set_r(restored, i, ctx.get(i.minus(1)) ?? 0)
                    i = i.plus(1)
                }
                back = { ..restored,
                    hi: ctx.get(31) ?? 0,
                    lo: ctx.get(32) ?? 0,
                    pc: ctx.get(33) ?? 0,
                    sr: cpu.sr.bitwise_and(0xFFFF_FFF0).bitwise_or(cpu.sr.shr_zf_wrap(2).bitwise_and(0x0F)),
                    branch: NoBranch,
                    load: NoLoad,
                    cycles: cpu.cycles.plus(1),
                }
                return { cpu: back, bus: bus0, st1_size: 0, st1_addr: 0, st1_val: 0, st2_size: 0, st2_addr: 0, st2_val: 0, rd1_size: 0, rd1_addr: 0, rd1_val: 0, rd2_size: 0, rd2_addr: 0, rd2_val: 0, ack_addr: 0, gte_kind: 0, gte_idx: 0, gte_val: 0 }
            } else {}
            k = Bus.kernel_call(bus0, ram0, ppc, get(cpu, 9), { a0: get(cpu, 4), a1: get(cpu, 5), a2: get(cpu, 6), a3: get(cpu, 7), sp: get(cpu, 29) })
            landed = land_all(cpu)
            {
                cpu: { ..set_r(landed, 2, k.ret),
                    pc: get(cpu, 31),
                    branch: NoBranch,
                    load: NoLoad,
                    cycles: cpu.cycles.plus(1),
                },
                bus: k.bus,
                st1_size: 0, st1_addr: 0, st1_val: 0, st2_size: 0, st2_addr: 0, st2_val: 0, rd1_size: 0, rd1_addr: 0, rd1_val: 0, rd2_size: 0, rd2_addr: 0, rd2_val: 0, ack_addr: 0, gte_kind: 0, gte_idx: 0, gte_val: 0,
            }
        } else if cpu.pc.bitwise_and(3) != 0 {
            t = take_exception(land_all(cpu), bus0, 0, exc_adel, Badv(cpu.pc))
            { cpu: t.cpu, bus: t.bus, st1_size: 0, st1_addr: 0, st1_val: 0, st2_size: 0, st2_addr: 0, st2_val: 0, rd1_size: 0, rd1_addr: 0, rd1_val: 0, rd2_size: 0, rd2_addr: 0, rd2_val: 0, ack_addr: 0, gte_kind: 0, gte_idx: 0, gte_val: 0 }
        } else {
            f = bus0.fetch_val(ram0, cpu.pc, cpu.cycles)
            op = f.val
            var mem_cost = f.cost
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
            var st1_size = 0.U8
            var st1_addr = 0.U32
            var st1_val = 0.U32
            var st2_size = 0.U8
            var st2_addr = 0.U32
            var st2_val = 0.U32
            var rd1_size = 0.U8
            var rd1_addr = 0.U32
            var rd1_val = 0.U32
            var rd2_size = 0.U8
            var rd2_addr = 0.U32
            var rd2_val = 0.U32
            var gte_kind = 0.U8
            var gte_idx = 0.U32
            var gte_val = 0.U32
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
            _decoded = match o {
                0 =>
                    match Mips.funct(op) {
                        0 => { # SLL
                            wrote_i = rd_i
                            wrote_v = b.shl_wrap(Mips.sa(op))
                            {}
                        }

                        2 => { # SRL
                            wrote_i = rd_i
                            wrote_v = b.shr_zf_wrap(Mips.sa(op))
                            {}
                        }

                        3 => { # SRA
                            wrote_i = rd_i
                            wrote_v = sra(b, Mips.sa(op))
                            {}
                        }

                        4 => { # SLLV
                            wrote_i = rd_i
                            wrote_v = b.shl_wrap(a.bitwise_and(31).to_u8_wrap())
                            {}
                        }

                        6 => { # SRLV
                            wrote_i = rd_i
                            wrote_v = b.shr_zf_wrap(a.bitwise_and(31).to_u8_wrap())
                            {}
                        }

                        7 => { # SRAV
                            wrote_i = rd_i
                            wrote_v = sra(b, a.bitwise_and(31).to_u8_wrap())
                            {}
                        }

                        8 => { # JR
                            br_arm = Bool.True
                            br_take = Bool.True
                            br_target = a
                            {}
                        }

                        9 => { # JALR
                            wrote_i = rd_i
                            wrote_v = slot_addr.plus_wrap(4)
                            br_arm = Bool.True
                            br_take = Bool.True
                            br_target = a
                            {}
                        }

                        12 => { # SYSCALL
                            has_exc = Bool.True
                            exc_code = exc_sys
                            {}
                        }

                        13 => { # BREAK
                            has_exc = Bool.True
                            exc_code = exc_bp
                            {}
                        }

                        16 => { # MFHI
                            wrote_i = rd_i
                            wrote_v = cpu.hi
                            {}
                        }

                        17 => { # MTHI
                            new_hi = a
                            {}
                        }

                        18 => { # MFLO
                            wrote_i = rd_i
                            wrote_v = cpu.lo
                            {}
                        }

                        19 => { # MTLO
                            new_lo = a
                            {}
                        }

                        24 => { # MULT
                            hl = Mips.mult_signed(a, b)
                            new_hi = hl.hi
                            new_lo = hl.lo
                            {}
                        }

                        25 => { # MULTU
                            hl = Mips.mult_unsigned(a, b)
                            new_hi = hl.hi
                            new_lo = hl.lo
                            {}
                        }

                        26 => { # DIV
                            hl = Mips.div_signed(a, b)
                            new_hi = hl.hi
                            new_lo = hl.lo
                            {}
                        }

                        27 => { # DIVU
                            hl = Mips.div_unsigned(a, b)
                            new_hi = hl.hi
                            new_lo = hl.lo
                            {}
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
                            {}
                        }

                        33 => { # ADDU
                            wrote_i = rd_i
                            wrote_v = a.plus_wrap(b)
                            {}
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
                            {}
                        }

                        35 => { # SUBU
                            wrote_i = rd_i
                            wrote_v = a.minus_wrap(b)
                            {}
                        }

                        36 => { # AND
                            wrote_i = rd_i
                            wrote_v = a.bitwise_and(b)
                            {}
                        }

                        37 => { # OR
                            wrote_i = rd_i
                            wrote_v = a.bitwise_or(b)
                            {}
                        }

                        38 => { # XOR
                            wrote_i = rd_i
                            wrote_v = a.bitwise_xor(b)
                            {}
                        }

                        39 => { # NOR
                            wrote_i = rd_i
                            wrote_v = a.bitwise_or(b).bitwise_not()
                            {}
                        }

                        42 => { # SLT
                            wrote_i = rd_i
                            wrote_v = if Mips.lt_signed(a, b) { 1 } else { 0 }
                            {}
                        }

                        43 => { # SLTU
                            wrote_i = rd_i
                            wrote_v = if a < b { 1 } else { 0 }
                            {}
                        }

                        _ => {
                            has_exc = Bool.True
                            exc_code = exc_ri
                            {}
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
                    {}
                }

                2 => { # J
                    br_arm = Bool.True
                    br_take = Bool.True
                    br_target = Mips.jump_target(op, slot_addr)
                    {}
                }

                3 => { # JAL
                    wrote_i = 31
                    wrote_v = slot_addr.plus_wrap(4)
                    br_arm = Bool.True
                    br_take = Bool.True
                    br_target = Mips.jump_target(op, slot_addr)
                    {}
                }

                4 => { # BEQ
                    br_arm = Bool.True
                    br_take = a == b
                    br_target = Mips.branch_target(op, slot_addr)
                    {}
                }

                5 => { # BNE
                    br_arm = Bool.True
                    br_take = a != b
                    br_target = Mips.branch_target(op, slot_addr)
                    {}
                }

                6 => { # BLEZ
                    br_arm = Bool.True
                    br_take = a == 0 or a >= 0x8000_0000
                    br_target = Mips.branch_target(op, slot_addr)
                    {}
                }

                7 => { # BGTZ
                    br_arm = Bool.True
                    br_take = a != 0 and a < 0x8000_0000
                    br_target = Mips.branch_target(op, slot_addr)
                    {}
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
                    {}
                }

                9 => { # ADDIU
                    wrote_i = rt_i
                    wrote_v = a.plus_wrap(si)
                    {}
                }

                10 => { # SLTI
                    wrote_i = rt_i
                    wrote_v = if Mips.lt_signed(a, si) { 1 } else { 0 }
                    {}
                }

                11 => { # SLTIU
                    wrote_i = rt_i
                    wrote_v = if a < si { 1 } else { 0 }
                    {}
                }

                12 => { # ANDI
                    wrote_i = rt_i
                    wrote_v = a.bitwise_and(Mips.imm(op))
                    {}
                }

                13 => { # ORI
                    wrote_i = rt_i
                    wrote_v = a.bitwise_or(Mips.imm(op))
                    {}
                }

                14 => { # XORI
                    wrote_i = rt_i
                    wrote_v = a.bitwise_xor(Mips.imm(op))
                    {}
                }

                15 => { # LUI
                    wrote_i = rt_i
                    wrote_v = Mips.imm(op).shl_wrap(16)
                    {}
                }

                16 => # COP0 — usable in kernel mode regardless of CU0
                    if cpu.sr.bitwise_and(0x1000_0000) == 0 and cpu.sr.bitwise_and(0x2) != 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                        {}
                    } else {
                    match rs_i {
                        0 => { # MFC0 (load-delayed)
                            load_i = rt_i
                            load_v = cop0_read(cpu, rd_i)
                            {}
                        }

                        4 =>
                            match rd_i { # MTC0
                                12 => {
                                    new_sr = b
                                    {}
                                }

                                13 => {
                                    new_cause = cpu.cause.bitwise_and(0xFFFF_FCFF).bitwise_or(b.bitwise_and(0x0000_0300))
                                    {}
                                }

                                                _ => {} # other cop0 registers: ignored for now
                            }

                        16 =>
                            if Mips.funct(op) == 16 { # RFE
                                new_sr = cpu.sr.bitwise_and(0xFFFF_FFF0).bitwise_or(cpu.sr.shr_zf_wrap(2).bitwise_and(0x0F))
                                {}
                            } else {
                                has_exc = Bool.True
                                exc_code = exc_ri
                                {}
                            }

                        _ => {} # an unrecognised COP0 rs is a SILENT
                        # NO-OP, not a reserved instruction: ps1-tests
                        # cpu/cop's testCop0InvalidOpcode runs
                        # `(16 << 26) | (0x1f << 21)` and asserts no
                        # exception was thrown. (MFC0/MTC0 on a
                        # nonexistent COP0 REGISTER is a different case
                        # that does raise RI — that belongs with the
                        # COP0 debug-register work psxtest_cpx needs.)
                    }
                    }

                # COP1/COP3 do not exist on the PlayStation, but the CU
                # bits still gate them: with SR.CUn SET they are silent
                # no-ops, and ONLY with it clear do they raise
                # coprocessor-unusable. (psxtest_cpx judges exactly this:
                # it runs each opcode with SR = F0000000h and wants no
                # exception at all.) The same rule covers LWC/SWC 0/1/3
                # below.
                17 =>
                    if cpu.sr.bitwise_and(0x2000_0000) == 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                        {}
                    } else {
                        {}
                    }

                19 =>
                    if cpu.sr.bitwise_and(0x8000_0000) == 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                        {}
                    } else {
                        {}
                    }

                18 => # COP2 (GTE)
                    if cpu.sr.bitwise_and(0x4000_0000) == 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                        {}
                    } else if rs_i >= 16 {
                        # bit 25 set: the imm25 command form
                        gte_kind = 2
                        gte_val = op.bitwise_and(0x01FF_FFFF)
                        mem_cost = mem_cost.plus(Gte.cycles_of(gte_val))
                        {}
                    } else {
                        match rs_i {
                            0 => { # MFC2 (load-delayed like any load)
                                load_i = rt_i
                                load_v = Gte.read(gte0, rd_i.to_u64())
                                {}
                            }

                            2 => { # CFC2
                                load_i = rt_i
                                load_v = Gte.read(gte0, rd_i.to_u64().plus(32))
                                {}
                            }

                            4 => { # MTC2
                                gte_kind = 1
                                gte_idx = rd_i.to_u32_wrap()
                                gte_val = b
                                {}
                            }

                            6 => { # CTC2
                                gte_kind = 1
                                gte_idx = rd_i.to_u32_wrap().plus(32)
                                gte_val = b
                                {}
                            }

                            _ => {
                                has_exc = Bool.True
                                exc_code = exc_ri
                                {}
                            }
                        }
                    }

                32 => { # LB
                    va = a.plus_wrap(si)
                    rr = bus0.read_val(ram0, 1, va, 0, cpu.cycles)
                    mem_cost = mem_cost.plus(rr.cost)
                    rd1_size = 1
                    rd1_addr = va
                    rd1_val = rr.val
                    load_i = rt_i
                    load_v = Bit.sext8(rr.val)
                    {}
                }

                33 => { # LH
                    va = a.plus_wrap(si)
                    if va.bitwise_and(1) != 0 {
                        has_exc = Bool.True
                        exc_code = exc_adel
                        has_badv = Bool.True
                        exc_badv = va
                        {}
                    } else {
                        rr = bus0.read_val(ram0, 2, va, 0, cpu.cycles)
                        mem_cost = mem_cost.plus(rr.cost)
                        rd1_size = 2
                        rd1_addr = va
                        rd1_val = rr.val
                        load_i = rt_i
                        load_v = Bit.sext16(rr.val)
                        {}
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
                            rr = bus0.read_val(ram0, 1, va, 0, cpu.cycles)
                            rd1_size = 1
                            rd1_addr = va
                            rd1_val = rr.val
                            { data: rr.val.bitwise_and(0xFF), cost: rr.cost }
                        } else if sh == 1 {
                            rr = bus0.read_val(ram0, 2, aligned, 0, cpu.cycles)
                            rd1_size = 2
                            rd1_addr = aligned
                            rd1_val = rr.val
                            { data: rr.val.bitwise_and(0xFFFF), cost: rr.cost }
                        } else if sh == 2 {
                            r1 = bus0.read_val(ram0, 2, aligned, 0, cpu.cycles)
                            r2 = bus0.read_val(ram0, 1, aligned.plus_wrap(2), 1, cpu.cycles)
                            rd1_size = 2
                            rd1_addr = aligned
                            rd1_val = r1.val
                            rd2_size = 1
                            rd2_addr = aligned.plus_wrap(2)
                            rd2_val = r2.val
                            { data: r1.val.bitwise_and(0xFFFF).bitwise_or(r2.val.bitwise_and(0xFF).shl_wrap(16)), cost: r1.cost.plus(r2.cost) }
                        } else {
                            rr = bus0.read_val(ram0, 4, aligned, 0, cpu.cycles)
                            rd1_size = 4
                            rd1_addr = aligned
                            rd1_val = rr.val
                            { data: rr.val, cost: rr.cost }
                        }
                    mem_cost = mem_cost.plus(got.cost)
                    load_i = rt_i
                    load_v = Mips.lwl_merge(merge_base, got.data, sh)
                    {}
                }

                35 => { # LW
                    va = a.plus_wrap(si)
                    if va.bitwise_and(3) != 0 {
                        has_exc = Bool.True
                        exc_code = exc_adel
                        has_badv = Bool.True
                        exc_badv = va
                        {}
                    } else {
                        rr = bus0.read_val(ram0, 4, va, 0, cpu.cycles)
                        mem_cost = mem_cost.plus(rr.cost)
                        rd1_size = 4
                        rd1_addr = va
                        rd1_val = rr.val
                        load_i = rt_i
                        load_v = rr.val
                        {}
                    }
                }

                36 => { # LBU
                    va = a.plus_wrap(si)
                    rr = bus0.read_val(ram0, 1, va, 0, cpu.cycles)
                    mem_cost = mem_cost.plus(rr.cost)
                    rd1_size = 1
                    rd1_addr = va
                    rd1_val = rr.val
                    load_i = rt_i
                    load_v = rr.val.bitwise_and(0xFF)
                    {}
                }

                37 => { # LHU
                    va = a.plus_wrap(si)
                    if va.bitwise_and(1) != 0 {
                        has_exc = Bool.True
                        exc_code = exc_adel
                        has_badv = Bool.True
                        exc_badv = va
                        {}
                    } else {
                        rr = bus0.read_val(ram0, 2, va, 0, cpu.cycles)
                        mem_cost = mem_cost.plus(rr.cost)
                        rd1_size = 2
                        rd1_addr = va
                        rd1_val = rr.val
                        load_i = rt_i
                        load_v = rr.val.bitwise_and(0xFFFF)
                        {}
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
                            rr = bus0.read_val(ram0, 4, va, 0, cpu.cycles)
                            rd1_size = 4
                            rd1_addr = va
                            rd1_val = rr.val
                            { data: rr.val, cost: rr.cost }
                        } else if sh == 1 {
                            r1 = bus0.read_val(ram0, 1, va, 0, cpu.cycles)
                            r2 = bus0.read_val(ram0, 2, va.plus_wrap(1), 1, cpu.cycles)
                            rd1_size = 1
                            rd1_addr = va
                            rd1_val = r1.val
                            rd2_size = 2
                            rd2_addr = va.plus_wrap(1)
                            rd2_val = r2.val
                            { data: r1.val.bitwise_and(0xFF).bitwise_or(r2.val.bitwise_and(0xFFFF).shl_wrap(8)), cost: r1.cost.plus(r2.cost) }
                        } else if sh == 2 {
                            rr = bus0.read_val(ram0, 2, va, 0, cpu.cycles)
                            rd1_size = 2
                            rd1_addr = va
                            rd1_val = rr.val
                            { data: rr.val.bitwise_and(0xFFFF), cost: rr.cost }
                        } else {
                            rr = bus0.read_val(ram0, 1, va, 0, cpu.cycles)
                            rd1_size = 1
                            rd1_addr = va
                            rd1_val = rr.val
                            { data: rr.val.bitwise_and(0xFF), cost: rr.cost }
                        }
                    mem_cost = mem_cost.plus(got.cost)
                    load_i = rt_i
                    load_v = Mips.lwr_merge(merge_base, got.data, sh)
                    {}
                }

                40 => { # SB
                    st1_size = 1
                    st1_addr = a.plus_wrap(si)
                    st1_val = b
                    {}
                }


                41 => { # SH
                    va = a.plus_wrap(si)
                    if va.bitwise_and(1) != 0 {
                        has_exc = Bool.True
                        exc_code = exc_ades
                        has_badv = Bool.True
                        exc_badv = va
                        {}
                    } else {
                        st1_size = 2
                        st1_addr = va
                        st1_val = b
                        {}
                    }
                }

                42 => { # SWL: store rt's top (sh+1) bytes ending at va (1-2 accesses)
                    va = a.plus_wrap(si)
                    sh = va.bitwise_and(3)
                    aligned = va.bitwise_and(0xFFFF_FFFC)
                    if sh == 0 {
                        st1_size = 1
                        st1_addr = va
                        st1_val = b.shr_zf_wrap(24)
                    } else if sh == 1 {
                        st1_size = 2
                        st1_addr = aligned
                        st1_val = b.shr_zf_wrap(16)
                    } else if sh == 2 {
                        st1_size = 2
                        st1_addr = aligned
                        st1_val = b.shr_zf_wrap(8)
                        st2_size = 1
                        st2_addr = aligned.plus_wrap(2)
                        st2_val = b.shr_zf_wrap(24)
                    } else {
                        st1_size = 4
                        st1_addr = aligned
                        st1_val = b
                    }
                    {}
                }

                43 => { # SW
                    va = a.plus_wrap(si)
                    if va.bitwise_and(3) != 0 {
                        has_exc = Bool.True
                        exc_code = exc_ades
                        has_badv = Bool.True
                        exc_badv = va
                        {}
                    } else {
                        st1_size = 4
                        st1_addr = va
                        st1_val = b
                        {}
                    }
                }

                46 => { # SWR: store rt's bottom (4-sh) bytes starting at va (1-2 accesses)
                    va = a.plus_wrap(si)
                    sh = va.bitwise_and(3)
                    if sh == 0 {
                        st1_size = 4
                        st1_addr = va
                        st1_val = b
                    } else if sh == 1 {
                        st1_size = 1
                        st1_addr = va
                        st1_val = b
                        st2_size = 2
                        st2_addr = va.plus_wrap(1)
                        st2_val = b.shr_zf_wrap(8)
                    } else if sh == 2 {
                        st1_size = 2
                        st1_addr = va
                        st1_val = b
                    } else {
                        st1_size = 1
                        st1_addr = va
                        st1_val = b
                    }
                    {}
                }

                48 =>
                    if cpu.sr.bitwise_and(0x1000_0000) == 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                        {}
                    } else {
                        # usable but the coprocessor does not exist: no
                        # transfer happens, yet the ADDRESS is still
                        # computed and a misaligned one still faults
                        va = a.plus_wrap(si)
                        if va.bitwise_and(3) != 0 {
                            has_exc = Bool.True
                            exc_code = exc_adel
                            exc_badv = va
                            has_badv = Bool.True
                        } else {}
                        {}
                    }

                49 =>
                    if cpu.sr.bitwise_and(0x2000_0000) == 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                        {}
                    } else {
                        # usable but the coprocessor does not exist: no
                        # transfer happens, yet the ADDRESS is still
                        # computed and a misaligned one still faults
                        va = a.plus_wrap(si)
                        if va.bitwise_and(3) != 0 {
                            has_exc = Bool.True
                            exc_code = exc_adel
                            exc_badv = va
                            has_badv = Bool.True
                        } else {}
                        {}
                    }

                51 =>
                    if cpu.sr.bitwise_and(0x8000_0000) == 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                        {}
                    } else {
                        # usable but the coprocessor does not exist: no
                        # transfer happens, yet the ADDRESS is still
                        # computed and a misaligned one still faults
                        va = a.plus_wrap(si)
                        if va.bitwise_and(3) != 0 {
                            has_exc = Bool.True
                            exc_code = exc_adel
                            exc_badv = va
                            has_badv = Bool.True
                        } else {}
                        {}
                    }

                56 =>
                    if cpu.sr.bitwise_and(0x1000_0000) == 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                        {}
                    } else {
                        # usable but the coprocessor does not exist: no
                        # transfer happens, yet the ADDRESS is still
                        # computed and a misaligned one still faults
                        va = a.plus_wrap(si)
                        if va.bitwise_and(3) != 0 {
                            has_exc = Bool.True
                            exc_code = exc_ades
                            exc_badv = va
                            has_badv = Bool.True
                        } else {}
                        {}
                    }

                57 =>
                    if cpu.sr.bitwise_and(0x2000_0000) == 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                        {}
                    } else {
                        # usable but the coprocessor does not exist: no
                        # transfer happens, yet the ADDRESS is still
                        # computed and a misaligned one still faults
                        va = a.plus_wrap(si)
                        if va.bitwise_and(3) != 0 {
                            has_exc = Bool.True
                            exc_code = exc_ades
                            exc_badv = va
                            has_badv = Bool.True
                        } else {}
                        {}
                    }

                59 =>
                    if cpu.sr.bitwise_and(0x8000_0000) == 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                        {}
                    } else {
                        # usable but the coprocessor does not exist: no
                        # transfer happens, yet the ADDRESS is still
                        # computed and a misaligned one still faults
                        va = a.plus_wrap(si)
                        if va.bitwise_and(3) != 0 {
                            has_exc = Bool.True
                            exc_code = exc_ades
                            exc_badv = va
                            has_badv = Bool.True
                        } else {}
                        {}
                    }

                50 => { # LWC2: memory -> GTE data register
                    if cpu.sr.bitwise_and(0x4000_0000) == 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                    } else {
                        va = a.plus_wrap(si)
                        if va.bitwise_and(3) != 0 {
                            has_exc = Bool.True
                            exc_code = exc_adel
                            exc_badv = va
                            has_badv = Bool.True
                        } else {
                            rr = bus0.read_val(ram0, 4, va, 0, cpu.cycles)
                            mem_cost = mem_cost.plus(rr.cost)
                            rd1_size = 4
                            rd1_addr = va
                            rd1_val = rr.val
                            gte_kind = 1
                            gte_idx = rt_i.to_u32_wrap()
                            gte_val = rr.val
                        }
                    }
                    {}
                }

                58 => { # SWC2: GTE data register -> memory
                    if cpu.sr.bitwise_and(0x4000_0000) == 0 {
                        has_exc = Bool.True
                        exc_code = exc_cpu
                    } else {
                        va = a.plus_wrap(si)
                        if va.bitwise_and(3) != 0 {
                            has_exc = Bool.True
                            exc_code = exc_ades
                            exc_badv = va
                            has_badv = Bool.True
                        } else {
                            st1_size = 4
                            st1_addr = va
                            st1_val = Gte.read(gte0, rt_i.to_u64())
                        }
                    }
                    {}
                }

                _ => {
                    has_exc = Bool.True
                    exc_code = exc_ri
                    {}
                }
            }
            # stores happen on a LINEAR bus chain — never inside a branch:
            # branch-dependent use shares the bus and sharing turns the
            # RAM List.set into a full clone (measured: 300x collapse)
            do_store = if has_exc or isolated(cpu) { 0.U8 } else { 1 }
            s1 = st1_size.times_wrap(do_store)
            s2 = st2_size.times_wrap(do_store)
            bus_w1 = if s1 == 0 { bus0 } else { bus0.write(s1, st1_addr, st1_val, cpu.cycles) }
            bus2 = if s2 == 0 { bus_w1 } else { bus_w1.write(s2, st2_addr, st2_val, cpu.cycles) }
            mem_cost = mem_cost.plus(Bus.write_cost(s1, st1_addr)).plus(Bus.write_cost(s2, st2_addr))
            if has_exc {
                vec_word = bus0.read_val(ram0, 4, 0x8000_0080, 0, cpu.cycles)
                if exc_code == exc_sys and Bus.trap_enabled(bus0) and vec_word.val == 0 {
                    # HLE critical sections when NO handler lives at the
                    # exception vector (the BIOS would have handled these):
                    # syscall(1) disables IRQs (SR &= ~0x401), syscall(2)
                    # enables (SR |= 0x401), resume at the next
                    # instruction. EXEs that install their own vector code
                    # (psxtest_cpu's exception tests) still vector normally.
                    a0v = get(cpu, 4)
                    hle_sr = if a0v == 1 {
                        cpu.sr.bitwise_and(0xFFFF_FBFE)
                    } else if a0v == 2 {
                        cpu.sr.bitwise_or(0x401)
                    } else {
                        cpu.sr
                    }
                    landed_s = land_all(cpu)
                    { cpu: { ..landed_s, pc: cpu.pc.plus_wrap(4), sr: hle_sr, cycles: cpu.cycles.plus(1).plus(mem_cost) }, bus: bus2, st1_size: 0, st1_addr: 0, st1_val: 0, st2_size: 0, st2_addr: 0, st2_val: 0, rd1_size: 0, rd1_addr: 0, rd1_val: 0, rd2_size: 0, rd2_addr: 0, rd2_val: 0, ack_addr: 0, gte_kind: 0, gte_idx: 0, gte_val: 0 }
                } else {
                t = take_exception(land_all(cpu), bus2, op, exc_code, if has_badv { Badv(exc_badv) } else { NoBadv })
                { cpu: t.cpu, bus: t.bus, st1_size: 0, st1_addr: 0, st1_val: 0, st2_size: 0, st2_addr: 0, st2_val: 0, rd1_size: 0, rd1_addr: 0, rd1_val: 0, rd2_size: 0, rd2_addr: 0, rd2_val: 0, ack_addr: 0, gte_kind: 0, gte_idx: 0, gte_val: 0 }
                }
            } else {
                # hoisted OUT of the return-record literal: a conditional
                # inside the record build re-poisons the bus copy (law 4)
                ack_rphys = rd1_addr.bitwise_and(0x1FFF_FFFF)
                ack_is_mode = rd1_size != 0 and ((ack_rphys >= 0x1F80_1100 and ack_rphys < 0x1F80_1130 and ack_rphys.bitwise_and(0xF) == 4) or ack_rphys == 0x1F80_1810)
                ack_v = if ack_is_mode { rd1_addr } else { 0 }
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
                        cycles: cpu.cycles.plus(1).plus(mem_cost),
                    },
                    bus: bus2,
                    st1_size: s1,
                    st1_addr: st1_addr,
                    st1_val: st1_val,
                    st2_size: s2,
                    st2_addr: st2_addr,
                    st2_val: st2_val,
                    rd1_size: rd1_size,
                    rd1_addr: rd1_addr,
                    rd1_val: rd1_val,
                    rd2_size: rd2_size,
                    rd2_addr: rd2_addr,
                    rd2_val: rd2_val,
                    gte_kind: gte_kind,
                    gte_idx: gte_idx,
                    gte_val: gte_val,
                    # timer MODE reads clear the reached flags on hardware;
                    # reads are pure — the acknowledge intent (computed
                    # above, outside this record build) is applied by the
                    # console layer after the step
                    ack_addr: ack_v,
                }
            }
        }

    # RAM stores happen HERE, on the var-threaded list — the only shape
    # proven immune to the clone-per-store collapse (see Bus.roc's shape
    # note and the perf repro). No-ops for size 0 and non-RAM regions;
    # the Bus handles scratchpad/I/O writes.
    ram_init : {} -> List(List(U8))
    ram_init = |_| List.repeat(List.repeat(0, 0x1000), 0x200)

    # driver-side RAM store: one page clone worst-case, never the whole 2 MB
    store_ram : List(List(U8)), U8, U32, U32 -> List(List(U8))
    store_ram = |pages, size, addr, val| {
        phys = addr.bitwise_and(0x1FFF_FFFF)
        if size == 0 or phys >= 0x0080_0000 or addr >= 0xFFFE0000 {
            pages
        } else {
            i0 = phys.bitwise_and(0x1F_FFFF).to_u64()
            pi = i0.shr_zf_wrap(12)
            off = i0.bitwise_and(0xFFF)
            # detach the page from the spine before setting: get alone
            # leaves the spine's reference alive and every set clones the
            # 4 KB page; parking [] in the slot drops it to unique
            page = pages.get(pi) ?? []
            pages1 = pages.set(pi, []) ?? pages
            page2 =
                if size == 1 {
                    page.set(off, val.to_u8_wrap()) ?? page
                } else if size == 2 {
                    ((page.set(off, val.to_u8_wrap()) ?? page).set(off.plus(1), val.shr_zf_wrap(8).to_u8_wrap())) ?? page
                } else {
                    ((((page.set(off, val.to_u8_wrap()) ?? page).set(off.plus(1), val.shr_zf_wrap(8).to_u8_wrap()) ?? page).set(off.plus(2), val.shr_zf_wrap(16).to_u8_wrap()) ?? page).set(off.plus(3), val.shr_zf_wrap(24).to_u8_wrap())) ?? page
                }
            pages1.set(pi, page2) ?? pages1
        }
    }

    # CAUSE.IP2 mirror (D3): the interrupt controller's irq2 line is a
    # LEVEL on CAUSE bit 10 — the driver syncs it after each step so both
    # the pre-fetch interrupt check and MFC0 CAUSE observe it
    set_irq2 : Cpu, Bool -> Cpu
    set_irq2 = |cpu, level|
        { ..cpu, cause: if level { cpu.cause.bitwise_or(0x400) } else { cpu.cause.bitwise_and(0xFFFF_FBFF) } }

    # SR.IsC: stores target the isolated cache, not memory
    isolated : Cpu -> Bool
    isolated = |cpu| cpu.sr.bitwise_and(0x1_0000) != 0

    kernel_trap_hit : Cpu, Bus -> Bool
    kernel_trap_hit = |cpu, bus| {
        ppc = cpu.pc.bitwise_and(0x1FFF_FFFF)
        (ppc == 0xA0 or ppc == 0xB0 or ppc == 0xC0) and Bus.trap_enabled(bus)
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
    Cpu.step(seeded.cpu, Bus.vector(op, pc, reads), [], Gte.init({}))
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
    step2 = Cpu.step(b.cpu, Bus.vector(0x0000_0000, 0x1004, []), [], Gte.init({})) # delay slot: NOP (SLL r0)
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
    mid = Cpu.step(l.cpu, Bus.vector(0x0044_1825, 0x1004, []), [], Gte.init({})) # OR r3, r2, r4 — stale r2
    mid2 = Cpu.step(mid.cpu, Bus.vector(0x0000_0000, 0x1008, []), [], Gte.init({}))
    l.cpu.get(2) == 0 # not yet visible
    and mid.cpu.get(3) == 0 # read the stale zero
    and mid.cpu.get(2) == 0xAB # landed after the slot instruction
    and mid2.cpu.get(2) == 0xAB
}

# delay-slot write to the same register wins over the pending load
expect {
    l = run1(0x1000, [0, 0x50], 0x8C22_0000, [0xAB]) # LW r2
    w = Cpu.step(l.cpu, Bus.vector(0x2402_0007, 0x1004, []), [], Gte.init({})) # ADDIU r2, r0, 7
    w.cpu.get(2) == 7
}

# LWL reads through a pending load to the same register and re-enters the pipe
expect {
    l = run1(0x1000, [0, 0x50], 0x8C22_0000, [0x0000_00AB]) # LW r2 <- 0xAB
    lwl = Cpu.step(l.cpu, Bus.vector(0x8822_0007, 0x1004, [0x1122_3344]), [], Gte.init({})) # LWL r2, 7(r1): vaddr 0x57, sh 3
    done = Cpu.step(lwl.cpu, Bus.vector(0x0000_0000, 0x1008, []), [], Gte.init({}))
    lwl.cpu.get(2) == 0 # still in the pipe
    and lwl.cpu.load == Pending({ reg: 2, val: 0x1122_3344 }) # sh 3: whole word
    and done.cpu.get(2) == 0x1122_3344
}

# exception in a taken delay slot: BD + bit30 set, EPC = branch, TAR = target
expect {
    b = run1(0x1000, [0, 1, 2], 0x1422_0010, []) # taken BNE
    f = Cpu.step(b.cpu, Bus.vector(0x8C22_0001, 0x1004, []), [], Gte.init({})) # LW r2, 1(r1): misaligned
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
    rfe = Cpu.step(withsr, Bus.vector(0x4200_0010, 0x3000, []), [], Gte.init({})) # RFE
    s.cpu.pc == 0x8000_0080
    and s.cpu.cause.bitwise_and(0x7C) == 32
    and s.cpu.sr.bitwise_and(0x3F) == 0 # push from zero stays zero
    and rfe.cpu.sr.bitwise_and(0x0F) == 0x03 # popped one level
}

# MFC0 is load-delayed; MTC0 writes SR
expect {
    withsr = { ..Cpu.init(0x1000), sr: 0x1234_5678 }
    m = Cpu.step(withsr, Bus.vector(0x4002_6000, 0x1000, []), [], Gte.init({})) # MFC0 r2, sr
    m2 = Cpu.step(m.cpu, Bus.vector(0x0000_0000, 0x1004, []), [], Gte.init({}))
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

# SR.CU gates all four coprocessor slots. These expects carry the
# behaviour that ps1-tests cpu/cop judges on hardware — that gate cannot
# run here because it reads and mutates the BIOS thread-control block
# (see the runner's exclusion note), so the semantics are pinned here
# instead. Every case below matches a named subtest of cpu/cop.
# testCop1Disabled / testCop3Disabled: CU clear -> coprocessor-unusable
expect {
    g = run1(0x1000, [], 0x4400_0000, []) # COP1 op, SR = 0
    g.cpu.pc == 0x8000_0080
    and g.cpu.cause.bitwise_and(0x7C) == 44
    and g.cpu.cause.bitwise_and(0x3000_0000) == 0x1000_0000 # CE = 1
}

expect {
    g = run1(0x1000, [], 0x4C00_0000, []) # COP3 op, SR = 0
    g.cpu.pc == 0x8000_0080
    and g.cpu.cause.bitwise_and(0x3000_0000) == 0x3000_0000 # CE = 3
}

# testCop1Enabled / testCop3Enabled: CU SET -> a silent no-op, NOT an
# exception. The coprocessors do not exist, but the CU bit still gates.
expect {
    seeded = { ..Cpu.init(0x1000), sr: 0xF000_0000 }
    g = Cpu.step(seeded, Bus.vector(0x4400_0000, 0x1000, []), [], Gte.init({}))
    g.cpu.pc == 0x1004 and g.cpu.cause.bitwise_and(0x7C) == 0
}

expect {
    seeded = { ..Cpu.init(0x1000), sr: 0xF000_0000 }
    g = Cpu.step(seeded, Bus.vector(0x4C00_0000, 0x1000, []), [], Gte.init({}))
    g.cpu.pc == 0x1004 and g.cpu.cause.bitwise_and(0x7C) == 0
}

# testSwc0Disabled / testSwc0Enabled: SWC0 is CU0-gated, and when usable
# it transfers nothing but still computes its address
expect {
    g = run1(0x1000, [], 0xE020_0000, []) # SWC0 $0, 0(r1), SR = 0
    g.cpu.cause.bitwise_and(0x7C) == 44
}

expect {
    seeded = { ..Cpu.init(0x1000), sr: 0xF000_0000 }
    g = Cpu.step(seeded, Bus.vector(0xE020_0000, 0x1000, []), [], Gte.init({}))
    g.cpu.pc == 0x1004 and g.cpu.cause.bitwise_and(0x7C) == 0
}

# a misaligned LWC3 still faults with an address error even though COP3
# does not exist (psxtest_cpx's lwc3_* rows want exactly this)
expect {
    seeded = { ..Cpu.set_r(Cpu.init(0x1000), 1, 0x0000_0001), sr: 0xF000_0000 }
    g = Cpu.step(seeded, Bus.vector(0xCC20_0000, 0x1000, []), [], Gte.init({}))
    g.cpu.pc == 0x8000_0080 and g.cpu.cause.bitwise_and(0x7C) == 16 # excode 4, AdEL
}

# testCop0InvalidOpcode: an unrecognised COP0 rs is a silent no-op
expect {
    g = run1(0x1000, [], 0x43E0_0000, []) # cop0 0x1f
    g.cpu.pc == 0x1004 and g.cpu.cause.bitwise_and(0x7C) == 0
}

# testCop2Enabled: with CU2 set, MFC2 executes and reads the GTE
expect {
    seeded = { ..Cpu.init(0x1000), sr: 0xF000_0000 }
    g = Cpu.step(seeded, Bus.vector(0x4801_0800, 0x1000, []), [], Gte.init({}))
    g.cpu.pc == 0x1004 and g.cpu.cause.bitwise_and(0x7C) == 0
}

# unmasked interrupt vectors with excode 0 before the next instruction
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False).raise_irq(2)
    ready = { ..Cpu.init(0x1000), sr: 0x0000_0401, cause: 0x0000_0400 } # IEc + IM2 set, IP2 mirrored
    r = Cpu.step(ready, b0, [], Gte.init({}))
    masked = { ..Cpu.init(0x1000), sr: 0x0000_0001, cause: 0x0000_0400 } # IEc but IM2 clear
    m = Cpu.step(masked, b0, [], Gte.init({}))
    r.cpu.pc == 0x8000_0080
    and r.cpu.cause.bitwise_and(0x7C) == 0 # excode 0 = interrupt
    and r.cpu.epc == 0x1000
    and m.cpu.pc != 0x8000_0080
}

# interrupt during a branch delay slot records the branch in EPC
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    in_slot = { ..Cpu.init(0x2004),
        sr: 0x0000_0401,
        cause: 0x0000_0400,
        branch: Slot({ take: Bool.True, target: 0x3000 }),
    }
    r = Cpu.step(in_slot, b0, [], Gte.init({}))
    r.cpu.epc == 0x2000 and r.cpu.cause.bitwise_and(0x8000_0000) != 0 and r.cpu.tar == 0x3000
}

# SR.IsC swallows stores: RAM unchanged while isolated
expect {
    bus0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    page0 = List.repeat(0, 0x1000)
    page1 = (((page0.set(0x100, 0x11) ?? page0).set(0x101, 0x11) ?? page0).set(0x102, 0x11) ?? page0).set(0x103, 0x11) ?? page0
    page = (((page1.set(0, 0x00) ?? page1).set(1, 0x00) ?? page1).set(2, 0x22) ?? page1).set(3, 0xAC) ?? page1 # SW r2, 0(r1)
    ram = [page]
    iso0 = { ..Cpu.init(0x0), sr: 0x0001_0000 }
    iso = Cpu.set_r(iso0, 1, 0x100)
    stepped = Cpu.step(iso, bus0, ram, Gte.init({}))
    ram2 = Cpu.store_ram(ram, stepped.st1_size, stepped.st1_addr, stepped.st1_val)
    check = stepped.bus.read_val(ram2, 4, 0x100, 0, 0)
    check.val == 0x1111_1111
}

# kernel trap: putchar captured, control returns to $ra
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.True)
    at_vec = Cpu.init(0x0000_00B0)
    seeded0 = Cpu.set_r(at_vec, 9, 0x3D) # $t1 = putchar
    seeded1 = Cpu.set_r(seeded0, 4, 0x21) # $a0 = '!'
    seeded = Cpu.set_r(seeded1, 31, 0x8000_1234)
    r = Cpu.step(seeded, b0, [], Gte.init({}))
    r.cpu.pc == 0x8000_1234 and r.bus.tty_bytes() == [0x21]
}

# a load from a timer MODE register surfaces the read-clear acknowledge
# as an intent; other loads do not
expect {
    # LHU r2, 0x1124(r1) with r1=0x1F800000; then LHU from RAM
    page0 = List.repeat(0, 0x1000)
    prog = [0x9422_1124.U32, 0x0000_0000, 0x9423_0000]
        .fold([], |acc, w| acc.append(w.to_u8_wrap()).append(w.shr_zf_wrap(8).to_u8_wrap()).append(w.shr_zf_wrap(16).to_u8_wrap()).append(w.shr_zf_wrap(24).to_u8_wrap()))
    page = List.concat(prog, List.repeat(0, 0x1000.U64.minus(prog.len())))
    _ = page0
    bus = Bus.ps1(List.repeat(0, 512), Bool.False)
    cpu = Cpu.set_r(Cpu.init(0x8000_0000), 1, 0x1F80_0000)
    r1 = Cpu.step(cpu, bus, [page], Gte.init({}))
    r2 = Cpu.step(r1.cpu, r1.bus, [page], Gte.init({}))
    r3 = Cpu.step({ ..r2.cpu, r1: 0 }, r2.bus, [page], Gte.init({}))
    r1.ack_addr == 0x1F80_1124 and r2.ack_addr == 0 and r3.ack_addr == 0
}
