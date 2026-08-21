# 32-bit word helpers the R3000 core and GTE will lean on: MIPS loads
# sign-extend bytes/halfwords into full registers, and much of the
# hardware is described bit-at-a-time.
Bit :: [].{
    # sign-extend the low 8 bits into a full word (MIPS LB)
    sext8 : U32 -> U32
    sext8 = |w| {
        b = w.bitwise_and(0xFF)
        if b >= 0x80 { b.bitwise_or(0xFFFF_FF00) } else { b }
    }

    # sign-extend the low 16 bits into a full word (MIPS LH, ADDIU immediates)
    sext16 : U32 -> U32
    sext16 = |w| {
        h = w.bitwise_and(0xFFFF)
        if h >= 0x8000 { h.bitwise_or(0xFFFF_0000) } else { h }
    }

    # bit n (0-31) of a word
    check : U32, U8 -> Bool
    check = |w, n| w.shr_zf_wrap(n).bitwise_and(1) == 1
}

expect Bit.sext8(0x0000_007F) == 0x0000_007F
expect Bit.sext8(0x0000_0080) == 0xFFFF_FF80
expect Bit.sext8(0x1234_56FF) == 0xFFFF_FFFF

expect Bit.sext16(0x1234_7FFF) == 0x0000_7FFF
expect Bit.sext16(0x0000_8000) == 0xFFFF_8000

expect Bit.check(0x8000_0000, 31)
expect Bit.check(0x8000_0000, 0) == Bool.False
