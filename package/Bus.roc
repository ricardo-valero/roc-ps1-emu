# The CPU's memory surface. Two variants for now (the PS1 memory map
# arrives with the bus change):
#
#   Vector — replay bus for the SingleStepTests harness: the fetch at the
#   test's base address returns the opcode, data reads pop the vector's
#   documented values in order, and every access is recorded in an ordered
#   trace of (kind, size, addr, val) for the runner to diff. Kind: 0 =
#   instruction fetch, 1 = data read, 2 = write (upstream's actions 4/1/2).
#
#   Flat — little-endian byte RAM for the bench and expects; the address
#   wraps by the (power-of-two) RAM length.
Bus := [
    Vector({ opcode : U32, base : U32, reads : List(U32), ri : U64, trace : List({ kind : U8, size : U8, addr : U32, val : U32 }) }),
    Flat(List(U8)),
].{
    vector : U32, U32, List(U32) -> Bus
    vector = |opcode, base, reads| Vector({ opcode: opcode, base: base, reads: reads, ri: 0, trace: [] })

    flat : List(U8) -> Bus
    flat = |mem| Flat(mem)

    flat_index : List(U8), U32 -> U64
    flat_index = |mem, addr| addr.to_u64().bitwise_and(mem.len().minus(1))

    flat_read : List(U8), U8, U32 -> U32
    flat_read = |mem, size, addr| {
        b0 = (mem.get(flat_index(mem, addr)) ?? 0).to_u32()
        b1 = (mem.get(flat_index(mem, addr.plus_wrap(1))) ?? 0).to_u32()
        b2 = (mem.get(flat_index(mem, addr.plus_wrap(2))) ?? 0).to_u32()
        b3 = (mem.get(flat_index(mem, addr.plus_wrap(3))) ?? 0).to_u32()
        match size {
            1 => b0
            2 => b0.bitwise_or(b1.shl_wrap(8))
            _ => b0.bitwise_or(b1.shl_wrap(8)).bitwise_or(b2.shl_wrap(16)).bitwise_or(b3.shl_wrap(24))
        }
    }

    fetch32 : Bus, U32 -> { bus : Bus, val : U32 }
    fetch32 = |bus, addr|
        match bus {
            Vector(v) => {
                val = if addr == v.base { v.opcode } else { addr }
                { bus: Vector({ ..v, trace: v.trace.append({ kind: 0, size: 4, addr: addr, val: val }) }), val: val }
            }

            Flat(mem) => { bus: bus, val: flat_read(mem, 4, addr) }
        }

    read : Bus, U8, U32 -> { bus : Bus, val : U32 }
    read = |bus, size, addr|
        match bus {
            Vector(v) => {
                val = v.reads.get(v.ri) ?? 0
                { bus: Vector({ ..v, ri: v.ri.plus(1), trace: v.trace.append({ kind: 1, size: size, addr: addr, val: val }) }), val: val }
            }

            Flat(mem) => { bus: bus, val: flat_read(mem, size, addr) }
        }

    write : Bus, U8, U32, U32 -> Bus
    write = |bus, size, addr, val|
        match bus {
            Vector(v) => Vector({ ..v, trace: v.trace.append({ kind: 2, size: size, addr: addr, val: val }) })
            Flat(mem) => {
                m1 = mem.set(flat_index(mem, addr), val.to_u8_wrap()) ?? mem
                m2 = if size >= 2 { m1.set(flat_index(m1, addr.plus_wrap(1)), val.shr_zf_wrap(8).to_u8_wrap()) ?? m1 } else { m1 }
                m3 = if size >= 3 { m2.set(flat_index(m2, addr.plus_wrap(2)), val.shr_zf_wrap(16).to_u8_wrap()) ?? m2 } else { m2 }
                m4 = if size >= 4 { m3.set(flat_index(m3, addr.plus_wrap(3)), val.shr_zf_wrap(24).to_u8_wrap()) ?? m3 } else { m3 }
                Flat(m4)
            }
        }

    trace : Bus -> List({ kind : U8, size : U8, addr : U32, val : U32 })
    trace = |bus|
        match bus {
            Vector(v) => v.trace
            Flat(_) => []
        }
}

# Vector: fetch at base returns the opcode; reads pop in order; all traced
expect {
    b0 = Bus.vector(0xDEAD_BEEF, 0x1000, [0x11, 0x22])
    f = b0.fetch32(0x1000)
    r1 = f.bus.read(4, 0x2000)
    r2 = r1.bus.read(1, 0x3001)
    w = r2.bus.write(2, 0x4002, 0x5566)
    f.val == 0xDEAD_BEEF
    and r1.val == 0x11
    and r2.val == 0x22
    and w.trace() == [
        { kind: 0, size: 4, addr: 0x1000, val: 0xDEAD_BEEF },
        { kind: 1, size: 4, addr: 0x2000, val: 0x11 },
        { kind: 1, size: 1, addr: 0x3001, val: 0x22 },
        { kind: 2, size: 2, addr: 0x4002, val: 0x5566 },
    ]
}

# Flat: little-endian round-trips at every size
expect {
    b0 = Bus.flat(List.repeat(0, 16))
    b1 = b0.write(4, 4, 0xAABB_CCDD).write(1, 12, 0x99)
    r4 = b1.read(4, 4)
    r2 = r4.bus.read(2, 6)
    r1 = r2.bus.read(1, 12)
    r4.val == 0xAABB_CCDD and r2.val == 0xAABB and r1.val == 0x99
}
