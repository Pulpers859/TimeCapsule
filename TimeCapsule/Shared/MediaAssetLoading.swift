import AVFoundation
import Photos
import UIKit

private nonisolated final class ImageRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?
    private var requestID = PHInvalidImageRequestID
    private var didFinish = false

    func setContinuation(_ continuation: CheckedContinuation<UIImage?, Never>) -> Bool {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setRequestID(_ requestID: PHImageRequestID) {
        lock.lock()
        if didFinish {
            lock.unlock()
            PHImageManager.default().cancelImageRequest(requestID)
            return
        }
        self.requestID = requestID
        lock.unlock()
    }

    func resume(returning value: UIImage?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: value)
    }

    func cancel() {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let requestID = requestID
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if requestID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(requestID)
        }
        continuation?.resume(returning: nil)
    }
}

private nonisolated final class PlayerRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AVPlayer?, Never>?
    private var requestID = PHInvalidImageRequestID
    private var didFinish = false

    func setContinuation(_ continuation: CheckedContinuation<AVPlayer?, Never>) -> Bool {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setRequestID(_ requestID: PHImageRequestID) {
        lock.lock()
        if didFinish {
            lock.unlock()
            PHImageManager.default().cancelImageRequest(requestID)
            return
        }
        self.requestID = requestID
        lock.unlock()
    }

    func resume(returning value: AVPlayer?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: value)
    }

    func cancel() {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let requestID = requestID
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if requestID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(requestID)
        }
        continuation?.resume(returning: nil)
    }
}

private nonisolated final class VideoExportRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL?, Never>?
    private var requestID: PHAssetResourceDataRequestID?
    private var didFinish = false

    func setContinuation(_ continuation: CheckedContinuation<URL?, Never>) -> Bool {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(returning: nil)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setRequestID(_ requestID: PHAssetResourceDataRequestID) {
        lock.lock()
        if didFinish {
            lock.unlock()
            PHAssetResourceManager.default().cancelDataRequest(requestID)
            return
        }
        self.requestID = requestID
        lock.unlock()
    }

    func resume(returning value: URL?) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: value)
    }

    func cancel() {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didFinish = true
        let requestID = requestID
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if let requestID {
            PHAssetResourceManager.default().cancelDataRequest(requestID)
        }
        continuation?.resume(returning: nil)
    }
}

func loadImage(
    from asset: PHAsset,
    targetSize: CGSize = CGSize(width: 800, height: 800),
    contentMode: PHImageContentMode = .aspectFill
) async -> UIImage? {
    let state = ImageRequestState()
    return await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            guard state.setContinuation(continuation) else { return }

            let manager = PHImageManager.default()
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            let requestID = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                state.resume(returning: image)
            }
            state.setRequestID(requestID)
        }
    }, onCancel: {
        state.cancel()
    })
}

func loadPlayer(from asset: PHAsset) async -> AVPlayer? {
    let state = PlayerRequestState()
    return await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { (continuation: CheckedContinuation<AVPlayer?, Never>) in
            guard state.setContinuation(continuation) else { return }

            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            let requestID = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
                if let playerItem {
                    state.resume(returning: AVPlayer(playerItem: playerItem))
                } else {
                    state.resume(returning: nil)
                }
            }
            state.setRequestID(requestID)
        }
    }, onCancel: {
        state.cancel()
    })
}

func exportVideoToTemporaryFile(from asset: PHAsset) async -> URL? {
    let state = VideoExportRequestState()
    return await withTaskCancellationHandler(operation: {
        await exportVideoToTemporaryFile(from: asset, state: state)
    }, onCancel: {
        state.cancel()
    })
}

private nonisolated func exportVideoToTemporaryFile(
    from asset: PHAsset,
    state: VideoExportRequestState
) async -> URL? {
    await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
        guard state.setContinuation(continuation) else { return }

        guard let resource = preferredVideoResource(for: asset) else {
            state.resume(returning: nil)
            return
        }

        let destinationURL = temporaryVideoURL(for: resource)
        try? FileManager.default.removeItem(at: destinationURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let requestID = PHAssetResourceManager.default().writeData(
            for: resource,
            toFile: destinationURL,
            options: options
        ) { error in
            state.resume(returning: error == nil ? destinationURL : nil)
        }
        state.setRequestID(requestID)
    }
}

private nonisolated func preferredVideoResource(for asset: PHAsset) -> PHAssetResource? {
    let resources = PHAssetResource.assetResources(for: asset)
    return resources.first { resource in
        resource.type == .video || resource.type == .fullSizeVideo
    }
}

private nonisolated func temporaryVideoURL(for resource: PHAssetResource) -> URL {
    let ext = (resource.originalFilename as NSString).pathExtension
    let filename = ext.isEmpty ? "\(UUID().uuidString).mov" : "\(UUID().uuidString).\(ext)"
    return FileManager.default.temporaryDirectory.appendingPathComponent(filename)
}
