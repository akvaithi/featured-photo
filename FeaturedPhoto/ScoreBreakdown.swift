/// Explains how a photo's best-shot score was composed (for display + tuning).
///
/// This type and `Scorer` are the two files shared verbatim with the Lightroom
/// plug-in's `featured-scorer` helper (see `lightroom/scripts/build-scorer.sh`),
/// so that both front ends rank photos identically. Keep them free of PhotoKit,
/// AppKit and SwiftUI imports — the helper is a plain command-line tool.
struct ScoreBreakdown: Hashable, Codable {
    var total: Double
    var aesthetic: Double   // 0...1 (composition/exposure/blur)
    var isUtility: Bool     // screenshot / document / receipt
    var faceCount: Int
    var faceQuality: Double // 0...1 (sharp, well-captured faces)
    var eyesOpen: Double    // 0...1 fraction of faces with both eyes open
    var smiling: Double     // 0...1 fraction of faces smiling
}
