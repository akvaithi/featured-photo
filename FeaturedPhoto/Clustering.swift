import Foundation
import Vision

/// The grouping rules that decide which photos could be the same shot, before
/// any pixels are looked at.
///
/// This file, `Scorer.swift` and `ScoreBreakdown.swift` are the three sources
/// shared verbatim with the Lightroom plug-in's `featured-scorer` helper (see
/// `lightroom/scripts/build-scorer.sh`), so a library grouped through the app,
/// through `--folder`, or through Lightroom groups the same way. Keep them free
/// of PhotoKit, AppKit and SwiftUI imports.
///
/// The plug-in's Lua half re-implements these same two rules in `FsGrouping.lua`
/// — Lua cannot call in here — and its test suite pins them to these values.
enum Clustering {

    /// Coarse orientation buckets. Photos only group with the same bucket, which
    /// is what stops a portrait and a landscape frame of one scene from merging.
    enum Orientation: String {
        case portrait, landscape, square
    }

    static func orientation(width: Double, height: Double) -> Orientation {
        guard width > 0, height > 0 else { return .square }
        let ratio = width / height
        if ratio > 1.15 { return .landscape }
        if ratio < 0.87 { return .portrait }
        return .square
    }

    /// Splits `items` into runs of consecutive frames taken within `window`
    /// seconds of each other. `items` must already be in capture order.
    ///
    /// The comparison is against the *previous frame*, not the run's start, so a
    /// long continuous burst stays one run instead of being cut every `window`
    /// seconds.
    static func byTime<T>(
        _ items: [T],
        window: TimeInterval,
        date: (T) -> Date
    ) -> [[T]] {
        var clusters: [[T]] = []
        var current: [T] = []
        var lastDate: Date?

        for item in items {
            let itemDate = date(item)
            if let last = lastDate, itemDate.timeIntervalSince(last) <= window {
                current.append(item)
            } else {
                if !current.isEmpty { clusters.append(current) }
                current = [item]
            }
            lastDate = itemDate
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    /// Groups photos that look like the same shot.
    ///
    /// Greedy and single-pass: a photo joins the first group whose representative
    /// it is within `threshold` of, otherwise it starts one. Photos with no
    /// feature print (an unreadable file) become singletons, which callers drop.
    ///
    /// Order matters — the caller passes ids in capture order, so the earliest
    /// frame of a burst becomes its group's representative.
    static func bySimilarity(
        _ ids: [String],
        prints: [String: FeaturePrintObservation],
        threshold: Double
    ) -> [[String]] {
        var groups: [[String]] = []
        var representatives: [FeaturePrintObservation?] = [] // index-aligned with `groups`

        for id in ids {
            guard let print = prints[id] else {
                groups.append([id])
                representatives.append(nil)
                continue
            }
            var placed = false
            for index in groups.indices {
                guard let representative = representatives[index] else { continue }
                if distance(representative, print) <= threshold {
                    groups[index].append(id)
                    placed = true
                    break
                }
            }
            if !placed {
                groups.append([id])
                representatives.append(print)
            }
        }
        return groups
    }

    /// Distance between two feature prints. Lower = more similar.
    /// Returns `.infinity` on failure, so a comparison that cannot be made never
    /// merges two photos.
    static func distance(_ a: FeaturePrintObservation, _ b: FeaturePrintObservation) -> Double {
        (try? a.distance(to: b)) ?? .infinity
    }

    /// Builds the "same camera" key from EXIF make, model and lens, e.g.
    /// "Apple · iPhone 15 Pro · back triple camera". Empty when nothing is known,
    /// which groups all such frames together rather than isolating each one.
    static func cameraKey(make: String?, model: String?, lens: String?) -> String {
        [make, model, lens]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}
