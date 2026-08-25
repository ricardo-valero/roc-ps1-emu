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
    State : { clip_l : I64, clip_t : I64, clip_r : I64, clip_b : I64, off_x : I64, off_y : I64, dither : Bool, semi_mode : U32, mask : U32 }

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
