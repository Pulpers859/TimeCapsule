import AVFoundation
import Photos
import UIKit
import Vision

/// Renders a shareable "recap" slideshow video (title card, crossfading
/// photos) from this day's memories. Photos only — videos are skipped.
nonisolated enum MemoryRecapExporter {
    static let renderSize = CGSize(width: 1080, height: 1920)
    static let maxPhotos = 30

    /// Motion is what separates a slideshow from a montage, so each photo gets
    /// a slow push in or pull out rather than sitting still.
    ///
    /// The cost is real and worth stating plainly: holding a slide used to be
    /// a *single* appended frame stretched over 1.8 seconds by its
    /// presentation timestamp. Motion means actually encoding every frame of
    /// that 1.8 seconds, so a full recap goes from ~180 appends to ~1700. That
    /// is paid for by drawing each frame directly into the pixel buffer
    /// instead of rendering an intermediate `UIImage` first, which is what the
    /// crossfade used to do.
    static let framesPerSecond = 24
    static let holdFrames = 43   // ~1.8s
    static let fadeFrames = 12   // ~0.5s
    static let maxZoom = 1.08

    nonisolated private struct Slide {
        let url: URL
        let zoomFrom: Double
        let zoomTo: Double
        let focusX: Double
        let focusY: Double
    }

    nonisolated private struct Layer {
        let image: CGImage
        let rect: CGRect
        let alpha: CGFloat
    }

    nonisolated private struct ActiveSlide {
        let image: CGImage
        let base: CGRect
        let slide: Slide
        let visibleTotal: Int
        var visibleIndex: Int
    }

    /// Returns a temporary .mp4 URL, or nil on failure. `onProgress` is
    /// called with 0...1 and may arrive on any queue.
    static func export(
        assets: [PHAsset],
        title: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async -> URL? {
        let photos = sample(candidates(from: assets), limit: maxPhotos)
        guard !photos.isEmpty, !Task.isCancelled else { return nil }

        // Inside the shared export directory, not loose in `tmp`.
        //
        // This holds up to 31 full-frame JPEGs of the user's photos. The
        // `defer` below removes them on every normal and cancelled path, but
        // not when the process dies — and this export allocates ~8 MB a frame,
        // so being jetsammed is a real possibility, as is a force-quit
        // mid-render. Loose in `tmp` nothing would ever reclaim them, because
        // `sweepStaleShareExports()` only enumerates the share directory and
        // iOS purges `tmp` on its own unpredictable schedule.
        let frameDirectory = shareExportDirectory()
            .appendingPathComponent("TimeCapsuleRecapFrames-\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: frameDirectory, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer {
            try? FileManager.default.removeItem(at: frameDirectory)
        }

        var slides: [Slide] = []
        if let card = renderTitleCard(title: title),
           let url = writeSlideImage(card, to: frameDirectory, index: 0) {
            // The title card holds still. A block of text drifting across the
            // screen reads as a rendering fault, not as production value.
            slides.append(Slide(url: url, zoomFrom: 1, zoomTo: 1, focusX: 0.5, focusY: 0.5))
        }
        // The title card is a slide but not a memory, and it may or may not
        // have rendered, so the photo count has to be measured rather than
        // assumed. See the guard below.
        let titleSlideCount = slides.count
        for (index, asset) in photos.enumerated() {
            guard !Task.isCancelled else { return nil }
            // Alternating the direction keeps consecutive slides from all
            // drifting the same way, which reads as a stuck animation.
            let pushesIn = slides.count.isMultiple(of: 2)
            if let image = await loadImage(from: asset, targetSize: renderSize, contentMode: .aspectFit),
               let slide = await stageSlide(
                   image,
                   to: frameDirectory,
                   index: slides.count,
                   pushesIn: pushesIn
               ) {
                slides.append(slide)
            }
            onProgress(0.45 * Double(index + 1) / Double(photos.count))
        }
        // Two actual photographs, not two slides. `slides.count > 1` was
        // satisfied by the title card plus a single photo, which is not a
        // recap — and it was reachable without the caller doing anything
        // wrong: the UI counts every image, while `candidates` drops
        // screenshots, so a day holding one photo and one screenshot passed
        // the caller's "at least 2 photos" check and arrived here with one
        // usable image. A photo failing to load (an iCloud original with no
        // connection) lands in the same place.
        guard slides.count - titleSlideCount >= 2, !Task.isCancelled else { return nil }

        let finalSlides = slides
        let encodingTask = Task.detached(priority: .userInitiated) {
            writeVideo(slides: finalSlides) { frameProgress in
                onProgress(0.45 + 0.55 * frameProgress)
            }
        }
        return await withTaskCancellationHandler {
            await encodingTask.value
        } onCancel: {
            encodingTask.cancel()
        }
    }

    /// What is eligible to appear in a recap at all.
    ///
    /// Screenshots are the single loudest complaint about Google Photos'
    /// memories: it pulls from the whole camera roll, so receipts, memes and
    /// shipping confirmations turn up alongside real memories. PhotoKit hands
    /// us that distinction for free in `mediaSubtypes`, with no pixels loaded.
    ///
    /// The fallback matters. If a day holds nothing but screenshots, showing
    /// them is still better than reporting that the recap failed.
    ///
    /// Not private: the gallery decides whether to offer the recap button at
    /// all, and it has to count the same things this does. Counting every
    /// image there while dropping screenshots here is how a day with one
    /// photo and one screenshot got offered a recap it could not make.
    static func candidates(from assets: [PHAsset]) -> [PHAsset] {
        let images = assets.filter { $0.mediaType == .image }
        let photographs = images.filter { !$0.mediaSubtypes.contains(.photoScreenshot) }
        return photographs.isEmpty ? images : photographs
    }

    /// Evenly samples across the full set so every year is represented, then
    /// lets each pick drift by a single place to land on a favourite.
    private static func sample(_ assets: [PHAsset], limit: Int) -> [PHAsset] {
        let indices = RecapPlan.sampleIndices(
            itemCount: assets.count,
            maximum: limit,
            preferring: assets.map(\.isFavorite)
        )
        return indices.map { assets[$0] }
    }

    // MARK: - Frame composition

    /// Redraws the photo at its fitted size on an opaque canvas.
    ///
    /// Two jobs. It bakes in EXIF orientation, so the writer never sees
    /// rotated pixels. And it deliberately does *not* letterbox: the slide on
    /// disk is the photo alone, because the pan and zoom are applied to the
    /// photo's rectangle at encode time. Letterboxing first would scale the
    /// black bars along with the picture.
    private static func normalizedPhoto(_ image: UIImage) -> UIImage? {
        let fitted = aspectFitRect(for: image.size, in: renderSize).size
        guard fitted.width >= 1, fitted.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: fitted, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: fitted))
        }
    }

    /// Normalises, measures and writes one slide, off the main actor.
    ///
    /// `export` is called from a `Task` inside a SwiftUI view, and this target
    /// builds with `NonisolatedNonsendingByDefault`, so a plain `nonisolated
    /// async` function here would still run on the main thread — the same trap
    /// documented at length in `MediaAssetLoading`. That was survivable when
    /// staging was one redraw per photo. Face detection adds tens of
    /// milliseconds per photo, thirty times over, so `@concurrent` is what
    /// keeps the progress bar moving instead of freezing the UI while a recap
    /// is prepared.
    @concurrent
    nonisolated private static func stageSlide(
        _ image: UIImage,
        to directory: URL,
        index: Int,
        pushesIn: Bool
    ) async -> Slide? {
        guard let photo = normalizedPhoto(image),
              let url = writeSlideImage(photo, to: directory, index: index) else { return nil }
        let focus = focusPoint(in: photo)
        return Slide(
            url: url,
            zoomFrom: pushesIn ? 1 : maxZoom,
            zoomTo: pushesIn ? maxZoom : 1,
            focusX: focus.x,
            focusY: focus.y
        )
    }

    /// Where the zoom should be anchored: the centre of the faces when there
    /// are any, the centre of the frame otherwise.
    ///
    /// A push that drifts toward the people in a shot rather than its
    /// geometric middle is most of what makes Apple's own memory movies read
    /// as produced. Vision runs entirely on device, so this costs nothing in
    /// privacy terms and needs no new permission.
    ///
    /// Bigger faces weigh more, so a row of strangers in the background can't
    /// drag the anchor off the subject in the foreground.
    private static func focusPoint(in image: UIImage) -> (x: Double, y: Double) {
        let centre = (x: 0.5, y: 0.5)
        guard let cgImage = image.cgImage else { return centre }

        // Deliberately the established request API rather than iOS 18's Vision
        // rewrite: for face rectangles the behaviour is identical, and this
        // spelling is stable across the whole supported range.
        let request = VNDetectFaceRectanglesRequest()
        // No orientation argument: the handler defaults to `.up`, which is
        // correct here precisely because `normalizedPhoto` has already baked
        // EXIF orientation into the pixels. Passing it explicitly would mean
        // naming a type from a module this file does not import directly,
        // which this target's `MemberImportVisibility` would reject.
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        guard (try? handler.perform([request])) != nil,
              let faces = request.results,
              !faces.isEmpty else { return centre }

        var weightedX = 0.0
        var weightedY = 0.0
        var totalWeight = 0.0
        for face in faces {
            let box = face.boundingBox
            let weight = Double(box.width) * Double(box.height)
            guard weight > 0 else { continue }
            // Vision measures from the bottom-left. Everything downstream of
            // here — the framing maths, the draw rects — is top-left.
            weightedX += Double(box.midX) * weight
            weightedY += (1 - Double(box.midY)) * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return centre }
        return (x: weightedX / totalWeight, y: weightedY / totalWeight)
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

    /// Where a slide sits at one point in its own motion.
    private static func frameRect(for active: ActiveSlide) -> CGRect {
        let progress = Double(active.visibleIndex) / Double(max(active.visibleTotal - 1, 1))
        let zoom = RecapPlan.zoomFactor(
            from: active.slide.zoomFrom,
            to: active.slide.zoomTo,
            progress: progress
        )
        let framed = RecapPlan.framedRect(
            base: RecapPlan.Rect(
                x: active.base.origin.x,
                y: active.base.origin.y,
                width: active.base.width,
                height: active.base.height
            ),
            zoom: zoom,
            focusX: active.slide.focusX,
            focusY: active.slide.focusY
        )
        return CGRect(x: framed.x, y: framed.y, width: framed.width, height: framed.height)
    }

    // MARK: - Video writing

    private static func writeVideo(slides: [Slide], onProgress: (Double) -> Void) -> URL? {
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
        let frameDuration = CMTime(
            value: CMTimeValue(timescale) / CMTimeValue(framesPerSecond),
            timescale: timescale
        )

        var time = CMTime.zero
        var appended = 0
        let totalAppends = slides.count * holdFrames + max(slides.count - 1, 0) * fadeFrames
        // Reported per whole percent, not per frame. Motion took this loop
        // from ~180 appends to ~1700, and every report is a hop to the main
        // queue that writes `recapProgress` and so re-evaluates the gallery's
        // whole body — a thousand-odd full re-renders during an export, to
        // move a progress ring that has a hundred distinguishable positions.
        var lastReportedPercent = -1

        // Budgets are counted in polls, not wall-clock time. A `Date()` deadline
        // measures how long the *clock* ran, and the clock keeps running while
        // the app is suspended in the background — so backgrounding a recap for
        // a minute used to blow every remaining deadline instantly and lose the
        // export. Counting polls measures time actually spent waiting, which is
        // what the budget was meant to express, and is immune to suspension.
        let readinessPollInterval: TimeInterval = 0.01
        let readinessPollBudget = Int(10 / readinessPollInterval)

        func append(_ layers: [Layer], at presentationTime: CMTime) -> Bool {
            // One drain point per frame. Each append allocates a 1080x1920
            // pixel buffer and a CGContext (~8 MB), and `writeVideo` is one
            // long synchronous job with no suspension point, so without an
            // explicit pool nothing is released until the whole export ends.
            return autoreleasepool { () -> Bool in
                guard let buffer = pixelBuffer(layers: layers, pool: adaptor.pixelBufferPool) else { return false }
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
                let progress = Double(appended) / Double(totalAppends)
                let percent = Int(progress * 100)
                if percent != lastReportedPercent {
                    lastReportedPercent = percent
                    onProgress(progress)
                }
                return ok
            }
        }

        var previous: ActiveSlide?

        for (index, slide) in slides.enumerated() {
            guard !Task.isCancelled else {
                abortWriting()
                return nil
            }
            guard let uiImage = UIImage(contentsOfFile: slide.url.path),
                  let cgImage = uiImage.cgImage else {
                abortWriting()
                return nil
            }

            var current = ActiveSlide(
                image: cgImage,
                base: aspectFitRect(for: uiImage.size, in: renderSize),
                slide: slide,
                visibleTotal: RecapPlan.visibleFrameCount(
                    slideIndex: index,
                    slideCount: slides.count,
                    holdFrames: holdFrames,
                    fadeFrames: fadeFrames
                ),
                visibleIndex: 0
            )

            if var outgoing = previous {
                for step in 0..<fadeFrames {
                    // The outgoing slide fades out as the incoming one fades
                    // in. Holding the outgoing slide at full opacity and
                    // simply covering it would be wrong here, because a slide
                    // is now the photo's own rectangle rather than a
                    // full-frame letterboxed composite — a portrait photo does
                    // not cover the landscape one behind it, so its edges
                    // would still be on screen at the end of the fade and then
                    // vanish in one frame.
                    //
                    // These two alphas summing to 1 is only half of what makes
                    // the result a dissolve; the other half is the additive
                    // blend mode in `pixelBuffer(layers:pool:)`, without which
                    // the overlap darkens. The reasoning is written out there.
                    //
                    // Reaching exactly 1.0 and 0.0 on the last fade frame is
                    // what makes the handoff to the next solo frame invisible.
                    let progress = CGFloat(step + 1) / CGFloat(fadeFrames)
                    let layers = [
                        Layer(image: outgoing.image, rect: frameRect(for: outgoing), alpha: 1 - progress),
                        Layer(image: current.image, rect: frameRect(for: current), alpha: progress)
                    ]
                    guard append(layers, at: time) else {
                        abortWriting()
                        return nil
                    }
                    time = time + frameDuration
                    outgoing.visibleIndex += 1
                    current.visibleIndex += 1
                }
            }

            for _ in 0..<holdFrames {
                guard !Task.isCancelled else {
                    abortWriting()
                    return nil
                }
                let layers = [Layer(image: current.image, rect: frameRect(for: current), alpha: 1)]
                guard append(layers, at: time) else {
                    abortWriting()
                    return nil
                }
                time = time + frameDuration
                current.visibleIndex += 1
            }

            previous = current
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

    /// Core Graphics puts its origin at the bottom-left, while every rectangle
    /// computed above is in top-left space (the convention UIKit, PhotoKit and
    /// the aspect-fit maths all use). The conversion happens here, once,
    /// rather than being reasoned about at each call site.
    private static func flippedToCoreGraphics(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: renderSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static func pixelBuffer(layers: [Layer], pool: CVPixelBufferPool?) -> CVPixelBuffer? {
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
        guard let buffer else { return nil }

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

        // A pooled buffer is recycled, so it arrives holding the previous
        // frame. Clearing is what makes the letterbox black instead of a
        // smear of whatever was encoded before.
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: renderSize))
        context.interpolationQuality = .medium

        // Additive, not source-over, and this is what actually makes the
        // crossfade a dissolve.
        //
        // Source-over composites each layer *against what is already there*,
        // so drawing the incoming slide at alpha p on top of an outgoing one
        // already at (1-p) yields p·B + (1-p)²·A: the outgoing slide is
        // attenuated a second time. The two weights then sum to
        // p + (1-p)², which is 1.0 at both ends of the fade but only 0.75 in
        // the middle — every transition dipped ~25% dark, for half a second,
        // thirty times a recap.
        //
        // The frame is cleared to black and a fade's alphas sum to exactly 1,
        // so adding the layers instead gives (1-p)·A + p·B — a true dissolve
        // where the slides overlap, a clean fade to black where only one of
        // them covers the pixel, and no clamping anywhere. A hold frame is a
        // single layer at alpha 1 added to black, which is unchanged.
        context.setBlendMode(.plusLighter)

        for layer in layers where layer.alpha > 0.001 {
            context.setAlpha(layer.alpha)
            context.draw(layer.image, in: flippedToCoreGraphics(layer.rect))
        }
        return buffer
    }
}
