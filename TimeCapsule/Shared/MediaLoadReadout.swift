#if ATTIC_SIDELOAD_MEDIA_READOUT
import AVFoundation
import Network
import Photos
import SwiftUI

/// What actually happens when Attic asks Photos for this memory, shown in the
/// info sheet: whether it is on the phone or only in iCloud, how long each
/// request takes, and the error Photos gives if it fails.
///
/// The viewer itself shows only the outcome — a picture, or black — and drops
/// the reason. When videos went black and Live Photos stopped moving on a
/// build whose media code had not changed, there was nothing on screen to say
/// why. This says why.
///
/// Sideload builds only, behind the build workflow's `media_readout` input.
/// Nothing runs until the button is tapped: it asks Photos for full-quality
/// data, which can mean a large iCloud download.
struct MediaLoadReadout: View {
    let asset: PHAsset
    @State private var lines: [String] = []
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(isRunning ? "Testing… (can take a minute or two)" : "Test Loading This Memory") {
                Task { await run() }
            }
            .disabled(isRunning)

            if !lines.isEmpty {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func append(_ line: String) {
        lines.append(line)
    }

    private func run() async {
        isRunning = true
        lines = []
        defer { isRunning = false }

        append("ENVIRONMENT")
        append("  access=\(describe(PHPhotoLibrary.authorizationStatus(for: .readWrite)))")
        append("  lowPower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)")
        append("  freeSpace=\(freeSpace())")
        append("  network=\(await MediaLoadProbe.networkSummary())")

        append("")
        append("ASSET")
        append("  type=\(describe(asset.mediaType)) live=\(asset.mediaSubtypes.contains(.photoLive)) duration=\(String(format: "%.1f", asset.duration))s")
        append("  size=\(asset.pixelWidth)x\(asset.pixelHeight) source=\(asset.sourceType.rawValue)")
        for resource in PHAssetResource.assetResources(for: asset) {
            // `locallyAvailable` is not public API, so it is only read when
            // the object answers to it; reading an unknown key would crash.
            let local: String = resource.responds(to: NSSelectorFromString("locallyAvailable"))
                ? "\(resource.value(forKey: "locallyAvailable") ?? "?")"
                : "unknown"
            append("  resource type=\(resource.type.rawValue) onPhone=\(local) \(resource.originalFilename)")
        }

        append("")
        append("STILL, phone only (no iCloud)")
        append("  " + (await MediaLoadProbe.stillRequest(asset, network: false, target: CGSize(width: 1200, height: 1200))))
        append("STILL, iCloud allowed")
        append("  " + (await MediaLoadProbe.stillRequest(asset, network: true, target: CGSize(width: 1200, height: 1200))))

        if asset.mediaSubtypes.contains(.photoLive) {
            append("")
            append("LIVE PHOTO, phone only")
            append("  " + (await MediaLoadProbe.liveRequest(asset, network: false)))
            append("LIVE PHOTO, iCloud allowed")
            append("  " + (await MediaLoadProbe.liveRequest(asset, network: true)))
        }

        if asset.mediaType == .video {
            append("")
            append("VIDEO, phone only")
            append("  " + (await MediaLoadProbe.videoRequest(asset, network: false)))
            append("VIDEO, iCloud allowed")
            append("  " + (await MediaLoadProbe.videoRequest(asset, network: true)))
        }
        append("")
        append("done")
    }

    // MARK: - Environment

    private func freeSpace() -> String {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return "unknown" }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }

    private func describe(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "full"
        case .limited: return "LIMITED"
        case .denied: return "DENIED"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private func describe(_ type: PHAssetMediaType) -> String {
        switch type {
        case .image: return "image"
        case .video: return "video"
        case .audio: return "audio"
        default: return "unknown"
        }
    }
}

/// The requests themselves, kept out of the view on purpose. The app's code
/// belongs to the main thread by default, and Photos calls these progress and
/// result handlers on its own background threads; a handler written inside
/// the view would claim the main thread it is not running on.
nonisolated enum MediaLoadProbe {
    // MARK: - Requests

    /// One labelled line: how it ended, after how long, the progress Photos
    /// reported, and every info key that says why.
    nonisolated final class Probe: @unchecked Sendable {
        let start = Date()
        private let lock = NSLock()
        private var progress: [Double] = []
        private var finished = false
        private var continuation: CheckedContinuation<String, Never>?

        func set(_ continuation: CheckedContinuation<String, Never>) {
            lock.lock(); self.continuation = continuation; lock.unlock()
        }

        func noteProgress(_ value: Double, _ error: Error?) {
            lock.lock()
            progress.append(value)
            lock.unlock()
            if let error { finish("progress error \(Probe.describe(error))") }
        }

        func finish(_ outcome: String) {
            lock.lock()
            guard !finished, let continuation else { lock.unlock(); return }
            finished = true
            self.continuation = nil
            let seconds = Date().timeIntervalSince(start)
            let progressText = progress.isEmpty ? "none" : "\(progress.count) updates, last \(Int((progress.last ?? 0) * 100))%"
            lock.unlock()
            continuation.resume(returning: String(format: "%.2fs ", seconds) + outcome + " | progress: " + progressText)
        }

        var progressText: String {
            lock.lock(); defer { lock.unlock() }
            return progress.isEmpty ? "none" : "\(progress.count) updates, last \(Int((progress.last ?? 0) * 100))%"
        }

        static func describe(_ error: Error) -> String {
            let ns = error as NSError
            return "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
        }

        static func describe(_ info: [AnyHashable: Any]?) -> String {
            guard let info else { return "info=nil" }
            var parts: [String] = []
            if let error = info[PHImageErrorKey] as? Error { parts.append("ERROR=\(describe(error))") }
            if let inCloud = info[PHImageResultIsInCloudKey] as? Bool { parts.append("inCloud=\(inCloud)") }
            if let degraded = info[PHImageResultIsDegradedKey] as? Bool { parts.append("degraded=\(degraded)") }
            if let cancelled = info[PHImageCancelledKey] as? Bool { parts.append("cancelled=\(cancelled)") }
            return parts.isEmpty ? "no info keys" : parts.joined(separator: " ")
        }
    }

    /// Gives up after a minute so a download that never ends still says so.
    static func withTimeout(_ probe: Probe, cancel: @escaping () -> Void) {
        Task {
            try? await Task.sleep(for: .seconds(60))
            cancel()
            probe.finish("TIMED OUT after 60s")
        }
    }

    static func stillRequest(_ asset: PHAsset, network: Bool, target: CGSize) async -> String {
        let probe = Probe()
        return await withCheckedContinuation { continuation in
            probe.set(continuation)
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = network
            options.progressHandler = { value, error, _, _ in probe.noteProgress(value, error) }
            let id = PHImageManager.default().requestImage(
                for: asset, targetSize: target, contentMode: .aspectFit, options: options
            ) { image, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                let size = image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "NO IMAGE"
                probe.finish("\(size) \(Probe.describe(info))")
            }
            withTimeout(probe) { PHImageManager.default().cancelImageRequest(id) }
        }
    }

    static func liveRequest(_ asset: PHAsset, network: Bool) async -> String {
        let probe = Probe()
        return await withCheckedContinuation { continuation in
            probe.set(continuation)
            let options = PHLivePhotoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = network
            options.progressHandler = { value, error, _, _ in probe.noteProgress(value, error) }
            let id = PHImageManager.default().requestLivePhoto(
                for: asset, targetSize: CGSize(width: 1200, height: 1200), contentMode: .aspectFit, options: options
            ) { livePhoto, info in
                if (info?[PHImageResultIsDegradedKey] as? Bool) == true { return }
                probe.finish("\(livePhoto == nil ? "NO LIVE PHOTO" : "live photo ok") \(Probe.describe(info))")
            }
            withTimeout(probe) { PHImageManager.default().cancelImageRequest(id) }
        }
    }

    static func videoRequest(_ asset: PHAsset, network: Bool) async -> String {
        let probe = Probe()
        let item: (AVPlayerItem?, String) = await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = network
            options.progressHandler = { value, error, _, _ in probe.noteProgress(value, error) }
            let once = Once()
            let id = PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { item, info in
                once.run { continuation.resume(returning: (item, Probe.describe(info))) }
            }
            Task {
                try? await Task.sleep(for: .seconds(60))
                PHImageManager.default().cancelImageRequest(id)
                once.run { continuation.resume(returning: (nil, "TIMED OUT after 60s")) }
            }
        }
        let requestTime = String(format: "%.2fs", Date().timeIntervalSince(probe.start))
        guard let playerItem = item.0 else {
            return "\(requestTime) NO PLAYER ITEM \(item.1) | progress: \(probe.progressText)"
        }
        // Photos handing back an item is not the same as it playing: ask the
        // item itself whether it can, and how long it took to say so.
        let status = await readiness(of: playerItem)
        let source = (playerItem.asset as? AVURLAsset).map { $0.url.isFileURL ? "file" : "STREAM \($0.url.scheme ?? "?")" } ?? "not a URL asset"
        return "\(requestTime) item ok \(item.1) | progress: \(probe.progressText) | source: \(source)\n  \(status)"
    }

    nonisolated final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func run(_ body: () -> Void) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            lock.unlock()
            body()
        }
    }

    /// Photos handing back an item is not the same as it playing. The
    /// viewer's broken state was exactly this: an item with a duration, a
    /// pause button showing, and time stuck at 0:00. So this plays it, muted,
    /// and watches for five seconds.
    static func readiness(of item: AVPlayerItem) async -> String {
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        let start = Date()
        var lines: [String] = []

        var ready = false
        for _ in 0..<60 {
            if item.status == .readyToPlay { ready = true; break }
            if item.status == .failed { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        switch item.status {
        case .failed:
            return "item FAILED: " + (item.error.map(Probe.describe) ?? "no error")
        case .readyToPlay:
            let duration = item.duration.seconds
            lines.append(String(format: "readyToPlay after %.2fs, duration %.1fs", Date().timeIntervalSince(start), duration.isFinite ? duration : -1))
        default:
            return "item STILL NOT READY after 30s"
        }
        guard ready else { return lines.joined(separator: "\n  ") }

        player.play()
        try? await Task.sleep(for: .seconds(5))
        let reason = player.reasonForWaitingToPlay?.rawValue ?? "none"
        let status: String
        switch player.timeControlStatus {
        case .playing: status = "playing"
        case .paused: status = "PAUSED"
        case .waitingToPlayAtSpecifiedRate: status = "WAITING"
        @unknown default: status = "unknown"
        }
        let loaded = item.loadedTimeRanges.map { range -> String in
            let r = range.timeRangeValue
            return String(format: "%.1f-%.1fs", r.start.seconds, (r.start + r.duration).seconds)
        }.joined(separator: ",")
        lines.append(String(format: "after 5s of play: %@ (waiting reason: %@), time %.2fs", status, reason, item.currentTime().seconds))
        lines.append("keepUp=\(item.isPlaybackLikelyToKeepUp) bufferEmpty=\(item.isPlaybackBufferEmpty) loaded=\(loaded.isEmpty ? "none" : loaded)")
        if let event = item.errorLog()?.events.last {
            lines.append("errorLog: \(event.errorDomain) \(event.errorStatusCode) \(event.errorComment ?? "")")
        }
        if item.status == .failed {
            lines.append("item FAILED during play: " + (item.error.map(Probe.describe) ?? "no error"))
        }
        player.pause()
        return lines.joined(separator: "\n  ")
    }

    static func networkSummary() async -> String {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let once = Once()
            monitor.pathUpdateHandler = { path in
                once.run {
                    var kinds: [String] = []
                    if path.usesInterfaceType(.wifi) { kinds.append("wifi") }
                    if path.usesInterfaceType(.cellular) { kinds.append("cellular") }
                    let text = "\(path.status == .satisfied ? "online" : "OFFLINE") \(kinds.joined(separator: "+")) lowDataMode=\(path.isConstrained) expensive=\(path.isExpensive)"
                    monitor.cancel()
                    continuation.resume(returning: text)
                }
            }
            monitor.start(queue: DispatchQueue(label: "media-readout-network"))
        }
    }

}
#endif
