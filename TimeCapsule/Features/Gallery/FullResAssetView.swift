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
    @State private var loadGeneration = 0

    private var mediaTaskID: String {
        "\(asset.localIdentifier)|render:\(shouldRender)|generation:\(loadGeneration)"
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
                resetPlaybackState()
                return
            }

            if asset.mediaType == .video {
                image = nil
                let loadedPlayer = await loadPlayer(from: asset)
                guard !Task.isCancelled else {
                    discard(loadedPlayer)
                    return
                }
                releasePlayer()
                player = loadedPlayer
                progressObserver.attach(
                    to: loadedPlayer,
                    onCurrentTimeChange: { currentTime = $0 },
                    onDurationChange: { duration = $0 },
                    onPlayingChange: { isPlaying = $0 }
                )
                if isActive {
                    loadedPlayer?.play()
                } else {
                    loadedPlayer?.pause()
                    loadedPlayer?.seek(to: .zero)
                }
            } else {
                let loadedImage = await loadImage(
                    from: asset,
                    targetSize: CGSize(width: 1290, height: 2796),
                    contentMode: .aspectFit
                )
                guard !Task.isCancelled else { return }
                releasePlayer()
                image = loadedImage
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                if let player {
                    player.play()
                } else if shouldRender && asset.mediaType == .video {
                    loadGeneration += 1
                }
            } else {
                player?.pause()
                player?.seek(to: .zero)
                resetPlaybackState()
                onScrubbingChanged(false)
                onZoomStateChange(false)
                if player == nil && shouldRender && asset.mediaType == .video {
                    loadGeneration += 1
                }
            }
        }
        .onDisappear {
            onScrubbingChanged(false)
            releasePlayer()
            resetPlaybackState()
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
}

@MainActor
final class AdjacentMediaPreheater {
    static let shared = AdjacentMediaPreheater()

    private let cachingManager = PHCachingImageManager()
    private var cachedAssetIDs: Set<String> = []

    private init() {}

    func updateCaching(for assets: [PHAsset], currentIndex: Int) {
        guard !assets.isEmpty, assets.indices.contains(currentIndex) else {
            stopCaching()
            return
        }

        let radius = 2
        let lowerBound = max(currentIndex - radius, 0)
        let upperBound = min(currentIndex + radius, assets.count - 1)
        let assetsToCache = Array(assets[lowerBound...upperBound])
        let nextIDs = Set(assetsToCache.map(\.localIdentifier))

        if cachedAssetIDs != nextIDs {
            cachingManager.stopCachingImagesForAllAssets()
            let imageAssets = assetsToCache.filter { $0.mediaType == .image }
            if !imageAssets.isEmpty {
                cachingManager.startCachingImages(
                    for: imageAssets,
                    targetSize: CGSize(width: 1290, height: 2796),
                    contentMode: .aspectFit,
                    options: nil
                )
            }

            cachedAssetIDs = nextIDs
        }

        // Video AVPlayers are intentionally not preheated here. Creating
        // throwaway players can trigger expensive iCloud/video work without
        // giving the active page a reusable player.
    }

    func stopCaching() {
        cachingManager.stopCachingImagesForAllAssets()
        cachedAssetIDs.removeAll()
    }
}
