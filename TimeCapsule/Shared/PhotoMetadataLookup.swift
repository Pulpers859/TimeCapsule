import ImageIO
import Photos

/// Cancellation plumbing for `requestImageDataAndOrientation`, in the same
/// shape as the request states in `MediaAssetLoading.swift`.
private nonisolated final class MetadataRequestState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PhotoEXIF?, Never>?
    private var requestID = PHInvalidImageRequestID
    private var didFinish = false

    func setContinuation(_ continuation: CheckedContinuation<PhotoEXIF?, Never>) -> Bool {
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

    func resume(returning value: PhotoEXIF?) {
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

/// Reads camera metadata straight from the file rather than from anything
/// PhotoKit surfaces on `PHAsset` itself, because `PHAsset` doesn't carry it —
/// no aperture, no ISO, no lens. Getting at it means asking for the original
/// bytes and reading their EXIF/TIFF blocks with ImageIO.
///
/// `@concurrent`: see the isolation note atop `MediaAssetLoading.swift`. This
/// runs from a SwiftUI `.task`, and decoding a multi-megabyte image's
/// metadata off the main actor is the whole point.
@concurrent
nonisolated func photoEXIF(for asset: PHAsset) async -> PhotoEXIF? {
    guard asset.mediaType == .image else { return nil }
    let state = MetadataRequestState()
    return await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { (continuation: CheckedContinuation<PhotoEXIF?, Never>) in
            guard state.setContinuation(continuation) else { return }

            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false
            options.version = .current

            let requestID = PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if isDegraded { return }
                state.resume(returning: parsedEXIF(from: data))
            }
            state.setRequestID(requestID)
        }
    }, onCancel: {
        state.cancel()
    })
}

private nonisolated func parsedEXIF(from data: Data?) -> PhotoEXIF? {
    guard let data,
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return nil
    }

    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]

    return PhotoEXIF(
        make: tiff?[kCGImagePropertyTIFFMake] as? String,
        model: tiff?[kCGImagePropertyTIFFModel] as? String,
        lensModel: exif?[kCGImagePropertyExifLensModel] as? String,
        fNumber: exif?[kCGImagePropertyExifFNumber] as? Double,
        exposureTime: exif?[kCGImagePropertyExifExposureTime] as? Double,
        iso: (exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first,
        focalLength35mm: exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int
    )
}
