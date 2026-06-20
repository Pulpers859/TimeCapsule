import AVFoundation
import Photos
import UIKit

private final class PhotoImageRequestState<Value>: @unchecked Sendable {
    private let cancellationValue: Value
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var requestID = PHInvalidImageRequestID
    private var didFinish = false

    init(cancellationValue: Value) {
        self.cancellationValue = cancellationValue
    }

    func setContinuation(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(returning: cancellationValue)
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

    func resume(returning value: Value) {
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
        continuation?.resume(returning: cancellationValue)
    }
}

private final class PhotoResourceRequestState<Value>: @unchecked Sendable {
    private let cancellationValue: Value
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var requestID: PHAssetResourceDataRequestID?
    private var didFinish = false

    init(cancellationValue: Value) {
        self.cancellationValue = cancellationValue
    }

    func setContinuation(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(returning: cancellationValue)
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

    func resume(returning value: Value) {
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
        continuation?.resume(returning: cancellationValue)
    }
}

func loadImage(
    from asset: PHAsset,
    targetSize: CGSize = CGSize(width: 800, height: 800),
    contentMode: PHImageContentMode = .aspectFill
) async -> UIImage? {
    let state = PhotoImageRequestState<UIImage?>(cancellationValue: nil)
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
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
    } onCancel: {
        state.cancel()
    }
}

func loadPlayer(from asset: PHAsset) async -> AVPlayer? {
    let state = PhotoImageRequestState<AVPlayer?>(cancellationValue: nil)
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
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
    } onCancel: {
        state.cancel()
    }
}

func exportVideoToTemporaryFile(from asset: PHAsset) async -> URL? {
    let state = PhotoResourceRequestState<URL?>(cancellationValue: nil)
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            guard state.setContinuation(continuation) else { return }

            let resources = PHAssetResource.assetResources(for: asset)
            guard let resource = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo }) else {
                state.resume(returning: nil)
                return
            }

            let ext = (resource.originalFilename as NSString).pathExtension
            let filename = ext.isEmpty ? "\(UUID().uuidString).mov" : "\(UUID().uuidString).\(ext)"
            let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: destinationURL)

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            let requestID = PHAssetResourceManager.default().writeData(for: resource, toFile: destinationURL, options: options) { error in
                state.resume(returning: error == nil ? destinationURL : nil)
            }
            state.setRequestID(requestID)
        }
    } onCancel: {
        state.cancel()
    }
}
