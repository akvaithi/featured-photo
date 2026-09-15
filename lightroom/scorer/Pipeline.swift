import CoreGraphics
import Foundation
import Vision

/// The pixel half of the algorithm: fingerprint, sub-cluster, score, rank.
///
/// Both front ends of this helper end up here — the Lightroom plug-in, which
/// hands over groups it gated on catalog metadata, and `--folder`, which gates
/// on EXIF read off the files themselves. Everything before this point differs;
/// nothing after it does.
enum Pipeline {

    struct Input {
        let id: String
        let path: String
    }

    struct Item: Encodable {
        let id: String
        let score: Double
        /// Feature-print distance to the stack's pick; nil for the pick itself.
        let distanceToTop: Double?
        let breakdown: ScoreBreakdown
    }

    struct Stack: Encodable {
        let items: [Item] // best first
    }

    struct Output {
        let stacks: [Stack]
        /// Photos whose file could not be decoded. They are never stacked.
        let unreadable: [String]
    }

    /// `progress` is called once per group with (index, total), 1-based.
    static func run(
        groups: [[Input]],
        threshold: Double,
        analysisSize: Int,
        progress: (Int, Int) -> Void = { _, _ in }
    ) async -> Output {
        var stacks: [Stack] = []
        var unreadable: [String] = []

        for (index, group) in groups.enumerated() {
            progress(index + 1, groups.count)

            // 1. Decode every candidate and fingerprint it. Feature prints are far
            //    cheaper than the scoring pass, so they come first and the scoring
            //    is then only paid for photos that actually landed in a stack.
            var images: [String: CGImage] = [:]
            var prints: [String: FeaturePrintObservation] = [:]
            for photo in group {
                let url = URL(fileURLWithPath: photo.path)
                guard let cg = FolderLibrary.cgImage(at: url, maxDimension: analysisSize) else {
                    unreadable.append(photo.id)
                    continue
                }
                images[photo.id] = cg
                if let fp = await Scorer.featurePrint(cg) {
                    prints[photo.id] = fp
                }
            }

            // 2. Split the group into runs of near-identical frames.
            let ids = group.map(\.id).filter { images[$0] != nil }
            let subGroups = Clustering.bySimilarity(ids, prints: prints, threshold: threshold)

            // 3. Score and rank each real (>= 2) sub-group.
            for sub in subGroups where sub.count >= 2 {
                var scored: [(id: String, breakdown: ScoreBreakdown)] = []
                for id in sub {
                    guard let cg = images[id] else { continue }
                    scored.append((id, await Scorer.bestShot(cg)))
                }
                guard scored.count >= 2 else { continue }
                scored.sort { $0.breakdown.total > $1.breakdown.total }

                // Record how far each frame sits from the chosen pick, which is what
                // the user reads to calibrate the similarity threshold.
                let topPrint = prints[scored[0].id]
                let items = scored.enumerated().map { offset, entry -> Item in
                    var distance: Double?
                    if offset != 0, let topPrint, let fp = prints[entry.id] {
                        distance = Scorer.distance(topPrint, fp)
                    }
                    return Item(
                        id: entry.id,
                        score: entry.breakdown.total,
                        distanceToTop: distance,
                        breakdown: entry.breakdown
                    )
                }
                stacks.append(Stack(items: items))
            }
        }

        return Output(stacks: stacks, unreadable: unreadable)
    }
}
