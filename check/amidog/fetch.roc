# Verify the Amidog test EXEs in check/amidog/data/ against pinned
# SHA-256 hashes. The upstream zips are DEFLATE-compressed, which pure
# Roc cannot extract, so unlike single-step this is a verify-only step:
# download and unzip by hand, then run this to check the pins.
#
#   curl -LO https://psx.amidog.se/lib/exe/fetch.php?media=psx:download:psxtest_cpu.zip
#   curl -LO https://psx.amidog.se/lib/exe/fetch.php?media=psx:download:psxtest_cpx.zip
#   curl -LO https://psx.amidog.se/lib/exe/fetch.php?media=psx:download:psxtest_gte.zip
#     (zip pins: psxtest_cpu.zip 0bf315206bdc961506e135e35084266563a07ecf7a76a52feab7c26cf79e7523,
#                psxtest_cpx.zip 975561499cefbfca9fbddc497d3ef3731e4f1dc33f7732452de06d1ac548d7bb,
#                psxtest_gte.zip 69e08e30a2abbf6cd933d511a426ecb7625af4dde6a63cac628f5e36622f74f3 (v1.4, 2013-12-31))
#   unzip psxtest_cpu.zip psxtest_cpu.exe -d check/amidog/data/
#   unzip psxtest_cpx.zip psxtest_cpx.exe -d check/amidog/data/
#   unzip psxtest_gte.zip psxtest_gte.exe -d check/amidog/data/
#
#   roc build check/amidog/fetch.roc --output=/tmp/amidog_fetch && /tmp/amidog_fetch
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
    chk: "../lib/main.roc",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import chk.Sha256

data_dir : Str
data_dir = "check/amidog/data"

files : List({ name : Str, sha256 : Str })
files = [
    { name: "psxtest_cpu.exe", sha256: "12486b5f7d52cad9f4e91ccd6aa33d16a298c25a29148934ceacc05a1423af00" },
    { name: "psxtest_cpx.exe", sha256: "ff75bda24f66fa421f7c6a6b7f3737dd936d8750de913863a113e4caa0a47f27" },
    { name: "psxtest_gte.exe", sha256: "3efcc3f714d54ba9ef1b0d0a7a28c530177fc22173dc51a69792ace99592b969" },
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

verify_all! = |idx|
    match files.get(idx) {
        Err(_) => Ok({})
        Ok(f) => {
            verify!(f)?
            verify_all!(idx.plus(1))
        }
    }

main! : List(OsStr) => Try({}, _)
main! = |_args| {
    verify_all!(0.U64)?
    Stdout.line!("amidog data: all pins verified")
}
