import AppKit
import Photos
import SwiftUI

/// Loads and displays a photo's thumbnail asynchronously, with a simple
/// in-memory cache. Works for both scan sources: PhotoKit assets go through
/// `PhotoLibrary`, files on disk through `FolderLibrary`.
struct AssetImage: View {
    let source: PhotoSource
    var maxDimension: CGFloat = 400

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .task(id: source.id) {
            if let cached = ThumbnailCache.shared.image(for: source.id, size: maxDimension) {
                image = cached
                return
            }
            let loaded = await Self.load(source, maxDimension: maxDimension)
            if let loaded {
                ThumbnailCache.shared.store(loaded, for: source.id, size: maxDimension)
            }
            image = loaded
        }
    }

    private static func load(_ source: PhotoSource, maxDimension: CGFloat) async -> NSImage? {
        switch source {
        case .library(let asset):
            return await PhotoLibrary.image(for: asset, maxDimension: maxDimension)

        case .file(let url):
            // Off the main actor: decoding a full-size frame down to 1400px is
            // slow enough to drop frames in the detail view's filmstrip.
            return await Task.detached(priority: .userInitiated) {
                guard let cg = FolderLibrary.cgImage(at: url, maxDimension: Int(maxDimension)) else {
                    return nil
                }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
        }
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    private func key(_ id: String, _ size: CGFloat) -> NSString { "\(id)@\(Int(size))" as NSString }

    func image(for id: String, size: CGFloat) -> NSImage? { cache.object(forKey: key(id, size)) }
    func store(_ image: NSImage, for id: String, size: CGFloat) { cache.setObject(image, forKey: key(id, size)) }
}
