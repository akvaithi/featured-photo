import Photos
import SwiftUI

/// Loads and displays a PHAsset thumbnail asynchronously, with a simple in-memory cache.
struct AssetImage: View {
    let asset: PHAsset
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
        .task(id: asset.localIdentifier) {
            if let cached = ThumbnailCache.shared.image(for: asset.localIdentifier, size: maxDimension) {
                image = cached
                return
            }
            let loaded = await PhotoLibrary.image(for: asset, maxDimension: maxDimension)
            if let loaded {
                ThumbnailCache.shared.store(loaded, for: asset.localIdentifier, size: maxDimension)
            }
            image = loaded
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
