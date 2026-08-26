import /Gpu

# The software rasterizer: GP0 primitives into the flat VRAM list.
# Correctness is defined by the hardware-captured VRAM references, not
# documentation faith — the fixed-point choices below started from the
# psx-spx description and the Mednafen/DuckStation consensus and are
# tuned until the references match BIT-EXACT. List in, list out,
# DIRECT (store_ram discipline).
#
# Pipeline per pixel: drawing-area clip -> dither (gouraud, when E1
# bit 9) -> 5-bit truncate -> semi-transparency blend -> mask check/set.
Raster :: [].{
    # signed 11-bit vertex component + signed 11-bit drawing offset
    sext11 : U32 -> I64
    sext11 = |v| {
        r = v.bitwise_and(0x7FF).to_i64()
        if r >= 0x400 { r.minus(0x800) } else { r }
    }

    # drawing state decoded from the dev slots
    State : { clip_l : I64, clip_t : I64, clip_r : I64, clip_b : I64, off_x : I64, off_y : I64, dither : Bool, semi_mode : U32, mask : U32, e1_full : U64 }

    state_from : U64, U64, U64, U64, U64 -> State
    state_from = |e1, e3, e4, e5, mask| {
        {
            clip_l: e3.bitwise_and(0x3FF).to_u32_wrap().to_i64(),
            clip_t: e3.shr_zf_wrap(10).bitwise_and(0x1FF).to_u32_wrap().to_i64(),
            clip_r: e4.bitwise_and(0x3FF).to_u32_wrap().to_i64(),
            clip_b: e4.shr_zf_wrap(10).bitwise_and(0x1FF).to_u32_wrap().to_i64(),
            off_x: sext11(e5.to_u32_wrap()),
            off_y: sext11(e5.shr_zf_wrap(11).to_u32_wrap()),
            dither: e1.bitwise_and(0x200) != 0,
            semi_mode: e1.shr_zf_wrap(5).bitwise_and(3).to_u32_wrap(),
            mask: mask.to_u32_wrap(),
            e1_full: e1,
        }
    }

    # psx-spx 4x4 dither offsets
    dither_at : U64, U64 -> I64
    dither_at = |x, y| {
        row = y.bitwise_and(3)
        col = x.bitwise_and(3)
        table = [-4.I64, 0, -3, 1, 2, -2, 3, -1, -3, 1, -4, 0, 3, -1, 2, -2]
        table.get(row.times_wrap(4).plus(col)) ?? 0
    }

    clamp255 : I64 -> I64
    clamp255 = |v| if v < 0 { 0 } else if v > 255 { 255 } else { v }

    # 8-bit rgb -> vram pixel with optional dither at (x,y)
    shade : I64, I64, I64, U64, U64, Bool -> U16
    shade = |r, g, b, x, y, dith| {
        d = if dith { dither_at(x, y) } else { 0 }
        r5 = clamp255(r.plus(d)).shr_zf_wrap(3)
        g5 = clamp255(g.plus(d)).shr_zf_wrap(3)
        b5 = clamp255(b.plus(d)).shr_zf_wrap(3)
        r5.bitwise_or(g5.shl_wrap(5)).bitwise_or(b5.shl_wrap(10)).to_u16_wrap()
    }

    # semi-transparency blend of fore over back, per 5-bit channel
    blend : U16, U16, U32 -> U16
    blend = |back, fore, mode| {
        ch = |shift| {
            b = back.shr_zf_wrap(shift).bitwise_and(31).to_u32().to_i64()
            f = fore.shr_zf_wrap(shift).bitwise_and(31).to_u32().to_i64()
            v = if mode == 0 {
                b.plus(f) // 2
            } else if mode == 1 {
                b.plus(f)
            } else if mode == 2 {
                b.minus(f)
            } else {
                b.plus(f // 4)
            }
            if v < 0 { 0.I64 } else if v > 31 { 31 } else { v }
        }
        ch(0).bitwise_or(ch(5).shl_wrap(5)).bitwise_or(ch(10).shl_wrap(10)).to_u16_wrap()
            .bitwise_or(fore.bitwise_and(0x8000))
    }

    # one shaded pixel through the full pipeline
    put_pixel : List(U16), I64, I64, U16, Bool, State -> List(U16)
    put_pixel = |vram, x, y, px, semi, st| {
        if x < st.clip_l or x > st.clip_r or y < st.clip_t or y > st.clip_b {
            vram
        } else {
            xu = x.to_u64_wrap()
            yu = y.to_u64_wrap()
            back = Gpu.vram_get(vram, xu, yu)
            if st.mask.bitwise_and(2) != 0 and back.bitwise_and(0x8000) != 0 {
                vram
            } else {
                out0 = if semi { blend(back, px, st.semi_mode) } else { px }
                out = if st.mask.bitwise_and(1) != 0 { out0.bitwise_or(0x8000) } else { out0 }
                Gpu.vram_set(vram, xu, yu, out)
            }
        }
    }

    # Triangle rasterization: a faithful port of Mednafen's PS1 GPU
    # algorithm (beetle-psx gpu_polygon.c) — core-vertex-anchored
    # interpolant plane in u32 WRAP arithmetic (FBS 12 + post-padding
    # 12, sampled >> 24), MakePolyXFP bias (1<<32)-(1<<11), edge steps
    # rounded away from zero, tripart edge table with the exact
    # anchor/direction per part. Bit-exactness judged by the hardware
    # references.
    Vtx : { x : I64, y : I64, r : I64, g : I64, b : I64 }

    xfp : I64 -> I64
    xfp = |x| x.shl_wrap(32).plus(0xFFFF_F800)

    xfp_int : I64 -> I64
    xfp_int = |v| v.shr_wrap(32)

    step_of : I64, I64 -> I64
    step_of = |dx, dy|
        if dy == 0 {
            0
        } else {
            n = dx.shl_wrap(32)
            adj = if n < 0 { n.minus(dy.minus(1)) } else if n > 0 { n.plus(dy.minus(1)) } else { n }
            adj // dy
        }

    # C-style truncating division (Roc // on mixed signs must not floor)
    tdiv : I64, I64 -> I64
    tdiv = |n, d| {
        q = n.abs() // d.abs()
        if (n < 0) == (d < 0) { q } else { 0.I64.minus(q) }
    }

    # per-pixel interpolant deltas, u32 wrap domain
    calcis : Vtx, Vtx, Vtx, (Vtx -> I64), (Vtx -> I64) -> I64
    calcis = |a, b, cc, fx, fy|
        (fx(b).minus(fx(a))).times_wrap(fy(cc).minus(fy(b))).minus((fx(cc).minus(fx(b))).times_wrap(fy(b).minus(fy(a))))

    delta32 : I64, I64 -> U32
    delta32 = |num, den| tdiv(num.shl_wrap(12), den).to_u32_wrap().shl_wrap(12)

    draw_tri : List(U16), Vtx, Vtx, Vtx, Bool, Bool, State -> List(U16)
    draw_tri = |vram0, in0, in1, in2, gouraud, semi, st| {
        # core vertex: leftmost with input-order ties (pre-sort)
        cv0 =
            if in1.x <= in0.x {
                if in2.x <= in1.x { 4.U64 } else { 2 }
            } else if in2.x < in0.x {
                4
            } else {
                1
            }
        # sort by y (three compare-swaps), tracking the core bit
        p1 = if in2.y < in1.y { { a: in0, b: in2, c: in1, cv: cv0.shr_zf_wrap(1).bitwise_and(2).bitwise_or(cv0.shl_wrap(1).bitwise_and(4)).bitwise_or(cv0.bitwise_and(1)) } } else { { a: in0, b: in1, c: in2, cv: cv0 } }
        p2 = if p1.b.y < p1.a.y { { a: p1.b, b: p1.a, c: p1.c, cv: p1.cv.shr_zf_wrap(1).bitwise_and(1).bitwise_or(p1.cv.shl_wrap(1).bitwise_and(2)).bitwise_or(p1.cv.bitwise_and(4)) } } else { p1 }
        p3 = if p2.c.y < p2.b.y { { a: p2.a, b: p2.c, c: p2.b, cv: p2.cv.shr_zf_wrap(1).bitwise_and(2).bitwise_or(p2.cv.shl_wrap(1).bitwise_and(4)).bitwise_or(p2.cv.bitwise_and(1)) } } else { p2 }
        v0 = p3.a
        v1 = p3.b
        v2 = p3.c
        core = p3.cv.shr_zf_wrap(1) # 0, 1, or 2
        cv = if core == 0 { v0 } else if core == 1 { v1 } else { v2 }
        too_big =
            v2.y.minus(v0.y) >= 512
            or (v0.x.minus(v1.x)).abs() >= 1024
            or (v1.x.minus(v2.x)).abs() >= 1024
            or (v0.x.minus(v2.x)).abs() >= 1024
        denom = calcis(v0, v1, v2, |v| v.x, |v| v.y)
        if too_big or v0.y == v2.y or denom == 0 {
            vram0
        } else {
            dr_dx = delta32(calcis(v0, v1, v2, |v| v.r, |v| v.y), denom)
            dr_dy = delta32(calcis(v0, v1, v2, |v| v.x, |v| v.r), denom)
            dg_dx = delta32(calcis(v0, v1, v2, |v| v.g, |v| v.y), denom)
            dg_dy = delta32(calcis(v0, v1, v2, |v| v.x, |v| v.g), denom)
            db_dx = delta32(calcis(v0, v1, v2, |v| v.b, |v| v.y), denom)
            db_dy = delta32(calcis(v0, v1, v2, |v| v.x, |v| v.b), denom)
            # interpolant base anchored at the core vertex, rebased to
            # the origin (u32 wrap)
            base_r = cv.r.to_u32_wrap().shl_wrap(12).plus_wrap(0x800).shl_wrap(12).minus_wrap(dr_dx.times_wrap(cv.x.to_u32_wrap())).minus_wrap(dr_dy.times_wrap(cv.y.to_u32_wrap()))
            base_g = cv.g.to_u32_wrap().shl_wrap(12).plus_wrap(0x800).shl_wrap(12).minus_wrap(dg_dx.times_wrap(cv.x.to_u32_wrap())).minus_wrap(dg_dy.times_wrap(cv.y.to_u32_wrap()))
            base_b = cv.b.to_u32_wrap().shl_wrap(12).plus_wrap(0x800).shl_wrap(12).minus_wrap(db_dx.times_wrap(cv.x.to_u32_wrap())).minus_wrap(db_dy.times_wrap(cv.y.to_u32_wrap()))
            base_coord = xfp(v0.x)
            base_step = step_of(v2.x.minus(v0.x), v2.y.minus(v0.y))
            bound_us = if v1.y == v0.y { 0.I64 } else { step_of(v1.x.minus(v0.x), v1.y.minus(v0.y)) }
            right_facing = if v1.y == v0.y { v1.x > v0.x } else { bound_us > base_step }
            bound_ls = if v2.y == v1.y { 0.I64 } else { step_of(v2.x.minus(v1.x), v2.y.minus(v1.y)) }
            vo = if core != 0 { 1.I64 } else { 0 }
            vp = if core == 2 { 3.I64 } else { 0 }
            # tripart[vo] (upper geometry), tripart[vo^1] (lower)
            vsel = |i| if i == 0 { v0 } else if i == 1 { v1 } else { v2 }
            mk_part = |yc_i, yb_i, rf_x, rf_s, base_y| {
                {
                    y_coord: vsel(yc_i).y,
                    y_bound: vsel(yb_i).y,
                    rf_c: xfp(rf_x),
                    rf_s: rf_s,
                    o_c: base_coord.plus(base_y.minus(v0.y).times_wrap(base_step)),
                    o_s: base_step,
                }
            }
            u0 = vo # 0^vo for vo in {0,1}
            u1 = 1.I64.minus(vo) # 1^vo
            part_u = mk_part(u0, u1, vsel(u0).x, bound_us, vsel(vo).y)
            l0 = if vp == 0 { 1.I64 } else { 2 } # 1^vp for vp in {0,3}
            l1 = if vp == 0 { 2.I64 } else { 1 } # 2^vp
            part_l = mk_part(l0, l1, vsel(l0).x, bound_ls, vsel(l0).y)
            dec_u = vo != 0
            dec_l = vp != 0
            var vram = vram0
            var pi = 0.U64
            while pi < 2 {
                first = if vo == 0 { pi == 0 } else { pi == 1 }
                tp = if first { part_u } else { part_l }
                dec = if first { dec_u } else { dec_l }
                var lc = if right_facing { tp.o_c } else { tp.rf_c }
                var ls = if right_facing { tp.o_s } else { tp.rf_s }
                var rc = if right_facing { tp.rf_c } else { tp.o_c }
                var rs = if right_facing { tp.rf_s } else { tp.o_s }
                if dec {
                    var yi = tp.y_coord
                    while yi > tp.y_bound {
                        yi = yi.minus(1)
                        lc = lc.minus(ls)
                        rc = rc.minus(rs)
                        vram = draw_span(vram, yi, xfp_int(lc), xfp_int(rc), base_r, base_g, base_b, dr_dx, dr_dy, dg_dx, dg_dy, db_dx, db_dy, gouraud, semi, st)
                    }
                } else {
                    var yi = tp.y_coord
                    while yi < tp.y_bound {
                        vram = draw_span(vram, yi, xfp_int(lc), xfp_int(rc), base_r, base_g, base_b, dr_dx, dr_dy, dg_dx, dg_dy, db_dx, db_dy, gouraud, semi, st)
                        yi = yi.plus(1)
                        lc = lc.plus(ls)
                        rc = rc.plus(rs)
                    }
                }
                pi = pi.plus(1)
            }
            vram
        }
    }

    draw_span : List(U16), I64, I64, I64, U32, U32, U32, U32, U32, U32, U32, U32, U32, Bool, Bool, State -> List(U16)
    draw_span = |vram0, y, x_start, x_bound, br, bg, bb, dr_dx, dr_dy, dg_dx, dg_dy, db_dx, db_dy, gouraud, semi, st| {
        if y < st.clip_t or y > st.clip_b {
            vram0
        } else {
            x0 = if x_start < st.clip_l { st.clip_l } else { x_start }
            xe = if x_bound > st.clip_r.plus(1) { st.clip_r.plus(1) } else { x_bound }
            if x0 >= xe {
                vram0
            } else {
                yu = y.to_u32_wrap()
                var cr = br.plus_wrap(dr_dx.times_wrap(x0.to_u32_wrap())).plus_wrap(dr_dy.times_wrap(yu))
                var cg = bg.plus_wrap(dg_dx.times_wrap(x0.to_u32_wrap())).plus_wrap(dg_dy.times_wrap(yu))
                var cb = bb.plus_wrap(db_dx.times_wrap(x0.to_u32_wrap())).plus_wrap(db_dy.times_wrap(yu))
                var vram = vram0
                var x = x0
                while x < xe {
                    px = shade(cr.shr_zf_wrap(24).to_u32().to_i64(), cg.shr_zf_wrap(24).to_u32().to_i64(), cb.shr_zf_wrap(24).to_u32().to_i64(), x.to_u64_wrap(), y.to_u64_wrap(), gouraud and st.dither)
                    vram = put_pixel(vram, x, y, px, semi, st)
                    cr = cr.plus_wrap(dr_dx)
                    cg = cg.plus_wrap(dg_dx)
                    cb = cb.plus_wrap(db_dx)
                    x = x.plus(1)
                }
                vram
            }
        }
    }

    # rectangles (0x60-0x7F untextured): flat color, no dither, sizes
    # from bits 3-4 (variable / 1x1 / 8x8 / 16x16); drawing offset and
    # clip apply; semi-transparency per bit 1
    draw_rect : List(U16), List(U32), State -> List(U16)
    draw_rect = |vram0, pkt, st| {
        head = pkt.get(0) ?? 0
        cmd = head.shr_zf_wrap(24)
        semi = cmd.bitwise_and(2) != 0
        size_bits = cmd.shr_zf_wrap(3).bitwise_and(3)
        xy = pkt.get(1) ?? 0
        wh =
            if size_bits == 0 {
                pkt.get(2) ?? 0
            } else if size_bits == 1 {
                0x0001_0001
            } else if size_bits == 2 {
                0x0008_0008
            } else {
                0x0010_0010
            }
        x0 = sext11(xy.to_u32_wrap()).plus(st.off_x)
        y0 = sext11(xy.shr_zf_wrap(16).to_u32_wrap()).plus(st.off_y)
        w = wh.bitwise_and(0x3FF).to_i64()
        h = wh.shr_zf_wrap(16).bitwise_and(0x1FF).to_i64()
        px = shade(head.bitwise_and(0xFF).to_i64(), head.shr_zf_wrap(8).bitwise_and(0xFF).to_i64(), head.shr_zf_wrap(16).bitwise_and(0xFF).to_i64(), 0, 0, Bool.False)
        var vram = vram0
        var y = y0
        while y < y0.plus(h) {
            var x = x0
            while x < x0.plus(w) {
                vram = put_pixel(vram, x, y, px, semi, st)
                x = x.plus(1)
            }
            y = y.plus(1)
        }
        vram
    }

    # Lines: Mednafen's DDA (gpu_line.c) — dominant-axis walk, steps
    # away-from-zero at 32 fraction bits, start biased +(1<<31) then
    # x -= 1024 (and y -= 1024 only when stepping upward), endpoint
    # INCLUSIVE, colors at 12 fraction bits with u32-wrap deltas.
    # Lines dither whenever E1 bit 9 is on — flat ones too.
    line_div : I64, I64 -> I64
    line_div = |delta, dk| {
        n = delta.shl_wrap(32)
        adj = if n < 0 { n.minus(dk.minus(1)) } else if n > 0 { n.plus(dk.minus(1)) } else { n }
        adj // dk
    }

    # signed reinterpretation of a u32 (color delta domain)
    s32 : U32 -> I64
    s32 = |v| {
        u = v.to_i64() # U32.to_i64 zero-extends
        if u >= 0x8000_0000 { u.minus(0x1_0000_0000) } else { u }
    }

    draw_line : List(U16), { x : I64, y : I64, r : I64, g : I64, b : I64 }, { x : I64, y : I64, r : I64, g : I64, b : I64 }, Bool, Bool, State -> List(U16)
    draw_line = |vram0, in_a, in_b, gouraud, semi, st| {
        dx_abs = (in_b.x.minus(in_a.x)).abs()
        dy_abs = (in_b.y.minus(in_a.y)).abs()
        k = if dx_abs > dy_abs { dx_abs } else { dy_abs }
        swapped = in_a.x > in_b.x and k != 0
        p0 = if swapped { in_b } else { in_a }
        p1 = if swapped { in_a } else { in_b }
        dx_dk = if k == 0 { 0.I64 } else { line_div(p1.x.minus(p0.x), k) }
        dy_dk = if k == 0 { 0.I64 } else { line_div(p1.y.minus(p0.y), k) }
        dr_dk = if k == 0 or gouraud == Bool.False { 0.I64 } else { tdiv(s32(p1.r.to_u32_wrap().minus_wrap(p0.r.to_u32_wrap()).shl_wrap(12)), k) }
        dg_dk = if k == 0 or gouraud == Bool.False { 0.I64 } else { tdiv(s32(p1.g.to_u32_wrap().minus_wrap(p0.g.to_u32_wrap()).shl_wrap(12)), k) }
        db_dk = if k == 0 or gouraud == Bool.False { 0.I64 } else { tdiv(s32(p1.b.to_u32_wrap().minus_wrap(p0.b.to_u32_wrap()).shl_wrap(12)), k) }
        var cx = p0.x.shl_wrap(32).bitwise_or(0x8000_0000).minus(1024)
        var cy0 = p0.y.shl_wrap(32).bitwise_or(0x8000_0000)
        var cy = if dy_dk < 0 { cy0.minus(1024) } else { cy0 }
        var cr = p0.r.to_u32_wrap().shl_wrap(12).bitwise_or(0x800)
        var cg = p0.g.to_u32_wrap().shl_wrap(12).bitwise_or(0x800)
        var cb = p0.b.to_u32_wrap().shl_wrap(12).bitwise_or(0x800)
        var vram = vram0
        var i = 0.I64
        while i <= k {
            x = cx.shr_wrap(32).bitwise_and(2047)
            y = cy.shr_wrap(32).bitwise_and(2047)
            rr = if gouraud { cr.shr_zf_wrap(12).bitwise_and(0xFF).to_u32().to_i64() } else { p0.r }
            gg = if gouraud { cg.shr_zf_wrap(12).bitwise_and(0xFF).to_u32().to_i64() } else { p0.g }
            bb = if gouraud { cb.shr_zf_wrap(12).bitwise_and(0xFF).to_u32().to_i64() } else { p0.b }
            px = shade(rr, gg, bb, x.to_u64_wrap(), y.to_u64_wrap(), st.dither)
            vram = put_pixel(vram, x, y, px, semi, st)
            cx = cx.plus_wrap(dx_dk)
            cy = cy.plus_wrap(dy_dk)
            cr = cr.plus_wrap(dr_dk.to_u32_wrap())
            cg = cg.plus_wrap(dg_dk.to_u32_wrap())
            cb = cb.plus_wrap(db_dk.to_u32_wrap())
            i = i.plus(1)
        }
        vram
    }

    # a line/polyline vertex from (color word, xy word) with offset
    line_vtx : U32, U32, State -> { x : I64, y : I64, r : I64, g : I64, b : I64 }
    line_vtx = |cw, xy, st| {
        {
            x: sext11(xy.to_u32_wrap()).plus(st.off_x),
            y: sext11(xy.shr_zf_wrap(16).to_u32_wrap()).plus(st.off_y),
            r: cw.bitwise_and(0xFF).to_i64(),
            g: cw.shr_zf_wrap(8).bitwise_and(0xFF).to_i64(),
            b: cw.shr_zf_wrap(16).bitwise_and(0xFF).to_i64(),
        }
    }

    # complete line packet (single segment or polyline word list)
    draw_lines : List(U16), List(U32), State -> List(U16)
    draw_lines = |vram0, pkt, st| {
        head = pkt.get(0) ?? 0
        cmd = head.shr_zf_wrap(24)
        gouraud = cmd.bitwise_and(0x10) != 0
        semi = cmd.bitwise_and(2) != 0
        stride = if gouraud { 2.U64 } else { 1 }
        # vertex i: color word (head for flat / per-vertex for gouraud),
        # xy word; for gouraud vertex 0 the color IS the head
        vat = |i| {
            cw = if gouraud { if i == 0 { head } else { pkt.get(i.times_wrap(2)) ?? 0 } } else { head }
            xy = pkt.get(i.times_wrap(stride).plus(1)) ?? 0
            line_vtx(cw, xy, st)
        }
        n_words = pkt.len()
        n_vts = if gouraud { n_words.plus(1) // 2 } else { n_words.minus(1) }
        var vram = vram0
        var i = 0.U64
        while i.plus(1) < n_vts {
            vram = draw_line(vram, vat(i), vat(i.plus(1)), gouraud, semi, st)
            i = i.plus(1)
        }
        vram
    }


    # ---------------------------------------------------------- texture
    # Texture sampling per Mednafen GetTexel: texture window folded into
    # the u-domain BEFORE the format shift (TexPageX enters pre-scaled),
    # 4/8-bit CLUT via the palette row, texel 0x0000 = transparent,
    # texel bit 15 = STP (drives per-texel blending and IS stored).
    TexCtx : { e1 : U64, e2 : U64, clut : U32, cache : List(U16) }

    tex_sample : List(U16), TexCtx, I64, I64 -> U16
    tex_sample = |vram, tc, u_in, v_in| {
        tm0 = tc.e1.shr_zf_wrap(7).bitwise_and(3)
        tm = if tm0 > 2 { 2.U64 } else { tm0 }
        tww = tc.e2.bitwise_and(0x1F)
        twh = tc.e2.shr_zf_wrap(5).bitwise_and(0x1F)
        twx = tc.e2.shr_zf_wrap(10).bitwise_and(0x1F)
        twy = tc.e2.shr_zf_wrap(15).bitwise_and(0x1F)
        page_x = tc.e1.bitwise_and(0xF).times_wrap(64)
        page_y = tc.e1.shr_zf_wrap(4).bitwise_and(1).times_wrap(256)
        uu = u_in.to_u64_wrap().bitwise_and(255)
        vv = v_in.to_u64_wrap().bitwise_and(255)
        shift = 2.U8.minus(tm.to_u8_wrap())
        u_ext = uu.bitwise_and(tww.shl_wrap(3).bitwise_not()).plus_wrap(twx.bitwise_and(tww).shl_wrap(3)).plus_wrap(page_x.shl_wrap(shift))
        fx = u_ext.shr_zf_wrap(shift).bitwise_and(1023)
        fy = vv.bitwise_and(twh.shl_wrap(3).bitwise_not()).plus_wrap(twy.bitwise_and(twh).shl_wrap(3)).plus_wrap(page_y)
        raw = Gpu.vram_get(vram, fx, fy)
        if tm == 0 {
            idx = raw.shr_zf_wrap(u_ext.bitwise_and(3).to_u8_wrap().times_wrap(4)).bitwise_and(0xF)
            clut_lookup(tc, idx.to_u64())
        } else if tm == 1 {
            idx = raw.shr_zf_wrap(u_ext.bitwise_and(1).to_u8_wrap().times_wrap(8)).bitwise_and(0xFF)
            clut_lookup(tc, idx.to_u64())
        } else {
            raw
        }
    }

    # palette entries come from the CLUT CACHE (loaded when the clut
    # word or texel format changed — the hardware quirk clut-cache
    # judges), never live VRAM
    clut_lookup : TexCtx, U64 -> U16
    clut_lookup = |tc, idx| tc.cache.get(idx) ?? 0

    # build the cache from VRAM (16 or 256 entries, x wraps at 1024)
    clut_load : List(U16), U32, U64 -> List(U16)
    clut_load = |vram, clut, count| {
        cx = clut.bitwise_and(0x3F).to_u64().times_wrap(16)
        cy = clut.shr_zf_wrap(6).bitwise_and(0x1FF).to_u64()
        var out = List.with_capacity(count)
        var i = 0.U64
        while i < count {
            out = out.append(Gpu.vram_get(vram, cx.plus(i).bitwise_and(0x3FF), cy))
            i = i.plus(1)
        }
        out
    }

    # modulated channel then dither-clamp (Mednafen ModTexel + DitherLUT)
    mod_chan : U16, U8, I64, I64 -> I64
    mod_chan = |texel5, shift, color8, dith| {
        t = texel5.shr_zf_wrap(shift).bitwise_and(0x1F).to_u32().to_i64()
        v = t.times_wrap(color8).shr_wrap(4).plus(dith)
        s = v.shr_wrap(3)
        if s < 0 { 0.I64 } else if s > 31 { 31 } else { s }
    }

    # textured pixel: modulation optional (raw when the cmd's bit 0 is
    # set), dither only where the caller says (polys yes when E1 bit 9,
    # sprites never), semi only when the texel's STP bit is set
    put_texel : List(U16), I64, I64, U16, { modulate : Bool, dith : I64, r : I64, g : I64, b : I64 }, Bool, State -> List(U16)
    put_texel = |vram, x, y, texel, mo, semi, st| {
        if x < st.clip_l or x > st.clip_r or y < st.clip_t or y > st.clip_b {
            vram
        } else {
            out =
                if mo.modulate {
                    r5 = mod_chan(texel, 0, mo.r, mo.dith)
                    g5 = mod_chan(texel, 5, mo.g, mo.dith)
                    b5 = mod_chan(texel, 10, mo.b, mo.dith)
                    r5.bitwise_or(g5.shl_wrap(5)).bitwise_or(b5.shl_wrap(10)).to_u16_wrap().bitwise_or(texel.bitwise_and(0x8000))
                } else {
                    texel
                }
            xu = x.to_u64_wrap()
            yu = y.to_u64_wrap()
            back = Gpu.vram_get(vram, xu, yu)
            if st.mask.bitwise_and(2) != 0 and back.bitwise_and(0x8000) != 0 {
                vram
            } else {
                blended = if semi and out.bitwise_and(0x8000) != 0 { blend(back, out, st.semi_mode) } else { out }
                final = if st.mask.bitwise_and(1) != 0 { blended.bitwise_or(0x8000) } else { blended }
                Gpu.vram_set(vram, xu, yu, final)
            }
        }
    }

    # textured sprite (0x64-0x7F with bit 2): flips from E1 bits 12/13,
    # clip adjusts the start texcoord, u re-seeds per row
    draw_sprite : List(U16), List(U32), U64, List(U16), State -> List(U16)
    draw_sprite = |vram0, pkt, e2, cache, st| {
        head = pkt.get(0) ?? 0
        cmd = head.shr_zf_wrap(24)
        semi = cmd.bitwise_and(2) != 0
        modulate = cmd.bitwise_and(1) == 0
        size_bits = cmd.shr_zf_wrap(3).bitwise_and(3)
        xy = pkt.get(1) ?? 0
        uvw = pkt.get(2) ?? 0
        wh =
            if size_bits == 0 {
                pkt.get(3) ?? 0
            } else if size_bits == 1 {
                0x0001_0001
            } else if size_bits == 2 {
                0x0008_0008
            } else {
                0x0010_0010
            }
        tc = { e1: st.e1_full, e2: e2, clut: uvw.shr_zf_wrap(16), cache: cache }
        x0 = sext11(xy.to_u32_wrap()).plus(st.off_x)
        y0 = sext11(xy.shr_zf_wrap(16).to_u32_wrap()).plus(st.off_y)
        w = wh.bitwise_and(0x3FF).to_i64()
        h = wh.shr_zf_wrap(16).bitwise_and(0x1FF).to_i64()
        flip_x = st.e1_full.bitwise_and(0x1000) != 0
        flip_y = st.e1_full.bitwise_and(0x2000) != 0
        u_inc = if flip_x { 0.I64.minus(1) } else { 1 }
        v_inc = if flip_y { 0.I64.minus(1) } else { 1 }
        u00 = uvw.bitwise_and(0xFF).to_i64()
        u0 = if flip_x { u00.to_u64_wrap().bitwise_or(1).to_u32_wrap().to_i64() } else { u00 }
        v0 = uvw.shr_zf_wrap(8).bitwise_and(0xFF).to_i64()
        xs = if x0 < st.clip_l { st.clip_l } else { x0 }
        ys = if y0 < st.clip_t { st.clip_t } else { y0 }
        xb = if x0.plus(w) > st.clip_r.plus(1) { st.clip_r.plus(1) } else { x0.plus(w) }
        yb = if y0.plus(h) > st.clip_b.plus(1) { st.clip_b.plus(1) } else { y0.plus(h) }
        u_start = u0.plus(xs.minus(x0).times_wrap(u_inc))
        r8 = head.bitwise_and(0xFF).to_i64()
        g8 = head.shr_zf_wrap(8).bitwise_and(0xFF).to_i64()
        b8 = head.shr_zf_wrap(16).bitwise_and(0xFF).to_i64()
        var vram = vram0
        var y = ys
        var v = v0.plus(ys.minus(y0).times_wrap(v_inc))
        while y < yb {
            var x = xs
            var u = u_start
            while x < xb {
                texel = tex_sample(vram, tc, u, v)
                if texel != 0 {
                    vram = put_texel(vram, x, y, texel, { modulate: modulate, dith: 0, r: r8, g: g8, b: b8 }, semi, st)
                } else {}
                u = u.plus(u_inc)
                x = x.plus(1)
            }
            v = v.plus(v_inc)
            y = y.plus(1)
        }
        vram
    }


    # textured triangle: the untextured walker plus u/v interpolant
    # planes (same anchors and wrap domain); texels gate semi by STP,
    # modulation dithers only when E1 bit 9
    TVtx : { x : I64, y : I64, r : I64, g : I64, b : I64, u : I64, v : I64 }

    draw_tri_tex : List(U16), TVtx, TVtx, TVtx, TexCtx, Bool, Bool, Bool, State -> List(U16)
    draw_tri_tex = |vram0, in0, in1, in2, tc, gouraud, semi, modulate, st| {
        cv0 =
            if in1.x <= in0.x {
                if in2.x <= in1.x { 4.U64 } else { 2 }
            } else if in2.x < in0.x {
                4
            } else {
                1
            }
        p1 = if in2.y < in1.y { { a: in0, b: in2, c: in1, cv: cv0.shr_zf_wrap(1).bitwise_and(2).bitwise_or(cv0.shl_wrap(1).bitwise_and(4)).bitwise_or(cv0.bitwise_and(1)) } } else { { a: in0, b: in1, c: in2, cv: cv0 } }
        p2 = if p1.b.y < p1.a.y { { a: p1.b, b: p1.a, c: p1.c, cv: p1.cv.shr_zf_wrap(1).bitwise_and(1).bitwise_or(p1.cv.shl_wrap(1).bitwise_and(2)).bitwise_or(p1.cv.bitwise_and(4)) } } else { p1 }
        p3 = if p2.c.y < p2.b.y { { a: p2.a, b: p2.c, c: p2.b, cv: p2.cv.shr_zf_wrap(1).bitwise_and(2).bitwise_or(p2.cv.shl_wrap(1).bitwise_and(4)).bitwise_or(p2.cv.bitwise_and(1)) } } else { p2 }
        v0 = p3.a
        v1 = p3.b
        v2 = p3.c
        core = p3.cv.shr_zf_wrap(1)
        cv = if core == 0 { v0 } else if core == 1 { v1 } else { v2 }
        too_big =
            v2.y.minus(v0.y) >= 512
            or (v0.x.minus(v1.x)).abs() >= 1024
            or (v1.x.minus(v2.x)).abs() >= 1024
            or (v0.x.minus(v2.x)).abs() >= 1024
        denom = (v1.x.minus(v0.x)).times_wrap(v2.y.minus(v1.y)).minus((v2.x.minus(v1.x)).times_wrap(v1.y.minus(v0.y)))
        if too_big or v0.y == v2.y or denom == 0 {
            vram0
        } else {
            cis = |fa, fb| (fa(v1).minus(fa(v0))).times_wrap(fb(v2).minus(fb(v1))).minus((fa(v2).minus(fa(v1))).times_wrap(fb(v1).minus(fb(v0))))
            dd = |num| delta32(num, denom)
            dr_dx = dd(cis(|t| t.r, |t| t.y))
            dr_dy = dd(cis(|t| t.x, |t| t.r))
            dg_dx = dd(cis(|t| t.g, |t| t.y))
            dg_dy = dd(cis(|t| t.x, |t| t.g))
            db_dx = dd(cis(|t| t.b, |t| t.y))
            db_dy = dd(cis(|t| t.x, |t| t.b))
            du_dx = dd(cis(|t| t.u, |t| t.y))
            du_dy = dd(cis(|t| t.x, |t| t.u))
            dv_dx = dd(cis(|t| t.v, |t| t.y))
            dv_dy = dd(cis(|t| t.x, |t| t.v))
            seed = |attr, ddx, ddy| attr.to_u32_wrap().shl_wrap(12).plus_wrap(0x800).shl_wrap(12).minus_wrap(ddx.times_wrap(cv.x.to_u32_wrap())).minus_wrap(ddy.times_wrap(cv.y.to_u32_wrap()))
            base_r = seed(cv.r, dr_dx, dr_dy)
            base_g = seed(cv.g, dg_dx, dg_dy)
            base_b = seed(cv.b, db_dx, db_dy)
            base_u = seed(cv.u, du_dx, du_dy)
            base_v = seed(cv.v, dv_dx, dv_dy)
            base_coord = xfp(v0.x)
            base_step = step_of(v2.x.minus(v0.x), v2.y.minus(v0.y))
            bound_us = if v1.y == v0.y { 0.I64 } else { step_of(v1.x.minus(v0.x), v1.y.minus(v0.y)) }
            right_facing = if v1.y == v0.y { v1.x > v0.x } else { bound_us > base_step }
            bound_ls = if v2.y == v1.y { 0.I64 } else { step_of(v2.x.minus(v1.x), v2.y.minus(v1.y)) }
            vo = if core != 0 { 1.I64 } else { 0 }
            vp = if core == 2 { 3.I64 } else { 0 }
            vsel = |i| if i == 0 { v0 } else if i == 1 { v1 } else { v2 }
            u0i = vo
            u1i = 1.I64.minus(vo)
            l0i = if vp == 0 { 1.I64 } else { 2 }
            var vram = vram0
            var pi = 0.U64
            while pi < 2 {
                first = if vo == 0 { pi == 0 } else { pi == 1 }
                tp = if first {
                    { y_coord: vsel(u0i).y, y_bound: vsel(u1i).y, rf_c: xfp(vsel(u0i).x), rf_s: bound_us, o_c: base_coord.plus(vsel(vo).y.minus(v0.y).times_wrap(base_step)), o_s: base_step, dec: vo != 0 }
                } else {
                    { y_coord: vsel(l0i).y, y_bound: vsel(if vp == 0 { 2.I64 } else { 1 }).y, rf_c: xfp(vsel(l0i).x), rf_s: bound_ls, o_c: base_coord.plus(vsel(l0i).y.minus(v0.y).times_wrap(base_step)), o_s: base_step, dec: vp != 0 }
                }
                var lc = if right_facing { tp.o_c } else { tp.rf_c }
                var ls = if right_facing { tp.o_s } else { tp.rf_s }
                var rc = if right_facing { tp.rf_c } else { tp.o_c }
                var rs = if right_facing { tp.rf_s } else { tp.o_s }
                if tp.dec {
                    var yi = tp.y_coord
                    while yi > tp.y_bound {
                        yi = yi.minus(1)
                        lc = lc.minus(ls)
                        rc = rc.minus(rs)
                        vram = tex_span(vram, yi, xfp_int(lc), xfp_int(rc), { br: base_r, bg: base_g, bb: base_b, bu: base_u, bv: base_v, dr: dr_dx, dg: dg_dx, db: db_dx, du: du_dx, dv: dv_dx, dry: dr_dy, dgy: dg_dy, dby: db_dy, duy: du_dy, dvy: dv_dy }, tc, gouraud, semi, modulate, st)
                    }
                } else {
                    var yi = tp.y_coord
                    while yi < tp.y_bound {
                        vram = tex_span(vram, yi, xfp_int(lc), xfp_int(rc), { br: base_r, bg: base_g, bb: base_b, bu: base_u, bv: base_v, dr: dr_dx, dg: dg_dx, db: db_dx, du: du_dx, dv: dv_dx, dry: dr_dy, dgy: dg_dy, dby: db_dy, duy: du_dy, dvy: dv_dy }, tc, gouraud, semi, modulate, st)
                        yi = yi.plus(1)
                        lc = lc.plus(ls)
                        rc = rc.plus(rs)
                    }
                }
                pi = pi.plus(1)
            }
            vram
        }
    }

    tex_span : List(U16), I64, I64, I64, { br : U32, bg : U32, bb : U32, bu : U32, bv : U32, dr : U32, dg : U32, db : U32, du : U32, dv : U32, dry : U32, dgy : U32, dby : U32, duy : U32, dvy : U32 }, TexCtx, Bool, Bool, Bool, State -> List(U16)
    tex_span = |vram0, y, x_start, x_bound, ip, tc, gouraud, semi, modulate, st| {
        if y < st.clip_t or y > st.clip_b {
            vram0
        } else {
            x0 = if x_start < st.clip_l { st.clip_l } else { x_start }
            xe = if x_bound > st.clip_r.plus(1) { st.clip_r.plus(1) } else { x_bound }
            if x0 >= xe {
                vram0
            } else {
                yu = y.to_u32_wrap()
                xu0 = x0.to_u32_wrap()
                var cr = ip.br.plus_wrap(ip.dr.times_wrap(xu0)).plus_wrap(ip.dry.times_wrap(yu))
                var cg = ip.bg.plus_wrap(ip.dg.times_wrap(xu0)).plus_wrap(ip.dgy.times_wrap(yu))
                var cb = ip.bb.plus_wrap(ip.db.times_wrap(xu0)).plus_wrap(ip.dby.times_wrap(yu))
                var cu = ip.bu.plus_wrap(ip.du.times_wrap(xu0)).plus_wrap(ip.duy.times_wrap(yu))
                var cvv = ip.bv.plus_wrap(ip.dv.times_wrap(xu0)).plus_wrap(ip.dvy.times_wrap(yu))
                var vram = vram0
                var x = x0
                while x < xe {
                    texel = tex_sample(vram, tc, cu.shr_zf_wrap(24).to_u32().to_i64(), cvv.shr_zf_wrap(24).to_u32().to_i64())
                    if texel != 0 {
                        dith = if modulate and st.dither { dither_at(x.to_u64_wrap(), y.to_u64_wrap()) } else { 0 }
                        rr = if gouraud { cr.shr_zf_wrap(24).to_u32().to_i64() } else { ip.br.shr_zf_wrap(24).to_u32().to_i64() }
                        gg = if gouraud { cg.shr_zf_wrap(24).to_u32().to_i64() } else { ip.bg.shr_zf_wrap(24).to_u32().to_i64() }
                        bb = if gouraud { cb.shr_zf_wrap(24).to_u32().to_i64() } else { ip.bb.shr_zf_wrap(24).to_u32().to_i64() }
                        vram = put_texel(vram, x, y, texel, { modulate: modulate, dith: dith, r: rr, g: gg, b: bb }, semi, st)
                    } else {}
                    cr = cr.plus_wrap(ip.dr)
                    cg = cg.plus_wrap(ip.dg)
                    cb = cb.plus_wrap(ip.db)
                    cu = cu.plus_wrap(ip.du)
                    cvv = cvv.plus_wrap(ip.dv)
                    x = x.plus(1)
                }
                vram
            }
        }
    }

    # decode + draw a textured polygon packet (poly texpage overrides
    # the page bits; its semi mode comes from the page word)
    draw_poly_tex : List(U16), List(U32), U64, List(U16), State -> List(U16)
    draw_poly_tex = |vram, pkt, e2, cache, st| {
        head = pkt.get(0) ?? 0
        cmd = head.shr_zf_wrap(24)
        gouraud = cmd.bitwise_and(0x10) != 0
        quad = cmd.bitwise_and(8) != 0
        semi = cmd.bitwise_and(2) != 0
        modulate = cmd.bitwise_and(1) == 0
        stride = if gouraud { 3.U64 } else { 2 }
        clut = (pkt.get(2) ?? 0).shr_zf_wrap(16)
        page = (pkt.get(if gouraud { 5.U64 } else { 4 }) ?? 0).shr_zf_wrap(16)
        e1m = st.e1_full.bitwise_and(0xFFFF_FE00).bitwise_or(page.bitwise_and(0x1FF).to_u64())
        tc = { e1: e1m, e2: e2, clut: clut, cache: cache }
        st2 = { ..st, semi_mode: page.shr_zf_wrap(5).bitwise_and(3).to_u32_wrap() }
        tvtx = |i| {
            base = i.times_wrap(stride)
            cw = if gouraud { if i == 0 { head } else { pkt.get(base) ?? 0 } } else { head }
            xy = pkt.get(base.plus(1)) ?? 0
            uv = pkt.get(base.plus(2)) ?? 0
            {
                x: sext11(xy.to_u32_wrap()).plus(st.off_x),
                y: sext11(xy.shr_zf_wrap(16).to_u32_wrap()).plus(st.off_y),
                r: cw.bitwise_and(0xFF).to_i64(),
                g: cw.shr_zf_wrap(8).bitwise_and(0xFF).to_i64(),
                b: cw.shr_zf_wrap(16).bitwise_and(0xFF).to_i64(),
                u: uv.bitwise_and(0xFF).to_i64(),
                v: uv.shr_zf_wrap(8).bitwise_and(0xFF).to_i64(),
            }
        }
        t0 = tvtx(0)
        t1 = tvtx(1)
        t2 = tvtx(2)
        d1 = draw_tri_tex(vram, t0, t1, t2, tc, gouraud, semi, modulate, st2)
        if quad {
            t3 = tvtx(3)
            draw_tri_tex(d1, t1, t2, t3, tc, gouraud, semi, modulate, st2)
        } else {
            d1
        }
    }

    # decode + draw a complete untextured polygon packet (flat/gouraud,
    # tri/quad); quads draw as v0v1v2 + v1v2v3
    draw_poly : List(U16), List(U32), State -> List(U16)
    draw_poly = |vram, pkt, st| {
        head = pkt.get(0) ?? 0
        cmd = head.shr_zf_wrap(24)
        gouraud = cmd.bitwise_and(0x10) != 0
        quad = cmd.bitwise_and(8) != 0
        semi = cmd.bitwise_and(2) != 0
        vtx = |i| {
            cw = if gouraud { pkt.get(i.times_wrap(2)) ?? 0 } else { head }
            xy = if gouraud { pkt.get(i.times_wrap(2).plus(1)) ?? 0 } else { pkt.get(i.plus(1)) ?? 0 }
            {
                x: sext11(xy.to_u32_wrap()).plus(st.off_x),
                y: sext11(xy.shr_zf_wrap(16).to_u32_wrap()).plus(st.off_y),
                r: cw.bitwise_and(0xFF).to_i64(),
                g: cw.shr_zf_wrap(8).bitwise_and(0xFF).to_i64(),
                b: cw.shr_zf_wrap(16).bitwise_and(0xFF).to_i64(),
            }
        }
        v0 = vtx(0)
        v1 = vtx(1)
        v2 = vtx(2)
        d1 = draw_tri(vram, v0, v1, v2, gouraud, semi, st)
        if quad {
            v3 = vtx(3)
            draw_tri(d1, v1, v2, v3, gouraud, semi, st)
        } else {
            d1
        }
    }
}

# a small flat triangle lands its interior and excludes right/bottom
# edges; drawing offset applies (tiny shapes only: expect-context sets
# always clone — the gates are the real judge)
expect {
    st = Raster.state_from(0, 0, 0x7FFFF, 0, 0)
    v = Gpu.vram_init({})
    pkt = [0x2000_00FF.U32, 0x0000_0000, 0x0000_0008, 0x0008_0004] # flat red tri (0,0) (8,0) (4,8)
    out = Raster.draw_poly(v, pkt, st)
    Gpu.vram_get(out, 1, 1) == 0x001F
    and Gpu.vram_get(out, 4, 4) == 0x001F
    and Gpu.vram_get(out, 8, 0) == 0 # right edge excluded
    and Gpu.vram_get(out, 4, 8) == 0 # bottom vertex excluded
    and Gpu.vram_get(out, 20, 20) == 0
}
