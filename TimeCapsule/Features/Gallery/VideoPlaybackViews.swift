import AVFoundation
import SwiftUI
import UIKit

struct PlainVideoPlayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerContainerView, context: Context) {
        uiView.player = player
    }
}

struct VideoPlaybackControls: View {
    let currentTime: Double
    let duration: Double
    let isPlaying: Bool
    let onTogglePlayPause: () -> Void
    let onSkipBack: () -> Void
    let sliderBinding: Binding<Double>
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                Button(action: onTogglePlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause video" : "Play video")

                Button(action: onSkipBack) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Skip back 10 seconds")

                Text(formattedTime(currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 44, alignment: .leading)

                Slider(
                    value: sliderBinding,
                    in: 0...max(duration, 1),
                    onEditingChanged: onEditingChanged
                )
                .tint(.white)
                .accessibilityLabel("Video position")
                .accessibilityValue("\(formattedTime(currentTime)) of \(formattedTime(duration))")

                Text(formattedTime(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }
}

final class PlayerContainerView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true
        playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.needsDisplayOnBoundsChange = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override static var layerClass: AnyClass {
        AVPlayerLayer.self
    }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            playerLayer.player = nil
        }
    }
}

@MainActor
final class PlayerProgressObserver {
    private weak var player: AVPlayer?
    private var timeObserverToken: Any?
    private var playbackEndObserver: NSObjectProtocol?
    private var onCurrentTimeChange: ((Double) -> Void)?
    private var onDurationChange: ((Double) -> Void)?
    private var onPlayingChange: ((Bool) -> Void)?
    private var latestCurrentTime: Double = 0
    private var latestDuration: Double = 0

    func attach(
        to player: AVPlayer?,
        onCurrentTimeChange: @escaping (Double) -> Void,
        onDurationChange: @escaping (Double) -> Void,
        onPlayingChange: @escaping (Bool) -> Void
    ) {
        detach()
        self.onCurrentTimeChange = onCurrentTimeChange
        self.onDurationChange = onDurationChange
        self.onPlayingChange = onPlayingChange

        self.player = player
        latestCurrentTime = 0
        latestDuration = 0

        guard let player else {
            onCurrentTimeChange(0)
            onDurationChange(0)
            onPlayingChange(false)
            return
        }

        publishSnapshot(for: player)

        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            let seconds = time.seconds.isFinite ? time.seconds : nil
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.publishSnapshot(for: player, currentTimeOverride: seconds)
            }
        }

        if let currentItem = player.currentItem {
            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main
            ) { [weak self, weak player] _ in
                Task { @MainActor [weak self, weak player] in
                    guard let self, let player, self.player === player else { return }
                    self.publishSnapshot(for: player)
                }
            }
        }
    }

    func detach() {
        if let player, let timeObserverToken {
            player.removeTimeObserver(timeObserverToken)
        }
        timeObserverToken = nil
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        playbackEndObserver = nil
        player = nil
        latestCurrentTime = 0
        latestDuration = 0
        onCurrentTimeChange?(0)
        onDurationChange?(0)
        onPlayingChange?(false)
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            if latestDuration > 0, latestCurrentTime >= latestDuration - 0.2 {
                player.seek(to: .zero)
                latestCurrentTime = 0
                onCurrentTimeChange?(0)
            }
            player.play()
        }
        publishSnapshot(for: player)
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let upperBound = latestDuration > 0 ? latestDuration : seconds
        let bounded = min(max(seconds, 0), upperBound)
        player.seek(
            to: CMTime(seconds: bounded, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self, weak player] _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player, self.player === player else { return }
                self.publishSnapshot(for: player, currentTimeOverride: bounded)
            }
        }
    }

    private func publishSnapshot(for player: AVPlayer, currentTimeOverride: Double? = nil) {
        let seconds = currentTimeOverride ?? {
            let current = player.currentTime().seconds
            return current.isFinite ? current : 0
        }()
        let rawDuration = player.currentItem?.duration.seconds ?? 0
        let normalizedDuration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : 0
        latestCurrentTime = seconds
        latestDuration = normalizedDuration
        onCurrentTimeChange?(seconds)
        onDurationChange?(normalizedDuration)
        onPlayingChange?(player.rate > 0 || player.timeControlStatus == .playing)
    }
}
