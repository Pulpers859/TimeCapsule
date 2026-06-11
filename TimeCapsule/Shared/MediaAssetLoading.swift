import AVFoundation
import Photos
import UIKit

func loadImage(
    from asset: PHAsset,
    targetSize: CGSize = CGSize(width: 800, height: 800),
    contentMode: PHImageContentMode = .aspectFill
) async -> UIImage? {
    await withCheckedContinuation { continuation in
        let manager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        var didResume = false

        _ = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if isDegraded { return }
            if didResume { return }
            didResume = true
            continuation.resume(returning: image)
        }
    }
}

func loadPlayer(from asset: PHAsset) async -> AVPlayer? {
    await withCheckedContinuation { continuation in
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
            if let playerItem {
                continuation.resume(returning: AVPlayer(playerItem: playerItem))
            } else {
                continuation.resume(returning: nil)
            }
        }
    }
}

func exportVideoToTemporaryFile(from asset: PHAsset) async -> URL? {
    await withCheckedContinuation { continuation in
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo }) else {
            continuation.resume(returning: nil)
            return
        }

        let ext = (resource.originalFilename as NSString).pathExtension
        let filename = ext.isEmpty ? "\(UUID().uuidString).mov" : "\(UUID().uuidString).\(ext)"
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destinationURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(for: resource, toFile: destinationURL, options: options) { error in
            continuation.resume(returning: error == nil ? destinationURL : nil)
        }
    }
}
