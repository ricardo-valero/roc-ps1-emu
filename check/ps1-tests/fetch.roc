# Verify the ps1-tests EXEs and vendored hardware logs against pinned
# SHA-256 hashes. Upstream ships tests.zip (DEFLATE — pure Roc cannot
# extract), so the EXEs are a verify-only step like the amidog slice;
# the psx.log hardware references are small text files vendored in the
# repo and pinned here against drift.
#
#   curl -LO https://github.com/JaCzekanski/ps1-tests/releases/download/build-158/tests.zip
#     (zip pin: 5de0e82854c1a511697a7ade381c2d778ec4b2fff4a7d7ac79e8098c35eb859b)
#   unzip tests.zip 'cpu/access-time/*' 'timers/*' 'dma/*' 'gpu/*' -d /tmp/ps1tests
#   cp /tmp/ps1tests/cpu/access-time/access-time.exe check/ps1-tests/data/
#   cp /tmp/ps1tests/timers/timers.exe check/ps1-tests/data/
#   cp /tmp/ps1tests/dma/otc-test/otc-test.exe check/ps1-tests/data/
#   (and the gpu/* EXEs the same way)
#   cp /tmp/ps1tests/gte/test-all/test-all.exe check/ps1-tests/data/
#   cp /tmp/ps1tests/gte/test-all/psx.log check/ps1-tests/data/test-all.psx.log
#   cp /tmp/ps1tests/cpu/cop/cop.exe check/ps1-tests/data/
#   cp /tmp/ps1tests/cpu/cop/psx.log check/ps1-tests/data/cop.psx.log
#   cp /tmp/ps1tests/gte-fuzz/gte_valid_0xc0ffee_50.log check/gte-fuzz/data/
#
#   VRAM references convert once from the upstream vram.png captures:
#   python3 check/ps1-tests/convert-vram.py <src>/vram.png data/<name>.vram
#
#   roc build check/ps1-tests/fetch.roc --output=/tmp/pt_fetch && /tmp/pt_fetch
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
    chk: "../lib/main.roc",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import chk.Sha256

data_dir : Str
data_dir = "check/ps1-tests/data"

files : List({ name : Str, sha256 : Str })
files = [
    { name: "access-time.exe", sha256: "09cd64de3207b99ef73a3670fdad21bdeba25ba058a7e22ef1a032a930ff50c0" },
    { name: "timers.exe", sha256: "21cfe908f61cdb48fd18e897f8587f3f30c67f0b150924a956145bcc18c4dcb7" },
    { name: "otc-test.exe", sha256: "e69038d45056d37ba67293f50b2cab6d53ca6a7c85f6b0ab0bed837f9ce8d8a6" },
    { name: "access-time.psx.log", sha256: "be133241b82750134bfa77ec6ed91a8930f14282c66086ff8c8c93bd104b2682" },
    { name: "timers.psx.log", sha256: "4bf658df4ef37b542b15b0ec77ce73278cd8f194ddf313b8ee804d2c9deb6353" },
    { name: "otc-test.psx.log", sha256: "0bdfe84629ea0bc044b5933d9b20dc6b6d4728a3188b4d39ef5db91e5c707401" },
    { name: "mask-bit.exe", sha256: "6617ed6ac43c49aec6767bd5462bd436285b36f168fa005621077b0ad9e04293" },
    { name: "gp0-e1.exe", sha256: "50929eb070496057ac461359adba09ff07bfcf2dc2c2eda3ab889bb5dd6a3c59" },
    { name: "chain-looping.exe", sha256: "8c4c28ca7372378fb4d63bdc2bfa951929de67a76e5ff1f1a7a7fe4709332c3d" },
    { name: "chopping.exe", sha256: "eb297da6af4513f03757e2e4eaa6b37488cda1d38cbc4768fea85b422a774521" },
    { name: "bandwidth.exe", sha256: "fbedfa366ca12dafe0d6084f2e8ea67e9453956eba8521b004e892aa5b06b3bf" },
    { name: "mask-bit.psx.log", sha256: "8fe9e908e1411ddfd7d0df8453d8e4e226691463c80ecd4dc93f47f51b1428e9" },
    { name: "gp0-e1.psx.log", sha256: "28ff3d043f776ed311eba41b6f8c01e758a4fd07c1d6bcb0420932cd945fa789" },
    { name: "chain-looping.psx.log", sha256: "f18938ed2f850a344206bd46dc926e7abbdd9170889b9c601c57ad8bcdbf1d58" },
    { name: "chopping.psx.log", sha256: "5cdb8283781705ac67308f076c653a37656e3c7494c2fc8d7fcf46c22c17a8aa" },
    { name: "bandwidth.psx.log", sha256: "b1dbea70c57848acad21498c7133b8ef6089005987a67fc9f4231c9fb1ba76c0" },
    { name: "triangle.exe", sha256: "f035e4893cdb9258d700f37ab88ae9aba03fcbbf4029a15862ccf8ca2f6d9a3f" },
    { name: "quad.exe", sha256: "2a5d3bc0cdf881e12302b2580a4032c8d3e1e6f8dbf5e46d5563c09154ba24b7" },
    { name: "lines.exe", sha256: "0e68352be9252cb6fe733e2f24db3cb70a82df14c175c1fe24334a2dfff239d1" },
    { name: "rectangles.exe", sha256: "6eaac3628dee8a62a268aa0c10b2b72fa1b9217525e23dd2673cc36961db37b6" },
    { name: "clipping.exe", sha256: "45817b0abfe7d1741c5c68fd47309eed9fff814e6a4615c3946a0eb11fbd3b2a" },
    { name: "clut-cache.exe", sha256: "528d1b318da23ea37cc5cb1ea78d9fe683367649887b01f6b4bcfd59c4818dc6" },
    { name: "texture-flip.exe", sha256: "9b8b06e2c286e86b4e90235c43037b516a693c108882c1522ca6f9cfed4e0563" },
    { name: "texture-overflow.exe", sha256: "31f3a173ad66fb2ac23900224ab09264bae42a3d278617f3482237286a25211f" },
    { name: "transparency.exe", sha256: "82a71923f5d9bfaded9aef65f307d8023d4578df70639dd5fc254b7e885dc1e8" },
    { name: "uv-interpolation.exe", sha256: "8b93fc4fbc411fc536f1dcead9cf136afcf5bceaf4c3c086dcae8b7c172039b5" },
    { name: "vram-to-vram-overlap.exe", sha256: "5f3d560f503f69bb712dad3e8842b5fc40509c9cb697fa6b59c7779a3f43cab5" },
    { name: "triangle.vram", sha256: "b9916d5e011991e3dbdd88680cc7abd4e017a4328f6e5cbb8402e0e7d3c34747" },
    { name: "quad.vram", sha256: "b9dddc2743e81cfc29e862f12ce77c7393af6ef54314cc373f5ca7c05cf8f73b" },
    { name: "lines.vram", sha256: "7c7d1c983c34dab4c6f71ffdfa76958ec3f34fc8293fae1a86f6cc5e6ab5f9cd" },
    { name: "rectangles.vram", sha256: "2317d02c5844cd8522093a94f92868f259851efe0168110818d2b579914edcd0" },
    { name: "clipping.vram", sha256: "b3c356b29c2feae42dae440df74774f943e3326f4e82626bd5ea6b506ca0c0ae" },
    { name: "clut-cache.vram", sha256: "734ea5210f20b6cfb1bc071f2a359dfe6241f115224595a97284c5f5bd88ddf7" },
    { name: "texture-flip.vram", sha256: "cb0ea3f99522714a26e4b2dec46543bc04eb82b99a7f594fb491576d3e36ef9f" },
    { name: "texture-overflow.vram", sha256: "2cc8b3fb0c59661c5a6e3092af108557c4618f7e47cc45cd185aaf3bc774a20c" },
    { name: "transparency.vram", sha256: "21b80ddf7c61ef0435e18167411a0e2900c215b81023241592ce0b08289a19ac" },
    { name: "uv-interpolation.vram", sha256: "44d1d1a4888edb6897afe9aeef657685a92b3c2de21599d4252b6f56ae8445fc" },
    { name: "vram-to-vram-overlap.vram", sha256: "93010b5ae50dd9ec22deb9f52623a1651afbed4a68035a77ebabb91aefab3369" },
    { name: "test-all.exe", sha256: "479adc925da6cc4844b567a033fabc06b2ab934ffbbb79c5dad698be20944b9e" },
    { name: "test-all.psx.log", sha256: "78db534a7b02b4bc4c521a20a406743f296dada95c5220568f2df6e0ac37b7a0" },
    { name: "cop.exe", sha256: "d31d3cec66abe8db7935b51590f206602346284da2ac20ea8614339924ea9981" },
    { name: "cop.psx.log", sha256: "e3b09837989c4fd53e4d192ac869f437d965a4d71342bb80d038b5cc813c729c" },
]

verify! : { name : Str, sha256 : Str } => Try({}, _)
verify! = |file| {
    path = "${data_dir}/${file.name}"
    match Path.from_os_str(OsStr.from_str(path)).read_bytes!() {
        Err(_) => {
            Stdout.line!("${file.name}: MISSING — see the manual-unzip instructions at the top of fetch.roc")?
            Err(Missing(file.name))
        }

        Ok(bytes) => {
            got = Sha256.hex(bytes)
            if got == file.sha256 {
                Stdout.line!("${file.name}: ok")?
                Ok({})
            } else {
                Stdout.line!("${file.name}: SHA-256 MISMATCH")?
                Stdout.line!("  pinned: ${file.sha256}")?
                Stdout.line!("  got:    ${got}")?
                Err(Mismatch(file.name, got))
            }
        }
    }
}

verify_all! = |idx, bad|
    match files.get(idx) {
        Err(_) => if bad == 0 { Ok({}) } else { Err(PinsFailed(bad)) }
        Ok(f) =>
            match verify!(f) {
                Ok(_) => verify_all!(idx.plus(1), bad)
                Err(_) => verify_all!(idx.plus(1), bad.plus(1))
            }
    }

main! : List(OsStr) => Try({}, _)
main! = |_args| {
    verify_all!(0.U64, 0.U64)?
    Stdout.line!("ps1-tests data: all pins verified")
}
