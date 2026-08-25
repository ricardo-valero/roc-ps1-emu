# Verify the ps1-tests EXEs and vendored hardware logs against pinned
# SHA-256 hashes. Upstream ships tests.zip (DEFLATE — pure Roc cannot
# extract), so the EXEs are a verify-only step like the amidog slice;
# the psx.log hardware references are small text files vendored in the
# repo and pinned here against drift.
#
#   curl -LO https://github.com/JaCzekanski/ps1-tests/releases/download/build-158/tests.zip
#     (zip pin: 5de0e82854c1a511697a7ade381c2d778ec4b2fff4a7d7ac79e8098c35eb859b)
#   unzip tests.zip 'cpu/access-time/*' 'timers/*' 'dma/otc-test/*' -d /tmp/ps1tests
#   cp /tmp/ps1tests/cpu/access-time/access-time.exe check/ps1-tests/data/
#   cp /tmp/ps1tests/timers/timers.exe check/ps1-tests/data/
#   cp /tmp/ps1tests/dma/otc-test/otc-test.exe check/ps1-tests/data/
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
