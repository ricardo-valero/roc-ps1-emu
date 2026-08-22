import /Bus
import /Cpu

# PS-X EXE sideloading: parse the 2 KB header, blit the text section into
# RAM, and seed the CPU registers — the whole on-console test corpus
# (Amidog, ps1-tests) is PS-EXEs, so this is the harness's front door.
# Header (little-endian): "PS-X EXE" magic, initial PC at 0x10, GP at
# 0x14, text address/size at 0x18/0x1C, stack base/offset at 0x30/0x34;
# the text image starts at file offset 0x800.
Exe :: [].{
    u32le : List(U8), U64 -> U32
    u32le = |b, i|
        (b.get(i) ?? 0).to_u32()
            .bitwise_or((b.get(i.plus(1)) ?? 0).to_u32().shl_wrap(8))
            .bitwise_or((b.get(i.plus(2)) ?? 0).to_u32().shl_wrap(16))
            .bitwise_or((b.get(i.plus(3)) ?? 0).to_u32().shl_wrap(24))

    parse : List(U8) -> Try({ pc : U32, gp : U32, sp : U32, text_addr : U32, text : List(U8) }, [NotAPsExe, ..])
    parse = |bytes| {
        magic = bytes.sublist({ start: 0, len: 8 })
        if magic != "PS-X EXE".to_utf8() {
            Err(NotAPsExe)
        } else {
            text_size = u32le(bytes, 0x1C).to_u64()
            sp_base = u32le(bytes, 0x30)
            sp_off = u32le(bytes, 0x34)
            Ok({
                pc: u32le(bytes, 0x10),
                gp: u32le(bytes, 0x14),
                sp: if sp_base == 0 { 0x801F_FF00 } else { sp_base.plus_wrap(sp_off) },
                text_addr: u32le(bytes, 0x18),
                text: bytes.sublist({ start: 0x800, len: text_size }),
            })
        }
    }

    # splice the text into a fresh flat image, repage it, seed the CPU
    load : Bus, List(U8) -> Try({ cpu : Cpu, bus : Bus, ram : List(List(U8)) }, [NotAPsExe, ..])
    load = |bus, bytes| {
        e = parse(bytes)?
        base = e.text_addr.bitwise_and(0x1F_FFFF).to_u64()
        flat0 = List.repeat(0, 0x200000)
        before = flat0.sublist({ start: 0, len: base })
        after = flat0.sublist({ start: base.plus(e.text.len()), len: flat0.len().minus(base).minus(e.text.len()) })
        flat = before.concat(e.text).concat(after)
        var pages = []
        var p = 0.U64
        while p < 0x200 {
            pages = pages.append(flat.sublist({ start: p.times_wrap(0x1000), len: 0x1000 }))
            p = p.plus(1)
        }
        c0 = Cpu.init(e.pc)
        c1 = Cpu.set_r(c0, 28, e.gp)
        c2 = Cpu.set_r(c1, 29, e.sp)
        c3 = Cpu.set_r(c2, 30, e.sp)
        Ok({ cpu: c3, bus: bus, ram: pages })
    }
}

# hand-built EXE round-trips through parse/load
expect {
    header0 = "PS-X EXE".to_utf8().concat(List.repeat(0, 0x800 - 8))
    put32 = |h, off, v| {
        h1 = h.set(off, U32.bitwise_and(v, 0xFF).to_u8_wrap()) ?? h
        h2 = h1.set(off.plus(1), U32.shr_zf_wrap(v, 8).to_u8_wrap()) ?? h1
        h3 = h2.set(off.plus(2), U32.shr_zf_wrap(v, 16).to_u8_wrap()) ?? h2
        h3.set(off.plus(3), U32.shr_zf_wrap(v, 24).to_u8_wrap()) ?? h3
    }
    header = put32(put32(put32(put32(put32(header0, 0x10, 0x8001_0000), 0x14, 0x8009_0000), 0x18, 0x8001_0000), 0x1C, 4), 0x30, 0x801F_F000)
    file = header.concat([0x0D, 0xC0, 0xDE, 0x24]) # one word of text
    bus = Bus.ps1(List.repeat(0, 512), Bool.False)
    match Exe.load(bus, file) {
        Ok(r) => {
            word = r.bus.read_val(r.ram, 4, 0x8001_0000, 0)
            r.cpu.pc == 0x8001_0000
            and Cpu.get(r.cpu, 28) == 0x8009_0000
            and Cpu.get(r.cpu, 29) == 0x801F_F000
            and word.val == 0x24DE_C00D
        }

        Err(_) => Bool.False
    }
}

expect Exe.parse([1, 2, 3]) == Err(NotAPsExe)
