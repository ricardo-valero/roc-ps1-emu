# roc-ps1-emu

A PlayStation 1 emulator in pure Roc. Fourth of the fleet, following
[roc-nes-emu], [roc-ngb-emu], and [roc-ngba-emu]. The acceptance title is
**Crash Team Racing (NTSC-U, SCUS-94426)** — chosen deliberately: the US
disc has no LibCrypt protection, and the game's hard demands (XA audio
streaming with SPU-IRQ capture-buffer readback, hblank-counter timing,
512-wide video) make it a thorough final exam. See [ROADMAP.md](ROADMAP.md)
for the change sequence and progress.

As far as we can tell, this is the first PlayStation 1 emulator attempted
in a functional language.

## Building and testing

Everything runs from the Nix devshell (direnv picks it up via `.envrc`):

```
nix develop           # or let direnv activate it
roc version           # the pinned nightly, kept in sync across the fleet
roc check package/main.roc
roc test  package/main.roc
```

The pure emulator core lives under `package/`; verification slices live
under `check/` and are pure Roc (see `check/README.md`). The Roc nightly
is pinned via `roc-lang/roc-overlay` through `flake.lock` — when bumping,
bump the sibling repos in the same session.

## External resources

Copyrighted material stays out of the repo. Conventions:

- **Disc images**: `../rom/` (sibling convention), bin/cue. Canonical
  target: `Crash Team Racing (USA).cue` + bin (SCUS-94426). PAL discs are
  LibCrypt-protected and out of scope.
- **BIOS**: every gate in `check/` runs **OpenBIOS**
  (https://pcsx-redux.consoledev.net/openbios/), executed LLE like a
  retail BIOS. Retail SCPH dumps in `../rom/` are supported for
  compatibility testing but never required by any check.
- **Test data**: fetched per-slice by `check/<slice>/fetch.roc` — the
  SingleStepTests/r3000 JSON, Amidog test EXEs, and JaCzekanski
  ps1-tests binaries.

## References

- psx-spx (the hardware bible): https://psx-spx.consoledev.net/
- simias's PlayStation Emulation Guide: https://github.com/simias/psx-guide
- Test suites: https://github.com/SingleStepTests/r3000,
  https://psx.amidog.se/, https://github.com/JaCzekanski/ps1-tests
- Oracles: Mednafen (accuracy reference), DuckStation software renderer
  (read-only — CC-BY-NC-ND), PCSX-Redux (debugger/TTY), no$psx

[roc-nes-emu]: https://github.com/ricardo-valero/roc-nes-emu
[roc-ngb-emu]: https://github.com/ricardo-valero/roc-ngb-emu
[roc-ngba-emu]: https://github.com/ricardo-valero/roc-ngba-emu
