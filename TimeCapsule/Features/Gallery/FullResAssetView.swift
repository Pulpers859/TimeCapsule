import AVFoundation
import Photos
import SwiftUI
import UIKit

struct FullResAssetView: View {
    let asset: PHAsset
    /// This is the page the pager is focused on: it owns a loaded player and
    /// is the only one that may hold one.
    let isCurrent: Bool
    /// Whether playback may run *right now*. Deliberately separate from
    /// `isCurrent`, and deliberately absent from `mediaTaskID`.
    ///
    /// The two used to be one flag, and anything that blocks playback —
    /// opening the info sheet, tapping Share, starting a delete — therefore
    /// changed the task identity and tore the player down. Dismissing the
    /// sheet built a new one and played it from the beginning, so tapping
    /// the ℹ︎ button three and a half minutes into a video and closing it
    /// again lost the position, in two taps, every time.
    let isPlaybackAllowed: Bool
    let shouldRender: Bool
    let showControls: Bool
    /// Bumped by the viewer's LIVE button; see `PhotoZoomScrollView`.
    var livePlaybackRequest = 0
    let onToggleChrome: () -> Void
    let onZoomStateChange: (Bool) -> Void
    let onScrubbingChanged: (Bool) -> Void
    @State private var image: UIImage? = nil
    /// The current page's Live Photo motion. Never held for a neighbour.
    @State private var livePhoto: PHLivePhoto? = nil
    @State private var player: AVPlayer? = nil
    @State private var progressObserver = PlayerProgressObserver()
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var didFail = false
    /// The video is asked to play but held up for data, typically an iCloud
    /// original still arriving.
    @State private var isVideoWaiting = false
    /// Why the video could not play, from the player itself.
    @State private var videoFailure: String? = nil
    /// `isVideoWaiting` once it has lasted long enough to be worth saying.
    @State private var showsVideoWaiting = false
    /// Bumped when a page whose photo failed comes back into focus, so the
    /// load is tried again. Taking `isCurrent` out of a photo's task id
    /// removed the retry that used to come with every return to the page.
    @State private var stillRetry = 0
    /// Whether the photo on screen is the real thing yet, said on screen so
    /// a placeholder is never mistaken for it. The quick thumbnail used to
    /// be left standing, blurry, with nothing to say a download was still
    /// running — or had failed.
    @State private var stillState: StillState = .settled
    /// Set once the user zooms in. Full resolution is only visible then, so
    /// it is only fetched then; at 1x a screen-sized copy is pixel for pixel
    /// what is shown.
    @State private var wantsDetail = false
    /// Which memory `image` belongs to, so a retry can keep the copy on
    /// screen while a different memory starts from nothing.
    @State private var stillAssetID: String? = nil
    /// The zoom-time full-resolution copy has replaced the screen-sized one,
    /// which must not then be put back over it.
    @State private var hasDetail = false
    /// Bumped whenever a newly loaded player is installed, purely so
    /// `onChange` has something to react to.
    @State private var playerGeneration = 0

    /// A photo's still is not keyed on `isCurrent`; a video's is, because
    /// only the current page may hold a player.
    ///
    /// The still used to be, and every swipe onto a page whose photo was
    /// still downloading from iCloud cancelled that download and started it
    /// again from nothing — and the page just left did the same. Browsing at
    /// a normal pace, an iCloud-only photo could keep restarting and never
    /// arrive. The Live Photo, which does depend on being current, has its
    /// own task, `liveTaskID`.
    private var mediaTaskID: String {
        asset.mediaType == .video
            ? "\(asset.localIdentifier)|render:\(shouldRender)|current:\(isCurrent)"
            : "\(asset.localIdentifier)|render:\(shouldRender)|retry:\(stillRetry)"
    }

    private var detailTaskID: String {
        "\(asset.localIdentifier)|render:\(shouldRender)|detail:\(wantsDetail)"
    }

    /// The photo's own shape fitted to the screen, in pixels: exactly what
    /// is shown at 1x, and no more.
    ///
    /// Asking for more is what turns "Optimize iPhone Storage" into a
    /// download, because the copy the phone keeps is about screen-sized. The
    /// first attempt at this was a square the length of the screen's long
    /// side, which for a 4:3 photo asked for 2151×2868 to show 1320×1760 —
    /// on a Pro Max more than the 2732 it replaced. Both orientations are
    /// tried, since the viewer rotates, and the larger kept.
    private var screenPixelSize: CGSize {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
        let points = screen?.bounds.size ?? CGSize(width: 440, height: 956)
        let scale = screen?.scale ?? 3
        let short = min(points.width, points.height) * scale
        let long = max(points.width, points.height) * scale
        let photoWidth = CGFloat(max(asset.pixelWidth, 1))
        let photoHeight = CGFloat(max(asset.pixelHeight, 1))

        func fitted(width: CGFloat, height: CGFloat) -> CGSize {
            let ratio = min(width / photoWidth, height / photoHeight, 1)
            return CGSize(width: (photoWidth * ratio).rounded(.up), height: (photoHeight * ratio).rounded(.up))
        }
        let portrait = fitted(width: short, height: long)
        let landscape = fitted(width: long, height: short)
        return portrait.width * portrait.height >= landscape.width * landscape.height ? portrait : landscape
    }

    /// Restarts when the page becomes current or stops being it, and once
    /// the still first appears, since the motion waits for the still.
    private var liveTaskID: String {
        "\(asset.localIdentifier)|render:\(shouldRender)|current:\(isCurrent)|still:\(image != nil)"
    }

    var body: some View {
        Group {
            if shouldRender {
                if asset.mediaType == .video {
                    videoContent
                } else {
                    photoContent
                }
            } else {
                Color.black
            }
        }
        .task(id: mediaTaskID) {
            // A different memory, or for a video a change of current page,
            // must not keep the previous Live Photo's video. A retry of the
            // same photo keeps it: nothing would load it again, since the
            // Live Photo's own task does not restart for a retry.
            if asset.mediaType == .video || stillAssetID != asset.localIdentifier {
                livePhoto = nil
            }
            guard shouldRender else {
                releasePlayer()
                image = nil
                stillAssetID = nil
                resetStillState()
                didFail = false
                resetPlaybackState()
                return
            }

            if asset.mediaType == .video {
                didFail = false
                if isCurrent {
                    image = nil
                    // Released *before* the load, like the photo branch below
                    // and for the same reason. A page is reused for a
                    // different asset at the same index whenever the pager's
                    // contents change under it — a delete that leaves
                    // `currentIndex` alone, and now every entry into day mode,
                    // where the tapped item's index in the day commonly lands
                    // within one of the memory's. Released afterwards, the
                    // *previous* video stayed alive and `applyPlaybackState()`
                    // would happily play it over the incoming page for as long
                    // as the replacement took to arrive, which for an iCloud
                    // original is a download.
                    releasePlayer()
                    isVideoWaiting = false
                    videoFailure = nil
                    let loadedPlayer = await loadPlayer(from: asset)
                    guard !Task.isCancelled else {
                        discard(loadedPlayer)
                        return
                    }
                    player = loadedPlayer
                    didFail = loadedPlayer == nil
                    progressObserver.attach(
                        to: loadedPlayer,
                        onCurrentTimeChange: { currentTime = $0 },
                        onDurationChange: { duration = $0 },
                        onPlayingChange: { isPlaying = $0 },
                        onWaitingChange: { isVideoWaiting = $0 },
                        onFailure: { videoFailure = $0 }
                    )
                    // Playback is applied by `.onChange(of: playerGeneration)`
                    // below, not decided here.
                    //
                    // This closure captures the view struct as it was when
                    // the task *started*, and `isPlaybackAllowed` is a `let`
                    // on it — so reading it after `await loadPlayer(...)`
                    // returns a value from before an unbounded wait. An
                    // iCloud original takes seconds, and tapping ℹ︎ during
                    // that wait left the stale `true` here to start the
                    // video underneath the presented info sheet. The mirror
                    // case was worse: loaded while blocked, the stale
                    // `false` meant it never auto-played at all and no
                    // further `onChange` was coming.
                    //
                    // Bumping a counter instead moves the decision into an
                    // `onChange`, whose closure SwiftUI rebuilds every
                    // update and which therefore reads the live value.
                    playerGeneration += 1
                } else {
                    releasePlayer()
                    guard await loadStill() else { return }
                }
            } else {
                didFail = false
                // Released *before* the load, as both video branches above
                // do. After it, a page reused for a photo — which happens on
                // a delete that leaves `currentIndex` unchanged — left the
                // previous video's player alive and audible for as long as
                // the replacement took to arrive, which for an iCloud
                // original is a download. The cancellation guard below
                // returns early too, so on that path it was never released
                // here at all.
                releasePlayer()
                guard await loadStill() else { return }
            }
        }
        // The Live Photo's motion, for the current page only, started as soon
        // as the photo first shows rather than after its full-quality copy.
        // A separate task so the still is not re-requested when the page
        // becomes current, and the motion is not held behind it.
        .task(id: liveTaskID) {
            livePhoto = nil
            guard shouldRender, isCurrent, image != nil,
                  asset.mediaType == .image,
                  asset.mediaSubtypes.contains(.photoLive) else { return }
            let loadedLivePhoto = await loadLivePhoto(
                from: asset,
                targetSize: screenPixelSize
            )
            guard !Task.isCancelled else { return }
            livePhoto = loadedLivePhoto
        }
        // Full resolution once the user zooms in, swapped in under the zoom
        // (`display(image:)` keeps the zoom for the same aspect ratio).
        .task(id: detailTaskID) {
            guard wantsDetail, shouldRender, asset.mediaType == .image, !hasDetail else { return }
            // Zoomed in on a copy that is not yet full resolution: say so
            // while it comes, as for the first download.
            stillState = .downloading(0)
            let report: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    if case .downloading = stillState { stillState = .downloading(value) }
                }
            }
            let detailed = await loadImage(
                from: asset,
                targetSize: CGSize(width: 4032, height: 4032),
                contentMode: .aspectFit,
                onProgress: report
            )
            guard !Task.isCancelled, stillAssetID == asset.localIdentifier else { return }
            guard let detailed else {
                stillState = .couldNotDownload
                return
            }
            image = detailed
            hasDetail = true
            stillState = .settled
        }
        // Shown only once a wait passes half a second, so a short buffer at
        // the start does not flash a spinner over a video that is fine.
        .task(id: isVideoWaiting) {
            guard isVideoWaiting else {
                showsVideoWaiting = false
                return
            }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            showsVideoWaiting = true
        }
        .onChange(of: isCurrent) { _, current in
            if current, didFail || stillState == .couldNotDownload, asset.mediaType != .video {
                stillRetry += 1
            }
            // Leaving the focused page is the only thing that releases the
            // player. Blocking playback no longer does.
            guard !current else { return }
            releasePlayer()
            resetPlaybackState()
            onScrubbingChanged(false)
            onZoomStateChange(false)
        }
        .onChange(of: isPlaybackAllowed) { _, _ in
            applyPlaybackState()
        }
        // Fires once a freshly loaded player has been installed, so a player
        // that arrived while playback was blocked — or while it was allowed
        // and has since been blocked — lands in the right state. The
        // previous version only reacted to `isPlaybackAllowed` changing and
        // bailed out on `player == nil`, so any change that happened during
        // the load was silently dropped.
        .onChange(of: playerGeneration) { _, _ in
            applyPlaybackState()
        }
        .onDisappear {
            onScrubbingChanged(false)
            releasePlayer()
            image = nil
            stillAssetID = nil
            resetStillState()
            livePhoto = nil
            didFail = false
            resetPlaybackState()
        }
    }

    /// Split out of `body`, which had grown past what the compiler can
    /// type-check in reasonable time.
    @ViewBuilder
    private var videoContent: some View {
        ZStack(alignment: .bottom) {
            if let player {
                PlainVideoPlayerView(player: player)
                    .background(Color.black)
                    .accessibilityElement()
                    .accessibilityLabel(spokenMediaLabel)
                    .accessibilityValue(isCurrent ? "Current memory" : "")
                    // The photo branch got an activate action for
                    // exactly this reason and the video branch did
                    // not. With the chrome hidden — which also
                    // hides the playback controls — VoiceOver had
                    // nothing to activate here, so Close, Share,
                    // Delete, Info and the transport were all
                    // unreachable until the user paged to a photo.
                    .accessibilityAction(.default, onToggleChrome)
                    .accessibilityHint("Double tap to show or hide the controls.")

                // `isPlaybackAllowed` as well as `isCurrent`.
                //
                // Splitting `isActive` in two and gating only on
                // `isCurrent` left a live, enabled play button
                // during a block that presents no modal of its
                // own: `isPreparingShare` and `isDeleting` only
                // `.disabled()` the three chrome buttons, and
                // these controls have no `.disabled` at all. So
                // the user could tap ▶ while a share export ran
                // and restart audio the block exists to stop —
                // and because `isPlaybackAllowed` is one derived
                // flag over five inputs, the hand-off from
                // `isPreparingShare` to `shareItem` changes no
                // value, fires no `onChange`, and never paused it
                // again. The video then played under the share
                // sheet. Before the split, being blocked hid
                // these controls; it still does.
                if let videoFailure {
                    ContentUnavailableView(
                        "Couldn't Play Video",
                        systemImage: "exclamationmark.triangle",
                        description: Text(videoFailure)
                    )
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                } else if showsVideoWaiting && isCurrent && isPlaybackAllowed {
                    // Black with a pause button and 0:00 was all
                    // a stalled iCloud video ever showed.
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("Loading video…")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                }

                // Not over a failure: play and scrub do nothing
                // for a video that cannot play.
                if showControls && isCurrent && isPlaybackAllowed && videoFailure == nil {
                    videoPlaybackControls
                }
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if didFail {
                ContentUnavailableView("Couldn't Load Video", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
                    // The video spinner, not just the photo one.
                    // This is the slower of the two: it covers a
                    // full `AVPlayerItem` download for an iCloud
                    // original.
                    .accessibilityLabel("Loading \(spokenMediaLabel)")
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleChrome)
    }

    private var videoPlaybackControls: some View {
        VideoPlaybackControls(
            currentTime: isScrubbing ? scrubPosition : currentTime,
            duration: duration,
            isPlaying: isPlaying,
            onTogglePlayPause: {
                progressObserver.togglePlayPause()
            },
            onSkipBack: {
                let destination = max(currentTime - 10, 0)
                progressObserver.seek(to: destination)
                currentTime = destination
            },
            sliderBinding: Binding(
                get: {
                    isScrubbing ? scrubPosition : currentTime
                },
                set: { newValue in
                    scrubPosition = newValue
                }
            ),
            onEditingChanged: { editing in
                onScrubbingChanged(editing)
                if editing {
                    scrubPosition = currentTime
                    isScrubbing = true
                } else {
                    isScrubbing = false
                    progressObserver.seek(to: scrubPosition)
                    currentTime = scrubPosition
                }
            }
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 22)
    }

    @ViewBuilder
    private var photoContent: some View {
        if let image {
            PhotoZoomScrollView(
                image: image,
                accessibilityDescription: spokenMediaLabel,
                isCurrentMemory: isCurrent,
                livePhoto: livePhoto,
                livePlaybackRequest: livePlaybackRequest,
                isPlaybackAllowed: isPlaybackAllowed,
                onZoomStateChange: { zoomed in
                    onZoomStateChange(zoomed)
                    if zoomed { wantsDetail = true }
                },
                onSingleTap: onToggleChrome
            )
            .overlay(alignment: .bottom) {
                if isCurrent && showControls {
                    stillStatusBadge
                }
            }
        } else if didFail {
            ContentUnavailableView("Couldn't Load Photo", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.white)
        } else {
            ProgressView()
                .tint(.white)
                // Previously inherited from the container label
                // that moved onto the media itself. An iCloud
                // original takes seconds, and for all of them this
                // page announced nothing at all.
                .accessibilityLabel("Loading \(spokenMediaLabel)")
        }
    }

    /// The thumbnail at once, then the sharp copy the phone holds, and only
    /// failing that a download — with its progress on screen, and a way to
    /// try again if it fails. Returns false if the task was cancelled.
    ///
    /// A different memory starts from a cleared image, so the previous one's
    /// photo never stands in for it. A retry of the same one keeps what is
    /// already showing.
    private func loadStill() async -> Bool {
        if stillAssetID != asset.localIdentifier {
            image = nil
            resetStillState()
            stillAssetID = asset.localIdentifier
        }
        let target = screenPixelSize

        if image == nil {
            let thumbnail = await loadImage(from: asset, targetSize: target, contentMode: .aspectFit, source: .instantThumbnail)
            guard !Task.isCancelled else { return false }
            if image == nil, let thumbnail { image = thumbnail }
        }

        let onPhone = await loadImage(from: asset, targetSize: target, contentMode: .aspectFit, source: .phoneOnly)
        guard !Task.isCancelled else { return false }
        if let onPhone {
            if !hasDetail { image = onPhone }
            stillState = .settled
            didFail = false
            return true
        }

        stillState = .downloading(0)
        let report: @Sendable (Double) -> Void = { value in
            Task { @MainActor in
                if case .downloading = stillState { stillState = .downloading(value) }
            }
        }
        let downloaded = await loadImage(from: asset, targetSize: target, contentMode: .aspectFit, onProgress: report)
        guard !Task.isCancelled else { return false }
        if let downloaded {
            if !hasDetail { image = downloaded }
            stillState = .settled
        } else {
            // Only a thumbnail to show: say so, rather than let it pass for
            // the photo.
            stillState = (image == nil || hasDetail) ? .settled : .couldNotDownload
        }
        didFail = image == nil
        return true
    }

    private func resetStillState() {
        stillState = .settled
        wantsDetail = false
        hasDetail = false
    }

    enum StillState: Equatable {
        case settled
        case downloading(Double)
        case couldNotDownload
    }

    @ViewBuilder
    private var stillStatusBadge: some View {
        switch stillState {
        case .settled:
            EmptyView()
        case .downloading(let progress):
            Label(
                progress > 0
                    ? "Downloading from iCloud · \(Int(progress * 100))%"
                    : "Downloading from iCloud…",
                systemImage: "icloud.and.arrow.down"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
            // Above the bottom controls, which sit over the page and are
            // drawn on top of it: at 14pt this went under the counter, and
            // the Try Again capsule under the info and LIVE buttons.
            .padding(.bottom, 76)
            .allowsHitTesting(false)
        case .couldNotDownload:
            Button {
                stillRetry += 1
            } label: {
                Label("Couldn't get the full photo · Try Again", systemImage: "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.6), in: Capsule())
                    .contentShape(Capsule())
            }
            // Above the bottom controls, which sit over the page and are
            // drawn on top of it: at 14pt this went under the counter, and
            // the Try Again capsule under the info and LIVE buttons.
            .padding(.bottom, 76)
        }
    }

    /// Brings the player in line with the current block state.
    ///
    /// Idempotent, and safe to call with no player or on a page that is not
    /// the focused one. Both triggers route through here so there is one
    /// definition of "should this be playing right now", evaluated against
    /// live state rather than anything captured earlier.
    private func applyPlaybackState() {
        guard isCurrent, let player else { return }
        if isPlaybackAllowed {
            VideoAudioSession.begin()
            player.play()
        } else {
            player.pause()
        }
    }

    private func releasePlayer() {
        progressObserver.detach()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }

    private func discard(_ player: AVPlayer?) {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }

    private func resetPlaybackState() {
        isVideoWaiting = false
        showsVideoWaiting = false
        videoFailure = nil
        scrubPosition = 0
        currentTime = 0
        duration = 0
        isPlaying = false
        isScrubbing = false
    }

    /// Applied to the media surface itself, never to the enclosing `Group`.
    ///
    /// It used to sit on the `Group`, and SwiftUI propagates an accessibility
    /// modifier on a container down to every element inside it. In the video
    /// branch that container also holds `VideoPlaybackControls`, so the
    /// play/pause button, the skip-back button and the scrubber were all
    /// relabelled with this date string and became indistinguishable. In the
    /// photo branch there was no element to propagate to at all — a
    /// `UIImageView` is not one by default — so the photo announced nothing.
    /// Both branches were wrong, in opposite directions.
    ///
    /// The running time is spoken, because "1:05" is read out as
    /// "one colon zero five".
    private var spokenMediaLabel: String {
        let type = asset.mediaType == .video ? "Video" : "Photo"
        let length = asset.mediaType == .video
            ? ", \(MediaDuration.spokenDuration(asset.duration))"
            : ""
        guard let date = asset.creationDate else { return type + length }
        return "\(type), \(date.formatted(date: .long, time: .shortened))\(length)"
    }
}
