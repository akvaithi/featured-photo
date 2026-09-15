#!/usr/bin/env bash
#
# Builds the native helper and runs everything that can be checked without
# Lightroom. Run this before claiming the plug-in works.
#
#   ./lightroom/scripts/build.sh
#
# What it cannot cover: anything that needs a real catalog. LrExportSession,
# the metadata fields, the collections and the grid selection are only ever
# exercised by loading the plug-in in Lightroom Classic.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
plugin="$root/lightroom/FeaturedStacks.lrdevplugin"

"$here/build-scorer.sh" "$@"

echo
echo "syntax-checking Lua…"
luac="$(command -v luac5.4 || command -v luac || true)"
if [ -z "$luac" ]; then
	echo "  skipped: no luac on PATH (brew install lua)" >&2
else
	for file in "$plugin"/*.lua "$root"/lightroom/tests/*.lua; do
		"$luac" -p "$file"
		echo "  ok $(basename "$file")"
	done
fi

echo
echo "running the plug-in test suite…"
lua="$(command -v lua5.4 || command -v lua || true)"
if [ -z "$lua" ]; then
	echo "  skipped: no lua on PATH (brew install lua)" >&2
	exit 0
fi
"$lua" "$root/lightroom/tests/test_plugin.lua" "$plugin/bin/macOS/featured-scorer"
