import SwiftUI
import Photos
import AVKit
import AVFoundation
import UIKit

struct FullScreenPhotoView: View {
    let asset: PHAsset
    let allAssets: [PHAsset]
    private let preheater = AdjacentMediaPreheater.shared

    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var showChrome = true
    @State private var visibleAssets: [PHAsset]
    @State private var showDeleteConfirm = false
    @State private var deleteError: String? = nil
    @State private var shareItem: ShareItem? = nil
    @State private var dragOffset: CGFloat = 0
    @State private var isCurrentAssetZoomed = false
    @State private var isVideoScrubbing = false
    private var currentAssetIsVideo: Bool {
        visibleAssets.indices.contains(currentIndex) && visibleAssets[currentIndex].mediaType == .video
    }

    init(asset: PHAsset, allAssets: [PHAsset]) {
        self.asset = asset
        self.allAssets = allAssets
        _visibleAssets = State(initialValue: allAssets)
        _currentIndex = State(initialValue: allAssets.firstIndex(where: { $0.localIdentifier == asset.localIdentifier }) ?? 0)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if visibleAssets.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 48))
                        .foregroundStyle(.white.opacity(0.6))
                    Text("All memories removed")
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                GeometryReader { geo in
                    let pageWidth = geo.size.width
                    HStack(spacing: 0) {
                        ForEach(Array(visibleAssets.enumerated()), id: \.element.localIdentifier) { index, a in
                            FullResAssetView(
                                asset: a,
                                isActive: index == currentIndex,
                                shouldRender: abs(index - currentIndex) <= 1,
                                showControls: showChrome,
                                onToggleChrome: {
                                    withAnimation {
                                        showChrome.toggle()
                                    }
                                },
                                onZoomStateChange: { isZoomed in
                                    if visibleAssets.indices.contains(currentIndex),
                                       visibleAssets[currentIndex].localIdentifier == a.localIdentifier {
                                        isCurrentAssetZoomed = isZoomed
                                    }
                                },
                                onScrubbingChanged: { isScrubbing in
                                    if visibleAssets.indices.contains(currentIndex),
                                       visibleAssets[currentIndex].localIdentifier == a.localIdentifier {
                                        isVideoScrubbing = isScrubbing
                                    }
                                }
                            )
                                .frame(width: pageWidth, height: geo.size.height)
                        }
                    }
                    .offset(x: -CGFloat(currentIndex) * pageWidth + dragOffset)
                    .gesture(pageDragGesture(pageWidth: pageWidth, isEnabled: !isCurrentAssetZoomed && !isVideoScrubbing))
                    .animation(.easeOut(duration: 0.25), value: currentIndex)
                }
            }

            if showChrome && !visibleAssets.isEmpty {
                VStack {
                    HStack {
                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        Spacer()
                        if let date = visibleAssets[currentIndex].creationDate {
                            Text(date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        Spacer()
                        Button(action: { shareCurrentPhoto() }) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        Button(action: { showDeleteConfirm = true }) {
                            Image(systemName: "trash")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .padding()
                    Spacer()
                    Text("\(currentIndex + 1) of \(visibleAssets.count)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.bottom, currentAssetIsVideo ? 92 : 8)
                }
                .transition(.opacity)
            }

        }
        .confirmationDialog("Delete this item?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Move to Recently Deleted", role: .destructive) {
                deleteCurrentPhoto()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves the item to Recently Deleted in Photos, where it can still be recovered for a limited time.")
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: item.items)
        }
        .alert("Couldn't Delete", isPresented: deleteErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "Something went wrong while moving the item to Recently Deleted.")
        }
        .onChange(of: currentIndex) { _ in
            isCurrentAssetZoomed = false
            isVideoScrubbing = false
            preloadAdjacentMedia()
        }
        .onAppear(perform: preloadAdjacentMedia)
        .onDisappear {
            preheater.stopCaching()
        }
        .preferredColorScheme(.dark)
    }

    private func pageDragGesture(pageWidth: CGFloat, isEnabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: isEnabled ? 15 : .greatestFiniteMagnitude)
            .onChanged { value in
                guard isEnabled else { return }
                let proposed = value.translation.width
                if (currentIndex == 0 && proposed > 0) ||
                   (currentIndex == visibleAssets.count - 1 && proposed < 0) {
                    dragOffset = proposed * 0.3
                } else {
                    dragOffset = proposed
                }
            }
            .onEnded { value in
                guard isEnabled else {
                    dragOffset = 0
                    return
                }
                let threshold = pageWidth * 0.2
                let predicted = value.predictedEndTranslation.width
                var newIndex = currentIndex

                if predicted < -threshold && currentIndex < visibleAssets.count - 1 {
                    newIndex += 1
                } else if predicted > threshold && currentIndex > 0 {
                    newIndex -= 1
                }

                withAnimation(.easeOut(duration: 0.25)) {
                    currentIndex = newIndex
                    dragOffset = 0
                }
            }
    }

    private func shareCurrentPhoto() {
        guard currentIndex < visibleAssets.count else { return }
        let asset = visibleAssets[currentIndex]
        let currentYear = Calendar.current.component(.year, from: Date())
        let photoYear = Calendar.current.component(.year, from: asset.creationDate ?? Date())
        let yearsAgo = currentYear - photoYear
        let caption = "\(yearsAgo) year\(yearsAgo == 1 ? "" : "s") ago today 📸"

        if asset.mediaType == .video {
            Task {
                if let videoURL = await exportVideoToTemporaryFile(from: asset) {
                    await MainActor.run {
                        shareItem = ShareItem(items: [videoURL, caption])
                    }
                }
            }
        } else {
            Task {
                if let image = await loadImage(
                    from: asset,
                    targetSize: CGSize(width: 1290, height: 2796),
                    contentMode: .aspectFit
                ) {
                    await MainActor.run {
                        shareItem = ShareItem(items: [image, caption])
                    }
                }
            }
        }
    }

    private func deleteCurrentPhoto() {
        guard currentIndex < visibleAssets.count else { return }
        let idx = currentIndex
        let assetToDelete = visibleAssets[idx]

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets([assetToDelete] as NSArray)
        }) { success, error in
            DispatchQueue.main.async {
                if success {
                    withAnimation {
                        visibleAssets.remove(at: idx)
                        isCurrentAssetZoomed = false
                        if currentIndex >= visibleAssets.count && currentIndex > 0 {
                            currentIndex = visibleAssets.count - 1
                        }
                    }
                    preloadAdjacentMedia()

                    NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)

                    if visibleAssets.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            dismiss()
                        }
                    }
                } else {
                    deleteError = error?.localizedDescription ?? "Could not move this item to Recently Deleted."
                }
            }
        }
    }

    private func preloadAdjacentMedia() {
        preheater.updateCaching(for: visibleAssets, currentIndex: currentIndex)
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}

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
        .task(id: shouldRender) {
            guard shouldRender else {
                player?.pause()
                player = nil
                image = nil
                progressObserver.detach()
                currentTime = 0
                duration = 0
                isPlaying = false
                return
            }

            if asset.mediaType == .video {
                image = nil
                let loadedPlayer = await loadPlayer(from: asset)
                player = loadedPlayer
                progressObserver.attach(
                    to: loadedPlayer,
                    onCurrentTimeChange: { currentTime = $0 },
                    onDurationChange: { duration = $0 },
                    onPlayingChange: { isPlaying = $0 }
                )
                if isActive {
                    loadedPlayer?.play()
                }
            } else {
                image = await loadImage(
                    from: asset,
                    targetSize: CGSize(width: 1290, height: 2796),
                    contentMode: .aspectFit
                )
            }
        }
        .onChange(of: isActive) { active in
            if active {
                player?.play()
            } else {
                player?.pause()
                player?.seek(to: .zero)
                scrubPosition = 0
                currentTime = 0
                isPlaying = false
                isScrubbing = false
                onScrubbingChanged(false)
                onZoomStateChange(false)
            }
        }
        .onDisappear {
            onScrubbingChanged(false)
            progressObserver.detach()
        }
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

        for asset in assetsToCache where asset.mediaType == .video {
            Task {
                _ = await loadPlayer(from: asset)
            }
        }
    }

    func stopCaching() {
        cachingManager.stopCachingImagesForAllAssets()
        cachedAssetIDs.removeAll()
    }
}

struct PhotoZoomScrollView: UIViewRepresentable {
    let image: UIImage
    let onZoomStateChange: (Bool) -> Void
    let onSingleTap: () -> Void

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let scrollView = ZoomingImageScrollView()
        scrollView.updateCallbacks(
            onZoomStateChange: onZoomStateChange,
            onSingleTap: onSingleTap
        )
        scrollView.display(image: image)
        return scrollView
    }

    func updateUIView(_ uiView: ZoomingImageScrollView, context: Context) {
        uiView.updateCallbacks(
            onZoomStateChange: onZoomStateChange,
            onSingleTap: onSingleTap
        )
        uiView.display(image: image)
    }
}

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
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

                Button(action: onSkipBack) {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

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
            guard let self, let player else { return }
            let seconds = time.seconds.isFinite ? time.seconds : nil
            self.publishSnapshot(for: player, currentTimeOverride: seconds)
        }

        if let currentItem = player.currentItem {
            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: currentItem,
                queue: .main
            ) { [weak self, weak player] _ in
                guard let self, let player else { return }
                self.publishSnapshot(for: player)
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
            guard let self, let player else { return }
            self.publishSnapshot(for: player, currentTimeOverride: bounded)
        }
    }

    private func publishSnapshot(for player: AVPlayer, currentTimeOverride: Double? = nil) {
        let seconds = currentTimeOverride ?? {
            let current = player.currentTime().seconds
            return current.isFinite ? current : 0
        }()
        let rawDuration = player.currentItem?.duration.seconds ?? 0
        let normalizedDuration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : 0
        latestDuration = normalizedDuration
        onCurrentTimeChange?(seconds)
        onDurationChange?(normalizedDuration)
        onPlayingChange?(player.rate > 0 || player.timeControlStatus == .playing)
    }
}

final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var currentImageIdentifier: ObjectIdentifier?
    private var hasConfiguredImage = false
    private var onZoomStateChange: ((Bool) -> Void)?
    private var onSingleTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0, bounds.height > 0, let image = imageView.image else {
            return
        }

        if !hasConfiguredImage {
            configureForCurrentBounds(using: image)
            hasConfiguredImage = true
        } else {
            centerImage()
        }
    }

    func updateCallbacks(
        onZoomStateChange: @escaping (Bool) -> Void,
        onSingleTap: @escaping () -> Void
    ) {
        self.onZoomStateChange = onZoomStateChange
        self.onSingleTap = onSingleTap
    }

    func display(image: UIImage) {
        let identifier = ObjectIdentifier(image)
        guard currentImageIdentifier != identifier else { return }

        currentImageIdentifier = identifier
        imageView.image = image
        hasConfiguredImage = false
        setNeedsLayout()
        layoutIfNeeded()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
        onZoomStateChange?(zoomScale > minimumZoomScale + 0.01)
    }

    private func configure() {
        delegate = self
        backgroundColor = .clear
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        bouncesZoom = true
        decelerationRate = .fast
        delaysContentTouches = false
        canCancelContentTouches = true
        maximumZoomScale = 4
        minimumZoomScale = 1

        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        addSubview(imageView)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.numberOfTapsRequired = 1

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
        addGestureRecognizer(doubleTap)
    }

    private func configureForCurrentBounds(using image: UIImage) {
        let fittedSize = aspectFitSize(for: image.size, in: bounds.size)
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
        zoomScale = 1
        minimumZoomScale = 1
        maximumZoomScale = 4
        contentOffset = .zero
        centerImage()
        onZoomStateChange?(false)
    }

    private func aspectFitSize(for imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              containerSize.width > 0, containerSize.height > 0 else {
            return containerSize
        }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = containerSize.width / containerSize.height

        if imageAspect > containerAspect {
            return CGSize(
                width: containerSize.width,
                height: containerSize.width / imageAspect
            )
        } else {
            return CGSize(
                width: containerSize.height * imageAspect,
                height: containerSize.height
            )
        }
    }

    private func centerImage() {
        let horizontalInset = max((bounds.width - imageView.frame.width) / 2, 0)
        let verticalInset = max((bounds.height - imageView.frame.height) / 2, 0)

        contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            onZoomStateChange?(false)
            return
        }

        let targetZoomScale = min(maximumZoomScale, 2.5)
        let tapPoint = gesture.location(in: imageView)
        zoom(to: zoomRect(for: targetZoomScale, centeredAt: tapPoint), animated: true)
    }

    private func zoomRect(for scale: CGFloat, centeredAt point: CGPoint) -> CGRect {
        let width = bounds.size.width / scale
        let height = bounds.size.height / scale

        return CGRect(
            x: point.x - (width / 2),
            y: point.y - (height / 2),
            width: width,
            height: height
        )
    }
}

func loadPlayer(from asset: PHAsset) async -> AVPlayer? {
    await withCheckedContinuation { continuation in
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
            if let playerItem {
                let player = AVPlayer(playerItem: playerItem)
                continuation.resume(returning: player)
            } else {
                continuation.resume(returning: nil)
            }
        }
    }
}

func exportVideoToTemporaryFile(from asset: PHAsset) async -> URL? {
    await withCheckedContinuation { continuation in
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo }) else {
            continuation.resume(returning: nil)
            return
        }

        let ext = (resource.originalFilename as NSString).pathExtension
        let filename = ext.isEmpty ? "\(UUID().uuidString).mov" : "\(UUID().uuidString).\(ext)"
        let destinationURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: destinationURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        PHAssetResourceManager.default().writeData(for: resource, toFile: destinationURL, options: options) { error in
            continuation.resume(returning: error == nil ? destinationURL : nil)
        }
    }
}
