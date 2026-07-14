#!/usr/bin/env bash
# Build the Board Size Modifier into a Godot Mod Loader .zip.
#
# The zip mounts into the game's res:// under mods-unpacked/, so the Mod Loader finds the mod at
# res://mods-unpacked/npopescu-VCBBoardSizeModifier/. Drop the resulting zip into the game's
# mods/ folder (see the launcher's "Runtime modding" tab).
set -euo pipefail
cd "$(dirname "$0")"

OUT="npopescu-VCBBoardSizeModifier.zip"
rm -f "$OUT"

# Zip the mods-unpacked/ tree so internal paths are exactly:
#   mods-unpacked/npopescu-VCBBoardSizeModifier/manifest.json
#   mods-unpacked/npopescu-VCBBoardSizeModifier/mod_main.gd
#   …
zip -r "$OUT" mods-unpacked \
	-x '*.DS_Store' -x '*/.*' >/dev/null

echo "Wrote $(pwd)/$OUT"
unzip -l "$OUT" | sed -n '1,40p'
