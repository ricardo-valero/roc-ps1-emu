import /Gpu

# The CPU's memory surface. Three variants:
#
#   Ps1 — the real console map: 2 MB RAM mirrored through
#   KUSEG/KSEG0/KSEG1, 1 KB scratchpad (not reachable via KSEG1), 512 KB
#   read-only BIOS window, I_STAT/I_MASK, and stubs. Accesses charge wait-state cycles via the `cost` return
#   field (initial table from psx-spx, calibrated by ps1-tests
#   access-time; see wait constants below). A kernel-vector TTY trap
#   captures test-EXE output without a BIOS (see Cpu.step).
#
#   Vector — replay bus for the SingleStepTests harness: the fetch at the
#   test's base address returns the opcode, data reads pop the vector's
#   documented values in order, and every access is recorded in an ordered
#   trace of (kind, size, addr, val) for the runner to diff. Kind: 0 =
#   instruction fetch, 1 = data read, 2 = write (upstream's actions 4/1/2).
#
#   Flat — the core-only bench surface: reads serve the same external
#   paged RAM as Ps1 (wrapping at 2 MB) but charge zero wait cost, and
#   writes are no-ops here — stores land via Cpu.store_ram like Ps1.
# PERF-CRITICAL SHAPE (this nightly): in-place List.set on data flowing
# through branchy record-returning functions is DEFEATED — every store
# then clones the list (2 MB RAM = ~300x collapse; minimal repros in the
# perf notes / repro repo). Established by single-variable flips: a Box
# anywhere in the payload, a List of records in the payload, a { bus, .. }
# record return from the updating function, a wrapper branch around it,
# and even ONE scalar `if` in a record-returning arm that reads a payload
# list all trigger it. Consequences here: the 2 MB RAM lives OUTSIDE the
# Bus and is var-threaded by Cpu.step (RAM stores happen there, on the
# only shape proven immune); the Bus carries scratchpad + rest with no
# Boxes and no record lists; read arms are branch-free mask arithmetic.

Ps1Rest : {
    bios : List(U8), # 512 KB, read-only (never written; carried plain)
    i_stat : U32,
    i_mask : U32,
    ram_size : U32, # 0x1F801060
    cache_ctrl : U32, # 0xFFFE0130 (KSEG2)
    # Cold device state lives in a SLOT TABLE (List(U64)) so the union
    # payload stays small — an unboxed 300-byte payload made every step's
    # bus copy a memmove (measured 25%; ngba boxes for this, Box is
    # poisoned on our nightly, a list pointer is the safe equivalent).
    # Slots: timers 0-14 (mode,target,anchor_clock,anchor_base,reached
    # x3), DMA 15-35 (madr,bcr,chcr x7), 36 dpcr, 37 dicr, 38 joy_ctrl,
    # 39 joy_seq, 40 joy_xact, 41 joy_rx, 42 spucnt, 43 hook_buf,
    # 44-59 GPU state (see Gpu.roc's slot map; 59 = GP1 09h
    # texture-disable-allow).
    dev : List(U64),
    exc_ctx : List(U32), # register file saved at HLE interrupt dispatch ([r1..r31, hi, lo, epc]) for B0:0x17
    tty_trap : Bool,
    tty : List(U8),
    tty_unknown : List(U64), # fail-loud record of unhandled kernel calls, packed table<<32|fn
}

Bus := [
    Vector({ opcode : U32, base : U32, reads : List(U32), trace : List({ kind : U8, size : U8, addr : U32, val : U32 }) }),
    Flat,
    Ps1(List(U8), Ps1Rest), # scratchpad, everything else — RAM is NOT in the bus (see note)
].{
    vector : U32, U32, List(U32) -> Bus
    vector = |opcode, base, reads| Vector({ opcode: opcode, base: base, reads: reads, trace: [] })

    flat : {} -> Bus
    flat = |_| Flat

    ps1 : List(U8), Bool -> Bus
    ps1 = |bios, tty_trap|
        Ps1(List.repeat(0, 0x400), {
            bios: bios,
            i_stat: 0,
            i_mask: 0,
            ram_size: 0,
            cache_ctrl: 0,
            dev: (List.repeat(0.U64, 60).set(36, 0x0765_4321) ?? List.repeat(0.U64, 60)).set(46, 1) ?? List.repeat(0.U64, 60), # dpcr reset; display disabled at power-on
            exc_ctx: [],
            tty_trap: tty_trap,
            tty: [],
            tty_unknown: [],
        })

    # paged read for the Flat bench surface: same two-level lookup as the
    # Ps1 RAM arm, wrapping at the 2 MB line, no wait cost
    paged_read : List(List(U8)), U8, U32 -> U32
    paged_read = |ram, size, addr| {
        ri = addr.to_u64().bitwise_and(0x1F_FFFF)
        page = ram.get(ri.shr_zf_wrap(12)) ?? []
        ro = ri.bitwise_and(0xFFF)
        b0 = (page.get(ro) ?? 0).to_u32()
        b1 = (page.get(ro.plus(1)) ?? 0).to_u32()
        b2 = (page.get(ro.plus(2)) ?? 0).to_u32()
        b3 = (page.get(ro.plus(3)) ?? 0).to_u32()
        match size {
            1 => b0
            2 => b0.bitwise_or(b1.shl_wrap(8))
            _ => b0.bitwise_or(b1.shl_wrap(8)).bitwise_or(b2.shl_wrap(16)).bitwise_or(b3.shl_wrap(24))
        }
    }

    # wait-state cycles charged ON TOP of the instruction. CALIBRATED
    # 2026-08-25 against ps1-tests cpu/access-time psx.log (hardware):
    # RAM data 5.21/5.3/5.14 -> wait 4; scratchpad ~1 -> 0; I/O 3.1-3.8
    # -> 2; BIOS 7.6/12.94/24.94 -> 7/12/24. INSTRUCTION fetches from
    # cacheable segments (KUSEG/KSEG0) charge 0 — the i-cache
    # approximation the timers psx.log demands (1000-cycle delay loops
    # measure ~1011 on hardware, ~1 cycle/instr); KSEG1 fetches pay the
    # full region wait. Revisit as a set, not singly.
    wait_ram : U64
    wait_ram = 4
    wait_bios_word : U64
    wait_bios_word = 23
    wait_bios_half : U64
    wait_bios_half = 11
    wait_bios_byte : U64
    wait_bios_byte = 6

    # sized waits as packed byte LUTs (8/16/32-bit at bits 0/8/16),
    # selected branch-free by size>>1. Values = hardware access-time
    # table minus the instruction cycle: EXP1 6/13/25, EXP2 10/25/55,
    # EXP3 6/6/9, CDROM 8/14/25, SPU 17/17/38 (psx.log 2026-08-25).
    sized_wait : U64, U8 -> U64
    sized_wait = |packed, size| packed.shr_zf_wrap(size.shr_zf_wrap(1).times_wrap(8)).bitwise_and(0xFF)

    lut_bios : U64
    lut_bios = 6.U64.bitwise_or(11.U64.shl_wrap(8)).bitwise_or(23.U64.shl_wrap(16))
    lut_exp1 : U64
    lut_exp1 = 5.U64.bitwise_or(12.U64.shl_wrap(8)).bitwise_or(24.U64.shl_wrap(16))
    lut_exp2 : U64
    lut_exp2 = 9.U64.bitwise_or(24.U64.shl_wrap(8)).bitwise_or(54.U64.shl_wrap(16))
    lut_exp3 : U64
    lut_exp3 = 5.U64.bitwise_or(5.U64.shl_wrap(8)).bitwise_or(8.U64.shl_wrap(16))
    lut_cdrom : U64
    lut_cdrom = 7.U64.bitwise_or(13.U64.shl_wrap(8)).bitwise_or(24.U64.shl_wrap(16))
    lut_spu : U64
    lut_spu = 16.U64.bitwise_or(16.U64.shl_wrap(8)).bitwise_or(37.U64.shl_wrap(16))
    wait_io : U64
    wait_io = 2

    # NTSC video timing, CPU-cycle denominated. The video clock is CPU x
    # 11/7; one scanline is 3413 video clocks; the dotclock divider is
    # fixed at 8 (320-wide mode — what the test EXEs initVideo with).
    # CALIBRATION: judged by the ps1-tests timers rows together with
    # Psx.ntsc_frame_cycles — revisit as a set, not singly.
    ntsc_cycles_per_line_num : U64
    ntsc_cycles_per_line_num = 23891 # 3413 x 7
    ntsc_cycles_per_line_den : U64
    ntsc_cycles_per_line_den = 11

    dv : Ps1Rest, U64 -> U64
    dv = |rest, i| rest.dev.get(i) ?? 0

    dv32 : Ps1Rest, U64 -> U32
    dv32 = |rest, i| (rest.dev.get(i) ?? 0).to_u32_wrap()

    dset : Ps1Rest, U64, U64 -> Ps1Rest
    dset = |rest, i, v| { ..rest, dev: rest.dev.set(i, v) ?? rest.dev }

    # timer 2's sync modes 0/3 STOP the counter (no blanking involved);
    # modes 1/2 free-run. Timer 0/1 sync gating needs blanking widths —
    # GPU-timing territory, excluded rows in the gate until then.
    t2_frozen : U32 -> Bool
    t2_frozen = |mode| {
        sync = mode.shr_zf_wrap(1).bitwise_and(3)
        mode.bitwise_and(1) == 1 and (sync == 0 or sync == 3)
    }

    # source ticks elapsed for a timer's clock source between two clocks:
    # sysclock (cycles), sysclock/8, hblank lines, dots (divider 8)
    src_ticks : U32, U32, U64 -> U64
    src_ticks = |timer, mode, dc| {
        src = mode.shr_zf_wrap(8).bitwise_and(3)
        if timer == 2 {
            if t2_frozen(mode) {
                0
            } else if src >= 2 { dc // 8 } else { dc }
        } else if timer == 1 {
            if src == 1 or src == 3 { dc.times_wrap(ntsc_cycles_per_line_den) // ntsc_cycles_per_line_num } else { dc }
        } else {
            if src == 1 or src == 3 { dc.times_wrap(ntsc_cycles_per_line_den) // (7 * 8) } else { dc }
        }
    }

    # the live 16-bit counter: anchor base + elapsed source ticks, folded
    # by the wrap period (target+1 when mode bit 3, else 0x10000)
    count_at : U32, { mode : U32, target : U32, anchor_clock : U64, anchor_base : U32 }, U64 -> U32
    count_at = |timer, t, clock| {
        dc = clock.minus_wrap(t.anchor_clock)
        ticks = src_ticks(timer, t.mode, dc)
        period = if t.mode.bitwise_and(8) != 0 { t.target.bitwise_and(0xFFFF).to_u64().plus(1) } else { 0x10000 }
        base = t.anchor_base.to_u64()
        folded = if period == 0 { 0.U64 } else { base.plus(ticks) % period }
        folded.to_u32_wrap()
    }

    # reached flags derived from the anchor window: once the counter has
    # passed TARGET (bit 0) or 0xFFFF (bit 1) since the last anchor, the
    # bit holds until a settle clears the window. Sticky across VAL and
    # TARGET writes because those fold the derived bits into the stored
    # field; MODE writes and MODE-read acks clear it (hardware).
    reached_bits : U32, { mode : U32, target : U32, anchor_clock : U64, anchor_base : U32 }, U64 -> U32
    reached_bits = |timer, t, clock| {
        dc = clock.minus_wrap(t.anchor_clock)
        ticks = src_ticks(timer, t.mode, dc)
        period = if t.mode.bitwise_and(8) != 0 { t.target.bitwise_and(0xFFFF).to_u64().plus(1) } else { 0x10000 }
        base = t.anchor_base.to_u64() % (if period == 0 { 1 } else { period })
        tgt = t.target.bitwise_and(0xFFFF).to_u64()
        dist_t = (tgt.plus(period).minus_wrap(base)) % (if period == 0 { 1 } else { period })
        hit_t = if ticks >= dist_t { 1.U32 } else { 0 }
        dist_f = 0xFFFF.U64.minus_wrap(base)
        hit_f = if t.mode.bitwise_and(8) == 0 and ticks >= dist_f { 2.U32 } else { 0 }
        hit_t.bitwise_or(hit_f)
    }

    # scalar-only timer read: VAL derives, MODE carries the read-cleared
    # reached flags (11/12) and bit 10 high, TARGET echoes. 0 elsewhere.
    # Branches are safe here — this helper never touches a payload list.
    timer_read : Bus, U32, U64 -> U32
    timer_read = |bus, addr, clock|
        match bus {
            Ps1(_, rest) => {
                phys = ps1_phys(addr)
                if phys < 0x1F80_1100 or phys >= 0x1F80_1130 {
                    0
                } else {
                    timer = phys.shr_zf_wrap(4).bitwise_and(3)
                    reg = phys.bitwise_and(0xF)
                    t = timer_of(rest, timer)
                    if reg == 0 {
                        count_at(timer, { mode: t.mode, target: t.target, anchor_clock: t.anchor_clock, anchor_base: t.anchor_base }, clock)
                    } else if reg == 4 {
                        flags = t.reached.bitwise_or(reached_bits(timer, { mode: t.mode, target: t.target, anchor_clock: t.anchor_clock, anchor_base: t.anchor_base }, clock)).bitwise_and(3)
                        t.mode.bitwise_or(0x400).bitwise_or(flags.shl_wrap(11))
                    } else if reg == 8 {
                        t.target
                    } else {
                        0
                    }
                }
            }

            _ => 0
        }

    timer_of : Ps1Rest, U32 -> { mode : U32, target : U32, anchor_clock : U64, anchor_base : U32, reached : U32 }
    timer_of = |rest, timer| {
        b = timer.to_u64().times_wrap(5)
        { mode: dv32(rest, b), target: dv32(rest, b.plus(1)), anchor_clock: dv(rest, b.plus(2)), anchor_base: dv32(rest, b.plus(3)), reached: dv32(rest, b.plus(4)) }
    }

    timer_set : Ps1Rest, U32, { mode : U32, target : U32, anchor_clock : U64, anchor_base : U32, reached : U32 } -> Ps1Rest
    timer_set = |rest, timer, t| {
        b = timer.to_u64().times_wrap(5)
        dset(dset(dset(dset(dset(rest, b, t.mode.to_u64()), b.plus(1), t.target.to_u64()), b.plus(2), t.anchor_clock), b.plus(3), t.anchor_base.to_u64()), b.plus(4), t.reached.to_u64())
    }

    # timer register writes re-anchor so tick history never spans the
    # change: VAL sets the base at now; MODE resets to 0 and clears the
    # reached flags (hardware); TARGET settles the live count first so
    # the wrap period changes without losing phase
    timer_write : Ps1Rest, U32, U32, U64 -> Ps1Rest
    timer_write = |rest, phys, val, clock| {
        timer = phys.shr_zf_wrap(4).bitwise_and(3)
        reg = phys.bitwise_and(0xF)
        t = timer_of(rest, timer)
        sticky = t.reached.bitwise_or(reached_bits(timer, { mode: t.mode, target: t.target, anchor_clock: t.anchor_clock, anchor_base: t.anchor_base }, clock))
        upd =
            if reg == 0 {
                { mode: t.mode, target: t.target, anchor_clock: clock, anchor_base: val.bitwise_and(0xFFFF), reached: sticky }
            } else if reg == 4 {
                { mode: val.bitwise_and(0x3FF), target: t.target, anchor_clock: clock, anchor_base: 0, reached: 0 }
            } else if reg == 8 {
                settled = count_at(timer, { mode: t.mode, target: t.target, anchor_clock: t.anchor_clock, anchor_base: t.anchor_base }, clock)
                { mode: t.mode, target: val.bitwise_and(0xFFFF), anchor_clock: clock, anchor_base: settled, reached: sticky }
            } else {
                { mode: t.mode, target: t.target, anchor_clock: t.anchor_clock, anchor_base: t.anchor_base, reached: t.reached }
            }
        timer_set(rest, timer, upd)
    }

    dma_ch : Ps1Rest, U32 -> { madr : U32, bcr : U32, chcr : U32 }
    dma_ch = |rest, ch| {
        b = 15.U64.plus(ch.to_u64().times_wrap(3))
        { madr: dv32(rest, b), bcr: dv32(rest, b.plus(1)), chcr: dv32(rest, b.plus(2)) }
    }

    dma_ch_set : Ps1Rest, U32, { madr : U32, bcr : U32, chcr : U32 } -> Ps1Rest
    dma_ch_set = |rest, ch, v| {
        b = 15.U64.plus(ch.to_u64().times_wrap(3))
        dset(dset(dset(rest, b, v.madr.to_u64()), b.plus(1), v.bcr.to_u64()), b.plus(2), v.chcr.to_u64())
    }

    # scalar-only DMA register read (0x1F801080-0x1F8010F7); DICR bit 31
    # is the computed master flag: force(15) OR master(23) AND any
    # enabled flag pending
    dma_read : Bus, U32 -> U32
    dma_read = |bus, addr|
        match bus {
            Ps1(_, rest) => {
                phys = ps1_phys(addr)
                if phys == 0x1F80_10F0 {
                    dv32(rest, 36)
                } else if phys == 0x1F80_10F4 {
                    force = dv32(rest, 37).bitwise_and(0x8000) != 0
                    pending = dv32(rest, 37).shr_zf_wrap(24).bitwise_and(0x7F).bitwise_and(dv32(rest, 37).shr_zf_wrap(16).bitwise_and(0x7F))
                    master = dv32(rest, 37).bitwise_and(0x0080_0000) != 0 and pending != 0
                    b31 = if force or master { 0x8000_0000.U32 } else { 0 }
                    dv32(rest, 37).bitwise_or(b31)
                } else if phys >= 0x1F80_1080 and phys < 0x1F80_10F0 {
                    ch = phys.minus_wrap(0x1F80_1080).shr_zf_wrap(4)
                    reg = phys.bitwise_and(0xF)
                    v = dma_ch(rest, ch)
                    if reg == 0 {
                        v.madr
                    } else if reg == 4 {
                        v.bcr
                    } else {
                        v.chcr
                    }
                } else {
                    0
                }
            }

            _ => 0
        }

    # DMA register writes: MADR masks to RAM range, DICR flags are
    # write-1-to-clear (bits 24-30) with writable low/enable bits
    dma_write : Ps1Rest, U32, U32 -> Ps1Rest
    dma_write = |rest, phys, val|
        if phys == 0x1F80_10F0 {
            dset(rest, 36, val.to_u64())
        } else if phys == 0x1F80_10F4 {
            writable = val.bitwise_and(0x00FF_803F)
            kept_flags = dv32(rest, 37).bitwise_and(0x7F00_0000).bitwise_and(val.bitwise_and(0x7F00_0000).bitwise_not())
            dset(rest, 37, writable.bitwise_or(kept_flags).to_u64())
        } else if phys >= 0x1F80_1080 and phys < 0x1F80_10F0 {
            ch = phys.minus_wrap(0x1F80_1080).shr_zf_wrap(4)
            reg = phys.bitwise_and(0xF)
            v = dma_ch(rest, ch)
            if reg == 0 {
                dma_ch_set(rest, ch, { ..v, madr: val.bitwise_and(0x00FF_FFFF) })
            } else if reg == 4 {
                dma_ch_set(rest, ch, { ..v, bcr: val })
            } else if ch == 6 {
                # D6 CHCR is hardwired except start/trigger/bit30: sync
                # bits do not stick, direction reads backward (0x...02)
                dma_ch_set(rest, ch, { ..v, chcr: val.bitwise_and(0x5100_0000).bitwise_or(2) })
            } else {
                dma_ch_set(rest, ch, { ..v, chcr: val })
            }
        } else {
            rest
        }

    # did a write at `phys` start a transfer? (CHCR writes check their
    # channel; DPCR writes re-scan all channels for armed+enabled ones).
    # Start needs CHCR bit 24, DPCR's enable bit for the channel, manual
    # trigger (bit 28) when sync mode 0, and OTC only supports mode 0.
    dma_kick_info : Bus, U32 -> { ch : U32, madr : U32, bcr : U32, chcr : U32, go : Bool }
    dma_kick_info = |bus, phys|
        match bus {
            Ps1(_, rest) => {
                if phys >= 0x1F80_1080 and phys < 0x1F80_10F0 {
                    ch = phys.minus_wrap(0x1F80_1080).shr_zf_wrap(4)
                    kick_check(rest, ch)
                } else if phys == 0x1F80_10F0 {
                    scan6 = kick_check(rest, 6)
                    if scan6.go { scan6 } else { kick_scan(rest, 0) }
                } else {
                    { ch: 0, madr: 0, bcr: 0, chcr: 0, go: Bool.False }
                }
            }

            _ => { ch: 0, madr: 0, bcr: 0, chcr: 0, go: Bool.False }
        }

    kick_scan : Ps1Rest, U32 -> { ch : U32, madr : U32, bcr : U32, chcr : U32, go : Bool }
    kick_scan = |rest, ch|
        if ch > 5 {
            { ch: 0, madr: 0, bcr: 0, chcr: 0, go: Bool.False }
        } else {
            k = kick_check(rest, ch)
            if k.go { k } else { kick_scan(rest, ch.plus(1)) }
        }

    kick_check : Ps1Rest, U32 -> { ch : U32, madr : U32, bcr : U32, chcr : U32, go : Bool }
    kick_check = |rest, ch| {
        v = dma_ch(rest, ch)
        enabled = dv32(rest, 36).shr_zf_wrap(ch.times_wrap(4).plus(3).to_u8_wrap()).bitwise_and(1) == 1
        started = v.chcr.bitwise_and(0x0100_0000) != 0
        sync = v.chcr.shr_zf_wrap(9).bitwise_and(3)
        manual = sync != 0 or v.chcr.bitwise_and(0x1000_0000) != 0
        mode_ok = ch != 6 or sync == 0
        { ch: ch, madr: v.madr, bcr: v.bcr, chcr: v.chcr, go: enabled and started and manual and mode_ok }
    }

    # transfer done: clear start/trigger, land MADR, zero the word count,
    # and run the DICR flag/IRQ ladder (I_STAT bit 3 when an enabled
    # channel flags with the master enable on)
    dma_complete : Bus, U32, U32 -> Bus
    dma_complete = |bus, ch, end_madr|
        match bus {
            Ps1(scratch, rest) => {
                v = dma_ch(rest, ch)
                r1 = dma_ch_set(rest, ch, { madr: end_madr, bcr: v.bcr.bitwise_and(0xFFFF_0000), chcr: v.chcr.bitwise_and(0xEEFF_FFFF) })
                dicr0 = dv32(r1, 37)
                irq_en = dicr0.shr_zf_wrap(16.U8.plus(ch.to_u8_wrap())).bitwise_and(1) == 1
                master = dicr0.bitwise_and(0x0080_0000) != 0
                r2 = if irq_en { dset(r1, 37, dicr0.bitwise_or(0x0100_0000.U32.shl_wrap(ch.to_u8_wrap())).to_u64()) } else { r1 }
                r3 = if irq_en and master { { ..r2, i_stat: r2.i_stat.bitwise_or(8) } } else { r2 }
                Ps1(scratch, r3)
            }

            other => other
        }

    # a started transfer on a channel with no device endpoint yet: loud,
    # surfaced through the same fail-loud ledger the kernel trap uses
    # (table 0xDA, fn = channel number). The channel is DISARMED (start/
    # trigger cleared, no completion side effects) so one start logs one
    # entry — the ledger already dooms the run, nothing can pass off it.
    dma_unhandled : Bus, U32 -> Bus
    dma_unhandled = |bus, ch|
        match bus {
            Ps1(scratch, rest) => {
                v = dma_ch(rest, ch)
                r1 = dma_ch_set(rest, ch, { ..v, chcr: v.chcr.bitwise_and(0xEEFF_FFFF) })
                Ps1(scratch, { ..r1, tty_unknown: r1.tty_unknown.append(0xDA.U64.shl_wrap(32).bitwise_or(ch.to_u64())) })
            }

            other => other
        }

    # an unimplemented GP0 command actually issued: loud (table 0xDB),
    # DEDUPED — the fact matters, not the half-million text-glyph repeats
    gpu_unknown : Bus, U32 -> Bus
    gpu_unknown = |bus, cmd|
        match bus {
            Ps1(scratch, rest) => {
                entry = 0xDB.U64.shl_wrap(32).bitwise_or(cmd.to_u64())
                if rest.tty_unknown.contains(entry) {
                    Ps1(scratch, rest)
                } else {
                    Ps1(scratch, { ..rest, tty_unknown: rest.tty_unknown.append(entry) })
                }
            }

            other => other
        }

    never : U64
    never = 0xFFFF_FFFF_FFFF_FFFF

    # inverse of src_ticks: cycles needed for `ticks` source ticks
    # (ceilinged for the ratio sources so scheduled instants never land
    # before the actual hit)
    cycles_for_ticks : U32, U32, U64 -> U64
    cycles_for_ticks = |timer, mode, ticks| {
        src = mode.shr_zf_wrap(8).bitwise_and(3)
        if timer == 2 {
            if src >= 2 { ticks.times_wrap(8) } else { ticks }
        } else if timer == 1 {
            if src == 1 or src == 3 { ticks.times_wrap(ntsc_cycles_per_line_num).plus(ntsc_cycles_per_line_den.minus(1)) // ntsc_cycles_per_line_den } else { ticks }
        } else {
            if src == 1 or src == 3 { ticks.times_wrap(56).plus(10) // 11 } else { ticks }
        }
    }

    # absolute clock of this timer's next IRQ hit strictly after `now`
    # (never when IRQs are off or a one-shot already fired — fired is
    # bit 2 of the stored reached word, cleared only by a MODE write)
    timer_next_irq : U32, { mode : U32, target : U32, anchor_clock : U64, anchor_base : U32, reached : U32 }, U64 -> U64
    timer_next_irq = |timer, t, now| {
        irq_t = t.mode.bitwise_and(0x10) != 0
        irq_f = t.mode.bitwise_and(0x20) != 0
        oneshot = t.mode.bitwise_and(0x40) == 0
        if (irq_t == Bool.False and irq_f == Bool.False) or (oneshot and t.reached.bitwise_and(4) != 0) or (timer == 2 and t2_frozen(t.mode)) {
            never
        } else {
            e = src_ticks(timer, t.mode, now.minus_wrap(t.anchor_clock))
            period = if t.mode.bitwise_and(8) != 0 { t.target.bitwise_and(0xFFFF).to_u64().plus(1) } else { 0x10000 }
            base = t.anchor_base.to_u64() % (if period == 0 { 1 } else { period })
            tgt = t.target.bitwise_and(0xFFFF).to_u64()
            dist_t = (tgt.plus(period).minus_wrap(base)) % (if period == 0 { 1 } else { period })
            n_t = if irq_t {
                if e >= dist_t { dist_t.plus(period.times_wrap((e.minus(dist_t) // period).plus(1))) } else { dist_t }
            } else {
                never
            }
            n_f = if irq_f and t.mode.bitwise_and(8) == 0 {
                dist_f = 0xFFFF.U64.minus_wrap(base)
                if e >= dist_f { dist_f.plus(0x10000.U64.times_wrap((e.minus(dist_f) // 0x10000).plus(1))) } else { dist_f }
            } else {
                never
            }
            n = if n_t < n_f { n_t } else { n_f }
            if n == never { never } else { t.anchor_clock.plus(cycles_for_ticks(timer, t.mode, n)) }
        }
    }

    # the console's single scheduled slot: earliest pending timer IRQ
    next_timer_event : Bus, U64 -> U64
    next_timer_event = |bus, now|
        match bus {
            Ps1(_, rest) => {
                a = timer_next_irq(0, timer_of(rest, 0), now)
                b = timer_next_irq(1, timer_of(rest, 1), now)
                d = timer_next_irq(2, timer_of(rest, 2), now)
                ab = if a < b { a } else { b }
                if ab < d { ab } else { d }
            }

            _ => never
        }

    # raise I_STAT for every timer whose IRQ condition has occurred, then
    # settle it (count preserved; the reached window restarts so repeat
    # timers fire once per period). One-shots mark fired (bit 2).
    timer_harvest : Bus, U64 -> Bus
    timer_harvest = |bus, now|
        match bus {
            Ps1(scratch, rest) => Ps1(scratch, harvest_one(harvest_one(harvest_one(rest, 0, now), 1, now), 2, now))
            other => other
        }

    harvest_one : Ps1Rest, U32, U64 -> Ps1Rest
    harvest_one = |rest, timer, now| {
        t = timer_of(rest, timer)
        wanted = t.mode.shr_zf_wrap(4).bitwise_and(3) # bits 4/5 -> flag bits 0/1
        oneshot = t.mode.bitwise_and(0x40) == 0
        fired = t.reached.bitwise_and(4) != 0
        hit = reached_bits(timer, { mode: t.mode, target: t.target, anchor_clock: t.anchor_clock, anchor_base: t.anchor_base }, now)
        due = hit.bitwise_and(wanted) != 0 and (oneshot == Bool.False or fired == Bool.False)
        if due {
            settled = count_at(timer, { mode: t.mode, target: t.target, anchor_clock: t.anchor_clock, anchor_base: t.anchor_base }, now)
            new_reached = t.reached.bitwise_or(hit).bitwise_or(if oneshot { 4 } else { 0 })
            stat = rest.i_stat.bitwise_or(0x10.U32.shl_wrap(timer.to_u8_wrap()))
            timer_set({ ..rest, i_stat: stat }, timer, { ..t, anchor_clock: now, anchor_base: settled, reached: new_reached })
        } else {
            rest
        }
    }

    # acknowledge a MODE read: settle the timer at the read's clock (the
    # count is preserved exactly) and clear the reached window — applied
    # by the console layer from the step's ack intent (reads are pure)
    timer_ack : Bus, U32, U64 -> Bus
    timer_ack = |bus, addr, clock|
        match bus {
            Ps1(scratch, rest) => {
                timer = ps1_phys(addr).shr_zf_wrap(4).bitwise_and(3)
                t = timer_of(rest, timer)
                settled = count_at(timer, { mode: t.mode, target: t.target, anchor_clock: t.anchor_clock, anchor_base: t.anchor_base }, clock)
                keep = t.reached.bitwise_and(4) # one-shot fired survives read-acks
                Ps1(scratch, timer_set(rest, timer, { ..t, anchor_clock: clock, anchor_base: settled, reached: keep }))
            }

            other => other
        }

    # physical address for the three main segments (KSEG2 handled where needed)
    ps1_phys : U32 -> U32
    ps1_phys = |addr| addr.bitwise_and(0x1FFF_FFFF)

    # little-endian read of `size` bytes from a list at idx
    le_read : List(U8), U64, U8 -> U32
    le_read = |mem, idx, size| {
        b0 = (mem.get(idx) ?? 0).to_u32()
        if size == 1 {
            b0
        } else if size == 2 {
            b0.bitwise_or((mem.get(idx.plus(1)) ?? 0).to_u32().shl_wrap(8))
        } else {
            b0
                .bitwise_or((mem.get(idx.plus(1)) ?? 0).to_u32().shl_wrap(8))
                .bitwise_or((mem.get(idx.plus(2)) ?? 0).to_u32().shl_wrap(16))
                .bitwise_or((mem.get(idx.plus(3)) ?? 0).to_u32().shl_wrap(24))
        }
    }

    le_write : List(U8), U64, U8, U32 -> List(U8)
    le_write = |mem, idx, size, val| {
        m1 = mem.set(idx, val.to_u8_wrap()) ?? mem
        if size == 1 {
            m1
        } else {
            m2 = m1.set(idx.plus(1), val.shr_zf_wrap(8).to_u8_wrap()) ?? m1
            if size == 2 {
                m2
            } else {
                m3 = m2.set(idx.plus(2), val.shr_zf_wrap(16).to_u8_wrap()) ?? m2
                m3.set(idx.plus(3), val.shr_zf_wrap(24).to_u8_wrap()) ?? m3
            }
        }
    }

    # 0xFFFFFFFF when t == 0, else 0. The read arms below are BRANCH-FREE
    # mask arithmetic on purpose: any conditional inside a record-returning
    # arm that reads a payload list defeats in-place updates of that list
    # for the rest of the program — every RAM store then clones 2 MB
    # (single-if flip measured; see perf notes / repro repo).
    zero_mask : U32 -> U32
    zero_mask = |t| 0.U32.minus_wrap(1.U32.minus_wrap(t.bitwise_or(0.U32.minus_wrap(t)).shr_zf_wrap(31)))

    bios_wait : U8 -> U64
    bios_wait = |size| if size == 4 { wait_bios_word } else if size == 2 { wait_bios_half } else { wait_bios_byte }

    # non-memory Ps1 writes (I/O registers, KSEG2); RAM stores are the
    # driver's store intents — see the shape note at the top. `clock` is
    # the cycle the write lands at: timer writes re-anchor with it.
    rest_write : Ps1Rest, U32, U32, U64 -> Ps1Rest
    rest_write = |rest, addr, val, clock|
        if addr >= 0xFFFE0000 {
            if addr == 0xFFFE0130 { { ..rest, cache_ctrl: val } } else { rest }
        } else {
            phys = ps1_phys(addr)
            if phys == 0x1F80_1070 {
                { ..rest, i_stat: rest.i_stat.bitwise_and(val) } # acknowledge: writing 0 bits clears
            } else if phys == 0x1F80_1074 {
                { ..rest, i_mask: val.bitwise_and(0x7FF) }
            } else if phys == 0x1F80_1060 {
                { ..rest, ram_size: val }
            } else if phys == 0x1F80_104A {
                # dropping TX-enable (or deselecting) starts a fresh exchange
                seq = if val.bitwise_and(1) == 0 { 0.U64 } else { dv(rest, 39) }
                dset(dset(rest, 38, val.bitwise_and(0xFFFF).to_u64()), 39, seq)
            } else if phys == 0x1F80_1DAA {
                dset(rest, 42, val.bitwise_and(0xFFFF).to_u64())
            } else if phys >= 0x1F80_1080 and phys < 0x1F80_10F8 {
                dma_write(rest, phys, val)
            } else if phys >= 0x1F80_1100 and phys < 0x1F80_1130 {
                timer_write(rest, phys, val, clock)
            } else if phys == 0x1F80_1040 {
                # emulated digital pad: 0x01 -> hi-z, 0x42 -> 0x41, tap ->
                # 0x5A, motor bytes -> switch state (0xFF = none pressed)
                # scripted input: START pressed on exchanges 5-8 then
                # released — the menu launches on the release edge
                pressed = dv32(rest, 40) >= 5 and dv32(rest, 40) < 9
                rx =
                    if dv32(rest, 39) == 1 {
                        0x41.U32
                    } else if dv32(rest, 39) == 2 {
                        0x5A.U32
                    } else if dv32(rest, 39) == 3 and pressed {
                        0xF7 # swlo with START down (active low)
                    } else {
                        0xFF
                    }
                xact = if dv(rest, 39) == 4 { dv(rest, 40).plus_wrap(1) } else { dv(rest, 40) }
                dset(dset(dset(rest, 39, dv(rest, 39).plus_wrap(1)), 40, xact), 41, rx.to_u64())
            } else {
                rest # BIOS window, expansion, other I/O: swallowed
            }
        }


    # Reads NEVER return the bus: the { bus, val, cost } record-return
    # shape marks the union shared and taxes every step with refcount and
    # copy traffic (measured; see the perf notes). The Vector variant's
    # fetch/read trace is synthesized by the vector RUNNER from the step's
    # read-intent fields instead — only writes still record into the bus.
    fetch_val : Bus, List(List(U8)), U32, U64 -> { val : U32, cost : U64 }
    fetch_val = |bus, ram, addr, clock| {
        _ = clock # fetches never target timer registers; parity param

        match bus {
            Vector(v) => { val: if addr == v.base { v.opcode } else { addr }, cost: 0 }
            Flat => { val: paged_read(ram, 4, addr), cost: 0 }
            Ps1(scratch, rest) => {
                phys = ps1_phys(addr)
                m_ram = zero_mask(phys.shr_zf_wrap(23))
                m_scr = zero_mask(phys.minus_wrap(0x1F80_0000).shr_zf_wrap(10)).bitwise_and(zero_mask(addr.shr_zf_wrap(29).bitwise_xor(5)).bitwise_not())
                m_bios = zero_mask(phys.minus_wrap(0x1FC0_0000).shr_zf_wrap(19))
                m_io = zero_mask(phys.minus_wrap(0x1F80_1000).shr_zf_wrap(12))
                m_is = zero_mask(phys.bitwise_xor(0x1F80_1070))
                m_im = zero_mask(phys.bitwise_xor(0x1F80_1074))
                m_rs = zero_mask(phys.bitwise_xor(0x1F80_1060))
                m_cc = zero_mask(addr.bitwise_xor(0xFFFE_0130))
                m_gs = zero_mask(phys.bitwise_xor(0x1F80_1814)) # GPUSTAT stub: always ready (bits 26/27/28), no GPU yet
                m_jd = zero_mask(phys.bitwise_xor(0x1F80_1040)) # JOY_DATA: digital-pad response byte
                m_js = zero_mask(phys.bitwise_xor(0x1F80_1044)) # JOY_STAT: TX ready/finished
                m_jc = zero_mask(phys.bitwise_xor(0x1F80_104A)) # JOY_CTRL echoes writes
                m_sc = zero_mask(phys.bitwise_xor(0x1F80_1DAA)) # SPUCNT echo
                m_ss = zero_mask(phys.bitwise_xor(0x1F80_1DAE)) # SPUSTAT mirrors SPUCNT low 6 (bit 10 = DMA ready)
                ri = phys.bitwise_and(0x1F_FFFF).to_u64()
                rpage = ram.get(ri.shr_zf_wrap(12)) ?? []
                ro = ri.bitwise_and(0xFFF)
                rv = (rpage.get(ro) ?? 0).to_u32()
                    .bitwise_or((rpage.get(ro.plus(1)) ?? 0).to_u32().shl_wrap(8))
                    .bitwise_or((rpage.get(ro.plus(2)) ?? 0).to_u32().shl_wrap(16))
                    .bitwise_or((rpage.get(ro.plus(3)) ?? 0).to_u32().shl_wrap(24))
                si = phys.bitwise_and(0x3FF).to_u64()
                sv = (scratch.get(si) ?? 0).to_u32()
                    .bitwise_or((scratch.get(si.plus(1)) ?? 0).to_u32().shl_wrap(8))
                    .bitwise_or((scratch.get(si.plus(2)) ?? 0).to_u32().shl_wrap(16))
                    .bitwise_or((scratch.get(si.plus(3)) ?? 0).to_u32().shl_wrap(24))
                bi = phys.bitwise_and(0x7_FFFF).to_u64()
                bv = (rest.bios.get(bi) ?? 0).to_u32()
                    .bitwise_or((rest.bios.get(bi.plus(1)) ?? 0).to_u32().shl_wrap(8))
                    .bitwise_or((rest.bios.get(bi.plus(2)) ?? 0).to_u32().shl_wrap(16))
                    .bitwise_or((rest.bios.get(bi.plus(3)) ?? 0).to_u32().shl_wrap(24))
                val = rv.bitwise_and(m_ram)
                    .bitwise_or(sv.bitwise_and(m_scr))
                    .bitwise_or(bv.bitwise_and(m_bios))
                    .bitwise_or(rest.i_stat.bitwise_and(m_is))
                    .bitwise_or(rest.i_mask.bitwise_and(m_im))
                    .bitwise_or(rest.ram_size.bitwise_and(m_rs))
                    .bitwise_or(rest.cache_ctrl.bitwise_and(m_cc))
                    .bitwise_or(0x1C00_0000.U32.bitwise_and(m_gs))
                    .bitwise_or(dv32(rest, 41).bitwise_and(m_jd))
                    .bitwise_or(0x7.U32.bitwise_and(m_js))
                    .bitwise_or(dv32(rest, 38).bitwise_and(m_jc))
                    .bitwise_or(dv32(rest, 42).bitwise_and(m_sc))
                    .bitwise_or(dv32(rest, 42).bitwise_and(0x3F).bitwise_and(m_ss))
                m_k1 = zero_mask(addr.shr_zf_wrap(29).bitwise_xor(5)) # KSEG1: uncached — the only fetches that pay waits
                cost = 4.U64.bitwise_and(m_ram.bitwise_and(m_k1).to_u64())
                    .bitwise_or(23.U64.bitwise_and(m_bios.bitwise_and(m_k1).to_u64()))
                    .bitwise_or(2.U64.bitwise_and(m_io.to_u64()))
                { val: val, cost: cost }
            }
        }
    }

    read_val : Bus, List(List(U8)), U8, U32, U64, U64 -> { val : U32, cost : U64 }
    read_val = |bus, ram, size, addr, k, clock| {
        # scalar-only pre-pass, guarded so ordinary reads never pay the
        # union match (the guard reads no payload list — law-safe);
        # covers the DMA (0x1080-0x10F7), timer (0x1100-0x112F), and GPU
        # (0x1810/0x1814) register files
        pp = addr.bitwise_and(0x1FFF_FFFF)
        tp = pp.minus_wrap(0x1F80_1080)
        tv = if tp < 0xB0 {
            dma_read(bus, addr).bitwise_or(timer_read(bus, addr, clock))
        } else if pp == 0x1F80_1810 or pp == 0x1F80_1814 {
            gpu_read(bus, addr)
        } else {
            0
        }

        match bus {
            Vector(v) => { val: v.reads.get(k) ?? 0, cost: 0 }
            Flat => { val: paged_read(ram, size, addr), cost: 0 }
            Ps1(scratch, rest) => {
                phys = ps1_phys(addr)
                m_ram = zero_mask(phys.shr_zf_wrap(23))
                m_scr = zero_mask(phys.minus_wrap(0x1F80_0000).shr_zf_wrap(10)).bitwise_and(zero_mask(addr.shr_zf_wrap(29).bitwise_xor(5)).bitwise_not())
                m_bios = zero_mask(phys.minus_wrap(0x1FC0_0000).shr_zf_wrap(19))
                m_io = zero_mask(phys.minus_wrap(0x1F80_1000).shr_zf_wrap(12))
                m_is = zero_mask(phys.bitwise_xor(0x1F80_1070))
                m_im = zero_mask(phys.bitwise_xor(0x1F80_1074))
                m_rs = zero_mask(phys.bitwise_xor(0x1F80_1060))
                m_cc = zero_mask(addr.bitwise_xor(0xFFFE_0130))
                m_gs = zero_mask(phys.bitwise_xor(0x1F80_1814)) # GPUSTAT: live, from the scalar pre-pass
                m_gr = zero_mask(phys.bitwise_xor(0x1F80_1810)) # GPUREAD: staged stream/info word, same pre-pass
                m_jd = zero_mask(phys.bitwise_xor(0x1F80_1040)) # JOY_DATA: digital-pad response byte
                m_js = zero_mask(phys.bitwise_xor(0x1F80_1044)) # JOY_STAT: TX ready/finished
                m_jc = zero_mask(phys.bitwise_xor(0x1F80_104A)) # JOY_CTRL echoes writes
                m_sc = zero_mask(phys.bitwise_xor(0x1F80_1DAA)) # SPUCNT echo
                m_ss = zero_mask(phys.bitwise_xor(0x1F80_1DAE)) # SPUSTAT mirrors SPUCNT low 6 (bit 10 = DMA ready)
                m_e1 = zero_mask(phys.minus_wrap(0x1F00_0000).shr_zf_wrap(23)) # EXP1 8 MB
                m_e2 = zero_mask(phys.minus_wrap(0x1F80_2000).shr_zf_wrap(13)) # EXP2 8 KB
                m_e3 = zero_mask(phys.minus_wrap(0x1FA0_0000).shr_zf_wrap(21)) # EXP3 2 MB
                m_cd = zero_mask(phys.minus_wrap(0x1F80_1800).shr_zf_wrap(2)) # CDROM regs
                m_spu = zero_mask(phys.minus_wrap(0x1F80_1C00).shr_zf_wrap(10)) # SPU regs
                m_tim = zero_mask(phys.minus_wrap(0x1F80_1100).shr_zf_wrap(6)) # timers: value from the scalar-only pre-pass
                m_dma = zero_mask(phys.minus_wrap(0x1F80_1080).shr_zf_wrap(7)) # DMA file: same pre-pass
                ri = phys.bitwise_and(0x1F_FFFF).to_u64()
                rpage = ram.get(ri.shr_zf_wrap(12)) ?? []
                ro = ri.bitwise_and(0xFFF)
                rv = (rpage.get(ro) ?? 0).to_u32()
                    .bitwise_or((rpage.get(ro.plus(1)) ?? 0).to_u32().shl_wrap(8))
                    .bitwise_or((rpage.get(ro.plus(2)) ?? 0).to_u32().shl_wrap(16))
                    .bitwise_or((rpage.get(ro.plus(3)) ?? 0).to_u32().shl_wrap(24))
                si = phys.bitwise_and(0x3FF).to_u64()
                sv = (scratch.get(si) ?? 0).to_u32()
                    .bitwise_or((scratch.get(si.plus(1)) ?? 0).to_u32().shl_wrap(8))
                    .bitwise_or((scratch.get(si.plus(2)) ?? 0).to_u32().shl_wrap(16))
                    .bitwise_or((scratch.get(si.plus(3)) ?? 0).to_u32().shl_wrap(24))
                bi = phys.bitwise_and(0x7_FFFF).to_u64()
                bv = (rest.bios.get(bi) ?? 0).to_u32()
                    .bitwise_or((rest.bios.get(bi.plus(1)) ?? 0).to_u32().shl_wrap(8))
                    .bitwise_or((rest.bios.get(bi.plus(2)) ?? 0).to_u32().shl_wrap(16))
                    .bitwise_or((rest.bios.get(bi.plus(3)) ?? 0).to_u32().shl_wrap(24))
                val = rv.bitwise_and(m_ram)
                    .bitwise_or(sv.bitwise_and(m_scr))
                    .bitwise_or(bv.bitwise_and(m_bios))
                    .bitwise_or(rest.i_stat.bitwise_and(m_is))
                    .bitwise_or(rest.i_mask.bitwise_and(m_im))
                    .bitwise_or(rest.ram_size.bitwise_and(m_rs))
                    .bitwise_or(rest.cache_ctrl.bitwise_and(m_cc))
                    .bitwise_or(tv.bitwise_and(m_gs.bitwise_or(m_gr)))
                    .bitwise_or(dv32(rest, 41).bitwise_and(m_jd))
                    .bitwise_or(0x7.U32.bitwise_and(m_js))
                    .bitwise_or(dv32(rest, 38).bitwise_and(m_jc))
                    .bitwise_or(dv32(rest, 42).bitwise_and(m_sc))
                    .bitwise_or(dv32(rest, 42).bitwise_and(0x3F).bitwise_and(m_ss))
                    .bitwise_or(tv.bitwise_and(m_tim.bitwise_or(m_dma)))
                m_io_plain = m_io.bitwise_and(m_cd.bitwise_or(m_spu).bitwise_not())
                cost = 4.U64.bitwise_and(m_ram.to_u64())
                    .bitwise_or(sized_wait(lut_bios, size).bitwise_and(m_bios.to_u64()))
                    .bitwise_or(2.U64.bitwise_and(m_io_plain.to_u64()))
                    .bitwise_or(sized_wait(lut_exp1, size).bitwise_and(m_e1.to_u64()))
                    .bitwise_or(sized_wait(lut_exp2, size).bitwise_and(m_e2.to_u64()))
                    .bitwise_or(sized_wait(lut_exp3, size).bitwise_and(m_e3.to_u64()))
                    .bitwise_or(sized_wait(lut_cdrom, size).bitwise_and(m_cd.to_u64()))
                    .bitwise_or(sized_wait(lut_spu, size).bitwise_and(m_spu.to_u64()))
                { val: val, cost: cost }
            }
        }
    }

    # pure write-cost lookup, separate from `write` ON PURPOSE: returning
    # the Bus wrapped in a { bus, cost } record from the updating function
    # defeats the in-place payload update — every RAM store then clones
    # 2 MB (~300x collapse; minimal repro in the perf notes). The write
    # returns the Bus DIRECTLY and the step adds this cost alongside.
    write_cost : U8, U32 -> U64
    write_cost = |size, addr| {
        phys = ps1_phys(addr)
        if size == 0 {
            0
        } else if phys >= 0x1F80_1000 and phys < 0x1F80_2000 {
            wait_io
        } else {
            0
        }
    }

    scratch_write : List(U8), U64, U8, U32 -> List(U8)
    scratch_write = |scratch, s0, size, val|
        if size == 1 {
            scratch.set(s0, val.to_u8_wrap()) ?? scratch
        } else if size == 2 {
            ((scratch.set(s0, val.to_u8_wrap()) ?? scratch).set(s0.plus(1), val.shr_zf_wrap(8).to_u8_wrap())) ?? scratch
        } else {
            ((((scratch.set(s0, val.to_u8_wrap()) ?? scratch).set(s0.plus(1), val.shr_zf_wrap(8).to_u8_wrap()) ?? scratch).set(s0.plus(2), val.shr_zf_wrap(16).to_u8_wrap()) ?? scratch).set(s0.plus(3), val.shr_zf_wrap(24).to_u8_wrap())) ?? scratch
        }

    # single function, size-0 handled INSIDE each arm, union returned
    # DIRECTLY: a size-0 wrapper around the updating function (like a
    # { bus, cost } record return) defeats the in-place payload update —
    # both measured as the full 2 MB clone-per-store collapse; see the
    # perf notes / repro repo
    write : Bus, U8, U32, U32, U64 -> Bus
    write = |bus, size, addr, val, clock|
        match bus {
            Vector(v) =>
                if size == 0 {
                    Vector(v)
                } else {
                    Vector({ ..v, trace: v.trace.append({ kind: 2, size: size, addr: addr, val: val }) })
                }
            Ps1(scratch, rest) => {
                phys = ps1_phys(addr)
                if size == 0 {
                    Ps1(scratch, rest)
                } else if addr < 0xFFFE0000 and addr < 0xA000_0000 and phys >= 0x1F80_0000 and phys < 0x1F80_0400 {
                    Ps1(scratch_write(scratch, phys.bitwise_and(0x3FF).to_u64(), size, val), rest)
                } else {
                    Ps1(scratch, rest_write(rest, addr, val, clock))
                }
            }

            Flat => Flat # stores land via Cpu.store_ram on the external RAM
        }

    trace : Bus -> List({ kind : U8, size : U8, addr : U32, val : U32 })
    trace = |bus|
        match bus {
            Vector(v) => v.trace
            Flat => []
            Ps1(_, _) => []
        }

    # HLE interrupt-dispatch support (the D5 trio): the hooked jmp_buf,
    # and the register context saved at delivery for ReturnFromException
    hook : Bus -> U32
    hook = |bus|
        match bus {
            Ps1(_, rest) => dv32(rest, 43)
            _ => 0
        }

    exc_ctx : Bus -> List(U32)
    exc_ctx = |bus|
        match bus {
            Ps1(_, rest) => rest.exc_ctx
            _ => []
        }

    set_exc_ctx : Bus, List(U32) -> Bus
    set_exc_ctx = |bus, ctx|
        match bus {
            Ps1(scratch, rest) => Ps1(scratch, { ..rest, exc_ctx: ctx })
            other => other
        }

    # console-layer access to the dev slot table (GPU state etc.)
    gpu_slot : Bus, U64 -> U64
    gpu_slot = |bus, i|
        match bus {
            Ps1(_, rest) => dv(rest, i)
            _ => 0
        }

    gpu_slot_set : Bus, U64, U64 -> Bus
    gpu_slot_set = |bus, i, v|
        match bus {
            Ps1(scratch, rest) => Ps1(scratch, dset(rest, i, v))
            other => other
        }

    # scalar-only GPU register read: GPUSTAT composed live from the
    # slots, GPUREAD serving the staged stream/info word (slot 49)
    gpu_read : Bus, U32 -> U32
    gpu_read = |bus, addr|
        match bus {
            Ps1(_, rest) => {
                phys = ps1_phys(addr)
                if phys == 0x1F80_1814 {
                    Gpu.gpustat({
                        e1: dv32(rest, 44),
                        mask: dv32(rest, 45),
                        disp_off: dv32(rest, 46),
                        dma_dir: dv32(rest, 47),
                        mode: dv32(rest, 48),
                        read_active: dv32(rest, 50),
                        irq1: dv32(rest, 58),
                        tex_allow: dv32(rest, 59),
                    })
                } else if phys == 0x1F80_1810 {
                    dv32(rest, 49)
                } else {
                    0
                }
            }

            _ => 0
        }

    # kernel-vector trap support (Cpu.step): is the TTY trap armed?
    trap_enabled : Bus -> Bool
    trap_enabled = |bus|
        match bus {
            Ps1(_, rest) => rest.tty_trap
            _ => Bool.False
        }

    # read a NUL-terminated string out of Ps1 RAM (for puts)
    read_cstring : List(List(U8)), U32 -> List(U8)
    read_cstring = |ram, addr| {
        var out = []
        var i = ps1_phys(addr).bitwise_and(0x1F_FFFF).to_u64()
        var going = Bool.True
        while going {
            ch = (ram.get(i.shr_zf_wrap(12)) ?? []).get(i.bitwise_and(0xFFF)) ?? 0
            if ch == 0 or out.len() >= 4096 {
                going = Bool.False
            } else {
                out = out.append(ch)
                i = i.plus(1)
            }
        }
        out
    }


    # --- mini-printf HLE (A0:0x3F) -------------------------------------
    # Amidog's tests report through the kernel's printf; this renders the
    # common conversions (%d %i %u %x %X %c %s %%, optional zero-pad and
    # width as in %08x) and nothing more. o32 varargs: a1-a3, then stack
    # words at sp+0x10, sp+0x14, ...
    dec_u32 : U32 -> List(U8)
    dec_u32 = |v| {
        var out = []
        var n = v
        var going = Bool.True
        while going {
            out = out.prepend(48.U8.plus((n % 10).to_u8_wrap()))
            n = n // 10
            if n == 0 {
                going = Bool.False
            } else {}
        }
        out
    }

    hex_u32 : U32, Bool -> List(U8)
    hex_u32 = |v, upper| {
        base = if upper { 55.U8 } else { 87 }
        var out = []
        var n = v
        var going = Bool.True
        while going {
            d = (n.bitwise_and(15)).to_u8_wrap()
            out = out.prepend(if d < 10 { d.plus(48) } else { d.plus(base) })
            n = n.shr_zf_wrap(4)
            if n == 0 {
                going = Bool.False
            } else {}
        }
        out
    }

    left_pad : List(U8), U64, U8 -> List(U8)
    left_pad = |digits, width, fill|
        if digits.len() >= width {
            digits
        } else {
            List.repeat(fill, width.minus(digits.len())).concat(digits)
        }

    ram_word : List(List(U8)), U32 -> U32
    ram_word = |ram, addr| paged_read(ram, 4, ps1_phys(addr))

    printf_render : List(List(U8)), U32, { a1 : U32, a2 : U32, a3 : U32, sp : U32 } -> List(U8)
    printf_render = |ram, fmt_addr, regs| {
        fmt = read_cstring(ram, fmt_addr)
        vararg = |k|
            match k {
                0 => regs.a1
                1 => regs.a2
                2 => regs.a3
                n => ram_word(ram, regs.sp.plus_wrap(0x10).plus_wrap(n.minus(3).times_wrap(4).to_u32_wrap()))
            }
        var out = []
        var argi = 0.U64
        var i = 0.U64
        while i < fmt.len() {
            ch = fmt.get(i) ?? 0
            if ch != 0x25 { # '%'
                out = out.append(ch)
                i = i.plus(1)
            } else {
                # flags/width: zero-pad + decimal width honored; '-'
                # (left-justify) accepted and treated as plain width
                var j = i.plus(1)
                var fill = 32.U8
                if (fmt.get(j) ?? 0) == 45 { # '-'
                    j = j.plus(1)
                } else {}
                if (fmt.get(j) ?? 0) == 48 { # '0'
                    fill = 48
                    j = j.plus(1)
                } else {}
                var width = 0.U64
                var scanning = Bool.True
                while scanning {
                    d = fmt.get(j) ?? 0
                    if d >= 48 and d <= 57 {
                        width = width.times_wrap(10).plus(d.minus(48).to_u64())
                        j = j.plus(1)
                    } else {
                        scanning = Bool.False
                    }
                }
                if (fmt.get(j) ?? 0) == 45 { # '-' after width (psn00b's %2-d)
                    j = j.plus(1)
                } else {}
                conv = fmt.get(j) ?? 0
                if conv == 0x25 { # %%
                    out = out.append(0x25)
                } else if conv == 100 or conv == 105 { # d i
                    v = vararg(argi)
                    argi = argi.plus(1)
                    body = if v.bitwise_and(0x8000_0000) != 0 { [45.U8].concat(dec_u32(0.U32.minus_wrap(v))) } else { dec_u32(v) }
                    out = out.concat(left_pad(body, width, fill))
                } else if conv == 117 { # u
                    v = vararg(argi)
                    argi = argi.plus(1)
                    out = out.concat(left_pad(dec_u32(v), width, fill))
                } else if conv == 120 or conv == 88 { # x X
                    v = vararg(argi)
                    argi = argi.plus(1)
                    out = out.concat(left_pad(hex_u32(v, conv == 88), width, fill))
                } else if conv == 99 { # c
                    v = vararg(argi)
                    argi = argi.plus(1)
                    out = out.append(v.to_u8_wrap())
                } else if conv == 115 { # s
                    v = vararg(argi)
                    argi = argi.plus(1)
                    out = out.concat(left_pad(read_cstring(ram, v), width, 32))
                } else {
                    # unknown conversion: emit verbatim so it shows in the tty
                    out = out.append(0x25).append(conv)
                }
                i = j.plus(1)
            }
        }
        out
    }

    # handle an A0/B0 kernel call: TTY output captured (putchar/puts and a
    # mini-printf), FlushCache no-ops, everything else recorded loudly in
    # tty_unknown (returns 0). `table` is 0xA0 or 0xB0; args carries
    # a0-a3 and sp for printf varargs.
    kernel_call : Bus, List(List(U8)), U32, U32, { a0 : U32, a1 : U32, a2 : U32, a3 : U32, sp : U32 } -> { bus : Bus, ret : U32 }
    kernel_call = |bus, ram, table, fn, args|
        match bus {
            Ps1(scratch, rest) => {
                is_putchar = (table == 0xA0 and fn == 0x3C) or (table == 0xB0 and fn == 0x3D)
                is_puts = (table == 0xA0 and fn == 0x3E) or (table == 0xB0 and fn == 0x3F)
                is_printf = table == 0xA0 and fn == 0x3F
                is_flush_cache = (table == 0xA0 and fn == 0x44) or (table == 0xA0 and fn == 0x72) # FlushCache / _96_remove: both no-ops here
                is_ccr = (table == 0xB0 and fn == 0x5B) or (table == 0xC0 and fn == 0x0A) # ChangeClearRCnt (both vectors): no-op, VSync self-times-out
                is_hook = table == 0xB0 and fn == 0x19 # HookEntryInt: record the dispatcher jmp_buf
                if is_putchar {
                    { bus: Ps1(scratch, { ..rest, tty: rest.tty.append(args.a0.to_u8_wrap()) }), ret: args.a0 }
                } else if is_puts {
                    { bus: Ps1(scratch, { ..rest, tty: rest.tty.concat(read_cstring(ram, args.a0)) }), ret: 0 }
                } else if is_printf {
                    rendered = printf_render(ram, args.a0, { a1: args.a1, a2: args.a2, a3: args.a3, sp: args.sp })
                    { bus: Ps1(scratch, { ..rest, tty: rest.tty.concat(rendered) }), ret: rendered.len().to_u32_wrap() }
                } else if is_flush_cache {
                    { bus: Ps1(scratch, rest), ret: 0 }
                } else if is_ccr {
                    { bus: Ps1(scratch, rest), ret: 0 }
                } else if is_hook {
                    { bus: Ps1(scratch, dset(rest, 43, args.a0.to_u64())), ret: 0 }
                } else {
                    { bus: Ps1(scratch, { ..rest, tty_unknown: rest.tty_unknown.append(table.to_u64().shl_wrap(32).bitwise_or(fn.to_u64())) }), ret: 0 }
                }
            }

            other => { bus: other, ret: 0 }
        }

    # harness accessors
    tty_bytes : Bus -> List(U8)
    tty_bytes = |bus|
        match bus {
            Ps1(_, rest) => rest.tty
            _ => []
        }

    tty_unknown_calls : Bus -> List({ table : U32, fn : U32 })
    tty_unknown_calls = |bus|
        match bus {
            Ps1(_, rest) =>
                rest.tty_unknown.fold([], |acc, packed|
                    acc.append({ table: packed.shr_zf_wrap(32).to_u32_wrap(), fn: packed.to_u32_wrap() }))

            _ => []
        }

    # interrupt controller line: any unmasked source pending?
    irq2 : Bus -> Bool
    irq2 = |bus|
        match bus {
            Ps1(_, rest) => rest.i_stat.bitwise_and(rest.i_mask) != 0

            _ => Bool.False
        }

    # raise an interrupt source (device changes and expects)
    raise_irq : Bus, U8 -> Bus
    raise_irq = |bus, bit|
        match bus {
            Ps1(scratch, rest) => Ps1(scratch, { ..rest, i_stat: rest.i_stat.bitwise_or(U32.shl_wrap(1, bit)) })

            other => other
        }
}

# Vector: fetch at base returns the opcode; reads serve by ordinal;
# only writes trace in the bus (fetch/read entries are synthesized by
# the vector runner from the step's intent fields)
expect {
    b0 = Bus.vector(0xDEAD_BEEF, 0x1000, [0x11, 0x22])
    f = b0.fetch_val([], 0x1000, 0)
    r1 = b0.read_val([], 4, 0x2000, 0, 0)
    r2 = b0.read_val([], 1, 0x3001, 1, 0)
    w = b0.write(2, 0x4002, 0x5566, 0)
    f.val == 0xDEAD_BEEF
    and r1.val == 0x11
    and r2.val == 0x22
    and w.trace() == [
        { kind: 2, size: 2, addr: 0x4002, val: 0x5566 },
    ]
}

# Flat: reads serve the external paged RAM at every size, zero cost
expect {
    b0 = Bus.flat({})
    page0 = List.repeat(0, 0x1000)
    page = ((((page0.set(4, 0xDD) ?? page0).set(5, 0xCC) ?? page0).set(6, 0xBB) ?? page0).set(7, 0xAA) ?? page0).set(12, 0x99) ?? page0
    ram = [page]
    r4 = b0.read_val(ram, 4, 4, 0, 0)
    r2 = b0.read_val(ram, 2, 6, 0, 0)
    r1 = b0.read_val(ram, 1, 12, 0, 0)
    r4.val == 0xAABB_CCDD and r2.val == 0xAABB and r1.val == 0x99 and r4.cost == 0
}

# Ps1: the three segments alias one RAM (external, read via the ram arg);
# scratchpad hides from KSEG1
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    page0 = List.repeat(0, 0x1000)
    page = (((page0.set(0x100, 0xBE) ?? page0).set(0x101, 0xBA) ?? page0).set(0x102, 0xFE) ?? page0).set(0x103, 0xCA) ?? page0
    ram = [page]
    k0 = b0.read_val(ram, 4, 0x8000_0100, 0, 0)
    k1 = b0.read_val(ram, 4, 0xA000_0100, 0, 0)
    sp = b0.write(4, 0x1F80_0010, 0x1234_5678, 0)
    sp_read = sp.read_val(ram, 4, 0x1F80_0010, 0, 0)
    sp_kseg1 = sp.read_val(ram, 4, 0xBF80_0010, 0, 0)
    k0.val == 0xCAFE_BABE and k1.val == 0xCAFE_BABE
    and sp_read.val == 0x1234_5678
    and sp_kseg1.val == 0
}

# Ps1: BIOS window is read-only and serves the image
expect {
    bios = (List.repeat(0, 512).set(0, 0x77) ?? List.repeat(0, 512))
    b0 = Bus.ps1(bios, Bool.False)
    r0 = b0.read_val([], 1, 0xBFC0_0000, 0, 0)
    w = b0.write(4, 0xBFC0_0000, 0xDEAD_BEEF, 0)
    r1 = w.read_val([], 1, 0xBFC0_0000, 0, 0)
    r0.val.bitwise_and(0xFF) == 0x77 and r1.val.bitwise_and(0xFF) == 0x77
}

# Ps1: wait costs — RAM charges, scratchpad does not, BIOS word costs most
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    ram = b0.read_val([], 4, 0x0000_0000, 0, 0)
    scr = b0.read_val([], 4, 0x1F80_0000, 0, 0)
    bio = b0.read_val([], 4, 0x1FC0_0000, 0, 0)
    io = b0.read_val([], 4, 0x1F80_1070, 0, 0)
    ram.cost == Bus.wait_ram and scr.cost == 0 and bio.cost == Bus.wait_bios_word and io.cost == Bus.wait_io
}

# Ps1: I_STAT acknowledge semantics and the irq2 line
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    raised = b0.raise_irq(2).raise_irq(4)
    masked = raised.write(4, 0x1F80_1074, 0x0004, 0) # unmask bit 2 only
    before = masked.irq2()
    acked = masked.write(4, 0x1F80_1070, 0xFFFF_FFFB, 0) # clear bit 2
    after = acked.irq2()
    stat = acked.read_val([], 4, 0x1F80_1070, 0, 0)
    before and after == Bool.False and stat.val == 0x0010 # bit 4 survives, still masked off
}

# Ps1: kernel putchar/puts capture, unknown recorded loudly
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.True)
    ram = [List.repeat(0, 0x400).concat("hi".to_utf8().append(0))]
    k1 = b0.kernel_call(ram, 0xB0, 0x3D, { a0: 65, a1: 0, a2: 0, a3: 0, sp: 0 }) # putchar 'A'
    k2 = k1.bus.kernel_call(ram, 0xA0, 0x3E, { a0: 0x0000_0400, a1: 0, a2: 0, a3: 0, sp: 0 }) # puts "hi"
    k3 = k2.bus.kernel_call(ram, 0xA0, 0x99, { a0: 0, a1: 0, a2: 0, a3: 0, sp: 0 })
    k3.bus.tty_bytes() == [65, 104, 105]
    and k3.bus.tty_unknown_calls() == [{ table: 0xA0, fn: 0x99 }]
}

# Ps1: mini-printf renders %d/%08x/%s/%c/%% with o32 varargs (4th+ on
# the stack); FlushCache no-ops without touching the unknown ledger
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.True)
    fmt = "v=%d h=%08x s=%s c=%c p=%% t=%u\n".to_utf8().append(0)
    page = List.repeat(0, 0x100)
        .concat(fmt)
        .concat(List.repeat(0, 0x200.U64.minus(0x100).minus(fmt.len())))
        .concat("ok".to_utf8().append(0))
    ram = [page.concat(List.repeat(0, 0x1000.U64.minus(page.len())))]
    # 6 conversions: a1=-2, a2=0xBEEF, a3=0x200 (str), stack: c, u
    sp = 0x300.U32
    ram2 = [((((((((ram.get(0) ?? []).set(0x310, 65) ?? []).set(0x311, 0) ?? []).set(0x312, 0) ?? []).set(0x313, 0) ?? []).set(0x314, 7) ?? []).set(0x315, 0) ?? []).set(0x316, 0) ?? []).set(0x317, 0) ?? []]
    k = b0.kernel_call(ram2, 0xA0, 0x3F, { a0: 0x100, a1: 0xFFFF_FFFE, a2: 0xBEEF, a3: 0x200, sp: sp })
    f = k.bus.kernel_call(ram2, 0xA0, 0x44, { a0: 0, a1: 0, a2: 0, a3: 0, sp: 0 })
    (Str.from_utf8(f.bus.tty_bytes()) ?? "") == "v=-2 h=0000beef s=ok c=A p=% t=7\n"
    and f.bus.tty_unknown_calls() == []
}

# Timers: sysclock counting derives from the clock; MODE write resets;
# VAL write re-bases; sysclock/8 divides; target-reset mode wraps early
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    t = b0.write(2, 0x1F80_1124, 0x0000, 100) # timer2 MODE: sysclock, free-run (reset at clock 100)
    v1 = t.read_val([], 2, 0x1F80_1120, 0, 350) # 250 cycles later
    v2 = t.read_val([], 2, 0x1F80_1120, 0, 100.plus(0x12345)) # wraps at 0x10000
    tb = t.write(2, 0x1F80_1120, 0x4000, 200) # VAL write re-bases to 0x4000 at clock 200
    v3 = tb.read_val([], 2, 0x1F80_1120, 0, 210)
    t8 = b0.write(2, 0x1F80_1124, 0x0200, 0) # timer2 MODE: sysclock/8
    v8 = t8.read_val([], 2, 0x1F80_1120, 0, 800)
    tr = b0.write(2, 0x1F80_1108, 100, 0) # timer0 TARGET=100
    tr2 = tr.write(2, 0x1F80_1104, 0x0008, 0) # timer0 MODE: reset-at-target, sysclock
    vr = tr2.read_val([], 2, 0x1F80_1100, 0, 250) # 250 ticks, period 101 -> 48
    v1.val == 250 and v2.val == 0x2345 and v3.val == 0x400A and v8.val == 100 and vr.val == 48
}

# Timer TARGET write settles the live count (phase preserved)
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    t = b0.write(2, 0x1F80_1124, 0x0000, 0) # timer2 sysclock from 0
    t2 = t.write(2, 0x1F80_1128, 0x8000, 500) # TARGET write at clock 500 settles base=500
    v = t2.read_val([], 2, 0x1F80_1120, 0, 700)
    v.val == 700
}

# MODE read shows reached-target once passed; the ack (console-applied)
# clears it; a later read is clear until the next pass. 0xFFFF flag too.
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    t = b0.write(2, 0x1F80_1128, 100, 0).write(2, 0x1F80_1124, 0x0000, 0) # target 100 (already set), MODE resets counter
    m1 = t.read_val([], 2, 0x1F80_1124, 0, 250) # passed 100 -> bit 11
    acked = t.timer_ack(0x1F80_1124, 250)
    m2 = acked.read_val([], 2, 0x1F80_1124, 0, 260) # window reset -> clear
    v = acked.read_val([], 2, 0x1F80_1120, 0, 260) # count preserved through ack
    tf = b0.write(2, 0x1F80_1124, 0x0000, 0).write(2, 0x1F80_1120, 0xFFF0, 1000) # VAL near wrap
    mf = tf.read_val([], 2, 0x1F80_1124, 0, 1000.plus(0x0F)) # reached 0xFFFF
    m1.val.bitwise_and(0x0800) != 0
    and m2.val.bitwise_and(0x0800) == 0
    and v.val == 260
    and mf.val.bitwise_and(0x1000) != 0
}

# Timer IRQ machinery: repeat mode fires each period (harvest raises
# I_STAT and re-schedules); one-shot fires exactly once until a MODE
# rewrite re-arms it
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    rep = b0.write(2, 0x1F80_1128, 100, 0).write(2, 0x1F80_1124, 0x0058, 0) # target 100, reset-at-target, IRQ-at-target, repeat
    at1 = rep.next_timer_event(0)
    h1 = rep.timer_harvest(at1)
    at2 = h1.next_timer_event(at1)
    h2 = h1.write(4, 0x1F80_1070, 0, at1).timer_harvest(at2) # ack I_STAT, next period fires again
    one = b0.write(2, 0x1F80_1128, 50, 0).write(2, 0x1F80_1124, 0x0018, 0) # one-shot IRQ-at-target
    oat = one.next_timer_event(0)
    oh = one.timer_harvest(oat)
    oat2 = oh.next_timer_event(oat)
    at1 == 100
    and h1.read_val([], 4, 0x1F80_1070, 0, at1).val.bitwise_and(0x40) != 0 # timer2 -> I_STAT bit 6
    and at2 == 201
    and h2.read_val([], 4, 0x1F80_1070, 0, at2).val.bitwise_and(0x40) != 0
    and oat == 50
    and oh.read_val([], 4, 0x1F80_1070, 0, oat).val.bitwise_and(0x40) != 0
    and oat2 == Bus.never
}

# DMA registers: MADR masks to 24 bits, CHCR/BCR round-trip, DPCR resets
# to 0x07654321, DICR flags are write-1-to-clear with computed bit 31
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    w = b0.write(4, 0x1F80_10E0, 0xFF12_3456, 0) # D6 MADR
        .write(4, 0x1F80_10E4, 0x0000_0400, 0) # D6 BCR
        .write(4, 0x1F80_10E8, 0x1100_0002, 0) # D6 CHCR
    madr = w.read_val([], 4, 0x1F80_10E0, 0, 0)
    bcr = w.read_val([], 4, 0x1F80_10E4, 0, 0)
    chcr = w.read_val([], 4, 0x1F80_10E8, 0, 0)
    dpcr0 = b0.read_val([], 4, 0x1F80_10F0, 0, 0)
    di = b0.write(4, 0x1F80_10F4, 0x00FF_0000, 0) # enable all channel IRQs + master
    di_rd = di.read_val([], 4, 0x1F80_10F4, 0, 0)
    madr.val == 0x0012_3456
    and bcr.val == 0x0000_0400
    and chcr.val == 0x1100_0002
    and dpcr0.val == 0x0765_4321
    and di_rd.val == 0x00FF_0000
}

# Timer 2 sync modes 0/3 stop the counter; 1/2 free-run
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    stopped = b0.write(2, 0x1F80_1124, 0x0001, 0) # sync on, mode 0
    frozen = stopped.read_val([], 2, 0x1F80_1120, 0, 5000)
    freerun = b0.write(2, 0x1F80_1124, 0x0003, 0) # sync on, mode 1
    live = freerun.read_val([], 2, 0x1F80_1120, 0, 5000)
    frozen.val == 0 and live.val == 5000
}
