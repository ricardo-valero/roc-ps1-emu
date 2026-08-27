import /Bus
import /Cpu
import /Dma
import /Gpu
import /Raster
import /Gte

# The console layer: owns emulated time. One run loop for every driver —
# CPU step, store-intent application, the VBlank frame clock, and the
# CAUSE.IP2 mirror sync all live HERE, not in the harnesses (the bench,
# Amidog, and ps1-tests runners are thin callers). Device events are
# scheduled, never polled per cycle.
#
# SHAPE NOTE: this loop moved from app context (poison-immune) into
# module context — the riskiest move of the dma-timers change. The
# var-threaded ram + direct-return store_ram + intent-application shape
# is preserved exactly; the real-bus bench gates that in-place stores
# survived (see the change's design D4 and the perf notes).
#
# The IP2 mirror rebuilds the Cpu record, so it is EDGE-TRIGGERED: a
# scalar compare per step, a rebuild only when the irq2 line moves.
Psx :: [].{
    # NTSC frame, scanline-derived: 263 lines x 3413 video clocks x 7/11
    # = 571,212 CPU cycles. CALIBRATED 2026-08-25 against the ps1-tests
    # timers psx.log frame-delay rows (hardware measures ~112,529 =
    # 46,993 + one recorded 0xFFFF wrap over an 8-wrap frame ->
    # ~571,288 implied; the scanline value sits within its jitter).
    # Revisit together with Bus.ntsc_cycles_per_line_*.
    ntsc_frame_cycles : U64
    ntsc_frame_cycles = 571_212

    # run the console for `budget` instructions; vram rides beside the
    # RAM pages (driver-owned, GPU commands land on it from group 2 on)
    run : Cpu, Bus, List(List(U8)), List(U16), List(U32), U64 -> { cpu : Cpu, bus : Bus, ram : List(List(U8)), vram : List(U16), steps : U64 }
    run = |cpu0, bus0, ram0, vram0, gte0, budget| {
        var cpu = cpu0
        var bus = bus0
        var ram = ram0
        # gte0 comes IN but does NOT go back out: adding `gte` to the
        # returned record SEGFAULTS the nightly compiler (isolated
        # 2026-08-26 — a fifth poison shape beside the four the membus
        # change recorded; the same record without it compiles). Nothing
        # needs it back: the register file lives for the length of a run
        # and every driver calls `run` once per program.
        var gte = gte0
        var vram = vram0
        var k = 0.U64
        var next_vblank = ntsc_frame_cycles
        var next_tirq = Bus.next_timer_event(bus0, 0)
        var irq_lvl = Bool.False
        # GP0 packet assembly + transfer stream state (D3): scalars and a
        # small word list; vram writes stay direct-list-return Gpu calls
        var gp0_in = [] # words queued for the GP0 machine this step (CPU store or DMA)
        var gp0_buf = List.with_capacity(16)
        var gp0_need = 0.U64
        var gp0_poly = Bool.False # assembling a polyline until its terminator
        var clut_cache = [] # palette cache: reloads only when tag changes (hardware)
        var clut_tag = 0x7FFF.U64 # no clut held, zero entries
        var st_up = Bool.False # A0h CPU->VRAM stream active
        var st_t = { x: 0.U64, y: 0.U64, w: 0.U64 }
        var st_li = 0.U64
        var st_total = 0.U64
        var rd_on = Bool.False # C0h VRAM->CPU stream active
        var rd_t = { x: 0.U64, y: 0.U64, w: 0.U64 }
        var rd_li = 0.U64
        var rd_total = 0.U64
        # TWO-LOOP SHAPE (perf): the inner hot loop is the exact
        # dma-timers-proven body and never references vram or the GP0
        # vars — loop-carried list vars inside a branchy loop body cost
        # ~35% in refcount churn (measured). GPU-touching events stash
        # scalars and exit to the outer handler; the outer loop pays the
        # churn only per GPU event.
        var ev = 0.U64 # 1 gp0 word, 2 gp1 word, 3 gpuread ack, 4 ch2 kick
        var ev_w = 0.U32
        var ev_madr = 0.U32
        var ev_bcr = 0.U32
        var ev_chcr = 0.U32
        var going = Bool.True
        while going {
            var hot = Bool.True
            while hot {
                r = Cpu.step(cpu, bus, ram, gte)
                cpu = r.cpu
                bus = r.bus
                # COP2 intents land here, exactly like store intents: the
                # step never carries the register file in its payload
                if r.gte_kind == 1 {
                    gte = Gte.write(gte, r.gte_idx.to_u64(), r.gte_val)
                } else if r.gte_kind == 2 {
                    gte = Gte.command(gte, r.gte_val)
                } else {}
                if r.st1_size != 0 {
                    ram = Cpu.store_ram(ram, r.st1_size, r.st1_addr, r.st1_val)
                    ram = Cpu.store_ram(ram, r.st2_size, r.st2_addr, r.st2_val)
                    # a write into the timer registers moves the schedule
                    wphys = r.st1_addr.bitwise_and(0x1FFF_FFFF)
                    if wphys >= 0x1F80_1100 and wphys < 0x1F80_1130 {
                        next_tirq = Bus.next_timer_event(bus, cpu.cycles)
                    } else {}
                    if wphys == 0x1F80_1810 {
                        ev = 1
                        ev_w = r.st1_val
                        hot = Bool.False
                    } else {}
                    if wphys == 0x1F80_1814 {
                        ev = 2
                        ev_w = r.st1_val
                        hot = Bool.False
                    } else {}
                    # a CHCR/DPCR write can start a transfer: OTC (channel 6)
                    # runs here; channel 2 exits to the GPU handler; the
                    # rest are LOUD until their device changes land
                    if wphys >= 0x1F80_1080 and wphys < 0x1F80_10F8 {
                        kick = Bus.dma_kick_info(bus, wphys)
                        if kick.go {
                            if kick.ch == 6 {
                                ram = Dma.otc_run(ram, kick.madr, kick.bcr)
                                bus = Bus.dma_complete(bus, 6, Dma.otc_end_madr(kick.madr, kick.bcr))
                                cpu = { ..cpu, cycles: cpu.cycles.plus(Dma.otc_words(kick.bcr)) }
                            } else if kick.ch == 2 {
                                ev = 4
                                ev_madr = kick.madr
                                ev_bcr = kick.bcr
                                ev_chcr = kick.chcr
                                hot = Bool.False
                            } else {
                                bus = Bus.dma_unhandled(bus, kick.ch)
                            }
                        } else {}
                    } else {}
                } else {}
                if r.ack_addr != 0 {
                    aphys = r.ack_addr.bitwise_and(0x1FFF_FFFF)
                    if aphys == 0x1F80_1810 {
                        ev = 3
                        hot = Bool.False
                    } else {
                        bus = bus.timer_ack(r.ack_addr, cpu.cycles)
                    }
                } else {}
                if cpu.cycles >= next_tirq {
                    bus = bus.timer_harvest(cpu.cycles)
                    next_tirq = Bus.next_timer_event(bus, cpu.cycles)
                } else {}
                if cpu.cycles >= next_vblank {
                    bus = bus.raise_irq(0)
                    next_vblank = next_vblank.plus(ntsc_frame_cycles)
                } else {}
                lvl = bus.irq2()
                if lvl != irq_lvl {
                    cpu = Cpu.set_irq2(cpu, lvl)
                    irq_lvl = lvl
                } else {}
                k = k.plus(1)
                if k >= budget {
                    hot = Bool.False
                    going = Bool.False
                } else {}
            }
            # ---- outer: GPU event handling (vram + GP0 state live here)
            if ev == 4 {
                sync = ev_chcr.shr_zf_wrap(9).bitwise_and(3)
                to_gpu = ev_chcr.bitwise_and(1) == 1
                if sync == 2 {
                    # linked list: walk OT nodes into the GP0 queue. A
                    # chain that never reaches the sentinel NEVER
                    # COMPLETES on hardware (busy stays set, no IRQ)
                    var node = ev_madr.bitwise_and(0x00FF_FFFF)
                    var hops = 0.U64
                    while node.bitwise_and(0x80_0000) == 0 and hops < 0x1_0000 {
                        hdr = Dma.load_word(ram, node)
                        var wi = 0.U32
                        while wi < hdr.shr_zf_wrap(24) {
                            gp0_in = gp0_in.append(Dma.load_word(ram, node.plus_wrap(4).plus_wrap(wi.times_wrap(4))))
                            wi = wi.plus(1)
                        }
                        node = hdr.bitwise_and(0x00FF_FFFF)
                        hops = hops.plus(1)
                    }
                    cpu = { ..cpu, cycles: cpu.cycles.plus(hops) }
                    if node.bitwise_and(0x80_0000) != 0 {
                        bus = Bus.dma_complete(bus, 2, 0x00FF_FFFF)
                    } else {}
                } else {
                    bs = ev_bcr.bitwise_and(0xFFFF).to_u64()
                    count = if sync == 1 {
                        bs.times_wrap(ev_bcr.shr_zf_wrap(16).to_u64())
                    } else if bs == 0 {
                        0x10000
                    } else {
                        bs
                    }
                    var addr = ev_madr
                    var wi = 0.U64
                    if to_gpu {
                        while wi < count {
                            gp0_in = gp0_in.append(Dma.load_word(ram, addr))
                            addr = addr.plus_wrap(4)
                            wi = wi.plus(1)
                        }
                    } else {
                        # GPU -> RAM: drain the C0h stream
                        while wi < count {
                            rw = Gpu.read_word(vram, rd_t, rd_li, rd_total)
                            ram = Cpu.store_ram(ram, 4, addr, rw)
                            rd_li = rd_li.plus(2)
                            addr = addr.plus_wrap(4)
                            wi = wi.plus(1)
                        }
                        if rd_li >= rd_total {
                            rd_on = Bool.False
                            bus = Bus.gpu_slot_set(bus, 50, 0)
                        } else {
                            bus = Bus.gpu_slot_set(bus, 49, Gpu.read_word(vram, rd_t, rd_li, rd_total).to_u64())
                        }
                    }
                    cpu = { ..cpu, cycles: cpu.cycles.plus(count) }
                    bus = Bus.dma_complete(bus, 2, addr.bitwise_and(0x00FF_FFFF))
                }
            } else if ev == 1 {
                gp0_in = gp0_in.append(ev_w)
            } else if ev == 2 {
                w = ev_w
                g1 = w.shr_zf_wrap(24).bitwise_and(0x3F)
                if g1 == 0x00 {
                    bus = Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(bus, 44, 0), 45, 0), 46, 1), 47, 0), 48, 0), 51, 0), 52, 0), 53, 0), 54, 0), 55, 0), 56, 0), 57, 0)
                    bus = Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(Bus.gpu_slot_set(bus, 58, 0), 50, 0), 49, 0), 59, 0)
                    gp0_buf = List.with_capacity(16)
                    gp0_need = 0
                    gp0_poly = Bool.False
                    st_up = Bool.False
                    rd_on = Bool.False
                } else if g1 == 0x01 {
                    gp0_buf = List.with_capacity(16)
                    gp0_need = 0
                    gp0_poly = Bool.False
                    st_up = Bool.False
                } else if g1 == 0x02 {
                    bus = Bus.gpu_slot_set(bus, 58, 0)
                } else if g1 == 0x03 {
                    bus = Bus.gpu_slot_set(bus, 46, w.bitwise_and(1).to_u64())
                } else if g1 == 0x04 {
                    bus = Bus.gpu_slot_set(bus, 47, w.bitwise_and(3).to_u64())
                } else if g1 == 0x05 {
                    bus = Bus.gpu_slot_set(bus, 55, w.bitwise_and(0x7_FFFF).to_u64())
                } else if g1 == 0x06 {
                    bus = Bus.gpu_slot_set(bus, 56, w.bitwise_and(0xFF_FFFF).to_u64())
                } else if g1 == 0x07 {
                    bus = Bus.gpu_slot_set(bus, 57, w.bitwise_and(0xF_FFFF).to_u64())
                } else if g1 == 0x08 {
                    bus = Bus.gpu_slot_set(bus, 48, w.bitwise_and(0xFF).to_u64())
                } else if g1 == 0x09 {
                    bus = Bus.gpu_slot_set(bus, 59, w.bitwise_and(1).to_u64())
                } else if g1 >= 0x10 {
                    idx = w.bitwise_and(0xF)
                    v = if idx == 7 { 2.U64 } else { Bus.gpu_slot(bus, Gpu.info_slot(idx)) }
                    bus = Bus.gpu_slot_set(bus, 49, v)
                } else {}
            } else if ev == 3 {
                if rd_on {
                    rd_li = rd_li.plus(2)
                    if rd_li >= rd_total {
                        rd_on = Bool.False
                        bus = Bus.gpu_slot_set(bus, 50, 0)
                    } else {
                        bus = Bus.gpu_slot_set(bus, 49, Gpu.read_word(vram, rd_t, rd_li, rd_total).to_u64())
                    }
                } else {}
            } else {}
            ev = 0
            # the GP0 machine: drains queued words (a CPU store queues
            # one; a ch2 DMA queues many) through one state machine
            var gqi = 0.U64
            while gqi < gp0_in.len() {
                w = gp0_in.get(gqi) ?? 0
                gqi = gqi.plus(1)
                if st_up {
                    vram = Gpu.stream_write(vram, st_t, st_li, st_total, w, Bus.gpu_slot(bus, 45).to_u32_wrap())
                    st_li = st_li.plus(2)
                    if st_li >= st_total {
                        st_up = Bool.False
                    } else {}
                } else if gp0_poly {
                    # polyline: terminator checked at vertex-boundary
                    # words ((w & 0xF000F000) == 0x50005000)
                    pcmd = (gp0_buf.get(0) ?? 0).shr_zf_wrap(24)
                    pg = pcmd.bitwise_and(0x10) != 0
                    at_boundary = if pg { gp0_buf.len().bitwise_and(1) == 0 } else { Bool.True }
                    if at_boundary and w.bitwise_and(0xF000_F000) == 0x5000_5000 {
                        rstl = Raster.state_from(Bus.gpu_slot(bus, 44), Bus.gpu_slot(bus, 52), Bus.gpu_slot(bus, 53), Bus.gpu_slot(bus, 54), Bus.gpu_slot(bus, 45))
                        vram = Raster.draw_lines(vram, gp0_buf, rstl)
                        gp0_buf = List.with_capacity(16)
                        gp0_poly = Bool.False
                    } else {
                        gp0_buf = gp0_buf.append(w)
                    }
                } else if gp0_need > 0 {
                    gp0_buf = gp0_buf.append(w)
                    gp0_need = gp0_need.minus(1)
                    if gp0_need == 0 {
                        cmd = (gp0_buf.get(0) ?? 0).shr_zf_wrap(24)
                        if cmd >= 0x20 and cmd < 0x40 and cmd.bitwise_and(4) == 0 {
                            rst = Raster.state_from(Bus.gpu_slot(bus, 44), Bus.gpu_slot(bus, 52), Bus.gpu_slot(bus, 53), Bus.gpu_slot(bus, 54), Bus.gpu_slot(bus, 45))
                            vram = Raster.draw_poly(vram, gp0_buf, rst)
                        } else if cmd >= 0x40 and cmd < 0x60 {
                            rstl = Raster.state_from(Bus.gpu_slot(bus, 44), Bus.gpu_slot(bus, 52), Bus.gpu_slot(bus, 53), Bus.gpu_slot(bus, 54), Bus.gpu_slot(bus, 45))
                            vram = Raster.draw_lines(vram, gp0_buf, rstl)
                        } else if cmd >= 0x60 and cmd < 0x80 and cmd.bitwise_and(4) == 0 {
                            rst = Raster.state_from(Bus.gpu_slot(bus, 44), Bus.gpu_slot(bus, 52), Bus.gpu_slot(bus, 53), Bus.gpu_slot(bus, 54), Bus.gpu_slot(bus, 45))
                            vram = Raster.draw_rect(vram, gp0_buf, rst)
                        } else if cmd == 0x02 or cmd == 0x80 {
                            vram = Gpu.exec_vram(vram, gp0_buf, Bus.gpu_slot(bus, 45).to_u32_wrap())
                        } else if cmd == 0xA0 {
                            d = Gpu.xfer_decode(gp0_buf.get(1) ?? 0, gp0_buf.get(2) ?? 0)
                            st_t = { x: d.x, y: d.y, w: d.w }
                            st_li = 0
                            st_total = d.w.times_wrap(d.h)
                            st_up = st_total > 0
                        } else if cmd == 0xC0 {
                            d = Gpu.xfer_decode(gp0_buf.get(1) ?? 0, gp0_buf.get(2) ?? 0)
                            rd_t = { x: d.x, y: d.y, w: d.w }
                            rd_li = 0
                            rd_total = d.w.times_wrap(d.h)
                            rd_on = rd_total > 0
                            bus = Bus.gpu_slot_set(Bus.gpu_slot_set(bus, 50, if rd_on { 1 } else { 0 }), 49, Gpu.read_word(vram, rd_t, 0, rd_total).to_u64())
                        } else if cmd >= 0x20 and cmd < 0x40 and cmd.bitwise_and(4) != 0 {
                            # textured polygon: draw, then latch its
                            # texpage word into E1 (hardware does)
                            rstt = Raster.state_from(Bus.gpu_slot(bus, 44), Bus.gpu_slot(bus, 52), Bus.gpu_slot(bus, 53), Bus.gpu_slot(bus, 54), Bus.gpu_slot(bus, 45))
                            pcl = (gp0_buf.get(2) ?? 0).shr_zf_wrap(16)
                            ppg = (gp0_buf.get(if cmd.bitwise_and(0x10) != 0 { 5.U64 } else { 4 }) ?? 0).shr_zf_wrap(16)
                            ptm0 = ppg.shr_zf_wrap(7).bitwise_and(3)
                            ptm = if ptm0 > 2 { 2.U64.to_u32_wrap() } else { ptm0 }
                            if ptm < 2 {
                                # reload only when the clut word moved or MORE
                                # entries are needed: 8bit->4bit reuses the
                                # cached 256 (stale on purpose — hardware)
                                pneed = if ptm == 0 { 16.U64 } else { 256 }
                                pheld = clut_tag.shr_zf_wrap(16)
                                if pcl.bitwise_and(0x7FFF).to_u64() != clut_tag.bitwise_and(0x7FFF) or pneed > pheld {
                                    clut_cache = Raster.clut_load(vram, pcl, pneed)
                                    clut_tag = pcl.bitwise_and(0x7FFF).to_u64().bitwise_or(pneed.shl_wrap(16))
                                } else {}
                            } else {}
                            vram = Raster.draw_poly_tex(vram, gp0_buf, Bus.gpu_slot(bus, 51), clut_cache, rstt)
                            idx = if cmd.bitwise_and(0x10) != 0 { 5.U64 } else { 4 }
                            page = (gp0_buf.get(idx) ?? 0).shr_zf_wrap(16)
                            pm = 0x1FF.U64.bitwise_or(if Bus.gpu_slot(bus, 59) != 0 { 0x800.U64 } else { 0 })
                            e1old = Bus.gpu_slot(bus, 44)
                            bus = Bus.gpu_slot_set(bus, 44, e1old.bitwise_and(pm.bitwise_not()).bitwise_or(page.to_u64().bitwise_and(pm)))
                        } else if cmd >= 0x60 and cmd < 0x80 and cmd.bitwise_and(4) != 0 {
                            rstt = Raster.state_from(Bus.gpu_slot(bus, 44), Bus.gpu_slot(bus, 52), Bus.gpu_slot(bus, 53), Bus.gpu_slot(bus, 54), Bus.gpu_slot(bus, 45))
                            scl = (gp0_buf.get(2) ?? 0).shr_zf_wrap(16)
                            stm0 = Bus.gpu_slot(bus, 44).shr_zf_wrap(7).bitwise_and(3).to_u32_wrap()
                            stm = if stm0 > 2 { 2.U32 } else { stm0 }
                            if stm < 2 {
                                sneed = if stm == 0 { 16.U64 } else { 256 }
                                sheld = clut_tag.shr_zf_wrap(16)
                                if scl.bitwise_and(0x7FFF).to_u64() != clut_tag.bitwise_and(0x7FFF) or sneed > sheld {
                                    clut_cache = Raster.clut_load(vram, scl, sneed)
                                    clut_tag = scl.bitwise_and(0x7FFF).to_u64().bitwise_or(sneed.shl_wrap(16))
                                } else {}
                            } else {}
                            vram = Raster.draw_sprite(vram, gp0_buf, Bus.gpu_slot(bus, 51), clut_cache, rstt)
                        } else {
                            bus = Bus.gpu_unknown(bus, cmd)
                        }
                        gp0_buf = List.with_capacity(16)
                    } else {}
                } else {
                    cmd = w.shr_zf_wrap(24)
                    need = Gpu.cmd_len(cmd)
                    if cmd >= 0x40 and cmd < 0x60 and cmd.bitwise_and(8) != 0 {
                        # polyline start: open-ended until the terminator
                        gp0_buf = List.with_capacity(16).append(w)
                        gp0_poly = Bool.True
                    } else if need > 1 {
                        gp0_buf = List.with_capacity(16).append(w)
                        gp0_need = need.minus(1)
                    } else if cmd == 0xE1 {
                        # bit 11 (texture disable) latches only when GP1
                        # 09h allows; an E1 write with allow off forces
                        # it low (the GP1 toggle alone preserves it)
                        new11 = if Bus.gpu_slot(bus, 59) != 0 { w.bitwise_and(0x800).to_u64() } else { 0 }
                        bus = Bus.gpu_slot_set(bus, 44, w.bitwise_and(0x00FF_F7FF).to_u64().bitwise_or(new11))
                    } else if cmd >= 0xE2 and cmd <= 0xE6 {
                        slot = 44.U64.plus(if cmd == 0xE6 { 1 } else { cmd.to_u64().minus(0xE2).plus(7) })
                        bus = Bus.gpu_slot_set(bus, slot, w.bitwise_and(0x00FF_FFFF).to_u64())
                    } else if cmd == 0x1F {
                        bus = Bus.gpu_slot_set(bus, 58, 1)
                    } else if cmd == 0x01 {
                        clut_tag = 0x7FFF # Clear Cache invalidates the CLUT cache
                    } else if cmd == 0x00 or cmd == 0x03 {
                        {}
                    } else {
                        bus = Bus.gpu_unknown(bus, cmd)
                    }
                }
            }
            if gp0_in.is_empty() == Bool.False {
                gp0_in = []
            } else {}
        }
        { cpu: cpu, bus: bus, ram: ram, vram: vram, steps: k }
    }
}

# the loop applies stores, raises VBlank on schedule, and mirrors irq2
expect {
    # SW r2 -> 0(r1); loop forever (J 0)
    prog = [0xAC22_0000.U32, 0x0800_0000, 0x0000_0000]
        .fold([], |acc, w| acc.append(w.to_u8_wrap()).append(w.shr_zf_wrap(8).to_u8_wrap()).append(w.shr_zf_wrap(16).to_u8_wrap()).append(w.shr_zf_wrap(24).to_u8_wrap()))
    page = List.concat(prog, List.repeat(0, 0x1000.U64.minus(prog.len())))
    bus0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    cpu0 = Cpu.set_r(Cpu.set_r(Cpu.init(0x8000_0000), 1, 0x100), 2, 0xCAFE_F00D)
    out = Psx.run(cpu0, bus0, [page], [], Gte.init({}), 4)
    word = out.bus.read_val(out.ram, 4, 0x100, 0, 0)
    out.steps == 4 and word.val == 0xCAFE_F00D
}

# a timer IRQ scheduled by the console reaches the CPU exception path:
# unmasked timer2 target hit vectors to 0x80000080 with excode 0
expect {
    prog = [0x0800_0000.U32, 0x0000_0000]
        .fold([], |acc, w| acc.append(w.to_u8_wrap()).append(w.shr_zf_wrap(8).to_u8_wrap()).append(w.shr_zf_wrap(16).to_u8_wrap()).append(w.shr_zf_wrap(24).to_u8_wrap()))
    page = List.concat(prog, List.repeat(0, 0x1000.U64.minus(prog.len())))
    bus = Bus.ps1(List.repeat(0, 512), Bool.False)
        .write(4, 0x1F80_1074, 0x40, 0) # unmask timer2 in I_MASK
        .write(2, 0x1F80_1128, 50, 0) # target 50
        .write(2, 0x1F80_1124, 0x0018, 0) # reset-at-target, IRQ-at-target, one-shot
    cpu = { ..Cpu.init(0x8000_0000), sr: 0x0000_0401 } # IEc + IM2
    out = Psx.run(cpu, bus, [page], [], Gte.init({}), 120)
    stat = out.bus.read_val(out.ram, 4, 0x1F80_1070, 0, out.cpu.cycles)
    stat.val.bitwise_and(0x40) != 0
    and out.cpu.cause.bitwise_and(0x7C) == 0 # excode 0 = interrupt
    and out.cpu.epc.bitwise_and(0xFFFF_FFF0) == 0x8000_0000 # taken inside the loop
    and out.cpu.pc > 0x8000_0080 # ran on from the vector's NOP sled
}

# an OTC start through the console clears the table, lands the register
# file, and a disabled DPCR blocks it; device channels are loud
expect {
    # SW r2 -> MADR; SW r3 -> BCR; SW r4 -> CHCR; loop
    prog = [0xAC22_10E0.U32, 0xAC23_10E4, 0xAC24_10E8, 0x0800_0000, 0x0000_0000]
        .fold([], |acc, w| acc.append(w.to_u8_wrap()).append(w.shr_zf_wrap(8).to_u8_wrap()).append(w.shr_zf_wrap(16).to_u8_wrap()).append(w.shr_zf_wrap(24).to_u8_wrap()))
    page = List.concat(prog, List.repeat(0, 0x1000.U64.minus(prog.len())))
    bus0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    bus_on = bus0.write(4, 0x1F80_10F0, 0x0F65_4329, 0) # enable ch6 + ch0 (reset DPCR enables nothing)
    cpu0 = Cpu.set_r(Cpu.set_r(Cpu.set_r(Cpu.set_r(Cpu.init(0x8000_0000), 1, 0x1F80_0000), 2, 0x200), 3, 4), 4, 0x1100_0000)
    out = Psx.run(cpu0, bus_on, [page], [], Gte.init({}), 8)
    term = out.bus.read_val(out.ram, 4, 0x1F4, 0, 0)
    e1 = out.bus.read_val(out.ram, 4, 0x200, 0, 0)
    chcr = out.bus.read_val([], 4, 0x1F80_10E8, 0, 0)
    madr = out.bus.read_val([], 4, 0x1F80_10E0, 0, 0)
    # DPCR at reset leaves every channel disabled: same program, no transfer
    out2 = Psx.run(cpu0, bus0, [page], [], Gte.init({}), 8)
    e2 = out2.bus.read_val(out2.ram, 4, 0x200, 0, 0)
    # device channel (2) started: loud
    cpu_dev = Cpu.set_r(cpu0, 1, 0x1F80_0000.minus_wrap(0x60)) # r1 + 0x10E0 -> 0x1F801080+... shift base so stores hit D2
    out3 = Psx.run(Cpu.set_r(cpu_dev, 4, 0x1100_0000), bus_on, [page], [], Gte.init({}), 5) # one loop pass = one start = one loud entry
    term.val == 0x00FF_FFFF
    and e1.val == 0x1FC
    and chcr.val.bitwise_and(0x0100_0000) == 0
    and madr.val == 0x1F4
    and e2.val == 0
    and out3.bus.tty_unknown_calls() == [{ table: 0xDA, fn: 0 }]
}

# OTC completion flags DICR and, with master + I_MASK + SR enables, the
# DMA interrupt (I_STAT bit 3) reaches the CPU exception path
expect {
    prog = [0xAC22_10E0.U32, 0xAC23_10E4, 0xAC24_10E8, 0x0800_0000, 0x0000_0000]
        .fold([], |acc, w| acc.append(w.to_u8_wrap()).append(w.shr_zf_wrap(8).to_u8_wrap()).append(w.shr_zf_wrap(16).to_u8_wrap()).append(w.shr_zf_wrap(24).to_u8_wrap()))
    page = List.concat(prog, List.repeat(0, 0x1000.U64.minus(prog.len())))
    bus = Bus.ps1(List.repeat(0, 512), Bool.False)
        .write(4, 0x1F80_10F0, 0x0F65_4321, 0) # enable ch6
        .write(4, 0x1F80_10F4, 0x00C0_0000, 0) # DICR: ch6 IRQ enable + master
        .write(4, 0x1F80_1074, 0x0008, 0) # unmask DMA in I_MASK
    cpu = { ..Cpu.set_r(Cpu.set_r(Cpu.set_r(Cpu.set_r(Cpu.init(0x8000_0000), 1, 0x1F80_0000), 2, 0x200), 3, 4), 4, 0x1100_0000), sr: 0x0000_0401 }
    out = Psx.run(cpu, bus, [page], [], Gte.init({}), 6)
    dicr = out.bus.read_val([], 4, 0x1F80_10F4, 0, 0)
    stat = out.bus.read_val([], 4, 0x1F80_1070, 0, 0)
    dicr.val.bitwise_and(0x4000_0000) != 0 # ch6 flag
    and dicr.val.bitwise_and(0x8000_0000) != 0 # computed master flag
    and stat.val.bitwise_and(8) != 0
    and out.cpu.cause.bitwise_and(0x7C) == 0 # took the interrupt, excode 0
    and out.cpu.pc >= 0x8000_0080 # vectored
}

# C0h VRAM->CPU readback through actual CPU loads: the staged GPUREAD
# word + consumed-intent refill serve consecutive words; GPUSTAT's
# ready-to-send bit drops when the stream is drained
expect {
    prog = [
        0x3C01_1F80.U32, 0x3421_1810, # r1 = 0x1F801810
        0x3C05_C000, 0xAC25_0000, # GP0 C0h
        0x3C05_0002, 0x34A5_0064, 0xAC25_0000, # yx: y=2 x=100
        0x3C05_0001, 0x34A5_0004, 0xAC25_0000, # wh: h=1 w=4
        0x8C22_0000, 0x0000_0000, # lw r2 <- GPUREAD
        0x8C23_0000, 0x0000_0000, # lw r3 <- GPUREAD
        0x0800_0000, 0x0000_0000,
    ].fold([], |acc, w| acc.append(w.to_u8_wrap()).append(w.shr_zf_wrap(8).to_u8_wrap()).append(w.shr_zf_wrap(16).to_u8_wrap()).append(w.shr_zf_wrap(24).to_u8_wrap()))
    page = List.concat(prog, List.repeat(0, 0x1000.U64.minus(prog.len())))
    v0 = Gpu.vram_init({})
    v1 = Gpu.vram_set(Gpu.vram_set(Gpu.vram_set(Gpu.vram_set(v0, 100, 2, 0x1111), 101, 2, 0x2222), 102, 2, 0x3333), 103, 2, 0x4444)
    bus = Bus.ps1(List.repeat(0, 512), Bool.False)
    out = Psx.run(Cpu.init(0x8000_0000), bus, [page], v1, Gte.init({}), 18)
    stat = out.bus.read_val([], 4, 0x1F80_1814, 0, out.cpu.cycles)
    Cpu.get(out.cpu, 2) == 0x2222_1111
    and Cpu.get(out.cpu, 3) == 0x4444_3333
    and stat.val.bitwise_and(0x0800_0000) == 0 # drained: not ready-to-send
    and stat.val.bitwise_and(0x0400_0000) != 0 # ready for commands again
}
