# Fetch the SingleStepTests r3000 vectors into check/single-step/data/ —
# pure Roc, no curl. 55 .json.bin files (~23 MB total; binary format, see
# NOTES.md — the runner parses it directly, no JSON transcoding). Each file
# is SHA-256-verified against the pin recorded here; upstream publishes no
# checksum manifest, so the pins were computed at the first verified fetch.
#
#   roc build check/single-step/fetch.roc --output=/tmp/fetch && /tmp/fetch
#
# Already-present files that match their pin are skipped, so an interrupted
# fetch resumes.
app [main!] {
	pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.21.0/4rAQg8kUYZ3Vksr4qMQHpaFYNiHSn9GgS7gVxghd1XYV.tar.zst",
	http: "https://github.com/roc-lang/http/releases/download/1.0.0/6ZUwqYhCS8PU9Mo6MF7oV82ET2o7KYb57CLKDq4cq4sS.tar.zst",
	chk: "../lib/main.roc",
}

import pf.OsStr
import pf.Http
import pf.Path
import pf.Stdout
import http.Request
import chk.Sha256

base_url : Str
base_url = "https://raw.githubusercontent.com/SingleStepTests/r3000/main/v1"

data_dir : Str
data_dir = "check/single-step/data"

# An empty pin means "not yet recorded": the fetch prints the computed hash
# so it can be baked in here, and exits nonzero at the end so an unpinned
# state can never look green.
files : List({ name : Str, sha256 : Str })
files = [
	{ name: "ADD.json.bin", sha256: "e1e11f8d96e35c11e90503d328c3279772531e644c9352a72accf565738883bb" },
	{ name: "ADDI.json.bin", sha256: "ca73e94efc9a69cc650fff3db2ce6fadd9dba053f8e99331ec54c8944314df8c" },
	{ name: "ADDIU.json.bin", sha256: "f04c6bc425ffa97cb952653af33c7568264ad37d4d6ecba5fde1beb67248ae69" },
	{ name: "ADDU.json.bin", sha256: "f886d27d26f4b89a4de43f005a1d6bfdcd1e752501019329be26e059ff32bbcf" },
	{ name: "AND.json.bin", sha256: "cc733a72a0359d6eba41bfcae66ff07752e1fe14a55244b251c457507201b684" },
	{ name: "ANDI.json.bin", sha256: "7f7ee0117d424deff5254e5d3660448d6634d983f67e5b3e5c39f927d94557e0" },
	{ name: "BCondZ.json.bin", sha256: "df5afbefe7514064756bde64f45f84eb8d50ef49ef9590f7dd2cf3bf8cc13554" },
	{ name: "BEQ.json.bin", sha256: "8d2c47243e5abdf70c9711296b9dd5714f9baf031dc5332656f8f94e1d83e6e9" },
	{ name: "BGTZ.json.bin", sha256: "0eef68875a743423f3f1d69fa2d09def0253a314686cedb4a10bc41bb59200db" },
	{ name: "BLEZ.json.bin", sha256: "d96d2a8d02a5b47c896b04381e2518735044fc8974a64cea5639ae2c4d011d34" },
	{ name: "BNE.json.bin", sha256: "87db1fd744198957d0460cffcc6042762385a15c649238a7559ebc3a6117c9fb" },
	{ name: "BREAK.json.bin", sha256: "a68e542f2aa83b0c91afe84645120c8da6ee85a669ad856d31cae88ef469c7f6" },
	{ name: "DIV.json.bin", sha256: "74fb72c5141f40ab1f719d8f8d09969122be76449ef22059d8c878e62cfb911a" },
	{ name: "DIVU.json.bin", sha256: "4a5424058e4b64fa2de6fa535c570b3c592eb18c44282aaf4293c0ef6934e117" },
	{ name: "J.json.bin", sha256: "383e5017e7cb256a34cb5214ee6f1ff6e3aa6f9321d763ba93126c50350588df" },
	{ name: "JAL.json.bin", sha256: "f37ec471892669d97dbfe82f056cb3d84b1618c612a2002868a788a060d54e59" },
	{ name: "JALR.json.bin", sha256: "083241b8b142fb9a5fd638d7708c221c8f1c68587858e3e0a38db48878321d31" },
	{ name: "JR.json.bin", sha256: "fd9cdbe12542a5dd9779489e17ad0c0631c632041cdd7c5f3a78329be75dd086" },
	{ name: "LB.json.bin", sha256: "799b12786b65a19ac2d1e6894e9da4573fa93e63f9027cbffcba6ac2d36d00f1" },
	{ name: "LBU.json.bin", sha256: "3cdccffba21f099694529433a8e0b05d4c6e0345bbe0bec2ecc431657822571a" },
	{ name: "LH.json.bin", sha256: "5ddb427d20694bb2b7dd06e037b84f78e4643abb56aea7837e6a1b2fe76c74a4" },
	{ name: "LHU.json.bin", sha256: "a872c0596cb7ca2ada16986314c31b02159bcd55ee3f8502418e5cd94b66d85e" },
	{ name: "LUI.json.bin", sha256: "f8581db8f7a0459d76f4bfbec74753bf98adee1c4a0d2c295e463d167e9bf0d8" },
	{ name: "LW.json.bin", sha256: "08fe23b2d7393473223bde7f603d13b8ccc1b2522c26579af9149e2662d63579" },
	{ name: "LWL.json.bin", sha256: "c3aa34313dbf7e7900d76ac584fbd6d5b94a2bd588eb87f28110227be1019c71" },
	{ name: "LWR.json.bin", sha256: "3dbb3fbc51ad3435d92c0310b5ebe18b5e3b1a845519efd28d18cbd03bf02d7c" },
	{ name: "MFHI.json.bin", sha256: "2163f6ac7ca87b4495a192351c106402e1ab86a328fef3a8ddce4b0eb1e216b7" },
	{ name: "MFLO.json.bin", sha256: "99f48e372ad46bb2dc872ad60611a3b463f933442c1dc06de72776cdb5ecee99" },
	{ name: "MTHI.json.bin", sha256: "13a79e92108bc6ad8f010aa5f0ef9725a9afde110edb14edbfc0d30a46c71b20" },
	{ name: "MTLO.json.bin", sha256: "6cb89401b3d9092cfe02b68763981ea310e248a582863c3b801b2a6f894c5027" },
	{ name: "MULT.json.bin", sha256: "1b188cbd0ae6b22e37eea7f51fd03bd3fde9cd278435004c08bcfad31670f9b0" },
	{ name: "MULTU.json.bin", sha256: "9d0c841477c9055ed6a0d24c67982e3527ca8dcc2d00a0a73ffc84b49aec7422" },
	{ name: "NOR.json.bin", sha256: "07abaf3f5d131006e728f945cf48143525a43ef811f1fa8cddc9f5bbdfea5d1d" },
	{ name: "OR.json.bin", sha256: "f733b46d5da6ca7525dbcd45d8677b8eba2c0f1c2da6653519b8cb4819c3ee4c" },
	{ name: "ORI.json.bin", sha256: "2f06466bc5a211e825c2a1381c6068a0b003e3e0454fc2538f65ceafee028241" },
	{ name: "SB.json.bin", sha256: "f268c90722b9c7a1bb06333fca41843590678b83f65f7ceb5050454349fea431" },
	{ name: "SHL.json.bin", sha256: "89e0b431af6d26c9a4c7103b5b38e840529c4c616a1e5a78084567c16acce152" },
	{ name: "SLL.json.bin", sha256: "8dc42ee2733d62ec536c3da97d9617f7dadd375b91a290206b8d38a088afd9f2" },
	{ name: "SLLV.json.bin", sha256: "519e24dad0ef87cb1c205bb85b6b66c560e6f8599a9d84904c20f248206d1ef7" },
	{ name: "SLT.json.bin", sha256: "a1c3a00e4d4abf4c139f6d0c88ebbd202f702de6b657c74844550c772118fc3f" },
	{ name: "SLTI.json.bin", sha256: "1e6c8d1e6774e69a14698117e746afd93aae497e63fe47970631a2b9d0d57bf7" },
	{ name: "SLTIU.json.bin", sha256: "f8a782855b178a9d6e4281d4b9615cfcd28217e32930b29d22b3f1c2505ff521" },
	{ name: "SLTU.json.bin", sha256: "113b8add0240c945d26394c020e5c3ec523130e6ac43cc14d4c585c8362ccec8" },
	{ name: "SRA.json.bin", sha256: "2f305bf73dd0fd2bd954f54fd68f7815b67a03d4aab05ef8b73fe7dcc01ad2c0" },
	{ name: "SRAV.json.bin", sha256: "b263f5a5a8ac9f6d08df155be6b345274ae152cecc8b0b16bd9763ebedc27bac" },
	{ name: "SRL.json.bin", sha256: "526ae4c7fbfa4e6c7c5b52181c9cf36852d3c41962fbf44b23012ff8d0c1569d" },
	{ name: "SRLV.json.bin", sha256: "5f047b35961eab0337b1eb129d12a08891ef35a99f29e6590ad5f9fc1bf46fe7" },
	{ name: "SUB.json.bin", sha256: "2accef7c8dab34269414b723a448e4d6f277c4f663032d118dfeaad43d1804a8" },
	{ name: "SUBU.json.bin", sha256: "e1fb5675b1d96d13e82f45d903b047f796eb35b6a56e9e25989fb2d3075f4ec5" },
	{ name: "SW.json.bin", sha256: "a5f5fc771eca8fa04bec8465c2d353b978724c338f0179710bebcf614b8d031d" },
	{ name: "SWL.json.bin", sha256: "a25a07362d068417f29f6435f760b3a8e60d4167d423d2aa0bfe32496b7c579d" },
	{ name: "SWR.json.bin", sha256: "7fac501a86b6e58e087aeb8545c5cd0f3dce4cf97c5d57ad7645fe324bbc213e" },
	{ name: "SYSCALL.json.bin", sha256: "5807b3ad215cac0787c5fd183d934236c041a01d47d92f25bae3735b2fdedcf2" },
	{ name: "XOR.json.bin", sha256: "ca47a3799b7169096e6b1181fb34ae26b6d43ecbcab36ff571565e6c4a625c4b" },
	{ name: "XORI.json.bin", sha256: "96f05d9ccce7de4123298721f50097e33a6e8d5669a8c6ad8e8c5ab3e33f631c" },
]

# Indirection on purpose: the flow analyzer constant-folds a `?? fallback`
# on an effectful call at the use site and warns; behind an effectful
# helper it does not (same workaround as the sibling repos' fetches).
read_or_empty! = |path| path.read_bytes!() ?? List.repeat(0x00.U8, 0)
is_present! = |path| path.is_file!() ?? Bool.False

# Returns Bool: did this file end up pinned-and-verified?
fetch_one! = |file| {
	path = Path.from_os_str(OsStr.from_str("${data_dir}/${file.name}"))
	if is_present!(path) {
		actual = Sha256.hex(read_or_empty!(path))
		if actual == file.sha256 {
			Stdout.line!("${file.name}: present, verified")?
			Ok(Bool.True)
		} else if file.sha256 == "" {
			Stdout.line!("${file.name}: present, UNPINNED — sha256 ${actual}")?
			Ok(Bool.False)
		} else {
			Stdout.line!("${file.name}: SHA-256 MISMATCH — expected ${file.sha256}, got ${actual}")?
			Err(ShaMismatch(file.name))
		}
	} else {
		response = Http.send!(Request.from_method(GET).with_uri("${base_url}/${file.name}"))?
		if response.status() == 200 {
			bytes = response.body()
			actual = Sha256.hex(bytes)
			if actual == file.sha256 {
				path.write_bytes!(bytes)?
				Stdout.line!("${file.name}: fetched + verified (${bytes.len().to_str()} bytes)")?
				Ok(Bool.True)
			} else if file.sha256 == "" {
				path.write_bytes!(bytes)?
				Stdout.line!("${file.name}: fetched, UNPINNED — sha256 ${actual}")?
				Ok(Bool.False)
			} else {
				Stdout.line!("${file.name}: SHA-256 MISMATCH — expected ${file.sha256}, got ${actual}")?
				Err(ShaMismatch(file.name))
			}
		} else {
			Stdout.line!("${file.name}: HTTP ${response.status().to_str()}")?
			Err(FetchFailed(file.name))
		}
	}
}

fetch_all! = |idx, verified|
	match files.get(idx) {
		Err(_) => Ok(verified)
		Ok(file) => {
			ok = fetch_one!(file)?
			fetch_all!(idx.plus(1), if ok { verified.plus(1) } else { verified })
		}
	}

main! : List(OsStr) => Try({}, _)
main! = |_args| {
	verified = fetch_all!(0, 0.U64)?
	total = files.len()
	if verified == total {
		Stdout.line!("all ${total.to_str()} vector files present and pin-verified in ${data_dir}/")
	} else {
		Stdout.line!("${verified.to_str()}/${total.to_str()} verified — bake the printed hashes into fetch.roc and re-run")?
		Err(UnpinnedFiles)
	}
}

expect files.len() == 55
