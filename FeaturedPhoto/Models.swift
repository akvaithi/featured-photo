import Foundation
import Photos

/// Where a photo in a stack came from.
///
/// A scan is either over the Photos library or over a folder on disk, never
/// both at once, but every view downstream works off this so neither has to
/// know which it is looking at.
enum PhotoSource: Hashable {
    case library(PHAsset)
    case file(URL)

    /// Stable within a scan, and unique across a library or a folder tree.
    var id: String {
        switch self {
        case .library(let asset): return asset.localIdentifier
        case .file(let url): return url.path
        }
    }

    /// The asset, when this came from the Photos library. Deletion is the only
    /// thing that needs it — the app never deletes a file off disk.
    var asset: PHAsset? {
        if case .library(let asset) = self { return asset }
        return nil
    }

    var url: URL? {
        if case .file(let url) = self { return url }
        return nil
    }

    /// Shown in the detail view for folder scans, where a filename is the only
    /// thing identifying a frame.
    var displayName: String? { url?.lastPathComponent }
}

/// A single photo candidate within (or outside of) a stack.
struct PhotoItem: Identifiable, Hashable {
    let source: PhotoSource
    let creationDate: Date
    var score: Double = 0   // best-shot score, higher = better
    var breakdown: ScoreBreakdown?
    var distanceToTop: Double?  // feature-print distance to the stack's top pick (lower = more similar)

    var id: String { source.id }

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Coarse orientation buckets. Photos only group with the same bucket.
/// The thresholds live in `Clustering`, which the Lightroom helper shares.
typealias PhotoOrientation = Clustering.Orientation

extension PHAsset {
    var orientationBucket: PhotoOrientation {
        Clustering.orientation(width: Double(pixelWidth), height: Double(pixelHeight))
    }
}

/// A group of near-identical photos. `items` is sorted best-first.
struct PhotoStack: Identifiable {
    let id = UUID()
    var items: [PhotoItem]

    var topPick: PhotoItem { items[0] }
    var others: [PhotoItem] { Array(items.dropFirst()) }
    var count: Int { items.count }
    var date: Date { topPick.creationDate }

    /// Folder scans have nothing to delete through — the app only ever deletes
    /// via PhotoKit, which puts photos in Recently Deleted rather than removing
    /// files from someone's disk.
    var isDeletable: Bool { items.allSatisfy { $0.source.asset != nil } }
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
