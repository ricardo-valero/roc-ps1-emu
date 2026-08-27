# Verify the GTE vector capture against its pinned SHA-256.
#
# The capture ships inside the same pinned ps1-tests release zip as the
# EXEs (DEFLATE — pure Roc cannot extract), so this is a verify-only
# step like the amidog and ps1-tests slices. Unlike the EXEs the log is
# TRACKED: it is a text reference, and the repo's convention is that
# hardware references live in git while binaries are fetched.
#
#   curl -LO https://github.com/JaCzekanski/ps1-tests/releases/download/build-158/tests.zip
#     (zip pin: 5de0e82854c1a511697a7ade381c2d778ec4b2fff4a7d7ac79e8098c35eb859b)
#   unzip tests.zip 'gte-fuzz/*' -d /tmp/ps1tests
#   cp /tmp/ps1tests/gte-fuzz/gte_valid_0xc0ffee_50.log check/gte-fuzz/data/
#
#   roc build check/gte-fuzz/fetch.roc --output=/tmp/gf_fetch && /tmp/gf_fetch
app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
    chk: "../lib/main.roc",
}

import pf.OsStr
import pf.Path
import pf.Stdout
import chk.Sha256

data_dir : Str
data_dir = "check/gte-fuzz/data"

files : List({ name : Str, sha256 : Str })
files = [
    { name: "gte_valid_0xc0ffee_50.log", sha256: "4577214dec452509eb5e8f3ff4c120d50bb361db13381ce9fee8bad2b3520421" },
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
                Err(Mismatch(file.name))
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
main! = |_| {
    verify_all!(0.U64)?
    Stdout.line!("gte-fuzz data: all pins verified")
}
