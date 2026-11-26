# cool_fox-main under Proton (NVIDIA)

The codec-d fork (`cool_fox-main`, based on fxceless/victory-fork) runs on
Linux through this repository's Proton setup once `scripts/bases/cool-fox/wine.patch`
is applied. Measured 2026-11-26 on the 31 GB / RTX 3060 box, Series X: the
first build there that got past the opening load without the OOM killer.

| | this checkout (`victory`) | cool_fox-main + patch |
|---|---|---|
| draws a frame | 5,200 | 4,776-7,110 |
| frame | ~1,000 ms | 450-525 ms |
| cgroup | 26 GB, OOM-killed 10 min in | 16 GB, flat for 10 min in the load |

## Why the patch

Wine's `d3dcompiler_47` has no `ByteAddressBuffer` methods, no interlocked
methods on resources, and drops `[RootSignature]`. cool_fox compiles its
indirect argument clamp and its ambient stand-in at run time and read the
root signature out of the shader blob, so under Proton:

- the argument clamp did not compile or make a pipeline, every indirect
  execution was dropped, and the world was black;
- the ambient stand-in failed too (`isnan`/`isinf` are not Wine's), leaving
  interiors black.

`wine.patch` makes the clamp a `StructuredBuffer<uint>` shader with one
walking group (no atomics), makes the root signatures in
`victory_gpu::host::compute_root` (`RootView`: root SRVs/UAVs and one-view
tables), replaces `isnan`/`isinf`, and carries the two Proton fixes
`run.sh` already applies to fxceless's fork (null pipeline-library blob,
Wine's ws2_32 has no `WSAConnectByList`/`GetAddrInfoExA`).

## Build and run

```sh
cp -a /path/to/cool_fox-main ~/.cache/victory/bases/cool-fox
patch -p1 -d ~/.cache/victory/bases/cool-fox < scripts/bases/cool-fox/wine.patch
(cd ~/.cache/victory/bases/cool-fox &&
    XWIN_ACCEPT_LICENSE=1 cargo xwin build --release -p victory \
        --target x86_64-pc-windows-msvc)

export VICTORY_AMBIENT_AIR=1.5 VICTORY_TEXTURE_NO_WAIT=1 VICTORY_RELAY=2 \
    VICTORY_WIDE_BACK=1 VICTORY_CARD_REHASH_RUNS=1 VICTORY_JOIN_COPIES=1 \
    VICTORY_INDIRECT_WINDOW=1 VICTORY_RELAY_COPY=1 VICTORY_CARD_STEPS=2 \
    VICTORY_INDIRECT_BATCH=2 VICTORY_MAP_THREADS=1 VICTORY_CARD_AWAKE=1 \
    VICTORY_SHOW_AFTER=1 VICTORY_AMBIENT=0.8 VICTORY_THIN=1 VICTORY_JOIN_PARTS=8 \
    VICTORY_UPLOAD_AHEAD=1 VICTORY_LEVELS_ON_DEMAND=1 VICTORY_CARD_BUFFERS_MIN_KB=64 \
    VICTORY_NO_WATCHDOG=1

VICTORY_EXE=~/.cache/victory/bases/cool-fox/target/x86_64-pc-windows-msvc/release/victory.exe \
    scripts/proton-run.sh run /path/to/game_scarlett_master.exe --execute
```

The title screen needs Return (the console's "press a button"); on this box
`/home/honza/press.py Return` sends it by XTEST. Series S is not used: this
build loads no PC FidelityFX DLLs, so the title's own upscaler draws white
under Proton; the preset above is Series X.

## Still open (2026-11-26)

- The batched clamp (`VICTORY_INDIRECT_BATCH=2`) still fails under Wine and
  falls back to one record at a time.
- 5 wave64 compute programs do not translate (`no wave32 lowering for this
  wave64 program`); their draws are dropped. Suspected of the blocky light
  in the prologue's room.
- 214 `a texture picked by index changed after its upload with nothing to
  tell of it` warnings in a load.
- The title's own ray-traced light needs `VICTORY_BVH_BUILDER=1`; not tried
  under Proton yet (`VICTORY_AMBIENT` is the stand-in for it).
