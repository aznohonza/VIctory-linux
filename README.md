# VIctory for Linux

[VIctory](https://github.com/Marvisak/VIctory) runs Xbox Series titles on a
PC: it loads the title's executable, answers its system calls and
translates its GPU work to Direct3D 12. This fork runs VIctory on Linux,
under Proton's Wine, with vkd3d-proton (Direct3D 12 on Vulkan) and DXVK's
DXGI.

The upstream README is kept as [README.victory.md](README.victory.md).

## Quick start

Requirements:

- Proton Experimental, installed from Steam (Library, then Tools).
- A Vulkan driver with mesh shaders. RADV on RDNA 2 or later has them.
- `rustup` and [`cargo-xwin`](https://github.com/rust-cross/cargo-xwin).
- On AMD and NVIDIA cards, Microsoft's `d3dcompiler_47.dll`, copied from a
  Windows install's `System32` to `~/.local/share/victory/d3dcompiler_47.dll`
  (the builds `run.sh` picks for them need it, see below).
- A copy of the game you own. This repository holds no game files.

```sh
rustup target add x86_64-pc-windows-msvc
cargo install --locked cargo-xwin
scripts/proton-viewtree.sh   # once: a faster Wine server (docs/linux-proton.md)
./run.sh /path/to/game
```

`run.sh` takes the folder holding the title's executable, or the executable
itself. It picks the VIctory build from the graphics card: avatarmanz's
VIctory-7900XTX on AMD, fxceless's victory-fork on NVIDIA, this checkout's
elsewhere, or the one `VICTORY_BUILD` names (`victory`, `victory-7900xtx`,
`klbf-lab`, `victory-fork`). The first run builds it (cargo-xwin then downloads the MSVC
runtime and the Windows SDK, and accepts their licence). Wine runs in a
prefix of its own, `~/.local/share/victory/proton`, made on first use.

## Status

Tested on CachyOS with an AMD RX 6950 XT (RADV, Mesa 26.2.6) and Proton
Experimental `experimental-11.0-20261112`.

- The title boots, runs its menus at its own 30 frames a second and loads
  the opening scene.
- In the prologue's cell, with the Wine server `scripts/proton-viewtree.sh`
  builds and the Series S mode `run.sh` starts, a frame takes 145 ms (about
  7 frames a second) with klbf-lab, whose picture at night is dark with
  magenta patches, and 260 ms (about 4) with this checkout's build, whose
  picture is right. The opening cutscene, up to 13,000 draws a frame, is
  much slower. With Steam's Wine server, frames take about five times longer.
- In the opening scene, VIctory-7900XTX (the build `run.sh` picks on AMD)
  takes 90 to 185 ms a frame, about 5 to 11 frames a second, with faces
  right; this checkout's build takes 500 to 1,700 ms and opens every
  character's mouth wide.
- This checkout's build draws and lights the world, without ray-traced
  shadows or reflections, as upstream. On AMD cards this needs RADV's waves
  of 32 lanes, which the scripts ask for.
- fxceless's build, picked on NVIDIA cards, has not been run on one here.
- After about 10 minutes of play the title stops itself when one of its
  object pools fills up. This also happens on Windows (upstream issue #698).
- A PlayStation pad (DualSense) works as an XInput pad, with the Xbox
  buttons' names in the title.

## What this fork adds

- `run.sh`, `scripts/proton-run.sh` and `scripts/wine-run.sh`, which set up
  Proton or the system's Wine with vkd3d-proton and DXVK.
- `scripts/proton-viewtree.sh`, which builds Proton's Wine server with a
  process's memory views in a tree: world frames about five times faster.
- `scripts/base.sh`, which builds the community's fastest VIctory for the
  card (VIctory-7900XTX, fxceless's victory-fork) with fixes for Proton.
- `scripts/vkd3d-proton-master.sh`, which fetches vkd3d-proton master for
  its dxil-spirv fix.
- Fixes for Wine and vkd3d-proton: VIctory's own shaders build with Wine's
  HLSL compiler, an empty pipeline library is asked for with a null blob,
  each translated program returns from one block (dxil-spirv cannot
  structure a loop left by both a break and a return), network functions
  Wine lacks fail cleanly, and the write tracking makes fewer protection
  changes, which are slow under Wine.
- Upstream pull requests taken ahead of upstream: #454 (an opt-in hook for
  the title's watchdog, on by default in `run.sh`), #1849, #1084, #416,
  #1014 and #1737.
- The test suite runs under Wine.
- `VICTORY_FRAME_RATE`, which sets the rate the title's frames are paced
  at, or lifts that cap (`0`).

[docs/linux-proton.md](docs/linux-proton.md) has the details: requirements,
building, running, tests and the known differences with Windows.

## Licence

GPL-3.0, as upstream: see [LICENSE](LICENSE).
