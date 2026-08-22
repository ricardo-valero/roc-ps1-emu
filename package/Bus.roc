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
    joy_ctrl : U32, # SIO0 control echo — enough for pad-init polls
    joy_seq : U32, # position within the current pad exchange
    joy_xact : U32, # completed-exchange counter (drives scripted button edges)
    joy_rx : U32, # response byte for the last TX (digital pad, no buttons)
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
            joy_ctrl: 0,
            joy_seq: 0,
            joy_xact: 0,
            joy_rx: 0xFF,
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

    # wait-state cycles charged ON TOP of the instruction (psx-spx memory
    # timings; BIOS is on the default 8-bit bus). CALIBRATION: judged by
    # ps1-tests cpu/access-time — revisit these together, not singly.
    wait_ram : U64
    wait_ram = 4
    wait_bios_word : U64
    wait_bios_word = 23
    wait_bios_half : U64
    wait_bios_half = 11
    wait_bios_byte : U64
    wait_bios_byte = 5
    wait_io : U64
    wait_io = 2

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

    # non-memory Ps1 writes (I/O registers, KSEG2); RAM/scratchpad stores
    # are handled INLINE in write_go — see the shape note at the top
    rest_write : Ps1Rest, U32, U32 -> Ps1Rest
    rest_write = |rest, addr, val|
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
                seq = if val.bitwise_and(1) == 0 { 0 } else { rest.joy_seq }
                { ..rest, joy_ctrl: val.bitwise_and(0xFFFF), joy_seq: seq }
            } else if phys == 0x1F80_1040 {
                # emulated digital pad: 0x01 -> hi-z, 0x42 -> 0x41, tap ->
                # 0x5A, motor bytes -> switch state (0xFF = none pressed)
                # scripted input: START pressed on exchanges 5-8 then
                # released — the menu launches on the release edge
                pressed = rest.joy_xact >= 5 and rest.joy_xact < 9
                rx =
                    if rest.joy_seq == 1 {
                        0x41.U32
                    } else if rest.joy_seq == 2 {
                        0x5A.U32
                    } else if rest.joy_seq == 3 and pressed {
                        0xF7 # swlo with START down (active low)
                    } else {
                        0xFF
                    }
                xact = if rest.joy_seq == 4 { rest.joy_xact.plus_wrap(1) } else { rest.joy_xact }
                { ..rest, joy_seq: rest.joy_seq.plus_wrap(1), joy_xact: xact, joy_rx: rx }
            } else {
                rest # BIOS window, expansion, other I/O: swallowed
            }
        }


    # Reads NEVER return the bus: the { bus, val, cost } record-return
    # shape marks the union shared and taxes every step with refcount and
    # copy traffic (measured; see the perf notes). The Vector variant's
    # fetch/read trace is synthesized by the vector RUNNER from the step's
    # read-intent fields instead — only writes still record into the bus.
    fetch_val : Bus, List(List(U8)), U32 -> { val : U32, cost : U64 }
    fetch_val = |bus, ram, addr|
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
                    .bitwise_or(rest.joy_rx.bitwise_and(m_jd))
                    .bitwise_or(0x7.U32.bitwise_and(m_js))
                    .bitwise_or(rest.joy_ctrl.bitwise_and(m_jc))
                cost = 4.U64.bitwise_and(m_ram.to_u64())
                    .bitwise_or(23.U64.bitwise_and(m_bios.to_u64()))
                    .bitwise_or(2.U64.bitwise_and(m_io.to_u64()))
                { val: val, cost: cost }
            }
        }

    read_val : Bus, List(List(U8)), U8, U32, U64 -> { val : U32, cost : U64 }
    read_val = |bus, ram, size, addr, k|
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
                m_gs = zero_mask(phys.bitwise_xor(0x1F80_1814)) # GPUSTAT stub: always ready (bits 26/27/28), no GPU yet
                m_jd = zero_mask(phys.bitwise_xor(0x1F80_1040)) # JOY_DATA: digital-pad response byte
                m_js = zero_mask(phys.bitwise_xor(0x1F80_1044)) # JOY_STAT: TX ready/finished
                m_jc = zero_mask(phys.bitwise_xor(0x1F80_104A)) # JOY_CTRL echoes writes
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
                    .bitwise_or(rest.joy_rx.bitwise_and(m_jd))
                    .bitwise_or(0x7.U32.bitwise_and(m_js))
                    .bitwise_or(rest.joy_ctrl.bitwise_and(m_jc))
                cost = 4.U64.bitwise_and(m_ram.to_u64())
                    .bitwise_or(23.U64.bitwise_and(m_bios.to_u64()))
                    .bitwise_or(2.U64.bitwise_and(m_io.to_u64()))
                { val: val, cost: cost }
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
    write : Bus, U8, U32, U32 -> Bus
    write = |bus, size, addr, val|
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
                    Ps1(scratch, rest_write(rest, addr, val))
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
                # flags/width: only zero-pad + decimal width honored
                var j = i.plus(1)
                var fill = 32.U8
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
                is_flush_cache = table == 0xA0 and fn == 0x44
                if is_putchar {
                    { bus: Ps1(scratch, { ..rest, tty: rest.tty.append(args.a0.to_u8_wrap()) }), ret: args.a0 }
                } else if is_puts {
                    { bus: Ps1(scratch, { ..rest, tty: rest.tty.concat(read_cstring(ram, args.a0)) }), ret: 0 }
                } else if is_printf {
                    rendered = printf_render(ram, args.a0, { a1: args.a1, a2: args.a2, a3: args.a3, sp: args.sp })
                    { bus: Ps1(scratch, { ..rest, tty: rest.tty.concat(rendered) }), ret: rendered.len().to_u32_wrap() }
                } else if is_flush_cache {
                    { bus: Ps1(scratch, rest), ret: 0 }
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
    f = b0.fetch_val([], 0x1000)
    r1 = b0.read_val([], 4, 0x2000, 0)
    r2 = b0.read_val([], 1, 0x3001, 1)
    w = b0.write(2, 0x4002, 0x5566)
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
    r4 = b0.read_val(ram, 4, 4, 0)
    r2 = b0.read_val(ram, 2, 6, 0)
    r1 = b0.read_val(ram, 1, 12, 0)
    r4.val == 0xAABB_CCDD and r2.val == 0xAABB and r1.val == 0x99 and r4.cost == 0
}

# Ps1: the three segments alias one RAM (external, read via the ram arg);
# scratchpad hides from KSEG1
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    page0 = List.repeat(0, 0x1000)
    page = (((page0.set(0x100, 0xBE) ?? page0).set(0x101, 0xBA) ?? page0).set(0x102, 0xFE) ?? page0).set(0x103, 0xCA) ?? page0
    ram = [page]
    k0 = b0.read_val(ram, 4, 0x8000_0100, 0)
    k1 = b0.read_val(ram, 4, 0xA000_0100, 0)
    sp = b0.write(4, 0x1F80_0010, 0x1234_5678)
    sp_read = sp.read_val(ram, 4, 0x1F80_0010, 0)
    sp_kseg1 = sp.read_val(ram, 4, 0xBF80_0010, 0)
    k0.val == 0xCAFE_BABE and k1.val == 0xCAFE_BABE
    and sp_read.val == 0x1234_5678
    and sp_kseg1.val == 0
}

# Ps1: BIOS window is read-only and serves the image
expect {
    bios = (List.repeat(0, 512).set(0, 0x77) ?? List.repeat(0, 512))
    b0 = Bus.ps1(bios, Bool.False)
    r0 = b0.read_val([], 1, 0xBFC0_0000, 0)
    w = b0.write(4, 0xBFC0_0000, 0xDEAD_BEEF)
    r1 = w.read_val([], 1, 0xBFC0_0000, 0)
    r0.val.bitwise_and(0xFF) == 0x77 and r1.val.bitwise_and(0xFF) == 0x77
}

# Ps1: wait costs — RAM charges, scratchpad does not, BIOS word costs most
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    ram = b0.read_val([], 4, 0x0000_0000, 0)
    scr = b0.read_val([], 4, 0x1F80_0000, 0)
    bio = b0.read_val([], 4, 0x1FC0_0000, 0)
    io = b0.read_val([], 4, 0x1F80_1070, 0)
    ram.cost == Bus.wait_ram and scr.cost == 0 and bio.cost == Bus.wait_bios_word and io.cost == Bus.wait_io
}

# Ps1: I_STAT acknowledge semantics and the irq2 line
expect {
    b0 = Bus.ps1(List.repeat(0, 512), Bool.False)
    raised = b0.raise_irq(2).raise_irq(4)
    masked = raised.write(4, 0x1F80_1074, 0x0004) # unmask bit 2 only
    before = masked.irq2()
    acked = masked.write(4, 0x1F80_1070, 0xFFFF_FFFB) # clear bit 2
    after = acked.irq2()
    stat = acked.read_val([], 4, 0x1F80_1070, 0)
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
