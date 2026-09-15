# CLAUDE.md

Guidance for working in this repo.

## What this is
A macOS app that brings Google Photos–style **"Auto Stacks"** to the Apple Photos
library. It scans the library, groups near-identical shots (burst-y "took it 5 times"
sets), picks the best frame per group, and lets you keep the top pick and delete the
rest — backed by the real Photos library via PhotoKit. Since Apple Photos has no public
stacks API, these are **virtual stacks** shown in-app; deletions go through PhotoKit's
standard path (Recently Deleted, ~30-day recovery, with macOS's own confirmation).

Grouping pipeline: time clustering (default 12 s) → orientation + optional camera gating
→ Vision feature-print similarity → best-shot scoring (aesthetics + face capture quality
+ eyes-open/smiling) → review & clean up.

There are two front ends over one engine: this macOS app, and a **Lightroom
Classic plug-in** in `lightroom/`. See [lightroom/README.md](lightroom/README.md)
before changing anything under it.

## Key files (`FeaturedPhoto/`)
- `FeaturedPhotoApp.swift` — `@main` SwiftUI app entry.
- `ContentView.swift` — main UI; `StackDetailView.swift` — per-stack filmstrip + score breakdown.
- `PhotoLibrary.swift` — PhotoKit access, scanning, deletion.
- `Scorer.swift` — Vision aesthetics + face capture quality + eyes-open/smiling scoring.
- `ScoreBreakdown.swift` — the score components.
- `Clustering.swift` — time / orientation / camera / similarity grouping rules.
- `FolderLibrary.swift` — scanning a folder: enumeration, EXIF, decoding.
- `StackStore.swift` — clustering / grouping into virtual stacks; `Models.swift` — data types.
- `AssetImage.swift` — thumbnail/image loading.
- `Info.plist`, `FeaturedPhoto.entitlements` — Photos access, hardened runtime, sandbox.

## Build & run
```bash
xcodegen generate            # regenerate FeaturedPhoto.xcodeproj from project.yml (optional)
open FeaturedPhoto.xcodeproj
# In Xcode: FeaturedPhoto target → Signing & Capabilities → set your team → ⌘R
```
On first launch, grant Photos access, then click **Scan**.

Headless build and install, which needs no Apple Developer team — the sandbox and
the Photos entitlement work under an ad-hoc signature for local use:

```bash
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild \
  -project FeaturedPhoto.xcodeproj -scheme FeaturedPhoto -configuration Release \
  -derivedDataPath /tmp/fp-build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" build
cp -R /tmp/fp-build/Build/Products/Release/FeaturedPhoto.app /Applications/
```

`DEVELOPER_DIR` is needed because `xcode-select` here points at CommandLineTools,
which has no `xcodebuild`. Do not `sudo xcode-select -s` to work around it.

## Key files (`lightroom/`)
- `FeaturedStacks.lrdevplugin/` — the plug-in (Lua). `FsEngine.lua` is the scan;
  `FsGrouping.lua` is the pure-Lua metadata clustering; `FsScorer.lua` runs the helper.
- `scorer/` — `featured-scorer`, the native helper the plug-in shells out to.
- `scripts/build.sh` — builds the helper, syntax-checks the Lua, runs the tests.

```bash
./lightroom/scripts/build.sh   # run this before believing the plug-in works
```

## Conventions / gotchas
- **The Xcode project is generated** — `project.yml` is the source of truth (XcodeGen).
  Edit `project.yml` for target/build-setting changes, not the `.xcodeproj` directly, and
  re-run `xcodegen generate`. Requires `brew install xcodegen`.
- Requires **macOS 15+ / Xcode 16+** (uses Vision's modern Swift request API).
- Deletions are real (PhotoKit) — but recoverable from Recently Deleted; the app never
  hard-deletes and macOS shows its own confirmation.
- Tuning knobs (time window, similarity threshold, camera gating) are exposed in the
  in-app Settings (⚙️); the "Distance to top" values in a stack help calibrate the
  similarity threshold.
- The app scans two sources: the Photos library (`StackStore.scan`) and a folder
  (`StackStore.scanFolder`). They differ only in the gating half; both meet in
  `StackStore.rank`. `PhotoSource` is what lets the views ignore the difference.
  **Deletion is Photos-only** — the app never removes a file from disk, and the
  folder entitlement is `files.user-selected.read-only`. Don't "fix" that asymmetry.
- **`Scorer.swift`, `ScoreBreakdown.swift`, `Clustering.swift` and `FolderLibrary.swift`
  are compiled into both front ends** — the app target and, via `build-scorer.sh`, the
  Lightroom helper.
  Keep them free of PhotoKit/AppKit/SwiftUI imports, and treat a change to the grouping
  or scoring as a change to every product. `FsGrouping.lua` is a deliberate second copy
  of the gating rules (Lua cannot call Swift); its tests pin it to the same thresholds.
- The helper also runs standalone: `featured-scorer --folder <path>` does the whole
  pipeline over image files, gating on EXIF instead of a catalog. Use it to check a
  grouping change without a library.
- **Lightroom Classic cannot stack existing photos.** `catalog:addPhoto` can stack a
  *newly imported* photo and that is the entire stacking surface of the SDK — there is
  no call for photos already in the catalog. Do not go looking for one; the plug-in
  surfaces its results as metadata, flags and collections instead, and
  `Select Next Stack` + ⌘G is the only route to a real stack.
- **Lightroom runs Lua 5.1**, where `unpack` is a global. `luac -p` (5.4 locally) will
  not catch 5.2+ syntax that Lightroom would reject, so avoid it by hand.
