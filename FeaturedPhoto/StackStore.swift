import Foundation
import Photos
import SwiftUI
import Vision

@MainActor
final class StackStore: ObservableObject {

    enum Phase: Equatable {
        case idle
        case denied
        case scanning(progress: Double, note: String)
        case done
    }

    /// What the current results came from, so the UI can say so and can hide
    /// actions that only make sense for one of them.
    enum Origin: Equatable {
        case library
        case folder(URL)

        var folderName: String? {
            if case .folder(let url) = self { return url.lastPathComponent }
            return nil
        }
    }

    @Published var phase: Phase = .idle
    @Published var stacks: [PhotoStack] = []
    @Published var config = StackConfig()
    @Published private(set) var origin: Origin = .library

    /// Resolution used for Vision analysis. Small keeps it fast; Vision models are robust to this.
    private let analysisSize: CGFloat = 256

    /// Session cache of EXIF camera identity per asset (keyed by localIdentifier).
    private var cameraKeyCache: [String: String] = [:]

    private func cameraKey(for asset: PHAsset) async -> String {
        if let cached = cameraKeyCache[asset.localIdentifier] { return cached }
        let key = await PhotoLibrary.cameraKey(for: asset)
        cameraKeyCache[asset.localIdentifier] = key
        return key
    }

    // MARK: - Scanning the Photos library

    func scan() async {
        let status = await PhotoLibrary.requestAuthorization()
        guard status == .authorized || status == .limited else {
            phase = .denied
            return
        }

        origin = .library
        phase = .scanning(progress: 0, note: "Fetching photos…")
        stacks = []

        let limit = config.scanLimit
        let assets = await Task.detached { PhotoLibrary.fetchRecentImageAssets(limit: limit) }.value

        // 1. Cluster consecutive shots taken close in time.
        let timeClusters = Clustering.byTime(assets, window: config.timeWindow) {
            $0.creationDate ?? .distantPast
        }

        var built: [PhotoStack] = []
        let candidateClusters = timeClusters.filter { $0.count >= 2 }
        let total = max(candidateClusters.count, 1)

        for (index, cluster) in candidateClusters.enumerated() {
            phase = .scanning(
                progress: Double(index) / Double(total),
                note: "Analyzing group \(index + 1) of \(candidateClusters.count)…"
            )

            // 2. Load analysis images, feature prints, and camera identity for this cluster.
            var prints: [String: FeaturePrintObservation] = [:]
            var images: [String: CGImage] = [:]
            var cameras: [String: String] = [:]
            for asset in cluster {
                guard let cg = await PhotoLibrary.cgImage(for: asset, maxDimension: analysisSize) else { continue }
                images[asset.localIdentifier] = cg
                if let fp = await Scorer.featurePrint(cg) {
                    prints[asset.localIdentifier] = fp
                }
                if config.requireSameCamera {
                    cameras[asset.localIdentifier] = await cameraKey(for: asset)
                }
            }

            // 3. Partition by orientation (and camera, if required) so only matching shots
            //    group together, then sub-cluster each partition by visual similarity.
            let partitions = Dictionary(grouping: cluster) { asset -> String in
                let camera = config.requireSameCamera ? (cameras[asset.localIdentifier] ?? "") : ""
                return "\(asset.orientationBucket.rawValue)#\(camera)"
            }

            var sources: [String: PhotoSource] = [:]
            var dates: [String: Date] = [:]
            var subGroups: [[String]] = []
            for (_, part) in partitions where part.count >= 2 {
                let ids = part.compactMap { asset -> String? in
                    guard images[asset.localIdentifier] != nil else { return nil }
                    sources[asset.localIdentifier] = .library(asset)
                    dates[asset.localIdentifier] = asset.creationDate ?? .distantPast
                    return asset.localIdentifier
                }
                subGroups += Clustering.bySimilarity(ids, prints: prints, threshold: config.similarityThreshold)
            }

            // 4. Score members of every real (size >= 2) sub-group and pick the top.
            built += await rank(
                subGroups,
                images: images,
                prints: prints,
                sources: sources,
                dates: dates
            )
        }

        built.sort { $0.date > $1.date } // newest stacks first
        stacks = built
        phase = .done
    }

    // MARK: - Scanning a folder

    /// Runs the same pipeline over a folder of image files.
    ///
    /// The gating half differs — capture time, orientation and camera come from
    /// each file's EXIF rather than from PhotoKit — but everything from the
    /// feature prints on is the code the library scan uses.
    func scanFolder(_ folder: URL) async {
        origin = .folder(folder)
        phase = .scanning(progress: 0, note: "Reading \(folder.lastPathComponent)…")
        stacks = []

        let window = config.timeWindow
        let sameCamera = config.requireSameCamera

        // Enumerating and reading EXIF for a large folder blocks; keep it off the
        // main actor so the progress view stays live.
        let groups = await Task.detached { () -> [[FolderLibrary.FilePhoto]] in
            let files = FolderLibrary.imageFiles(under: folder, recursive: true)
            let photos = files.compactMap(FolderLibrary.read).sorted { $0.date < $1.date }
            return FolderLibrary.candidateGroups(
                photos,
                timeWindow: window,
                requireSameCamera: sameCamera
            )
        }.value

        var built: [PhotoStack] = []
        let total = max(groups.count, 1)

        for (index, group) in groups.enumerated() {
            phase = .scanning(
                progress: Double(index) / Double(total),
                note: "Analyzing group \(index + 1) of \(groups.count)…"
            )

            var images: [String: CGImage] = [:]
            var prints: [String: FeaturePrintObservation] = [:]
            var sources: [String: PhotoSource] = [:]
            var dates: [String: Date] = [:]
            var ids: [String] = []

            for photo in group {
                let size = Int(analysisSize)
                let url = photo.url
                // Decoding is CPU-bound; off the main actor so the progress
                // view keeps redrawing during a long scan.
                let decoded = await Task.detached(priority: .userInitiated) {
                    FolderLibrary.cgImage(at: url, maxDimension: size)
                }.value
                guard let cg = decoded else { continue }
                images[photo.id] = cg
                sources[photo.id] = .file(photo.url)
                dates[photo.id] = photo.date
                ids.append(photo.id)
                if let fp = await Scorer.featurePrint(cg) {
                    prints[photo.id] = fp
                }
            }

            let subGroups = Clustering.bySimilarity(ids, prints: prints, threshold: config.similarityThreshold)
            built += await rank(
                subGroups,
                images: images,
                prints: prints,
                sources: sources,
                dates: dates
            )
        }

        built.sort { $0.date > $1.date }
        stacks = built
        phase = .done
    }

    // MARK: - Shared ranking

    /// Scores every real (size >= 2) sub-group and turns it into a stack whose
    /// items are ordered best first. Both scans end here.
    private func rank(
        _ subGroups: [[String]],
        images: [String: CGImage],
        prints: [String: FeaturePrintObservation],
        sources: [String: PhotoSource],
        dates: [String: Date]
    ) async -> [PhotoStack] {
        var built: [PhotoStack] = []

        for group in subGroups where group.count >= 2 {
            var items: [PhotoItem] = []
            for id in group {
                guard let source = sources[id] else { continue }
                var item = PhotoItem(
                    source: source,
                    creationDate: dates[id] ?? .distantPast
                )
                if let cg = images[id] {
                    let breakdown = await Scorer.bestShot(cg)
                    item.score = breakdown.total
                    item.breakdown = breakdown
                }
                items.append(item)
            }
            guard items.count >= 2 else { continue }
            items.sort { $0.score > $1.score }

            // Record how similar each shot is to the chosen top pick (for display/tuning).
            if let topPrint = prints[items[0].id] {
                for idx in items.indices where idx != 0 {
                    if let fp = prints[items[idx].id] {
                        items[idx].distanceToTop = Clustering.distance(topPrint, fp)
                    }
                }
            }

            built.append(PhotoStack(items: items))
        }
        return built
    }

    /// Removes the given items from a stack (after a successful library deletion).
    func removeItems(_ ids: Set<String>, from stack: PhotoStack) {
        guard let idx = stacks.firstIndex(where: { $0.id == stack.id }) else { return }
        var remaining = stacks[idx].items.filter { !ids.contains($0.id) }
        if remaining.count >= 2 {
            remaining.sort { $0.score > $1.score }
            stacks[idx].items = remaining
        } else {
            stacks.remove(at: idx) // no longer a stack
        }
    }
}
