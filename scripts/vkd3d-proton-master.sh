#!/usr/bin/env bash
# Downloads vkd3d-proton's newest master build (its CI's package) into
# ~/.local/share/victory/vkd3d-proton and prints that folder, which
# scripts/proton-run.sh then uses (VICTORY_VKD3D_DIR). Needs the GitHub CLI
# (`gh`), logged in: GitHub serves CI packages to signed-in users only.
#
# Proton Experimental 11.0-20261112 ships a dxil-spirv (vkd3d-proton's DXIL
# to SPIR-V translation) that recurses without end on some of the programs
# VIctory makes, which ends the thread making pipelines. dxil-spirv fixed it
# (its pull request #371, in vkd3d-proton master since 2026-11-23).
set -euo pipefail
repo=HansKristian-Work/vkd3d-proton
dir="${XDG_DATA_HOME:-$HOME/.local/share}/victory/vkd3d-proton"

run=$(gh api "repos/$repo/actions/runs?branch=master&status=success&per_page=20" \
    --jq '[.workflow_runs[] | select(.name == "Artifacts (Package)")][0] | "\(.id) \(.head_sha)"')
read -r id sha <<<"$run"
if [[ -z "${id:-}" ]]; then
    echo "vkd3d-proton-master.sh: no successful master package found" >&2
    exit 1
fi
if [[ "$(cat "$dir/.commit" 2>/dev/null)" != "$sha" ]]; then
    artifact=$(gh api "repos/$repo/actions/runs/$id/artifacts" --jq '.artifacts[0].id')
    echo "vkd3d-proton-master.sh: downloading vkd3d-proton master ${sha:0:12}" >&2
    tmp=$(mktemp -d)
    trap 'rm -rf "${tmp:?}"' EXIT
    gh api "repos/$repo/actions/artifacts/$artifact/zip" >"$tmp/package.zip"
    unzip -q "$tmp/package.zip" -d "$tmp/package"
    rm -rf "${dir:?}"
    mkdir -p "$dir"
    install -m 644 "$tmp/package/x64/d3d12.dll" "$tmp/package/x64/d3d12core.dll" "$dir/"
    echo "$sha" >"$dir/.commit"
fi
echo "$dir"
