#!/usr/bin/env bash
# Runs a title with VIctory on Linux, under Proton (see docs/linux-proton.md).
#
#   ./run.sh <game folder, or the title's exe> [more `victory run` options]
#
# The VIctory build depends on the graphics card, unless VICTORY_BUILD names
# one: avatarmanz's VIctory-7900XTX on AMD cards, fxceless's victory-fork on
# NVIDIA cards (the fastest each in the community's rankings, built by
# scripts/base.sh), this
# checkout's build ("victory") on others. This checkout's release build is
# made first if it is missing (cargo-xwin). The title's watchdog is off
# unless VICTORY_NO_WATCHDOG says otherwise: a world load under Wine can
# outlast it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

usage() {
    echo "usage: ./run.sh <game folder, or the title's exe> [more victory run options]" >&2
    exit 2
}
[[ $# -ge 1 && "$1" != "-h" && "$1" != "--help" ]] || usage
game="$1"
shift

if [[ -d "$game" ]]; then
    mapfile -t exes < <(find "$game" -maxdepth 1 -type f -iname '*.exe' | sort)
    if [[ ${#exes[@]} -ne 1 ]]; then
        echo "run.sh: ${#exes[@]} .exe files in $game; name the title's exe instead" >&2
        exit 1
    fi
    title="${exes[0]}"
elif [[ -f "$game" ]]; then
    title="$game"
else
    echo "run.sh: no such folder or file: $game" >&2
    exit 1
fi

# The card's maker, from the kernel's view of the cards (an NVIDIA card wins
# over an AMD integrated GPU).
gpu_vendor() {
    local file vendors=""
    for file in /sys/class/drm/card*/device/vendor; do
        [[ -r "$file" ]] && vendors+=" $(<"$file")"
    done
    case "$vendors" in
        *0x10de*) echo nvidia ;;
        *0x1002*) echo amd ;;
        *) echo other ;;
    esac
}
build="${VICTORY_BUILD:-}"
if [[ -z "$build" ]]; then
    case "$(gpu_vendor)" in
        amd) build=victory-7900xtx ;;
        nvidia) build=victory-fork ;;
        *) build=victory ;;
    esac
fi
echo "run.sh: VIctory build: $build (VICTORY_BUILD=victory, victory-7900xtx, klbf-lab or victory-fork)" >&2

# A variable's value unless it is set already.
default() {
    [[ -n "${!1+x}" ]] || export "$1=$2"
}
case "$build" in
    victory)
        target="${CARGO_TARGET_DIR:-$ROOT/target}"
        exe="$target/x86_64-pc-windows-msvc/release/victory.exe"
        if [[ ! -f "$exe" ]]; then
            echo "run.sh: building VIctory (release) first" >&2
            (cd "$ROOT" && XWIN_ACCEPT_LICENSE=1 cargo xwin build --release -p victory --target x86_64-pc-windows-msvc)
        fi
        ;;
    klbf-lab)
        exe="$("$ROOT/scripts/base.sh" klbf-lab)"
        # klbf-lab's settings for AMD cards (its docs/GUIDE.md), with late
        # waits off: they lose the device on RADV. It splits its own ballots
        # for 64-lane waves, so RADV's waves stay as they are.
        default VICTORY_SHADER_OPT 0
        default VICTORY_SKIP_PIPELINES 39f0e9aeb156a61c
        default VICTORY_LATE_WAIT 0
        default VICTORY_WIDE_BACK 0
        default VICTORY_PIPELINE_WAIT_MS 24
        default VICTORY_RELAY_COPY_QUEUE 0
        default VICTORY_CARD_BUFFERS_MIN_MB 1
        default VICTORY_CARD_BUFFERS_MB 1024
        default VICTORY_RADV_WAVE32 0
        ;;
    victory-7900xtx)
        exe="$("$ROOT/scripts/base.sh" victory-7900xtx)"
        # Its own settings (scripts/play.ps1 there, without -Safe).
        for setting in TEXTURE_NO_WAIT=1 RELAY=2 WIDE_BACK=1 CARD_REHASH_RUNS=1 JOIN_COPIES=1 \
            INDIRECT_WINDOW=1 RELAY_COPY=1 CARD_STEPS=2 INDIRECT_BATCH=2 MAP_THREADS=1 \
            TITLE_PRIORITIES=0 CARD_AWAKE=1 SHOW_AFTER=1 AMBIENT=0.8 SKIP_PIPELINES=none \
            THIN=1 JOIN_PARTS=8 UPLOAD_AHEAD=1; do
            default "VICTORY_${setting%%=*}" "${setting#*=}"
        done
        ;;
    victory-fork)
        exe="$("$ROOT/scripts/base.sh" victory-fork)"
        ;;
    *)
        echo "run.sh: unknown VICTORY_BUILD $build" >&2
        exit 2
        ;;
esac
if [[ "$build" != victory ]]; then
    # Its own HLSL needs Microsoft's compiler, put next to the exe.
    export WINEDLLOVERRIDES="d3dcompiler_47=n,b;${WINEDLLOVERRIDES:-}"
fi
export VICTORY_NO_WATCHDOG="${VICTORY_NO_WATCHDOG-1}"
# The title's BVH walks need vkd3d-proton master's dxil-spirv (Proton's
# recurses without end on them, which stops pipelines being made).
if [[ -z "${VICTORY_VKD3D_DIR+x}" ]] && ! "$ROOT/scripts/vkd3d-proton-master.sh" >/dev/null; then
    echo "run.sh: vkd3d-proton master is missing (gh logged in?): pipelines may stop being made" >&2
fi

# Series S mode unless --console is given, for the builds that hand the
# title's upscaling to AMD FidelityFX on the host: the title renders at
# 1280x720 and upscales with the PC build of AMD's SDK (the console's draws
# white under Proton). In the prologue's cell a frame took 220 to 270 ms
# instead of 290 to 380 in Series X mode (this checkout, RX 6950 XT).
console=()
if [[ "$build" == victory || "$build" == klbf-lab ]]; then
    ffx="${XDG_DATA_HOME:-$HOME/.local/share}/victory/fidelityfx"
    sdk="https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/raw/v2.4.0/Kits/FidelityFX/signedbin"
    # The SDK 2.4.0 files' SHA-256: a download is kept only if it matches.
    declare -A sums=(
        [amd_fidelityfx_loader_dx12.dll]=e2191d3c0828be45eb8affd4e3ec0378f2293adc345b772a7170edcf3b021ecb
        [amd_fidelityfx_upscaler_dx12.dll]=aad4fccccb29084a655f9a4f9f613bd22c8c03fb4a0f8840148cc6543b4ccace
    )
    matches() {
        echo "${sums[$1]}  $2" | sha256sum --quiet -c - >/dev/null 2>&1
    }
    ffx_ok=1
    for dll in "${!sums[@]}"; do
        if [[ ! -s "$ffx/$dll" ]]; then
            mkdir -p "$ffx"
            echo "run.sh: downloading $dll (AMD FidelityFX SDK 2.4.0, MIT licence)" >&2
            if curl -fL --retry 3 -o "$ffx/$dll.part" "$sdk/$dll" && matches "$dll" "$ffx/$dll.part"; then
                mv "$ffx/$dll.part" "$ffx/$dll"
            else
                rm -f "${ffx:?}/$dll.part"
            fi
        fi
        if ! matches "$dll" "$ffx/$dll"; then
            echo "run.sh: $ffx/$dll is missing or not the SDK 2.4.0 file: Series X mode" >&2
            ffx_ok=0
        fi
    done
    if (( ffx_ok )); then
        # This checkout reads the first name, klbf-lab the second.
        default VICTORY_FIDELITYFX_DIR "Z:${ffx//\//\\}"
        default VICTORY_FFX_DIR "$VICTORY_FIDELITYFX_DIR"
        if [[ " $* " != *" --console "* ]]; then
            console=(--console series-s)
        fi
    fi
fi
VICTORY_EXE="$exe" exec "$ROOT/scripts/proton-run.sh" run "$title" --execute "${console[@]}" "$@"
