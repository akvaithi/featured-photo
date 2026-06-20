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

## Key files (`FeaturedPhoto/`)
- `FeaturedPhotoApp.swift` — `@main` SwiftUI app entry.
- `ContentView.swift` — main UI; `StackDetailView.swift` — per-stack filmstrip + score breakdown.
- `PhotoLibrary.swift` — PhotoKit access, scanning, deletion.
- `Scorer.swift` — Vision aesthetics + face capture quality + eyes-open/smiling scoring.
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
