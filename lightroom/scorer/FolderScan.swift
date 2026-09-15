import Foundation

/// `--folder`: the whole algorithm over a folder of image files, with no Photos
/// library and no Lightroom catalog involved.
///
/// This is the standalone way to see what the grouping and ranking actually do
/// to a given set of photos — useful for calibrating the similarity threshold
/// before pointing either front end at a real library.
///
/// The work itself lives in `FolderLibrary` (enumeration, EXIF, gating) and
/// `Pipeline` (Vision), both of which the macOS app compiles too. What is left
/// here is argument plumbing and the report.
enum FolderScan {

    struct Options {
        var timeWindow: TimeInterval = 12
        var threshold: Double = 0.5
        var analysisSize: Int = 256
        var requireSameCamera: Bool = true
        var recursive: Bool = true
    }

    struct Report {
        let root: URL
        let photos: [FolderLibrary.FilePhoto]
        let fellBackToFileDate: Int
        /// Files that looked like images but whose metadata would not open —
        /// truncated downloads, unreadable permissions, a codec macOS lacks.
        /// Counted rather than dropped, so the numbers in the report add up.
        let unscannable: [URL]
        let candidateGroups: Int
        let candidateFrames: Int
        let stacks: [Pipeline.Stack]
        let unreadable: [String]
        /// Maps a Pipeline item id back to the photo it came from.
        let photosById: [String: FolderLibrary.FilePhoto]
    }

    static func run(
        root: URL,
        options: Options,
        progress: (Int, Int) -> Void = { _, _ in }
    ) async -> Report {
        let files = FolderLibrary.imageFiles(under: root, recursive: options.recursive)

        var scanned: [FolderLibrary.FilePhoto] = []
        var unscannable: [URL] = []
        for url in files {
            if let photo = FolderLibrary.read(url) {
                scanned.append(photo)
            } else {
                unscannable.append(url)
            }
        }
        let photos = scanned.sorted { $0.date < $1.date }

        let groups = FolderLibrary.candidateGroups(
            photos,
            timeWindow: options.timeWindow,
            requireSameCamera: options.requireSameCamera
        )

        var photosById: [String: FolderLibrary.FilePhoto] = [:]
        let inputs = groups.map { group in
            group.map { photo -> Pipeline.Input in
                photosById[photo.id] = photo
                return Pipeline.Input(id: photo.id, path: photo.url.path)
            }
        }

        let output = await Pipeline.run(
            groups: inputs,
            threshold: options.threshold,
            analysisSize: options.analysisSize,
            progress: progress
        )

        return Report(
            root: root,
            photos: photos,
            fellBackToFileDate: photos.filter(\.dateFromFilesystem).count,
            unscannable: unscannable,
            candidateGroups: groups.count,
            candidateFrames: groups.reduce(0) { $0 + $1.count },
            stacks: output.stacks,
            unreadable: output.unreadable,
            photosById: photosById
        )
    }

    // MARK: - Reporting

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// The human-readable report. `--json` prints the machine one instead.
    static func describe(_ report: Report, options: Options) -> String {
        var lines: [String] = []
        lines.append("Scanned \(report.photos.count) image\(report.photos.count == 1 ? "" : "s") in \(report.root.path)")
        if report.fellBackToFileDate > 0 {
            lines.append("  \(report.fellBackToFileDate) had no EXIF capture time; the file's own date was used")
        }
        // Never drop a file silently: a scan that quietly ignored half a folder
        // would read as a scan that found nothing worth stacking.
        if !report.unscannable.isEmpty {
            lines.append("  \(report.unscannable.count) could not be opened and were skipped:")
            for url in report.unscannable.prefix(5) {
                lines.append("    \(url.lastPathComponent)")
            }
            if report.unscannable.count > 5 {
                lines.append("    …and \(report.unscannable.count - 5) more")
            }
        }
        lines.append("  \(report.candidateFrames) frames in \(report.candidateGroups) candidate group(s) after the \(Int(options.timeWindow))s / orientation\(options.requireSameCamera ? " / camera" : "") gate")
        if !report.unreadable.isEmpty {
            lines.append("  \(report.unreadable.count) could not be decoded")
        }
        lines.append("")

        if report.stacks.isEmpty {
            lines.append("No stacks: nothing looked like a repeat of another shot.")
            lines.append("Widen --time-window or raise --threshold to group more loosely.")
            return lines.joined(separator: "\n")
        }

        for (index, stack) in report.stacks.enumerated() {
            let when = report.photosById[stack.items[0].id].map { stamp.string(from: $0.date) } ?? ""
            lines.append("Stack \(index + 1) — \(stack.items.count) frames  \(when)")

            for (position, item) in stack.items.enumerated() {
                let name = report.photosById[item.id]?.url.lastPathComponent ?? item.id
                let marker = position == 0 ? "★" : " "
                var line = String(format: "  %@ %.3f  %@", marker, item.score, name)
                if let distance = item.distanceToTop {
                    line += String(format: "   d %.3f", distance)
                }
                if position == 0 {
                    let detail = item.breakdown
                    var notes = [String(format: "aesthetic %.2f", detail.aesthetic)]
                    if detail.faceCount > 0 {
                        notes.append("\(detail.faceCount) face\(detail.faceCount == 1 ? "" : "s")")
                        notes.append(String(format: "capture %.2f", detail.faceQuality))
                        notes.append(String(format: "eyes open %.0f%%", detail.eyesOpen * 100))
                        notes.append(String(format: "smiling %.0f%%", detail.smiling * 100))
                    }
                    if detail.isUtility { notes.append("screenshot/document") }
                    line += "   [\(notes.joined(separator: ", "))]"
                }
                lines.append(line)
            }
            lines.append("")
        }

        let frames = report.stacks.reduce(0) { $0 + $1.items.count }
        lines.append("\(report.stacks.count) stack(s), \(frames) frames, \(frames - report.stacks.count) duplicate(s) behind a better shot.")
        return lines.joined(separator: "\n")
    }
}
