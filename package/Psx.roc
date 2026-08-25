import /Bus
import /Cpu
import /Dma

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

    # run the console for `budget` instructions
    run : Cpu, Bus, List(List(U8)), U64 -> { cpu : Cpu, bus : Bus, ram : List(List(U8)), steps : U64 }
    run = |cpu0, bus0, ram0, budget| {
        var cpu = cpu0
        var bus = bus0
        var ram = ram0
        var k = 0.U64
        var next_vblank = ntsc_frame_cycles
        var next_tirq = Bus.next_timer_event(bus0, 0)
        var irq_lvl = Bool.False
        var going = Bool.True
        while going {
            r = Cpu.step(cpu, bus, ram)
            cpu = r.cpu
            bus = r.bus
            if r.st1_size != 0 {
                ram = Cpu.store_ram(ram, r.st1_size, r.st1_addr, r.st1_val)
                ram = Cpu.store_ram(ram, r.st2_size, r.st2_addr, r.st2_val)
                # a write into the timer registers moves the schedule
                wphys = r.st1_addr.bitwise_and(0x1FFF_FFFF)
                if wphys >= 0x1F80_1100 and wphys < 0x1F80_1130 {
                    next_tirq = Bus.next_timer_event(bus, cpu.cycles)
                } else {}
                # a CHCR/DPCR write can start a transfer: OTC (channel 6)
                # runs atomically on the pages; device channels are LOUD
                # until their device changes land
                if wphys >= 0x1F80_1080 and wphys < 0x1F80_10F8 {
                    kick = Bus.dma_kick_info(bus, wphys)
                    if kick.go {
                        if kick.ch == 6 {
                            ram = Dma.otc_run(ram, kick.madr, kick.bcr)
                            bus = Bus.dma_complete(bus, 6, Dma.otc_end_madr(kick.madr, kick.bcr))
                            cpu = { ..cpu, cycles: cpu.cycles.plus(Dma.otc_words(kick.bcr)) }
                        } else if kick.ch == 2 {
                            # GPU channel: no device yet, but the psn00b
                            # framework screen-clears through it in every
                            # test — swallow-complete, ledger a WARNING
                            # (0xDA:2); nothing gated flows through it
                            bus = Bus.dma_complete(Bus.dma_unhandled(bus, 2), 2, kick.madr)
                        } else {
                            bus = Bus.dma_unhandled(bus, kick.ch)
                        }
                    } else {}
                } else {}
            } else {}
            if r.ack_addr != 0 {
                bus = bus.timer_ack(r.ack_addr, cpu.cycles)
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
                going = Bool.False
            } else {}
        }
        { cpu: cpu, bus: bus, ram: ram, steps: k }
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
    out = Psx.run(cpu0, bus0, [page], 4)
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
    out = Psx.run(cpu, bus, [page], 120)
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
    out = Psx.run(cpu0, bus_on, [page], 8)
    term = out.bus.read_val(out.ram, 4, 0x1F4, 0, 0)
    e1 = out.bus.read_val(out.ram, 4, 0x200, 0, 0)
    chcr = out.bus.read_val([], 4, 0x1F80_10E8, 0, 0)
    madr = out.bus.read_val([], 4, 0x1F80_10E0, 0, 0)
    # DPCR at reset leaves every channel disabled: same program, no transfer
    out2 = Psx.run(cpu0, bus0, [page], 8)
    e2 = out2.bus.read_val(out2.ram, 4, 0x200, 0, 0)
    # device channel (2) started: loud
    cpu_dev = Cpu.set_r(cpu0, 1, 0x1F80_0000.minus_wrap(0x60)) # r1 + 0x10E0 -> 0x1F801080+... shift base so stores hit D2
    out3 = Psx.run(Cpu.set_r(cpu_dev, 4, 0x1100_0000), bus_on, [page], 5) # one loop pass = one start = one loud entry
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
    out = Psx.run(cpu, bus, [page], 6)
    dicr = out.bus.read_val([], 4, 0x1F80_10F4, 0, 0)
    stat = out.bus.read_val([], 4, 0x1F80_1070, 0, 0)
    dicr.val.bitwise_and(0x4000_0000) != 0 # ch6 flag
    and dicr.val.bitwise_and(0x8000_0000) != 0 # computed master flag
    and stat.val.bitwise_and(8) != 0
    and out.cpu.cause.bitwise_and(0x7C) == 0 # took the interrupt, excode 0
    and out.cpu.pc >= 0x8000_0080 # vectored
}
