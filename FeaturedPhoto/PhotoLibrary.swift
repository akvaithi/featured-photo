import AppKit
import CoreGraphics
import ImageIO
import Photos

/// Thin wrapper around PhotoKit for authorization, fetching, image loading and deletion.
enum PhotoLibrary {

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                cont.resume(returning: status)
            }
        }
    }

    /// Fetches the most recent image assets, returned oldest-first for sequential grouping.
    static func fetchRecentImageAssets(limit: Int) -> [PHAsset] {
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        opts.fetchLimit = limit
        let result = PHAsset.fetchAssets(with: opts)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assets.append(asset) }
        return assets.reversed() // oldest-first
    }

    /// Loads a downscaled CGImage suitable for Vision analysis or thumbnails.
    static func cgImage(for asset: PHAsset, maxDimension: CGFloat) async -> CGImage? {
        let nsImage = await image(for: asset, maxDimension: maxDimension)
        return nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    static func image(for asset: PHAsset, maxDimension: CGFloat) async -> NSImage? {
        await withCheckedContinuation { cont in
            let box = ResumeOnce(cont)
            let opts = PHImageRequestOptions()
            opts.isNetworkAccessAllowed = true
            opts.deliveryMode = .highQualityFormat
            opts.resizeMode = .fast
            opts.isSynchronous = false
            let target = CGSize(width: maxDimension, height: maxDimension)
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: target,
                contentMode: .aspectFit,
                options: opts
            ) { image, _ in
                box.resume(image)
            }
        }
    }

    /// Identifies the capturing camera from EXIF (make + model + lens), e.g.
    /// "Apple · iPhone 15 Pro · back triple camera". Empty string if unavailable.
    /// Reads metadata only from the original file — no pixel decode.
    static func cameraKey(for asset: PHAsset) async -> String {
        await withCheckedContinuation { cont in
            let box = ResumeOnce(cont)
            let opts = PHContentEditingInputRequestOptions()
            opts.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: opts) { input, _ in
                guard let url = input?.fullSizeImageURL,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                else { box.resume(""); return }

                let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
                let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                let make = (tiff?[kCGImagePropertyTIFFMake] as? String) ?? ""
                let model = (tiff?[kCGImagePropertyTIFFModel] as? String) ?? ""
                let lens = (exif?[kCGImagePropertyExifLensModel] as? String) ?? ""

                let key = [make, model, lens]
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                box.resume(key)
            }
        }
    }

    static func delete(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }
}

/// Guards a CheckedContinuation against PhotoKit delivering more than one callback.
private final class ResumeOnce<T>: @unchecked Sendable {
    private var done = false
    private let lock = NSLock()
    private let cont: CheckedContinuation<T, Never>

    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }

    func resume(_ value: T) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        cont.resume(returning: value)
    }
}
