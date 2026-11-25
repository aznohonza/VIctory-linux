#!/usr/bin/env bash
# Runs victory.exe (or another Windows exe) under Proton's Wine on Linux,
# with vkd3d-proton (D3D12) and DXVK (DXGI) from the Proton build.
# See docs/linux-proton.md.
#
#   scripts/proton-run.sh config
#   scripts/proton-run.sh run /path/to/game/<the title's exe> --execute
#
# As cargo's runner (its first argument is the test exe):
#   CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUNNER=$PWD/scripts/proton-run.sh \
#       cargo xwin test --workspace --target x86_64-pc-windows-msvc
#
# Environment:
#   PROTON       a Proton folder (default: the one scripts/proton-viewtree.sh
#                made from Proton - Experimental, else Proton - Experimental
#                from Steam)
#   PREFIX       the Proton prefix to use (default: ~/.local/share/victory/proton)
#   VICTORY_EXE  the exe to run (default: this checkout's release build)
#   VICTORY_VKD3D_DIR  a folder with another vkd3d-proton's d3d12.dll and
#                d3d12core.dll (default: the one scripts/vkd3d-proton-master.sh
#                fills, when it exists; empty: Proton's own)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -z "${PROTON:-}" ]]; then
    for d in "$HOME/.steam/steam/steamapps/common/Proton - Experimental" \
             "$HOME/.local/share/Steam/steamapps/common/Proton - Experimental" \
             "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/steamapps/common/Proton - Experimental"; do
        if [[ -x "$d/files/bin/wine" ]]; then PROTON="$d"; break; fi
    done
    # The same Proton with a faster Wine server, while it was made from
    # this one (scripts/proton-viewtree.sh writes the version it took).
    viewtree="${XDG_DATA_HOME:-$HOME/.local/share}/victory/proton-viewtree"
    if [[ -n "${PROTON:-}" && -f "$viewtree/.victory-viewtree" ]]; then
        if [[ "$(awk '{print $1}' "$viewtree/.victory-viewtree")" == "$(awk '{print $2}' "$PROTON/version")" ]]; then
            PROTON="$viewtree"
        else
            echo "proton-run.sh: Proton Experimental changed since $viewtree was made," \
                 "run scripts/proton-viewtree.sh again (Steam's Proton is used meanwhile)" >&2
        fi
    fi
fi
if [[ -z "${PROTON:-}" || ! -x "$PROTON/files/bin/wine" ]]; then
    echo "Proton not found: install Proton Experimental in Steam or set PROTON" >&2
    exit 1
fi
PREFIX="${PREFIX:-${XDG_DATA_HOME:-$HOME/.local/share}/victory/proton}"

# First run: let Proton build the prefix (it installs vkd3d-proton and DXVK).
if [[ ! -f "$PREFIX/pfx/system.reg" ]]; then
    mkdir -p "$PREFIX"
    STEAM_COMPAT_DATA_PATH="$PREFIX" \
    STEAM_COMPAT_CLIENT_INSTALL_PATH="${STEAM_COMPAT_CLIENT_INSTALL_PATH:-$HOME/.steam/steam}" \
    SteamAppId=0 SteamGameId=0 \
        python3 "$PROTON/proton" run cmd /c exit >/dev/null 2>&1 || true
fi

export WINEPREFIX="$PREFIX/pfx"
export WINEDLLOVERRIDES="d3d12,d3d12core,dxgi,d3d11,d3d10core=n,b;${WINEDLLOVERRIDES:-}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEFSYNC=1
# RADV (Mesa's driver for AMD cards) runs vertex, geometry, mesh and pixel
# shaders in waves of 64 lanes on RDNA 2. The title's programs are written
# for waves of 32: in waves of 64 its geometry loses its triangles (the
# world draws only its sky) and faces lose details (dark eyes). gewave32
# and pswave32 ask RADV for waves of 32 there; other drivers ignore them.
# VICTORY_RADV_WAVE32=0 leaves RADV's waves alone, for a VIctory build that
# splits its own ballots for 64-lane waves.
if [[ "${VICTORY_RADV_WAVE32:-1}" != 0 ]]; then
    for flag in gewave32 pswave32; do
        case ",${RADV_PERFTEST:-}," in
            *",$flag,"*) ;;
            *) RADV_PERFTEST="${RADV_PERFTEST:+$RADV_PERFTEST,}$flag" ;;
        esac
    done
    export RADV_PERFTEST
fi
# vkd3d-proton's pipeline cache, out of the working directory.
export VKD3D_SHADER_CACHE_PATH="${VKD3D_SHADER_CACHE_PATH:-$PREFIX/vkd3d-cache}"
mkdir -p "$VKD3D_SHADER_CACHE_PATH"

# Crashes print a backtrace in the terminal instead of opening Wine's dialog.
if [[ ! -f "$PREFIX/.no-crash-dialog" ]]; then
    env -u DISPLAY -u WAYLAND_DISPLAY "$PROTON/files/bin/wine" reg add 'HKCU\Software\Wine\WineDbg' \
        /v ShowCrashDialog /t REG_DWORD /d 0 /f >/dev/null 2>&1 && touch "$PREFIX/.no-crash-dialog"
fi

# Pads Wine would show as raw HID devices (a DualSense) go through SDL
# instead and show as XInput pads, the kind VIctory reads. Wine's HID bus
# reads this when it starts, so the Wine server is let go first.
if [[ ! -f "$PREFIX/.pads-as-xinput" ]]; then
    env -u DISPLAY -u WAYLAND_DISPLAY "$PROTON/files/bin/wine" reg add 'HKLM\System\CurrentControlSet\Services\winebus' \
        /v DisableHidraw /t REG_DWORD /d 1 /f >/dev/null 2>&1 && touch "$PREFIX/.pads-as-xinput"
    timeout 30 "$PROTON/files/bin/wineserver" -w ||
        echo "proton-run.sh: pads show as XInput once every program in $PREFIX has exited" >&2
fi

WINE="$PROTON/files/bin/wine"
if [[ -n "${VICTORY_EXE:-}" ]]; then
    set -- "$VICTORY_EXE" "$@"
elif [[ "${1:-}" != *.exe || ! -f "${1:-}" ]]; then
    set -- "$ROOT/target/x86_64-pc-windows-msvc/release/victory.exe" "$@"
fi

# Another vkd3d-proton (scripts/vkd3d-proton-master.sh), put next to the exe,
# where Wine looks first: VICTORY_VKD3D_DIR, else the folder that script
# fills when it exists. A copy left there earlier goes when neither is set.
vkd3d="${VICTORY_VKD3D_DIR-${XDG_DATA_HOME:-$HOME/.local/share}/victory/vkd3d-proton}"
here="$(dirname "$1")"
if [[ -n "$vkd3d" && -f "$vkd3d/d3d12core.dll" ]]; then
    for dll in d3d12.dll d3d12core.dll; do
        cmp -s "$vkd3d/$dll" "$here/$dll" || install -m 644 "$vkd3d/$dll" "$here/"
    done
    echo "$vkd3d" >"$here/.vkd3d-proton"
elif [[ -f "$here/.vkd3d-proton" ]]; then
    rm -f "${here:?}/d3d12.dll" "${here:?}/d3d12core.dll" "${here:?}/.vkd3d-proton"
fi
exec "$WINE" "$@"
