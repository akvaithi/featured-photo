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

    @Published var phase: Phase = .idle
    @Published var stacks: [PhotoStack] = []
    @Published var config = StackConfig()

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

    func scan() async {
        let status = await PhotoLibrary.requestAuthorization()
        guard status == .authorized || status == .limited else {
            phase = .denied
            return
        }

        phase = .scanning(progress: 0, note: "Fetching photos…")
        stacks = []

        let limit = config.scanLimit
        let assets = await Task.detached { PhotoLibrary.fetchRecentImageAssets(limit: limit) }.value

        // 1. Cluster consecutive shots taken close in time.
        let timeClusters = clusterByTime(assets, window: config.timeWindow)

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
            var subGroups: [[PHAsset]] = []
            for (_, part) in partitions where part.count >= 2 {
                subGroups += subClusterBySimilarity(part, prints: prints, threshold: config.similarityThreshold)
            }

            // 4. Score members of every real (size >= 2) sub-group and pick the top.
            for group in subGroups where group.count >= 2 {
                var items: [PhotoItem] = []
                for asset in group {
                    var item = PhotoItem(
                        id: asset.localIdentifier,
                        asset: asset,
                        creationDate: asset.creationDate ?? .distantPast
                    )
                    if let cg = images[asset.localIdentifier] {
                        let breakdown = await Scorer.bestShot(cg)
                        item.score = breakdown.total
                        item.breakdown = breakdown
                    }
                    items.append(item)
                }
                items.sort { $0.score > $1.score }

                // Record how similar each shot is to the chosen top pick (for display/tuning).
                if let topPrint = prints[items[0].id] {
                    for idx in items.indices where idx != 0 {
                        if let fp = prints[items[idx].id] {
                            items[idx].distanceToTop = Scorer.distance(topPrint, fp)
                        }
                    }
                }

                built.append(PhotoStack(items: items))
            }
        }

        built.sort { $0.date > $1.date } // newest stacks first
        stacks = built
        phase = .done
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

    // MARK: - Grouping helpers

    private func clusterByTime(_ assets: [PHAsset], window: TimeInterval) -> [[PHAsset]] {
        var clusters: [[PHAsset]] = []
        var current: [PHAsset] = []
        var lastDate: Date?

        for asset in assets {
            let date = asset.creationDate ?? .distantPast
            if let last = lastDate, date.timeIntervalSince(last) <= window {
                current.append(asset)
            } else {
                if !current.isEmpty { clusters.append(current) }
                current = [asset]
            }
            lastDate = date
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    private func subClusterBySimilarity(
        _ cluster: [PHAsset],
        prints: [String: FeaturePrintObservation],
        threshold: Double
    ) -> [[PHAsset]] {
        var groups: [[PHAsset]] = []
        var reps: [FeaturePrintObservation?] = [] // kept index-aligned with `groups`

        for asset in cluster {
            guard let fp = prints[asset.localIdentifier] else {
                groups.append([asset]) // no fingerprint → its own singleton
                reps.append(nil)
                continue
            }
            var placed = false
            for i in groups.indices {
                guard let rep = reps[i] else { continue }
                if Scorer.distance(rep, fp) <= threshold {
                    groups[i].append(asset)
                    placed = true
                    break
                }
            }
            if !placed {
                groups.append([asset])
                reps.append(fp)
            }
        }
        return groups
    }
}
