#!/usr/bin/env bash
# Builds a VIctory base other than this checkout and prints the path of its
# release victory.exe, for run.sh (VICTORY_BUILD) and scripts/proton-run.sh
# (VICTORY_EXE):
#
#   scripts/base.sh klbf-lab        # PastiiJay/klbf-lab: AMD cards
#   scripts/base.sh victory-fork    # fxceless/victory-fork: NVIDIA cards
#   scripts/base.sh victory-7900xtx # avatarmanz/VIctory-7900XTX: AMD cards
#
# Each base is fetched at a fixed commit into ~/.cache/victory/bases,
# patched with scripts/bases/<name>/*.patch (fixes for Proton) and built
# with cargo-xwin. These bases compile their own HLSL with methods Wine's
# compiler lacks (RWByteAddressBuffer), so Microsoft's d3dcompiler_47.dll is
# put next to the exe: from D3DCOMPILER_47 when set, else
# ~/.local/share/victory/d3dcompiler_47.dll (copied from a Windows install's
# System32).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
name="${1:?usage: scripts/base.sh klbf-lab|victory-fork|victory-7900xtx}"
case "$name" in
    klbf-lab) repo=https://github.com/PastiiJay/klbf-lab commit=3c2dbec66faafe6701d86090d5e7e53957f5c88c ;;
    victory-fork) repo=https://github.com/fxceless/victory-fork commit=085ee7c4c3d1dfaed41d683fa9f465a6f9dac8c3 ;;
    victory-7900xtx) repo=https://github.com/avatarmanz/VIctory-7900XTX commit=0a43566532c57b34a5397d6fdc91e419de32e8e9 ;;
    *) echo "base.sh: unknown base $name (klbf-lab, victory-fork, victory-7900xtx)" >&2; exit 2 ;;
esac

src="${XDG_CACHE_HOME:-$HOME/.cache}/victory/bases/$name-${commit:0:12}"
if [[ ! -f "$src/.prepared" ]]; then
    echo "base.sh: fetching $name at ${commit:0:12}" >&2
    rm -rf "${src:?}"
    mkdir -p "$src"
    git -C "$src" init -q
    git -C "$src" fetch -q --depth 1 "$repo" "$commit"
    git -C "$src" checkout -q FETCH_HEAD
    shopt -s nullglob
    for patch in "$ROOT/scripts/bases/$name"/*.patch; do
        git -C "$src" apply "$patch"
    done
    touch "$src/.prepared"
fi

exe="$src/target/x86_64-pc-windows-msvc/release/victory.exe"
if [[ ! -f "$exe" ]]; then
    echo "base.sh: building $name (release), several minutes the first time" >&2
    (cd "$src" && XWIN_ACCEPT_LICENSE=1 CARGO_TARGET_DIR="$src/target" \
        cargo xwin build --release -p victory --target x86_64-pc-windows-msvc) >&2
fi

dll="${D3DCOMPILER_47:-${XDG_DATA_HOME:-$HOME/.local/share}/victory/d3dcompiler_47.dll}"
if [[ ! -f "$dll" ]]; then
    cat >&2 <<EOF
base.sh: $name needs Microsoft's d3dcompiler_47.dll, not found at $dll.
Copy it from a Windows install (C:\\Windows\\System32\\d3dcompiler_47.dll) to
that path, or set D3DCOMPILER_47 to a copy of it.
EOF
    exit 1
fi
cp -f "$dll" "$(dirname "$exe")/d3dcompiler_47.dll"
echo "$exe"
