# Macro Osc: 64-bit (aarch64) build for Gen 2 MPCs

An unofficial local build of [saustin2010/mpc-vst-macro-osc](https://github.com/saustin2010/mpc-vst-macro-osc)
release 1.1.1 (repository commit `cffb851`) for a 64-bit MPC, made on 2026-11-15 for an MPC Key 37
(Gen 2) on MPC OS 3.10.1.12. The published release has a 32-bit (armv7) binary only, which a Gen 2
MPC cannot load.

## Build

```bash
./build-aarch64.sh native
```

```bash
./test-native.sh
```

`build-aarch64.sh` needs git, python3, curl, shasum and Zig. Zig defaults to the one bundled with
inMusic's MPC Plugin Builder SDK (`~/dev/mpc-plugin-builder-sdk/.sdk-tools/zigenv`, Zig 0.17.1);
set `SDK=` or `ZIG=` to use another. No Docker. Everything it downloads or generates goes under
`build/` (git-ignored). It:

1. clones the framework fork the port is built with, `saustin2010/mpc-vst-plugins`, at the commit
   the release workflow pins (`e3a0af4`), into `build/framework`;
2. generates `build/params.h` with the framework's `tools/gen_vst.py vst.json --params-h` (pure
   Python, standard library only);
3. compiles the port's sources, `wrapper/vst2_wrap.c` and the Schwung adapter with the flags of the
   framework's `tools/build_port.sh` (C++ branch), using `zig c++` / `zig cc` with
   `-target aarch64-linux-gnu.2.31 -mcpu=cortex_a55` (the SDK's `file64` target) in place of gcc
   in Docker, and links with a version script so only `VSTPluginMain` is exported;
4. downloads the published `SYN-Macro-Osc-1.1.1-mpc-armv7.zip`, checks it against its sha256
   (`de7d1127...be3f`, the same value GitHub and the Open MPC catalogue give) and checks every file
   in it against the zip's own `SHA256SUMS`. Its `install.sh` is never run;
5. assembles `build/aarch64/Émilie Gillet - VST - [SYN] Macro Osc/`.

With `native` it also builds the same sources for this computer (`build/native/`), for the tests.

## What is in the plugin folder

| Item | Where it comes from |
|---|---|
| `braids.so` | built here: aarch64, glibc symbols up to 2.27, needs only libc, libm, libpthread |
| `Plugin Skins/` (TUI.json, Q-Links, 217 images) | the 1.1.1 release zip, unchanged |
| `braids/presets/` (10 presets) | the 1.1.1 release zip, unchanged |
| `version.xml` | the 1.1.1 release zip, unchanged |
| `plugin.json` | written here, the same keys upstream's `tools/release.py` writes for an aarch64 build: name `[SYN] Macro Osc`, manufacturer `Émilie Gillet`, uid `0x42724473` (`BrDs`, the plugin-list entry's `42724473`), `file64: braids.so`, `format: vst2` |
| `LICENSE` | this repository's MIT licence |
| `CREDITS.txt` | `CREDITS-aarch64.txt`: who made what, and that this is an unofficial build |
| `SHA256SUMS` | of the folder's files, for checking a copy |

`braids.so` stays at the top of the folder: the wrapper finds its presets in `braids/` next to the
library (`wrapper/plugin_dir.h`). Left out, because they belong to the modded-MPC install route:
`plugin-meta.xml`, `mpc-plugin.json`, `install.sh`, `uninstall.sh`, `plugin_list.awk`.

## What was changed

No build setting, parameter, name, uid or screen was changed, so projects saved with the 32-bit
build should open with this one (not tested: there is no Gen 1 device here).

One source change, in `src/dsp/braids/digital_oscillator.cc` (`ComputeDelay`, under `MPC_PORT`;
also added to `upstream-changes.diff`):

- **COMB model, low notes with TIMBRE turned down.** The delay is shifted right by
  `12 - num_shifts`; below about MIDI note 35 with TIMBRE at 0, `num_shifts` passes 12 and the
  count goes negative (a huge `size_t`). That is undefined in C++, and the two CPUs disagree: a
  32-bit ARM shifts everything out and gives 0, AArch64 takes the count modulo 32 and gives 0 to
  15. The function now returns 0 there, which is what the 32-bit build does. The difference was at
  most 15/65536 of a sample of delay, so it was not audible and not a crash; the change makes the
  two builds agree and removes the undefined behaviour. Found with UBSan.

Seen and left alone (not a 64-bit matter, same in the 32-bit build and the original module code):
the WLIN model reads one byte past its 64-entry `wave_line` table when TIMBRE is at maximum
(`digital_oscillator.cc:1645`). The byte read is another table's first entry and every value it can
hold selects a valid wave (`wt_waves` holds 256), so it does not crash.

Nothing else needed changing: the wrapper already uses `intptr_t` for the pointer-sized VST2
fields, and the engine has no assembly, NEON or 32-bit assumptions.

## What was tested

Offline, on the Mac (Apple Silicon), 2026-11-15:

- `tools/validate.py` from the SDK on the folder: binary is 64-bit AArch64, exports
  `VSTPluginMain`, max glibc 2.27, skin and Q-Link files consistent. It reports one error, "missing
  `file32`" (this folder is 64-bit only by design), and one warning, no `<uiversion>` in
  `version.xml` (kept as upstream ships it; other community plugins with the same file draw their
  screens on MPC OS 3.10.1).
- `host_sim ... test` from the SDK on the native build: 19 passed, 0 warnings, 0 failures (load,
  10 programs, sound from MIDI notes, block sizes 32/128/512, parameter sweep, state round-trip,
  silence after all-notes-off).
- The framework's own host test (`tools/host_test.c`) on the native build under UBSan: PASSED.
  This replaces `tools/test_port.sh`, which needs Docker.
- A sweep of all 47 models (three TIMBRE and COLOR settings each, five notes from 12 to 127, filter,
  FM, octave and pitch bend varied) on the native build under UBSan: no non-finite output, no
  silent model. This is what found the COMB shift. Run by hand, not part of `test-native.sh`.

The native build is the same source on the same CPU family (arm64) but with macOS libraries, so
these tests exercise the code, not the Linux binary itself.

On the device (MPC Key 37 Gen 2, MPC OS 3.10.1.12), 2026-11-15:

- Copied to `/storage/VST2 Plugins/Émilie Gillet - VST - [SYN] Macro Osc/` (staged as `.new`,
  then renamed); all 235 files match `SHA256SUMS`.
- The dynamic loader resolves every symbol of `braids.so` against the device's libraries
  (`LD_BIND_NOW=1 LD_WARN=1 LD_TRACE_LOADED_OBJECTS=1 /lib/ld-linux-aarch64.so.1 ./braids.so`: no
  warnings).
- MPC app restarted once (23:42 device time, new process 14676). The plugin was then loaded from
  External Plugins and played by the owner, who reported that it loads, shows its screen and makes
  sound. Device log (`journalctl`, `az01-launch-MPC[14676]`), 23:43:29:
  `Attempting to load VST: /storage/VST2 Plugins/Émilie Gillet - VST - [SYN] Macro Osc/braids.so`,
  `Creating VST instance: braids`, `Initialising VST: braids (1.0.0.0)`. No crash or out-of-memory
  line in the log afterwards, and `braids.so` is mapped in the running MPC process.
- Memory: `MemAvailable` 2.73 GB right after the restart, 2.41 GB with Macro Osc loaded and its
  screen opened.
- Not checked one by one on the device: each of the 47 models, the ALGORITHM list, the PRESET menu,
  Q-Link behaviour, saving and reopening a project, CPU load with four voices.

## Removing it

Delete the folder from `/storage/VST2 Plugins/` and restart the MPC app.
