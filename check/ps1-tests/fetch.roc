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
