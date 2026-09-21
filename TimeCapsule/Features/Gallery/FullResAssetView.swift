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
    let onToggleChrome: () -> Void
    let onZoomStateChange: (Bool) -> Void
    let onScrubbingChanged: (Bool) -> Void
    @State private var image: UIImage? = nil
    @State private var player: AVPlayer? = nil
    @State private var progressObserver = PlayerProgressObserver()
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying = false
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false
    @State private var didFail = false
    /// Bumped whenever a newly loaded player is installed, purely so
    /// `onChange` has something to react to.
    @State private var playerGeneration = 0

    private var mediaTaskID: String {
        "\(asset.localIdentifier)|render:\(shouldRender)|current:\(isCurrent)"
    }

    var body: some View {
        Group {
            if shouldRender {
                if asset.mediaType == .video {
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
                            if showControls && isCurrent && isPlaybackAllowed {
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
                } else {
                    if let image {
                        PhotoZoomScrollView(
                            image: image,
                            accessibilityDescription: spokenMediaLabel,
                            isCurrentMemory: isCurrent,
                            onZoomStateChange: onZoomStateChange,
                            onSingleTap: onToggleChrome
                        )
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
            } else {
                Color.black
            }
        }
        .task(id: mediaTaskID) {
            guard shouldRender else {
                releasePlayer()
                image = nil
                didFail = false
                resetPlaybackState()
                return
            }

            if asset.mediaType == .video {
                didFail = false
                if isCurrent {
                    image = nil
                    let loadedPlayer = await loadPlayer(from: asset)
                    guard !Task.isCancelled else {
                        discard(loadedPlayer)
                        return
                    }
                    releasePlayer()
                    player = loadedPlayer
                    didFail = loadedPlayer == nil
                    progressObserver.attach(
                        to: loadedPlayer,
                        onCurrentTimeChange: { currentTime = $0 },
                        onDurationChange: { duration = $0 },
                        onPlayingChange: { isPlaying = $0 }
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
                    let preview = await loadImage(
                        from: asset,
                        targetSize: CGSize(width: 2732, height: 2732),
                        contentMode: .aspectFit
                    )
                    guard !Task.isCancelled else { return }
                    image = preview
                    didFail = preview == nil
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
                let loadedImage = await loadImage(
                    from: asset,
                    targetSize: CGSize(width: 2732, height: 2732),
                    contentMode: .aspectFit
                )
                guard !Task.isCancelled else { return }
                image = loadedImage
                didFail = loadedImage == nil
            }
        }
        .onChange(of: isCurrent) { _, current in
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
            didFail = false
            resetPlaybackState()
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
