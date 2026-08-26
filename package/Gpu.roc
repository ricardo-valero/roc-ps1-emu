# GPU state and VRAM. VRAM is 1024x512 15-bit pixels as ONE flat
# List(U16), owned by the DRIVER and var-threaded through the console
# layer beside the RAM pages — never inside the Bus union. Every
# function that writes it takes the list and returns it DIRECTLY (the
# store_ram discipline: no record wrapping, no Box — poison laws), so
# in-place updates survive; the real-bus bench gates that they did.
Gpu :: [].{
    vram_w : U64
    vram_w = 1024
    vram_h : U64
    vram_h = 512

    vram_init : {} -> List(U16)
    vram_init = |_| List.repeat(0.U16, 1024 * 512)

    # pixel index with the GPU's coordinate wrap
    vram_index : U64, U64 -> U64
    vram_index = |x, y| y.bitwise_and(511).times_wrap(1024).plus(x.bitwise_and(1023))

    vram_get : List(U16), U64, U64 -> U16
    vram_get = |vram, x, y| vram.get(vram_index(x, y)) ?? 0

    vram_set : List(U16), U64, U64, U16 -> List(U16)
    vram_set = |vram, x, y, px| vram.set(vram_index(x, y), px) ?? vram

    # fill a rectangle (used by GP0 02h later; here it is the in-place
    # workhorse — a full-screen fill through this loop is the clone
    # detector: cloning would copy 1 MB half a million times)
    fill_rect : List(U16), U64, U64, U64, U64, U16 -> List(U16)
    fill_rect = |vram0, x0, y0, w, h, px| {
        var vram = vram0
        var y = y0
        while y < y0.plus(h) {
            var x = x0
            while x < x0.plus(w) {
                vram = vram.set(vram_index(x, y), px) ?? vram
                x = x.plus(1)
            }
            y = y.plus(1)
        }
        vram
    }
    # ---------------------------------------------------------------- state
    # GPU scalar state lives in the Bus dev slot table (bus-readable for
    # GPUSTAT, console-written from GP0/GP1 store intents). Slot indices:
    #   44 e1 texpage, 45 e6 mask, 46 display-disable, 47 dma-direction,
    #   48 display-mode, 49 staged GPUREAD word, 50 read-stream-active,
    #   51 e2 texture window, 52 e3 area top-left, 53 e4 area bottom-right,
    #   54 e5 drawing offset, 55 display start, 56/57 display range h/v,
    #   58 irq1 flag

    # GPUSTAT from the slot values (psx-spx bit layout); `read_active` keeps
    # bit 27 honest while a C0h stream is staged, dma-request (25) follows
    # the direction per the gpustat hardware log
    gpustat : { e1 : U32, mask : U32, disp_off : U32, dma_dir : U32, mode : U32, read_active : U32, irq1 : U32, tex_allow : U32 } -> U32
    gpustat = |s| {
        # transfers are atomic here, so the GPU is never observably busy:
        # cmd-ready (26) and dma-ready (28) stay HIGH even while a C0h
        # read is staged — hardware behaves this way too (the psn00b
        # send path waits bit 28 right after issuing C0h); bit 27 alone
        # signals VRAM-read data waiting
        ready_cmd = 1.U32
        ready_vram = if s.read_active != 0 { 1.U32 } else { 0 }
        ready_dma = 1.U32
        dreq =
            if s.dma_dir == 0 {
                0.U32
            } else if s.dma_dir == 1 {
                1 # FIFO: not-full — we have no fifo depth, always ready
            } else if s.dma_dir == 2 {
                ready_dma
            } else {
                ready_vram
            }
        s.e1.bitwise_and(0x7FF)
            .bitwise_or(s.mask.bitwise_and(3).shl_wrap(11))
            .bitwise_or(0x0000_2000) # bit 13: interlace field (constant until display timing exists)
            .bitwise_or(s.mode.bitwise_and(0x80).shl_wrap(7)) # 14: reverse flag
            .bitwise_or(s.e1.shr_zf_wrap(11).bitwise_and(1).shl_wrap(15)) # tex disable (bit 11 latches only when GP1 09h allows — see the E1 write path)
            .bitwise_or(s.mode.bitwise_and(0x40).shl_wrap(10)) # 16: hres2
            .bitwise_or(s.mode.bitwise_and(3).shl_wrap(17)) # 17-18: hres1
            .bitwise_or(s.mode.bitwise_and(4).shl_wrap(17)) # 19: vres
            .bitwise_or(s.mode.bitwise_and(8).shl_wrap(17)) # 20: video mode
            .bitwise_or(s.mode.bitwise_and(0x10).shl_wrap(17)) # 21: color depth
            .bitwise_or(s.mode.bitwise_and(0x20).shl_wrap(17)) # 22: interlace
            .bitwise_or(s.disp_off.bitwise_and(1).shl_wrap(23))
            .bitwise_or(s.irq1.bitwise_and(1).shl_wrap(24))
            .bitwise_or(dreq.shl_wrap(25))
            .bitwise_or(ready_cmd.shl_wrap(26))
            .bitwise_or(ready_vram.shl_wrap(27))
            .bitwise_or(ready_dma.shl_wrap(28))
            .bitwise_or(s.dma_dir.bitwise_and(3).shl_wrap(29))
    }

    # GP0 packet length in words (header included) for the non-stream
    # commands; streams (A0/C0) have their pixel counts computed separately
    cmd_len : U32 -> U64
    cmd_len = |cmd| {
        if cmd >= 0x20 and cmd < 0x40 {
            # polygons: 3 or 4 verts, +1 word per vertex if textured, +1 per
            # extra vertex color if gouraud (first color is the header)
            verts = if cmd.bitwise_and(8) != 0 { 4.U64 } else { 3 }
            tex = if cmd.bitwise_and(4) != 0 { 1.U64 } else { 0 }
            shade = if cmd.bitwise_and(0x10) != 0 { verts.minus(1) } else { 0 }
            1.U64.plus(verts.times_wrap(1.U64.plus(tex))).plus(shade)
        } else if cmd >= 0x40 and cmd < 0x60 {
            # lines: 2 points (+1 color if gouraud); polylines are assembled
            # until the 0x5555_5555 terminator by the caller
            if cmd.bitwise_and(0x10) != 0 { 4 } else { 3 }
        } else if cmd >= 0x60 and cmd < 0x80 {
            # rectangles: header + vertex, +1 texcoord word, +1 size word
            # for variable-size (size bits 3-4 == 0)
            tex = if cmd.bitwise_and(4) != 0 { 1.U64 } else { 0 }
            var_size = if cmd.bitwise_and(0x18) == 0 { 1.U64 } else { 0 }
            2.U64.plus(tex).plus(var_size)
        } else if cmd == 0x02 {
            3
        } else if cmd == 0xA0 or cmd == 0xC0 {
            3
        } else if cmd == 0x80 {
            4
        } else {
            1 # E1-E6, 00, 01, 1F and everything single-word
        }
    }

    # 02h fill: coords masked to 16-pixel steps horizontally per hardware
    fill_decode : U32, U32 -> { x : U64, y : U64, w : U64, h : U64 }
    fill_decode = |yx, wh| {
        x = yx.bitwise_and(0x3F0).to_u64()
        y = yx.shr_zf_wrap(16).bitwise_and(0x1FF).to_u64()
        w = wh.bitwise_and(0x3FF).to_u64().plus(0x0F).bitwise_and(0xFFFF_FFF0)
        h = wh.shr_zf_wrap(16).bitwise_and(0x1FF).to_u64()
        { x: x, y: y, w: w, h: h }
    }

    # masked pixel write: check-mask skips masked pixels, set-mask forces
    # bit 15 — every non-fill write path goes through this
    put_masked : List(U16), U64, U64, U16, U32 -> List(U16)
    put_masked = |vram, x, y, px, mask| {
        if mask.bitwise_and(2) != 0 and vram_get(vram, x, y).bitwise_and(0x8000) != 0 {
            vram
        } else {
            forced = if mask.bitwise_and(1) != 0 { px.bitwise_or(0x8000) } else { px }
            vram_set(vram, x, y, forced)
        }
    }

    # 80h VRAM->VRAM copy with wrapping and mask semantics. Copies in
    # 128-pixel chunks — source pixels of a chunk are all read BEFORE
    # any are written (the hardware FIFO behavior overlapping copies
    # observe; per-pixel interleave diverges on the overlap test)
    copy_rect : List(U16), U64, U64, U64, U64, U64, U64, U32 -> List(U16)
    copy_rect = |vram0, sx, sy, dx, dy, w, h, mask| {
        var vram = vram0
        var row = 0.U64
        while row < h {
            var cx = 0.U64
            while cx < w {
                chunk = if w.minus(cx) > 128 { 128.U64 } else { w.minus(cx) }
                var buf = List.with_capacity(128)
                var i = 0.U64
                while i < chunk {
                    buf = buf.append(vram_get(vram, sx.plus(cx).plus(i), sy.plus(row)))
                    i = i.plus(1)
                }
                var j = 0.U64
                while j < chunk {
                    vram = put_masked(vram, dx.plus(cx).plus(j), dy.plus(row), buf.get(j) ?? 0, mask)
                    j = j.plus(1)
                }
                cx = cx.plus(chunk)
            }
            row = row.plus(1)
        }
        vram
    }

    # transfer size decode for A0h/C0h (0 encodes the maximum)
    xfer_decode : U32, U32 -> { x : U64, y : U64, w : U64, h : U64 }
    xfer_decode = |yx, wh| {
        w0 = wh.bitwise_and(0x3FF).to_u64()
        h0 = wh.shr_zf_wrap(16).bitwise_and(0x1FF).to_u64()
        {
            x: yx.bitwise_and(0x3FF).to_u64(),
            y: yx.shr_zf_wrap(16).bitwise_and(0x1FF).to_u64(),
            w: if w0 == 0 { 0x400 } else { w0 },
            h: if h0 == 0 { 0x200 } else { h0 },
        }
    }

    # 24-bit BGR command color -> 15-bit VRAM pixel
    c24to15 : U32 -> U16
    c24to15 = |c| {
        r = c.bitwise_and(0xFF).shr_zf_wrap(3)
        g = c.shr_zf_wrap(8).bitwise_and(0xFF).shr_zf_wrap(3)
        b = c.shr_zf_wrap(16).bitwise_and(0xFF).shr_zf_wrap(3)
        r.bitwise_or(g.shl_wrap(5)).bitwise_or(b.shl_wrap(10)).to_u16_wrap()
    }

    # execute a complete vram-touching packet (02h fill, 80h copy; the
    # primitive commands join in the rasterizer group). List in, list
    # out, DIRECT — the store_ram discipline.
    exec_vram : List(U16), List(U32), U32 -> List(U16)
    exec_vram = |vram, pkt, mask| {
        head = pkt.get(0) ?? 0
        cmd = head.shr_zf_wrap(24)
        if cmd == 0x02 {
            d = fill_decode(pkt.get(1) ?? 0, pkt.get(2) ?? 0)
            fill_rect(vram, d.x, d.y, d.w, d.h, c24to15(head))
        } else if cmd == 0x80 {
            s = xfer_decode(pkt.get(1) ?? 0, pkt.get(3) ?? 0)
            dd = xfer_decode(pkt.get(2) ?? 0, pkt.get(3) ?? 0)
            copy_rect(vram, s.x, s.y, dd.x, dd.y, s.w, s.h, mask)
        } else {
            vram
        }
    }

    # linear-cursor pixel position for A0h/C0h streams (row-major)
    stream_pos : { x : U64, y : U64, w : U64 }, U64 -> { x : U64, y : U64 }
    stream_pos = |t, li| { x: t.x.plus(li % t.w), y: t.y.plus(li // t.w) }

    # one A0h stream word: two masked pixel writes at the linear cursor
    stream_write : List(U16), { x : U64, y : U64, w : U64 }, U64, U64, U32, U32 -> List(U16)
    stream_write = |vram0, t, li, total, word, mask| {
        p1 = stream_pos(t, li)
        vram = put_masked(vram0, p1.x, p1.y, word.to_u16_wrap(), mask)
        if li.plus(1) < total {
            p2 = stream_pos(t, li.plus(1))
            put_masked(vram, p2.x, p2.y, word.shr_zf_wrap(16).to_u16_wrap(), mask)
        } else {
            vram
        }
    }

    # one C0h stream word staged for GPUREAD (two pixels, zero-padded)
    read_word : List(U16), { x : U64, y : U64, w : U64 }, U64, U64 -> U32
    read_word = |vram, t, li, total| {
        p1 = stream_pos(t, li)
        lo = vram_get(vram, p1.x, p1.y).to_u32()
        hi = if li.plus(1) < total {
            p2 = stream_pos(t, li.plus(1))
            vram_get(vram, p2.x, p2.y).to_u32()
        } else {
            0
        }
        lo.bitwise_or(hi.shl_wrap(16))
    }

    # GP1 10h info values come from these slots
    info_slot : U32 -> U64
    info_slot = |idx|
        if idx == 2 { 51 } else if idx == 3 { 52 } else if idx == 4 { 53 } else if idx == 5 { 54 } else { 49 }
}

# fills land exactly their rectangle (SMALL fills here: expect bindings
# stay live for failure reporting, so expect-context sets always clone —
# the in-place proof is the var-threaded fill-rate probe + the bench
# tripwire, ~1 ns/pixel measured 2026-08-25)
expect {
    v0 = Gpu.vram_init({})
    v1 = Gpu.fill_rect(v0, 0, 0, 64, 4, 0x7FFF)
    v2 = Gpu.fill_rect(v1, 10, 1, 3, 2, 0x1234)
    Gpu.vram_get(v2, 0, 0) == 0x7FFF
    and Gpu.vram_get(v2, 63, 3) == 0x7FFF
    and Gpu.vram_get(v2, 10, 1) == 0x1234
    and Gpu.vram_get(v2, 12, 2) == 0x1234
    and Gpu.vram_get(v2, 13, 2) == 0x7FFF
    and Gpu.vram_get(v2, 10, 3) == 0x7FFF
    and Gpu.vram_get(v2, 64, 0) == 0
}


# transfers: fill decodes 16-pixel granularity; copy honors mask; stream
# round-trips through write and read words
expect {
    v0 = Gpu.vram_init({})
    v1 = Gpu.exec_vram(v0, [0x02BB_9977, 0x0002_0005, 0x0001_0011], 0) # fill: x=0 (5&~15), y=2, w=32 (17 rounded), h=1, color 77/99/BB
    t = { x: 0.U64, y: 2.U64, w: 32.U64 }
    w0 = Gpu.read_word(v1, t, 0, 64)
    v2 = Gpu.stream_write(v1, { x: 100.U64, y: 0.U64, w: 2.U64 }, 0, 4, 0x8123_4567, 0)
    v3 = Gpu.stream_write(v2, { x: 100.U64, y: 0.U64, w: 2.U64 }, 0, 4, 0x0BCD_0ABC, 2) # check-mask: (100,0) clear -> overwritten, (101,0) masked -> survives
    v4 = Gpu.exec_vram(v3, [0x8000_0000, 0x0000_0064, 0x0014_0000, 0x0001_0002], 1) # copy 2x1 from (100,0) to (0,20) with set-mask
    px = Gpu.c24to15(0x00BB_9977)
    Gpu.vram_get(v1, 0, 2) == px
    and Gpu.vram_get(v1, 31, 2) == px
    and Gpu.vram_get(v1, 32, 2) == 0
    and w0 == px.to_u32().bitwise_or(px.to_u32().shl_wrap(16))
    and Gpu.vram_get(v2, 100, 0) == 0x4567
    and Gpu.vram_get(v2, 101, 0) == 0x8123
    and Gpu.vram_get(v3, 100, 0) == 0x0ABC # unmasked pixel overwritten
    and Gpu.vram_get(v3, 101, 0) == 0x8123 # masked pixel survived the check-mask write
    and Gpu.vram_get(v4, 0, 20) == 0x8ABC # copied with set-mask forcing bit 15
    and Gpu.vram_get(v4, 1, 20) == 0x8123
}
