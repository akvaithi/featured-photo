#!/usr/bin/env bash
#
# Builds featured-scorer, the native helper the Lightroom plug-in shells out to,
# and installs it into the plug-in bundle.
#
#   ./lightroom/scripts/build-scorer.sh            # universal, release
#   ./lightroom/scripts/build-scorer.sh --debug    # host arch only, unoptimised
#
# Scorer.swift and ScoreBreakdown.swift are compiled straight out of the macOS
# app's sources rather than copied, so the plug-in and the app cannot drift into
# ranking photos differently. That is the reason this is a script and not a
# SwiftPM package: a package cannot reach outside its own directory for sources.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"

app="$root/FeaturedPhoto"
scorer="$root/lightroom/scorer"
dest="$root/lightroom/FeaturedStacks.lrdevplugin/bin/macOS"
out="$dest/featured-scorer"

sources=(
	"$app/Scorer.swift"
	"$app/ScoreBreakdown.swift"
	"$app/Clustering.swift"
	"$app/FolderLibrary.swift"
	"$scorer/FeaturedScorer.swift"
	"$scorer/FolderScan.swift"
	"$scorer/Pipeline.swift"
)

for source in "${sources[@]}"; do
	[ -f "$source" ] || { echo "missing source: $source" >&2; exit 1; }
done

# The app targets macOS 15 and so does this: Vision's modern Swift request API
# (GenerateImageFeaturePrintRequest and friends) does not exist before it.
deployment="15.0"
debug=0
[ "${1:-}" = "--debug" ] && debug=1

mkdir -p "$dest"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

build_slice() {
	local arch="$1" product="$2"
	# -swift-version 5 matches the app's SWIFT_VERSION; Swift 6 language mode
	# would reject the shared sources' concurrency for no benefit here.
	xcrun swiftc \
		-swift-version 5 \
		-target "${arch}-apple-macos${deployment}" \
		$( [ "$debug" = 1 ] && echo "-Onone -g" || echo "-O -whole-module-optimization" ) \
		-parse-as-library \
		-framework Vision -framework CoreImage -framework ImageIO -framework CoreGraphics \
		"${sources[@]}" \
		-o "$product"
}

if [ "$debug" = 1 ]; then
	echo "building featured-scorer (debug, $(uname -m))…"
	build_slice "$(uname -m)" "$out"
else
	echo "building featured-scorer (universal, release)…"
	build_slice arm64 "$work/featured-scorer-arm64"
	build_slice x86_64 "$work/featured-scorer-x86_64"
	xcrun lipo -create -output "$out" \
		"$work/featured-scorer-arm64" "$work/featured-scorer-x86_64"
fi

chmod +x "$out"

# Lightroom runs the helper out of the plug-in bundle, where an unsigned binary
# from a downloaded zip trips Gatekeeper. Ad-hoc signing is enough to make it
# launchable; a release build should re-sign with a Developer ID.
xcrun codesign --force --sign - "$out" 2>/dev/null || \
	echo "warning: could not ad-hoc sign $out" >&2

echo "installed: $out"
xcrun lipo -info "$out" 2>/dev/null || true
"$out" --version
