import AVFoundation
import Photos
import UIKit

/// Renders a shareable "recap" slideshow video (title card, crossfading
/// photos) from this day's memories. Photos only — videos are skipped.
nonisolated enum MemoryRecapExporter {
    static let renderSize = CGSize(width: 1080, height: 1920)
    static let maxPhotos = 30

    /// Returns a temporary .mp4 URL, or nil on failure. `onProgress` is
    /// called with 0...1 and may arrive on any queue.
    static func export(
        assets: [PHAsset],
        title: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> URL? {
        let photos = sample(assets.filter { $0.mediaType == .image }, limit: maxPhotos)
        guard !photos.isEmpty, !Task.isCancelled else { return nil }

        let frameDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimeCapsuleRecapFrames-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: frameDirectory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: frameDirectory)
        }

        var slideURLs: [URL] = []
        if let card = renderTitleCard(title: title) {
            if let url = writeSlideImage(card, to: frameDirectory, index: slideURLs.count) {
                slideURLs.append(url)
            }
        }
        for (index, asset) in photos.enumerated() {
            guard !Task.isCancelled else { return nil }
            if let image = await loadImage(from: asset, targetSize: renderSize, contentMode: .aspectFit),
               let frame = composeFrame(image),
               let url = writeSlideImage(frame, to: frameDirectory, index: slideURLs.count) {
                slideURLs.append(url)
            }
            onProgress(0.45 * Double(index + 1) / Double(photos.count))
        }
        guard slideURLs.count > 1, !Task.isCancelled else { return nil }

        let finalSlideURLs = slideURLs
        let encodingTask = Task.detached(priority: .userInitiated) {
            writeVideo(slideURLs: finalSlideURLs) { frameProgress in
                onProgress(0.45 + 0.55 * frameProgress)
            }
        }
        return await withTaskCancellationHandler {
            await encodingTask.value
        } onCancel: {
            encodingTask.cancel()
        }
    }

    /// Evenly samples across the full set so every year is represented.
    private static func sample(_ assets: [PHAsset], limit: Int) -> [PHAsset] {
        RecapPlan.sampleIndices(itemCount: assets.count, maximum: limit).map { assets[$0] }
    }

    // MARK: - Frame composition

    /// Full-frame slide: photo aspect-fit, centered on black. Rendering
    /// through UIKit bakes in EXIF orientation so the writer never sees
    /// rotated pixels.
    private static func composeFrame(_ image: UIImage) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: renderSize))
            let fitted = aspectFitRect(for: image.size, in: renderSize)
            image.draw(in: fitted)
        }
    }

    private static func blend(_ a: UIImage, with b: UIImage, alpha: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: renderSize))
            a.draw(in: CGRect(origin: .zero, size: renderSize))
            b.draw(in: CGRect(origin: .zero, size: renderSize), blendMode: .normal, alpha: alpha)
        }
    }

    private static func renderTitleCard(title: String) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: renderSize, format: format)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: renderSize))

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 88, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 44, weight: .regular),
                .foregroundColor: UIColor.white.withAlphaComponent(0.65)
            ]
            let titleString = NSAttributedString(string: title, attributes: titleAttributes)
            let subtitleString = NSAttributedString(string: "Over the years", attributes: subtitleAttributes)

            let titleSize = titleString.size()
            let subtitleSize = subtitleString.size()
            let totalHeight = titleSize.height + 18 + subtitleSize.height
            let titleOrigin = CGPoint(
                x: (renderSize.width - titleSize.width) / 2,
                y: (renderSize.height - totalHeight) / 2
            )
            let subtitleOrigin = CGPoint(
                x: (renderSize.width - subtitleSize.width) / 2,
                y: titleOrigin.y + titleSize.height + 18
            )
            titleString.draw(at: titleOrigin)
            subtitleString.draw(at: subtitleOrigin)
        }
    }

    private static func writeSlideImage(_ image: UIImage, to directory: URL, index: Int) -> URL? {
        let url = directory.appendingPathComponent(String(format: "slide-%03d.jpg", index))
        guard let data = image.jpegData(compressionQuality: 0.92) else { return nil }
        do {
            // No `.completeFileProtection` here. These slides are read back by
            // `UIImage(contentsOfFile:)` further down, and a complete-protected
            // file becomes unreadable the moment the screen locks — which is
            // exactly what happens when the user sets a long recap going and
            // stops touching the phone. The container's default protection
            // (complete-until-first-user-authentication) is the right level: the
            // file is already unreadable while the device is locked at boot, and
            // it is deleted as soon as the export finishes.
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private static func aspectFitRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Video writing

    private static func writeVideo(slideURLs: [URL], onProgress: (Double) -> Void) -> URL? {
        // Written into the shared export directory rather than loose in `tmp`
        // so `sweepStaleShareExports()` can reclaim it. A recap is handed to
        // the share sheet exactly like a single memory, so it leaks the same
        // way if the app is killed while the sheet is open.
        let url = shareExportDirectory()
            .appendingPathComponent("TimeCapsuleRecap-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: url)
            }
        }

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(renderSize.width),
                kCVPixelBufferHeightKey as String: Int(renderSize.height)
            ]
        )
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)

        // `cancelWriting()` is only legal while the writer is actually writing.
        // Calling it on a writer that has already failed — or that is finishing
        // — is documented misuse and raises an Objective-C exception, which
        // Swift cannot catch, so it would take the app down rather than
        // surfacing the "Couldn't create the recap" alert the code intends.
        func abortWriting() {
            guard writer.status == .writing else { return }
            writer.cancelWriting()
        }

        let timescale: CMTimeScale = 600
        let hold = CMTime(value: 1080, timescale: timescale)    // 1.8s per slide
        let fadeStep = CMTime(value: 60, timescale: timescale)  // 0.1s per blend frame
        let fadeFrames = 5                                       // 0.5s crossfade

        var time = CMTime.zero
        var appended = 0
        let totalAppends = slideURLs.count + max(slideURLs.count - 1, 0) * fadeFrames

        // Budgets are counted in polls, not wall-clock time. A `Date()` deadline
        // measures how long the *clock* ran, and the clock keeps running while
        // the app is suspended in the background — so backgrounding a recap for
        // a minute used to blow every remaining deadline instantly and lose the
        // export. Counting polls measures time actually spent waiting, which is
        // what the budget was meant to express, and is immune to suspension.
        let readinessPollInterval: TimeInterval = 0.01
        let readinessPollBudget = Int(10 / readinessPollInterval)

        func append(_ image: UIImage, at presentationTime: CMTime) -> Bool {
            // One drain point per frame. Each append allocates a 1080x1920
            // pixel buffer and a CGContext (~8 MB), and `writeVideo` is one
            // long synchronous job with no suspension point, so without an
            // explicit pool nothing is released until the whole export ends.
            return autoreleasepool { () -> Bool in
                guard let buffer = pixelBuffer(from: image, pool: adaptor.pixelBufferPool) else { return false }
                var pollsRemaining = readinessPollBudget
                while !input.isReadyForMoreMediaData {
                    guard !Task.isCancelled,
                          writer.status == .writing,
                          pollsRemaining > 0 else {
                        return false
                    }
                    pollsRemaining -= 1
                    Thread.sleep(forTimeInterval: readinessPollInterval)
                }
                guard !Task.isCancelled else { return false }
                let ok = adaptor.append(buffer, withPresentationTime: presentationTime)
                appended += 1
                onProgress(Double(appended) / Double(totalAppends))
                return ok
            }
        }

        guard var previousSlide = UIImage(contentsOfFile: slideURLs[0].path) else {
            abortWriting()
            return nil
        }

        guard append(previousSlide, at: time) else {
            abortWriting()
            return nil
        }
        time = time + hold

        for nextURL in slideURLs.dropFirst() {
            guard !Task.isCancelled else {
                abortWriting()
                return nil
            }
            guard let nextSlide = UIImage(contentsOfFile: nextURL.path) else {
                abortWriting()
                return nil
            }

            for step in 1...fadeFrames {
                let appendedFrame = autoreleasepool { () -> Bool in
                    let alpha = CGFloat(step) / CGFloat(fadeFrames + 1)
                    return append(blend(previousSlide, with: nextSlide, alpha: alpha), at: time)
                }
                guard appendedFrame else {
                    abortWriting()
                    return nil
                }
                time = time + fadeStep
            }

            guard append(nextSlide, at: time) else {
                abortWriting()
                return nil
            }
            time = time + hold
            previousSlide = nextSlide
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: time)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        // Same poll-budget reasoning as the readiness wait above. Note there is
        // no `cancelWriting()` in this loop: `finishWriting` has already been
        // called, and no other method may be invoked on the writer afterwards.
        // Giving up here means giving up on waiting, not cancelling the write.
        var finishPollsRemaining = 300  // 300 x 0.1s = 30s of real waiting
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            guard !Task.isCancelled, finishPollsRemaining > 0 else {
                return nil
            }
            finishPollsRemaining -= 1
        }
        completed = writer.status == .completed
        // Deliberately no file-protection attribute. This file exists only to
        // be handed to another app through the share sheet, so protecting it
        // buys no privacy, and marking it `.complete` makes it unreadable the
        // moment the screen locks — including while the receiving app is still
        // uploading it.
        return completed ? url : nil
    }

    private static func pixelBuffer(from image: UIImage, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            let attrs = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true
            ] as CFDictionary
            CVPixelBufferCreate(
                nil,
                Int(renderSize.width),
                Int(renderSize.height),
                kCVPixelFormatType_32ARGB,
                attrs,
                &buffer
            )
        }
        guard let buffer, let cgImage = image.cgImage else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(origin: .zero, size: renderSize))
        return buffer
    }
}
