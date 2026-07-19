import AVFoundation
import Photos
import SwiftUI
import UIKit

struct FullResAssetView: View {
    let asset: PHAsset
    let isActive: Bool
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

    private var mediaTaskID: String {
        "\(asset.localIdentifier)|render:\(shouldRender)|active:\(isActive)"
    }

    var body: some View {
        Group {
            if shouldRender {
                if asset.mediaType == .video {
                    ZStack(alignment: .bottom) {
                        if let player {
                            PlainVideoPlayerView(player: player)
                                .background(Color.black)

                            if showControls && isActive {
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
                        }
                    }
                    .background(Color.black)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onToggleChrome)
                } else {
                    if let image {
                        PhotoZoomScrollView(
                            image: image,
                            onZoomStateChange: onZoomStateChange,
                            onSingleTap: onToggleChrome
                        )
                    } else if didFail {
                        ContentUnavailableView("Couldn't Load Photo", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.white)
                    } else {
                        ProgressView()
                            .tint(.white)
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
                if isActive {
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
                    loadedPlayer?.play()
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
                let loadedImage = await loadImage(
                    from: asset,
                    targetSize: CGSize(width: 2732, height: 2732),
                    contentMode: .aspectFit
                )
                guard !Task.isCancelled else { return }
                releasePlayer()
                image = loadedImage
                didFail = loadedImage == nil
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                if let player {
                    player.play()
                }
            } else {
                releasePlayer()
                resetPlaybackState()
                onScrubbingChanged(false)
                onZoomStateChange(false)
            }
        }
        .onDisappear {
            onScrubbingChanged(false)
            releasePlayer()
            image = nil
            didFail = false
            resetPlaybackState()
        }
        .accessibilityLabel(mediaAccessibilityLabel)
        .accessibilityValue(isActive ? "Current memory" : "")
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

    private var mediaAccessibilityLabel: String {
        let type = asset.mediaType == .video ? "Video" : "Photo"
        guard let date = asset.creationDate else { return type }
        return "\(type), \(date.formatted(date: .long, time: .shortened))"
    }
}
