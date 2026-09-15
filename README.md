# Featured Photo

**Google Photos–style "Auto Stacks"** for your photo library — as a macOS app for
Apple Photos, and as a plug-in for Lightroom Classic.

It scans your library, groups near-identical shots (the kind you take 5 times to get one good one), picks the best frame from each group as the **top pick**, and lets you **keep that one and delete the rest** — all backed by your real Photos library.

> Apple Photos has no public "stacks" API, so these are **virtual stacks** shown inside this app. Deletions go through PhotoKit's standard path — items move to **Recently Deleted** (recoverable ~30 days), and macOS shows its own confirmation dialog first.

## Three ways to run it

| | Library | Result |
| --- | --- | --- |
| [macOS app](#build--run) — **Scan** | Apple Photos, via PhotoKit | virtual stacks in-app, with deletion |
| [macOS app](#build--run) — **Scan Folder…** | any folder on disk | the same stacks, read-only — nothing is modified |
| [Lightroom Classic plug-in](lightroom/) | any Lightroom Classic catalog | metadata, pick flags and collections; **⌘G** for real stacks |
| `featured-scorer --folder` | any folder of image files | a report on stdout; nothing is written |

The grouping and ranking are identical across all three — the plug-in's helper
compiles the app's `Scorer.swift`, `ScoreBreakdown.swift` and `Clustering.swift`
directly, so they cannot drift apart.

Lightroom Classic's SDK cannot stack photos that are already in the catalog —
see [lightroom/README.md](lightroom/README.md) for what that means and what the
plug-in does instead.

Deletion is Photos-only, by design. A folder scan shows you the stacks and the
picks and touches nothing — the app never removes a file from disk, and the
sandbox entitlement for folders is read-only.

### Trying it from a terminal

```sh
lightroom/FeaturedStacks.lrdevplugin/bin/macOS/featured-scorer --folder ~/Pictures/shoot
```

```
Stack 2 — 3 frames  2026-08-04 17:57:32
  ★ 0.839  _DSC5385.jpg   [aesthetic 0.91, 1 face, capture 0.57, eyes open 100%, smiling 100%]
    0.814  _DSC5385.tif   d 0.054
    0.812  _DSC5385.jpg   d 0.044
```

`★` is the pick, `d` is each frame's distance to it. Build it first with
`./lightroom/scripts/build.sh`; `--help` lists the tuning flags.

## How it works

1. **Time clustering** — consecutive shots taken within a configurable window (default 12s).
2. **Orientation + camera gating** — a group can only contain photos of the same orientation (portrait/landscape/square) and, optionally, the same camera (EXIF make · model · lens).
3. **Visual similarity** — within each partition, photos are merged only if their Vision feature-print distance is under the similarity threshold.
4. **Best-shot scoring** — the top pick blends:
   - Vision image aesthetics (composition / exposure / blur, with a screenshot/document penalty)
   - Face capture quality (`DetectFaceCaptureQualityRequest`)
   - **Eyes open** and **smiling** (Core Image `CIDetector`)
5. **Review & clean up** — open a stack to swipe the filmstrip, see why a pick won (score breakdown + distance-to-top), then "Keep top pick, delete N others" or delete individual frames.

## Requirements

- macOS 15+
- Xcode 16+ (Vision's modern Swift API)
- [XcodeGen](https://github.com/yonik/XcodeGen) (`brew install xcodegen`) if you want to regenerate the project

## Build & run

```sh
xcodegen generate          # regenerate FeaturedPhoto.xcodeproj from project.yml (optional)
open FeaturedPhoto.xcodeproj
```

In Xcode: select the **FeaturedPhoto** target → **Signing & Capabilities** → set your team (a free personal team works) → **⌘R**. On first launch, grant Photos access, then click **Scan**.

## Settings (⚙️ in the toolbar)

| Setting | What it does |
| --- | --- |
| Time window | Max gap between shots in the same session |
| Similarity threshold | Lower = stricter (more identical). Tune using the "Distance to top" values shown in a stack's detail view |
| Scan limit | How many of the most recent photos to analyze |
| Same camera only | Never group photos from different cameras |

## Project layout

```
FeaturedPhoto/                   the macOS app
├── FeaturedPhotoApp.swift       App entry
├── Models.swift                 PhotoSource, PhotoItem, PhotoStack, StackConfig
├── Clustering.swift             Time / orientation / similarity grouping rules —
│                                shared with the plug-in
├── FolderLibrary.swift          Folder scanning: enumeration, EXIF, decoding —
│                                shared with the plug-in
├── ScoreBreakdown.swift         Score components — shared with the plug-in
├── PhotoLibrary.swift           PhotoKit: auth, fetch, image load, EXIF camera, delete
├── Scorer.swift                 Vision feature print + aesthetics + face/expression
│                                scoring — shared with the plug-in
├── StackStore.swift             Scan orchestration & grouping engine
├── AssetImage.swift             Async thumbnail view + cache
├── ContentView.swift            Stack grid + settings popover
└── StackDetailView.swift        Filmstrip, attribute breakdown, delete actions

lightroom/                       the Lightroom Classic plug-in
├── FeaturedStacks.lrdevplugin/  the plug-in itself (Lua)
├── scorer/                      featured-scorer, the native helper (Swift)
├── scripts/build.sh             build the helper, check the Lua, run the tests
└── tests/                       SDK stubs + a suite that needs no Lightroom
```

`Scorer.swift` and `ScoreBreakdown.swift` are compiled into both the app and the
plug-in's helper, so the two front ends cannot drift into ranking photos
differently.

## License

MIT
