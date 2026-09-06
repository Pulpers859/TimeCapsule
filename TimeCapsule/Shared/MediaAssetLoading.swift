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

/// Cancellation plumbing for the `requestExportSession` round trip, in the
/// same shape as the image and player request states above.
private nonisolated final class VideoExportSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AVAssetExportSession?, Never>?
    private var requestID = PHInvalidImageRequestID
    private var didFinish = false

    func setContinuation(_ continuation: CheckedContinuation<AVAssetExportSession?, Never>) -> Bool {
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

    func resume(returning value: AVAssetExportSession?) {
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

/// Directory that every share export is written into.
///
/// Shares get their own subdirectory so stale ones can be found and swept
/// later. The previous code wrote loose files into `tmp` and relied entirely on
/// `completionWithItemsHandler` to clean them up, which leaks whenever the app
/// is killed while the share sheet is open.
func shareExportDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TimeCapsuleShare", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Deletes share exports left behind by a previous run.
///
/// The grace period matters: a share extension may still be reading the file
/// after the share sheet reports completion, so nothing recent is touched.
func sweepStaleShareExports(olderThan age: TimeInterval = 600) {
    let directory = shareExportDirectory()
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ) else { return }

    let cutoff = Date().addingTimeInterval(-age)
    for entry in entries {
        let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let modified, modified > cutoff { continue }
        try? FileManager.default.removeItem(at: entry)
    }
}

/// Exports a video to a temporary file suitable for handing to another app.
///
/// Two deliberate choices here, both of which are corrections:
///
/// This asks Photos for an export session rather than downloading the raw
/// `PHAssetResource`. The resource list holds the *original* recording, so an
/// edited video — trimmed, filtered, slowed — was previously shared as its
/// unedited original while Photos.app shares the rendered version the user is
/// actually looking at. `version = .current` asks for that rendered version.
///
/// The output is `.mp4` rather than `.mov`. `AVAssetExportPresetHighestQuality`
/// is documented to produce H.264 video and AAC audio in either container, so
/// this costs nothing, and `.mp4` is the container third-party share extensions
/// are most reliably exercised against.
///
/// Note there is no file-protection attribute. A file whose entire purpose is
/// to be handed to another process gains no privacy from one, and marking it
/// `.complete` makes it unreadable if the screen locks while the receiving app
/// is still uploading.
func exportVideoToTemporaryFile(from asset: PHAsset) async -> URL? {
    let state = VideoExportSessionState()
    guard let exporter = await withTaskCancellationHandler(operation: {
        await videoExportSession(for: asset, state: state)
    }, onCancel: {
        state.cancel()
    }) else { return nil }

    guard !Task.isCancelled else { return nil }

    let usesMP4 = exporter.supportedFileTypes.contains(.mp4)
    let fileType: AVFileType = usesMP4 ? .mp4 : .mov
    let destinationURL = shareExportDirectory()
        .appendingPathComponent("TimeCapsuleShare-\(UUID().uuidString).\(usesMP4 ? "mp4" : "mov")")
    try? FileManager.default.removeItem(at: destinationURL)

    // The documented, Apple-maintained privacy scrub: it drops location and
    // identifying metadata from the shared copy. Deliberately not paired with
    // `metadata = []`, which is redundant with the filter and interacts with it
    // in ways Apple does not document.
    exporter.metadataItemFilter = AVMetadataItemFilter.forSharing()
    exporter.shouldOptimizeForNetworkUse = true

    do {
        try await exporter.export(to: destinationURL, as: fileType)
    } catch {
        try? FileManager.default.removeItem(at: destinationURL)
        return nil
    }

    guard !Task.isCancelled else {
        try? FileManager.default.removeItem(at: destinationURL)
        return nil
    }
    return destinationURL
}

private nonisolated func videoExportSession(
    for asset: PHAsset,
    state: VideoExportSessionState
) async -> AVAssetExportSession? {
    await withCheckedContinuation { (continuation: CheckedContinuation<AVAssetExportSession?, Never>) in
        guard state.setContinuation(continuation) else { return }

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let requestID = PHImageManager.default().requestExportSession(
            forVideo: asset,
            options: options,
            exportPreset: AVAssetExportPresetHighestQuality
        ) { exportSession, _ in
            state.resume(returning: exportSession)
        }
        state.setRequestID(requestID)
    }
}
