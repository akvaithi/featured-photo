# Featured Photo — Auto Stacks for Lightroom Classic

The same grouping and best-shot ranking as the macOS app, run over a Lightroom
Classic catalog instead of the Apple Photos library.

## Read this first: Lightroom cannot be made to stack

Lightroom Classic's SDK has exactly one stacking call — the optional argument to
`catalog:addPhoto` that stacks a **newly imported** photo with an existing one.
There is nothing that stacks photos already in the catalog, and no way to invoke
the Photo ▸ Stacking commands. This is a long-standing, [acknowledged SDK
limitation](https://community.adobe.com/questions-675/lightroom-sdk-stack-operations-989964),
not something a cleverer plug-in gets around.

So the plug-in does the part that is actually hard — deciding *which frames are
the same shot* and *which one is best* — and surfaces the answer four ways:

| Output | What you get |
| --- | --- |
| **Plug-in metadata** | `Stack`, `Stack Role`, `Stack Size`, `Best Shot Score`, `Distance to Pick`, `Score Detail` on every frame — filterable in the Library filter and usable as smart-collection rules |
| **Pick flags** | The best frame of each stack is flagged |
| **Collections** | `Featured Auto Stacks ▸ Best Picks` and `▸ Duplicates` |
| **Colour label** | Optional, on the pick |

For **real** Lightroom stacks there is a semi-manual route: `Select Next Stack`
selects one group in the grid with its pick as the active photo, and you press
**⌘G**. Run it again for the next one. Tedious past a few dozen stacks, but it is
the only path to a genuine stack that exists.

Nothing here deletes a photo. `Duplicates` is a collection you review yourself.

## Trying it on a folder first

The helper runs the whole algorithm standalone, over a folder of image files —
no Photos library, no catalog, nothing written anywhere:

```sh
lightroom/FeaturedStacks.lrdevplugin/bin/macOS/featured-scorer --folder ~/Pictures/shoot
```

```
Scanned 36 images in /Users/…/shoot
  25 frames in 9 candidate group(s) after the 12s / orientation / camera gate

Stack 2 — 3 frames  2026-08-04 17:57:32
  ★ 0.839  _DSC5385.jpg   [aesthetic 0.91, 1 face, capture 0.57, eyes open 100%, smiling 100%]
    0.814  _DSC5385.tif   d 0.054
    0.812  _DSC5385.jpg   d 0.044
```

`★` is the pick; `d` is each frame's feature-print distance to it. This is the
fastest way to calibrate `--threshold` before pointing anything at a real
library.

| | |
| --- | --- |
| `--time-window <seconds>` | max gap between frames in one burst (default 12) |
| `--threshold <distance>` | similarity cutoff, lower is stricter (default 0.5) |
| `--any-camera` | group frames from different cameras too |
| `--no-recurse` | do not descend into subfolders |
| `--analysis-size <pixels>` | longest edge Vision sees (default 256) |
| `--json` | machine-readable, same shape as plug-in mode |

Capture time comes from EXIF `DateTimeOriginal`; files without it fall back to
the filesystem date, and the report says how many did. Files it found but could
not open are listed rather than dropped, so the counts always add up.

**Hidden files are skipped**, including ones carrying macOS's `UF_HIDDEN` flag
rather than a leading dot. Those do not look hidden in `ls -la` or in the Finder
— only `ls -lO` shows the flag — so if the scan reports fewer images than you
expect, check that first.

## Install

```sh
./lightroom/scripts/build.sh     # builds the helper, checks Lua, runs the tests
```

Then in Lightroom Classic: **File ▸ Plug-in Manager ▸ Add**, and choose
`lightroom/FeaturedStacks.lrdevplugin`.

Requires macOS 15+ (the scoring is Apple's Vision framework) and Lightroom
Classic 13+. On Windows the plug-in loads but the menu command stops with an
explanation — there is no Vision there.

## Use

1. Select some photos, or a folder or collection. With nothing selected the scan
   covers everything in the current source.
2. **Library ▸ Plug-in Extras ▸ Find Auto Stacks…**
3. Review what it found, then **Apply** — or **Discard**, which writes nothing.

Settings live in **File ▸ Plug-in Manager**, under the plug-in. The defaults are
the macOS app's, so the same photos group the same way through either front end.

Calibrate the similarity threshold against the **Distance to Pick** column: a
stack whose frames all sit near `0.0` was never in doubt, one with a `0.45` in it
is the threshold doing real work. Lower is stricter.

## How it is put together

Lightroom's SDK is Lua and cannot analyse an image, so the work is split at the
point where pixels start to matter:

```
   Lua (FsEngine)                             Swift (featured-scorer)
   ─────────────────────────────────────      ──────────────────────────────
   target photos
     capture time / orientation / camera  ->  (nothing — no pixels needed)
     candidate groups of 2+
     export 256px JPEGs to a temp folder
                                          ->  Pipeline:
                                              Vision feature prints
                                              sub-cluster by similarity
                                              aesthetics + face capture quality
                                              + eyes-open / smiling
     stacks, ranked best first            <-  JSON on stdout
     metadata, flags, collections
```

`--folder` mode is the same picture with the left column replaced by
`FolderScan`, which reads capture time, orientation and camera out of the files'
EXIF instead of a catalog. Everything from `Pipeline` on is identical.

The metadata pass runs over the whole selection first because it needs no
pixels; only groups that survive it are ever exported, which on a real catalog
is the difference between rendering everything and rendering a few percent.

`featured-scorer` compiles `Scorer.swift`, `ScoreBreakdown.swift` and
`Clustering.swift` **straight out of the macOS app's sources** rather than
copying them, so the front ends cannot drift into grouping or ranking photos
differently. That is why the build is a script and not a SwiftPM package — a
package cannot reach outside its own directory.

`FsGrouping.lua` is the one unavoidable second copy of the gating rules, because
Lua cannot call into Swift. The test suite pins it to the same thresholds.

### Files

| File | |
| --- | --- |
| `Info.lua` | manifest: menu items, metadata provider, settings panel |
| `FsEngine.lua` | the scan, end to end |
| `FsGrouping.lua` | capture time / orientation / camera clustering (pure Lua, tested) |
| `FsRenditions.lua` | exporting the throwaway analysis JPEGs |
| `FsScorer.lua` | finding and running the native helper |
| `FsApply.lua` | writing metadata, flags, labels, collections |
| `FsJson.lua` | JSON both ways — the SDK ships none |
| `FsReviewDialog.lua` | the results filmstrip |
| `FsSettings.lua` | the knobs, and their defaults |
| `MenuFindStacks.lua` / `MenuSelectNextStack.lua` / `MenuClearResults.lua` | the three menu commands |
| `scorer/Pipeline.swift` | fingerprint, sub-cluster, score, rank — where both modes meet |
| `scorer/FolderScan.swift` | `--folder`: EXIF gating over files on disk |
| `scorer/FeaturedScorer.swift` | argument parsing and the two entry points |

## Testing without Lightroom

`tests/lr_stubs.lua` stubs enough of the SDK — `import`, `LOC`, `LrTasks`,
`LrFileUtils`, a catalog, an export session — to run every non-UI module under a
plain Lua interpreter. `tests/test_plugin.lua` drives them against the **real**
helper binary, with fixture images synthesised as BMPs so the similarity
assertions are exact rather than dependent on sample photos.

```sh
lua lightroom/tests/test_plugin.lua \
    lightroom/FeaturedStacks.lrdevplugin/bin/macOS/featured-scorer
```

What it cannot cover: anything needing a real catalog — `LrExportSession`, the
metadata fields, the collections, the grid selection. Those are only ever
exercised by loading the plug-in in Lightroom Classic.

Two rules the harness enforces, both learned the hard way:

* **`LrTasks.execute` yields, and views are built on the main thread.** Anything
  that shells out has to go through `LrTasks.startAsyncTask` and arrive by
  binding, or Lightroom refuses to draw the panel. `FsScorer.version` returns
  `nil` rather than raising when it cannot yield, and the stub raises the same
  way Lightroom would so the test catches a regression.
* **Lightroom runs Lua 5.1.** `unpack` is a global there and only
  `table.unpack` since 5.2, so `FsReviewDialog` accepts either. Avoid 5.2+
  syntax; `luac -p` will not catch it for you.
