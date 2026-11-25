# Linux (Proton)

VIctory is a Windows program, and it also runs on Linux under Proton's Wine
with vkd3d-proton for Direct3D 12 and DXVK's DXGI.

Its test suite passes there (2026-11-25): CachyOS, Linux 7.3, AMD RX 6950 XT
(RADV, Mesa 26.2.6), Proton Experimental `experimental-11.0-20261112`. The
title runs there too, up to the opening scene (status in the
[README](../README.md)).

## Requirements

- Steam's **Proton Experimental** (Steam → Library → Tools). Older Protons
  may not work: GE-Proton 11-11's vkd3d-proton turns some translated
  shaders into invalid SPIR-V, on which RADV crashes (`vkCreateGraphicsPipelines`,
  exit code 3).
- A Vulkan driver with mesh shaders (RADV on RDNA 2 or later has them).
- `rustup` and [`cargo-xwin`](https://github.com/rust-cross/cargo-xwin)
  to build the Windows target on Linux.

## Building

```sh
rustup target add x86_64-pc-windows-msvc
cargo install --locked cargo-xwin
# cargo-xwin downloads the MSVC CRT and Windows SDK; this accepts their licence.
export XWIN_ACCEPT_LICENSE=1
cargo xwin build --release -p victory --target x86_64-pc-windows-msvc
```

The diagnostics build likewise:
`cargo xwin build --profile diag -p victory --features diagnostics --target x86_64-pc-windows-msvc`.

Only the MSVC target runs titles. The mingw target (`x86_64-pc-windows-gnu`)
builds, but Rust keeps its per-thread state there outside the static TLS
block the loader restores around a title's thread notices, so the first
thread std starts with a title attached aborts the process.

## Running

In one command, from the checkout:

```sh
./run.sh /path/to/game
```

The path is the folder holding the title's exe, or the exe itself; more
`victory run` options can follow it. `run.sh` builds the release exe the
first time (in `CARGO_TARGET_DIR` when set), turns the title's watchdog off
(`VICTORY_NO_WATCHDOG=1` unless set otherwise, see below) and runs the title
with `scripts/proton-run.sh`.

### Builds by card

`run.sh` picks the VIctory build from the graphics card, unless
`VICTORY_BUILD` names one:

| Card | Build (`VICTORY_BUILD`) | Source |
|---|---|---|
| AMD | `klbf-lab` | PastiiJay/klbf-lab, first on AMD in the community's rankings |
| NVIDIA | `victory-fork` | fxceless/victory-fork, the reference build for NVIDIA |
| Other | `victory` | this checkout |

`scripts/base.sh` fetches the first two at a fixed commit into
`~/.cache/victory/bases`, applies the fixes for Proton in
`scripts/bases/<name>` and builds them. Both compile their own HLSL with
methods Wine's compiler lacks, so they need Microsoft's `d3dcompiler_47.dll`:
copy it from a Windows install's `System32` to
`~/.local/share/victory/d3dcompiler_47.dll`, or set `D3DCOMPILER_47` to a
copy of it. `run.sh` gives each build its own settings (klbf-lab's for AMD,
with late waits off as RADV needs), keeping any value already set.

Measured in the prologue's cell on an RX 6950 XT, Series S mode, last minute
of a run:

| Build | Frame | Picture at night |
|---|---|---|
| `klbf-lab` | 145 ms (6.9 fps) | dark, with magenta patches |
| `victory` | 260 ms (3.9 fps) | right |

With the `victory` and `klbf-lab` builds, `run.sh` runs the title in its
Series S mode unless `--console` is given: the title then renders at
1280×720 and upscales with AMD FidelityFX (`victory-fork` has no such mode
on the host and stays in Series X mode). The
console's upscaler draws a white picture under Proton, so `run.sh`
downloads the PC one from AMD's FidelityFX SDK 2.4.0 (MIT licence, two DLLs
in `~/.local/share/victory/fidelityfx`, checked against the SHA-256 of that
release's files) and points `VICTORY_FIDELITYFX_DIR` at it. Without them, or
when a file does not match, it stays in Series X mode. In the prologue's cell, a
frame took 220 to 270 ms instead of 290 to 380 in Series X mode (RX 6950
XT).

`scripts/proton-run.sh` runs `victory.exe` with Proton's Wine, in a prefix of
its own (`~/.local/share/victory/proton`, made on first use), with
vkd3d-proton and DXVK. Linux paths work as arguments.

```sh
scripts/proton-run.sh config
scripts/proton-run.sh run /path/to/game/<the title's exe> --execute
```

`PROTON` selects another Proton folder, `PREFIX` another prefix and
`VICTORY_EXE` another exe (the diagnostics build, say). Without `PROTON`,
the folder `scripts/proton-viewtree.sh` makes is used (next section) while
it matches the installed Proton Experimental. Saves, settings and
`crashes.log` live in the prefix's `%LOCALAPPDATA%\victory\data` unless
`victory.toml` or `VICTORY_DATA_DIR` says otherwise. Wine's crash dialog is
off in that prefix: a crash prints its backtrace in the terminal instead.

With an Xbox controller connected, the keyboard is not a pad (as on
Windows). `VICTORY_KEYS` presses still reach the title, on the first
connected pad.

VIctory reads XInput pads. Wine shows a PlayStation pad (a DualSense) as a
raw HID device, which no XInput slot answers, so both scripts set Wine's
`DisableHidraw` in their prefix: the pad then goes through SDL and shows as
an XInput pad, with the Xbox buttons' names in the title.

The title's own watchdog ends the process when its main thread has not
advanced for about 30 seconds, which a world load under Wine can exceed.
`VICTORY_NO_WATCHDOG=1` turns it off on build 1.0.2.1: the loader patches
its two sites, each only if its bytes are the expected ones, and leaves
other builds alone. It hides a stall without fixing it, so a real deadlock
then waits instead of ending the process.

The title paces its frames at 30 a second (it sets a 33.333 ms interval).
`VICTORY_FRAME_RATE` overrides that rate: `VICTORY_FRAME_RATE=60` paces
frames at 60 a second, and `VICTORY_FRAME_RATE=0` does not pace them, so
the menus run as fast as they render. Unset, the title's rate stays.

On AMD cards, RADV (Mesa's Vulkan driver) runs vertex, geometry, mesh and
pixel shaders in waves of 64 lanes on RDNA 2, while the title's programs
expect waves of 32. Its geometry then loses its triangles, so the world shows
only its sky, and faces lose details. Both scripts add `gewave32,pswave32` to
`RADV_PERFTEST`, keeping any value already set. Other drivers ignore it.
`VICTORY_RADV_WAVE32=0` leaves RADV's waves alone: `run.sh` sets it for
klbf-lab, which splits its own ballots for waves of 64 and draws wrong in
waves of 32.

### vkd3d-proton master

The dxil-spirv (vkd3d-proton's DXIL to SPIR-V translation) of Proton
Experimental 11.0-20261112 recurses without end on some of the title's
programs (its BVH walks), and the stack overflow ends the thread making
pipelines: no new pipeline is made after it. dxil-spirv fixed it (its pull
request #371, in vkd3d-proton master since 2026-11-23).
`scripts/vkd3d-proton-master.sh` downloads vkd3d-proton master's newest
package from its CI into `~/.local/share/victory/vkd3d-proton` (it needs the
GitHub CLI, logged in), and `run.sh` runs it for this checkout's build.
`proton-run.sh` then puts its `d3d12.dll` and `d3d12core.dll` next to the
exe, where Wine looks first. `VICTORY_VKD3D_DIR` names another folder, and
an empty one keeps Proton's.

### A faster Wine server

The title maps and unmaps thousands of memory views a frame. Wine's server
checks each new view against every view of the process, and walks the same
list to find a view by its address. Under Proton, that takes most of a world
frame. `scripts/proton-viewtree.sh` builds Proton Experimental's own Wine
server with the views in a tree ordered by address
(`scripts/wineserver-view-tree.patch`, from upstream issue #340), and makes
a Proton folder that uses it:

```sh
scripts/proton-viewtree.sh
```

Only the server is built, from the Wine commit of the installed Proton
Experimental. Every other file is a hard link to that Proton's (a copy where
hard links cannot be made), in `~/.local/share/victory/proton-viewtree`.
`proton-run.sh`, and so `run.sh`, use that folder while it matches the
installed Proton Experimental. After a Steam update of Proton, they warn and
use Steam's Proton until the script runs again. The script needs git, curl,
autoconf, flex, bison, perl, python3 and a C compiler, and keeps the Wine
source in `~/.cache/victory`.

Measured with the diagnostics build in the opening scene (RX 6950 XT,
medians over 3 minutes of the world, two runs each):

| | Steam's server | Views in a tree |
|---|---|---|
| World frame | 2,592 to 2,958 ms | 556 to 612 ms |
| Copies of title memory | 625 to 751 ms | 121 to 129 ms |
| Protection changes | 438 ms | 45 to 47 ms |
| First world frame after launch | 106 to 121 s | 71 s |

Both columns ran the same exe, before the RADV setting above, so the world's
geometry was missing in both. With it, a world frame took 616 to 798 ms with
the tree of views.

### Commands to a running title

In the diagnostics build, `VICTORY_LIVE` names a file read and removed at
each presented frame, one command a line: `skip <hash>` and `unskip <hash>`
cut or restore the pipelines using a shader, `skips` logs those cut,
`capture` captures the next frame (as `VICTORY_CAPTURE_FRAMES` would, into
`VICTORY_CAPTURE`) and `mark <text>` writes a line in the log, to cut a
run's measures. A test then needs no new start of the title.

### Without Proton (system Wine)

A system Wine works too (reported with Wine 11.22 on RDNA2, RDNA3 and
RDNA 3.5). What Proton brings has to be added:

- **vkd3d-proton 3.2 or newer**: `d3d12.dll` and `d3d12core.dll` (Proton
  Experimental's `files/lib/wine/vkd3d-proton/x86_64-windows`). 3.1 turns
  some translated shaders into SPIR-V RADV cannot take.
- **DXVK's `dxgi.dll`**, and `WINEDLLOVERRIDES="d3d12,d3d12core,dxgi=n"`.
- No Microsoft `d3dcompiler_47`: Wine's built-in one compiles the two
  shaders VIctory makes at run time (the argument clamp and the depth
  converter).

`scripts/wine-run.sh` does this with the system's `wine`, in a prefix of its
own (`~/.local/share/victory/wine`, made on first use without a window,
`VICTORY_WINEPREFIX` for another) with Wine's crash dialog off. It takes
vkd3d-proton and DXVK from the newest Proton build Steam has. If that one
ships vkd3d-proton 3.1, `VICTORY_PROTON` names Proton Experimental's folder
instead. It is a cargo runner too.

## Tests

```sh
cargo xwin build --manifest-path tests/fixtures/hle-probe/Cargo.toml \
    --target x86_64-pc-windows-msvc --target-dir target/hle-probe
export VICTORY_HLE_PROBE=$PWD/target/hle-probe/x86_64-pc-windows-msvc/debug/hle_probe.dll
CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUNNER=$PWD/scripts/proton-run.sh \
    cargo xwin test --workspace --target x86_64-pc-windows-msvc --exclude xtask
cargo test -p xtask
```

Wine cannot start the Linux programs two tests start. So
`loads_binds_and_calls_probe` takes its stand-in title built beforehand
(`VICTORY_HLE_PROBE`) instead of building it with `cargo`, and xtask's
tests, whose asset-policy check runs `git`, run natively.

With two GPUs, `DXVK_FILTER_DEVICE_NAME` and `VKD3D_FILTER_DEVICE_NAME` pick
one by name. Under Wine, a Ryzen's integrated GPU is named "AMD Radeon(TM)
Graphics". One that drives no display is a safe place for tests that could
hang a GPU.

## Known differences

- **Speed.** Wine emulates write watching page by page, so the copies of
  title memory take longer than on Windows.
- **Software rendering does not work.** On lavapipe, Wine cannot handle the
  write faults of VIctory's guarded title memory when lavapipe's own
  threads take them.
- **Wine and vkd3d-proton differ from Windows in a few places VIctory now
  handles:**
  - Wine's HLSL compiler (`D3DCompile`, built on vkd3d-shader) has no
    `RWByteAddressBuffer` methods and does not embed root signatures. So
    VIctory's two shaders read structured buffers of words, and their root
    signatures are made apart.
  - vkd3d-proton refuses an empty pipeline library given a non-null blob
    pointer, and does not check DXIL container hashes.
  - Its DXIL to SPIR-V translation cannot structure a loop left by both a
    break and a return, so each translated program returns from one block.
