import Foundation
import Photos

/// A single photo candidate within (or outside of) a stack.
struct PhotoItem: Identifiable, Hashable {
    let id: String          // PHAsset.localIdentifier
    let asset: PHAsset
    let creationDate: Date
    var score: Double = 0   // best-shot score, higher = better
    var breakdown: ScoreBreakdown?
    var distanceToTop: Double?  // feature-print distance to the stack's top pick (lower = more similar)

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Coarse orientation buckets. Photos only group with the same bucket.
enum PhotoOrientation: String {
    case portrait, landscape, square
}

extension PHAsset {
    var orientationBucket: PhotoOrientation {
        let w = Double(pixelWidth), h = Double(pixelHeight)
        guard w > 0, h > 0 else { return .square }
        let ratio = w / h
        if ratio > 1.15 { return .landscape }
        if ratio < 0.87 { return .portrait }
        return .square
    }
}

/// Explains how a photo's best-shot score was composed (for display + tuning).
struct ScoreBreakdown: Hashable {
    var total: Double
    var aesthetic: Double   // 0...1 (composition/exposure/blur)
    var isUtility: Bool     // screenshot / document / receipt
    var faceCount: Int
    var faceQuality: Double // 0...1 (sharp, well-captured faces)
    var eyesOpen: Double    // 0...1 fraction of faces with both eyes open
    var smiling: Double     // 0...1 fraction of faces smiling
}

/// A group of near-identical photos. `items` is sorted best-first.
struct PhotoStack: Identifiable {
    let id = UUID()
    var items: [PhotoItem]

    var topPick: PhotoItem { items[0] }
    var others: [PhotoItem] { Array(items.dropFirst()) }
    var count: Int { items.count }
    var date: Date { topPick.creationDate }
}

/// Tunable knobs for the stacking engine.
struct StackConfig {
    /// Max seconds between consecutive shots to be considered the same burst/session.
    var timeWindow: TimeInterval = 12
    /// Vision feature-print distance threshold. Lower = stricter (more identical).
    var similarityThreshold: Double = 0.5
    /// How many of the most recent photos to scan.
    var scanLimit: Int = 600
    /// Only group photos captured by the same camera (EXIF make/model/lens).
    var requireSameCamera: Bool = true
}
