# Featured Photo

A macOS app that brings **Google Photos–style "Auto Stacks"** to your Apple Photos library.

It scans your library, groups near-identical shots (the kind you take 5 times to get one good one), picks the best frame from each group as the **top pick**, and lets you **keep that one and delete the rest** — all backed by your real Photos library.

> Apple Photos has no public "stacks" API, so these are **virtual stacks** shown inside this app. Deletions go through PhotoKit's standard path — items move to **Recently Deleted** (recoverable ~30 days), and macOS shows its own confirmation dialog first.

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
FeaturedPhoto/
├── FeaturedPhotoApp.swift   App entry
├── Models.swift             PhotoItem, PhotoStack, StackConfig, scoring/orientation
├── PhotoLibrary.swift       PhotoKit: auth, fetch, image load, EXIF camera, delete
├── Scorer.swift             Vision feature print + aesthetics + face/expression scoring
├── StackStore.swift         Scan orchestration & grouping engine
├── AssetImage.swift         Async thumbnail view + cache
├── ContentView.swift        Stack grid + settings popover
└── StackDetailView.swift    Filmstrip, attribute breakdown, delete actions
```

## License

MIT
