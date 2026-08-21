import /Bit

# Field extraction and pure instruction semantics for the R3000A's MIPS I
# ISA: everything here is state-free math — the CPU's step loop in Cpu.roc
# owns registers, hazards, and exceptions. Unaligned merge tables and
# store-effect shapes follow psx-spx (little-endian PSX conventions).
Mips :: [].{
    op6 : U32 -> U32
    op6 = |i| i.shr_zf_wrap(26)

    rs : U32 -> U64
    rs = |i| i.shr_zf_wrap(21).bitwise_and(31).to_u64()

    rt : U32 -> U64
    rt = |i| i.shr_zf_wrap(16).bitwise_and(31).to_u64()

    rd : U32 -> U64
    rd = |i| i.shr_zf_wrap(11).bitwise_and(31).to_u64()

    sa : U32 -> U8
    sa = |i| i.shr_zf_wrap(6).bitwise_and(31).to_u8_wrap()

    funct : U32 -> U32
    funct = |i| i.bitwise_and(63)

    imm : U32 -> U32
    imm = |i| i.bitwise_and(0xFFFF)

    simm : U32 -> U32
    simm = |i| Bit.sext16(i)

    # Targets are relative to the DELAY SLOT's address — normally pc+4,
    # but when the branch itself executes in a taken delay slot, the next
    # instruction lives at the pending jump's destination and targets are
    # computed from there (pinned by the in-slot vector cases).

    # J/JAL: top 4 bits of the delay slot's address + 26-bit field << 2
    jump_target : U32, U32 -> U32
    jump_target = |i, slot_addr| slot_addr.bitwise_and(0xF000_0000).bitwise_or(i.bitwise_and(0x03FF_FFFF).shl_wrap(2))

    # conditional branches: delay slot address + sign-extended offset words
    branch_target : U32, U32 -> U32
    branch_target = |i, slot_addr| slot_addr.plus_wrap(simm(i).shl_wrap(2))

    # signed compare via sign-bit bias (avoids I32 round-trips)
    lt_signed : U32, U32 -> Bool
    lt_signed = |a, b| a.bitwise_xor(0x8000_0000) < b.bitwise_xor(0x8000_0000)

    neg32 : U32 -> U32
    neg32 = |a| a.bitwise_not().plus_wrap(1)

    abs32 : U32 -> U32
    abs32 = |a| if a >= 0x8000_0000 { neg32(a) } else { a }

    # two's-complement overflow of a + b = sum / a - b = diff
    add_overflows : U32, U32, U32 -> Bool
    add_overflows = |a, b, sum|
        a.bitwise_xor(b).bitwise_not().bitwise_and(a.bitwise_xor(sum)).bitwise_and(0x8000_0000) != 0

    sub_overflows : U32, U32, U32 -> Bool
    sub_overflows = |a, b, diff|
        a.bitwise_xor(b).bitwise_and(a.bitwise_xor(diff)).bitwise_and(0x8000_0000) != 0

    mult_signed : U32, U32 -> { hi : U32, lo : U32 }
    mult_signed = |a, b| {
        p0 = abs32(a).to_u64().times_wrap(abs32(b).to_u64())
        neg = (a >= 0x8000_0000) != (b >= 0x8000_0000)
        p = if neg { 0.U64.minus_wrap(p0) } else { p0 }
        { hi: p.shr_zf_wrap(32).to_u32_wrap(), lo: p.to_u32_wrap() }
    }

    mult_unsigned : U32, U32 -> { hi : U32, lo : U32 }
    mult_unsigned = |a, b| {
        p = a.to_u64().times_wrap(b.to_u64())
        { hi: p.shr_zf_wrap(32).to_u32_wrap(), lo: p.to_u32_wrap() }
    }

    # R3000 division never traps: divide-by-zero and 0x80000000/-1 have
    # defined results (psx-spx); remainder takes the dividend's sign
    div_signed : U32, U32 -> { hi : U32, lo : U32 }
    div_signed = |a, b|
        if b == 0 {
            { hi: a, lo: if a >= 0x8000_0000 { 1 } else { 0xFFFF_FFFF } }
        } else if a == 0x8000_0000 and b == 0xFFFF_FFFF {
            { hi: 0, lo: 0x8000_0000 }
        } else {
            q = (abs32(a).to_u64() // abs32(b).to_u64()).to_u32_wrap()
            r = (abs32(a).to_u64() % abs32(b).to_u64()).to_u32_wrap()
            neg = (a >= 0x8000_0000) != (b >= 0x8000_0000)
            {
                hi: if a >= 0x8000_0000 { neg32(r) } else { r },
                lo: if neg { neg32(q) } else { q },
            }
        }

    div_unsigned : U32, U32 -> { hi : U32, lo : U32 }
    div_unsigned = |a, b|
        if b == 0 {
            { hi: a, lo: 0xFFFF_FFFF }
        } else {
            { hi: (a.to_u64() % b.to_u64()).to_u32_wrap(), lo: (a.to_u64() // b.to_u64()).to_u32_wrap() }
        }

    # --- unaligned loads (little-endian PSX tables) ---
    # `data` is the assembled memory bytes with the lowest address in the
    # low byte (the CPU reads them as 1–2 partial bus accesses; see Cpu).

    # LWL: (vaddr & 3) + 1 bytes ending at vaddr land in the TOP of rt
    lwl_merge : U32, U32, U32 -> U32
    lwl_merge = |base, data, sh|
        match sh {
            0 => base.bitwise_and(0x00FF_FFFF).bitwise_or(data.shl_wrap(24))
            1 => base.bitwise_and(0x0000_FFFF).bitwise_or(data.shl_wrap(16))
            2 => base.bitwise_and(0x0000_00FF).bitwise_or(data.shl_wrap(8))
            _ => data
        }

    # LWR: 4 - (vaddr & 3) bytes starting at vaddr land in the BOTTOM of rt
    lwr_merge : U32, U32, U32 -> U32
    lwr_merge = |base, data, sh|
        match sh {
            0 => data
            1 => base.bitwise_and(0xFF00_0000).bitwise_or(data)
            2 => base.bitwise_and(0xFFFF_0000).bitwise_or(data)
            _ => base.bitwise_and(0xFFFF_FF00).bitwise_or(data)
        }
}

expect Mips.op6(0x8C59_847B) == 0x23 # LW
expect Mips.rs(0x014A_FDE0) == 10 and Mips.rt(0x014A_FDE0) == 10 # fields of ADD $10,$10,...
expect Mips.rd(0x0000_F821) == 31
expect Mips.simm(0x2442_FFFF) == 0xFFFF_FFFF # ADDIU with -1

expect Mips.jump_target(0x0A25_9007, 0x8CAD_8800) == 0x8896_401C
expect Mips.branch_target(0x1000_0003, 0x0000_1004) == 0x0000_1010
expect Mips.branch_target(0x1000_FFFF, 0x0000_1004) == 0x0000_1000 # offset -1: back to the delay slot

expect Mips.lt_signed(0xFFFF_FFFF, 0) and Mips.lt_signed(0x8000_0000, 0x7FFF_FFFF)
expect Mips.lt_signed(1, 0xFFFF_FFFF) == Bool.False

expect Mips.add_overflows(0x7FFF_FFFF, 1, 0x8000_0000)
expect Mips.add_overflows(0xFFFF_FFFF, 1, 0) == Bool.False
expect Mips.sub_overflows(0x8000_0000, 1, 0x7FFF_FFFF)

expect Mips.mult_signed(0xFFFF_FFFF, 2) == { hi: 0xFFFF_FFFF, lo: 0xFFFF_FFFE } # -1 * 2 = -2
expect Mips.mult_unsigned(0xFFFF_FFFF, 2) == { hi: 1, lo: 0xFFFF_FFFE }

expect Mips.div_signed(7, 0xFFFF_FFFE) == { hi: 1, lo: 0xFFFF_FFFD } # 7 / -2 = -3 rem 1
expect Mips.div_signed(0xFFFF_FFF9, 0) == { hi: 0xFFFF_FFF9, lo: 1 } # -7 / 0: defined
expect Mips.div_signed(7, 0) == { hi: 7, lo: 0xFFFF_FFFF }
expect Mips.div_signed(0x8000_0000, 0xFFFF_FFFF) == { hi: 0, lo: 0x8000_0000 }
expect Mips.div_unsigned(7, 0) == { hi: 7, lo: 0xFFFF_FFFF }
expect Mips.div_unsigned(7, 2) == { hi: 1, lo: 3 }

expect Mips.lwl_merge(0xAABB_CCDD, 0x44, 0) == 0x44BB_CCDD
expect Mips.lwl_merge(0xAABB_CCDD, 0x0000_2233, 1) == 0x2233_CCDD
expect Mips.lwl_merge(0xAABB_CCDD, 0x1122_3344, 3) == 0x1122_3344
expect Mips.lwr_merge(0xAABB_CCDD, 0x1122_3344, 0) == 0x1122_3344
expect Mips.lwr_merge(0xAABB_CCDD, 0x0011_2233, 1) == 0xAA11_2233
expect Mips.lwr_merge(0xAABB_CCDD, 0x11, 3) == 0xAABB_CC11
