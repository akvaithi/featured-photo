import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading photos out of a plain folder, as an alternative to PhotoKit.
///
/// The macOS app's "Scan Folder…" and the helper's `--folder` both come through
/// here, so a folder scanned either way sees the same files with the same
/// capture times. Like `Scorer`, `ScoreBreakdown` and `Clustering`, this file is
/// compiled into both products — keep it free of PhotoKit, AppKit and SwiftUI.
enum FolderLibrary {

    /// One image file, with everything grouping needs read from its metadata.
    struct FilePhoto: Hashable {
        let url: URL
        let date: Date
        let orientation: Clustering.Orientation
        let camera: String
        /// True when there was no EXIF capture time and the file's own date was
        /// used. Worth reporting: file dates survive a copy far less reliably.
        let dateFromFilesystem: Bool

        var id: String { url.path }
    }

    // MARK: - Enumeration

    /// Every image file under `root`, sorted by path so a run is reproducible.
    ///
    /// Hidden files are skipped, which includes files carrying macOS's
    /// `UF_HIDDEN` flag rather than a leading dot — those look perfectly normal
    /// in the Finder and in `ls -la`, and only `ls -lO` reveals them.
    static func imageFiles(under root: URL, recursive: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: options
        ) else { return [] }

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let type = values.contentType,
                  type.conforms(to: .image)
            else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }

    // MARK: - Metadata

    /// EXIF writes "2026:05:11 19:53:03" — colons in the date, and no zone.
    private static let exifFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    /// Reads capture time, dimensions and camera without decoding any pixels.
    /// Returns nil for a file ImageIO will not open at all; callers report those
    /// rather than dropping them, so a scan's counts add up.
    static func read(_ url: URL) -> FilePhoto? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }

        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

        var date: Date?
        for key in [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized] {
            if let text = exif?[key] as? String, let parsed = exifFormatter.date(from: text) {
                date = parsed
                break
            }
        }
        if date == nil, let text = tiff?[kCGImagePropertyTIFFDateTime] as? String {
            date = exifFormatter.date(from: text)
        }

        let fromFilesystem = date == nil
        if date == nil {
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            date = values?.creationDate ?? values?.contentModificationDate
        }
        guard let captureDate = date else { return nil }

        // Orientation-aware: a portrait frame from a phone is stored landscape
        // with an EXIF orientation of 6 or 8, and bucketing the stored size would
        // put it in the wrong partition.
        var width = (props[kCGImagePropertyPixelWidth] as? Double) ?? 0
        var height = (props[kCGImagePropertyPixelHeight] as? Double) ?? 0
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        if (5...8).contains(orientation) { swap(&width, &height) }

        return FilePhoto(
            url: url,
            date: captureDate,
            orientation: Clustering.orientation(width: width, height: height),
            camera: Clustering.cameraKey(
                make: tiff?[kCGImagePropertyTIFFMake] as? String,
                model: tiff?[kCGImagePropertyTIFFModel] as? String,
                lens: exif?[kCGImagePropertyExifLensModel] as? String
            ),
            dateFromFilesystem: fromFilesystem
        )
    }

    // MARK: - Pixels

    /// Decodes `url` downscaled so its longest edge is at most `maxDimension`.
    /// Returns nil for anything ImageIO cannot read.
    static func cgImage(at url: URL, maxDimension: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // kCGImageSourceCreateThumbnailWithTransform applies the EXIF orientation.
        // Without it a portrait frame reaches Vision on its side, which moves both
        // the aesthetics score and the face landmarks.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Grouping

    /// The metadata pass: sort by capture time, cluster, then split each cluster
    /// by orientation and (optionally) camera. Returns groups of two or more.
    ///
    /// This is the file-backed twin of what `StackStore` does with PHAssets and
    /// `FsGrouping.lua` does with catalog metadata.
    static func candidateGroups(
        _ photos: [FilePhoto],
        timeWindow: TimeInterval,
        requireSameCamera: Bool
    ) -> [[FilePhoto]] {
        var groups: [[FilePhoto]] = []

        for cluster in Clustering.byTime(photos, window: timeWindow, date: \.date) where cluster.count >= 2 {
            var buckets: [String: [FilePhoto]] = [:]
            var order: [String] = []
            for photo in cluster {
                let key = "\(photo.orientation.rawValue)#\(requireSameCamera ? photo.camera : "")"
                if buckets[key] == nil { order.append(key) }
                buckets[key, default: []].append(photo)
            }
            for key in order where buckets[key]!.count >= 2 {
                groups.append(buckets[key]!)
            }
        }
        return groups
    }
}
