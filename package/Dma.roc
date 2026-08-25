# DMA transfers that have a live endpoint. Only channel 6 (OTC) runs
# here — it touches nothing but RAM: clear an ordering table backward
# from MADR, each entry the 24-bit address of the one below it, the
# lowest terminated with 0xFFFFFF. Device channels are kicked loudly to
# their (future) device changes by the console layer.
#
# Pages in, pages out, DIRECTLY — no record wrapping (poison law 1);
# page-detach before each set (the store_ram discipline).
Dma :: [].{
    # word count: BCR low half, 0 meaning 0x10000
    otc_words : U32 -> U64
    otc_words = |bcr| {
        n = bcr.bitwise_and(0xFFFF).to_u64()
        if n == 0 { 0x10000 } else { n }
    }

    # MADR after completion: the terminator's address
    otc_end_madr : U32, U32 -> U32
    otc_end_madr = |madr, bcr|
        madr.bitwise_and(0x1F_FFFC).minus_wrap(otc_words(bcr).minus(1).to_u32_wrap().times_wrap(4)).bitwise_and(0x00FF_FFFF)

    store_word : List(List(U8)), U64, U32 -> List(List(U8))
    store_word = |pages, i0, val| {
        pi = i0.shr_zf_wrap(12)
        off = i0.bitwise_and(0xFFF)
        page = pages.get(pi) ?? []
        pages1 = pages.set(pi, []) ?? pages
        page2 = ((((page.set(off, val.to_u8_wrap()) ?? page).set(off.plus(1), val.shr_zf_wrap(8).to_u8_wrap()) ?? page).set(off.plus(2), val.shr_zf_wrap(16).to_u8_wrap()) ?? page).set(off.plus(3), val.shr_zf_wrap(24).to_u8_wrap())) ?? page
        pages1.set(pi, page2) ?? pages1
    }

    # word read from the RAM pages (DMA walks RAM a lot)
    load_word : List(List(U8)), U32 -> U32
    load_word = |pages, addr| {
        i0 = addr.bitwise_and(0x1F_FFFC).to_u64()
        page = pages.get(i0.shr_zf_wrap(12)) ?? []
        o = i0.bitwise_and(0xFFF)
        (page.get(o) ?? 0).to_u32()
            .bitwise_or((page.get(o.plus(1)) ?? 0).to_u32().shl_wrap(8))
            .bitwise_or((page.get(o.plus(2)) ?? 0).to_u32().shl_wrap(16))
            .bitwise_or((page.get(o.plus(3)) ?? 0).to_u32().shl_wrap(24))
    }

    otc_run : List(List(U8)), U32, U32 -> List(List(U8))
    otc_run = |pages0, madr, bcr| {
        var pages = pages0
        var addr = madr.bitwise_and(0x1F_FFFC)
        var left = otc_words(bcr)
        while left > 1 {
            pages = store_word(pages, addr.to_u64(), addr.minus_wrap(4).bitwise_and(0x00FF_FFFF))
            addr = addr.minus_wrap(4).bitwise_and(0x1F_FFFC)
            left = left.minus(1)
        }
        store_word(pages, addr.to_u64(), 0x00FF_FFFF)
    }
}

# OTC layout: back-pointers descending, terminator at the lowest entry
expect {
    ram0 = [List.repeat(0, 0x1000)]
    ram = Dma.otc_run(ram0, 0x10C, 4)
    rd = |r, a| ((r.get(0) ?? []).get(a) ?? 0).to_u32()
        .bitwise_or(((r.get(0) ?? []).get(a.plus(1)) ?? 0).to_u32().shl_wrap(8))
        .bitwise_or(((r.get(0) ?? []).get(a.plus(2)) ?? 0).to_u32().shl_wrap(16))
        .bitwise_or(((r.get(0) ?? []).get(a.plus(3)) ?? 0).to_u32().shl_wrap(24))
    rd(ram, 0x10C) == 0x108
    and rd(ram, 0x108) == 0x104
    and rd(ram, 0x104) == 0x100
    and rd(ram, 0x100) == 0x00FF_FFFF
    and Dma.otc_end_madr(0x10C, 4) == 0x100
}
