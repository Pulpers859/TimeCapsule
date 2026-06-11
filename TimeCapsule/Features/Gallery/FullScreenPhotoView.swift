import SwiftUI
import Photos
import AVFoundation
import Combine
import UIKit
import CoreLocation
import MapKit

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
    @State private var locationName: String? = nil
    @State private var isAutoPlaying = false
    @State private var autoPlayProgress: Double = 0
    @State private var showInfo = false
    @State private var reverseGeocodeTask: Task<Void, Never>? = nil
    private let autoPlayTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private var currentAssetIsVideo: Bool {
        visibleAssets.indices.contains(currentIndex) && visibleAssets[currentIndex].mediaType == .video
    }
    private var currentAssetIsImage: Bool {
        visibleAssets.indices.contains(currentIndex) && visibleAssets[currentIndex].mediaType == .image
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
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 130)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 160)
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            if isAutoPlaying && !visibleAssets.isEmpty {
                VStack {
                    StoryProgressBar(
                        count: visibleAssets.count,
                        currentIndex: currentIndex,
                        progress: autoPlayProgress
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
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
                        VStack(spacing: 4) {
                            if let date = visibleAssets[currentIndex].creationDate {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.white)
                            }
                            if currentAssetIsImage, let location = locationName {
                                HStack(spacing: 3) {
                                    Image(systemName: "location.fill")
                                        .font(.system(size: 8))
                                    Text(location)
                                        .font(.caption2)
                                }
                                .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    HStack {
                        Button(action: { showInfo = true }) {
                            Image(systemName: "info.circle")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        Spacer()
                        Text("\(currentIndex + 1) of \(visibleAssets.count)")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        Button(action: toggleAutoPlay) {
                            Image(systemName: isAutoPlaying ? "pause.fill" : "play.fill")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                    .padding(.horizontal, 16)
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
        .sheet(isPresented: $showInfo) {
            if visibleAssets.indices.contains(currentIndex) {
                MemoryInfoSheet(asset: visibleAssets[currentIndex], locationName: locationName)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .onChange(of: currentIndex) { _, _ in
            isCurrentAssetZoomed = false
            isVideoScrubbing = false
            autoPlayProgress = 0
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            preloadAdjacentMedia()
            resolveLocation()
        }
        .onChange(of: isCurrentAssetZoomed) { _, zoomed in
            if zoomed {
                stopAutoPlay()
            }
        }
        .onReceive(autoPlayTimer) { _ in
            autoPlayTick()
        }
        .onAppear {
            preloadAdjacentMedia()
            resolveLocation()
        }
        .onDisappear {
            reverseGeocodeTask?.cancel()
            preheater.stopCaching()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .preferredColorScheme(.dark)
    }

    private var currentAutoPlayDuration: Double {
        guard visibleAssets.indices.contains(currentIndex) else { return 4 }
        let asset = visibleAssets[currentIndex]
        if asset.mediaType == .video {
            return min(max(asset.duration, 3), 15)
        }
        return 4
    }

    private func toggleAutoPlay() {
        if isAutoPlaying {
            stopAutoPlay()
        } else {
            guard !visibleAssets.isEmpty else { return }
            autoPlayProgress = 0
            withAnimation {
                // Starting from the end means "replay" — wrap to the beginning.
                if currentIndex == visibleAssets.count - 1 && visibleAssets.count > 1 {
                    currentIndex = 0
                }
                isAutoPlaying = true
                showChrome = false
            }
            UIApplication.shared.isIdleTimerDisabled = true
        }
    }

    private func stopAutoPlay() {
        guard isAutoPlaying else { return }
        withAnimation {
            isAutoPlaying = false
        }
        autoPlayProgress = 0
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func autoPlayTick() {
        guard isAutoPlaying, !visibleAssets.isEmpty else { return }
        // Hold while the user is mid-interaction or a sheet/dialog is up.
        guard shareItem == nil, !showDeleteConfirm, !showInfo,
              !isCurrentAssetZoomed, !isVideoScrubbing, dragOffset == 0 else { return }

        autoPlayProgress += 0.05 / max(currentAutoPlayDuration, 0.5)
        if autoPlayProgress >= 1 {
            if currentIndex < visibleAssets.count - 1 {
                autoPlayProgress = 0
                withAnimation(.easeOut(duration: 0.25)) {
                    currentIndex += 1
                }
            } else {
                stopAutoPlay()
                withAnimation {
                    showChrome = true
                }
            }
        }
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
                    resolveLocation()

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

    private func resolveLocation() {
        locationName = nil
        reverseGeocodeTask?.cancel()
        guard visibleAssets.indices.contains(currentIndex) else { return }
        let current = visibleAssets[currentIndex]
        guard current.mediaType == .image, let location = current.location else { return }

        reverseGeocodeTask = Task {
            let resolved = await reverseGeocodeName(for: location)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                locationName = resolved
            }
        }
    }

    private func reverseGeocodeName(for location: CLLocation) async -> String? {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return nil
        }

        return await withCheckedContinuation { continuation in
            request.getMapItems { items, _ in
                let bestMatch = items?.first
                let resolved = bestMatch?.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true)
                    ?? bestMatch?.name
                continuation.resume(returning: resolved)
            }
        }
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )
    }
}

struct StoryProgressBar: View {
    let count: Int
    let currentIndex: Int
    let progress: Double

    /// Past this many items, segments get too thin to read — fall back to one
    /// continuous bar instead of rendering sliver capsules.
    private let maxSegments = 24

    var body: some View {
        if count > maxSegments {
            bar(fraction: overallFraction)
        } else {
            HStack(spacing: 3) {
                ForEach(0..<count, id: \.self) { index in
                    bar(fraction: fraction(for: index))
                }
            }
        }
    }

    private var overallFraction: Double {
        guard count > 0 else { return 0 }
        return (Double(currentIndex) + min(max(progress, 0), 1)) / Double(count)
    }

    private func fraction(for index: Int) -> Double {
        if index < currentIndex { return 1 }
        if index == currentIndex { return min(max(progress, 0), 1) }
        return 0
    }

    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                Capsule()
                    .fill(.white)
                    .frame(width: max(geo.size.width * fraction, 0))
            }
        }
        .frame(height: 3)
    }
}

struct MemoryInfoSheet: View {
    let asset: PHAsset
    let locationName: String?
    @State private var mapPosition: MapCameraPosition

    init(asset: PHAsset, locationName: String?) {
        self.asset = asset
        self.locationName = locationName
        let center = asset.location?.coordinate ?? CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
        )
        _mapPosition = State(initialValue: .region(region))
    }

    private var yearsAgoLabel: String? {
        guard let date = asset.creationDate else { return nil }
        let yearsAgo = Calendar.current.component(.year, from: Date()) - Calendar.current.component(.year, from: date)
        guard yearsAgo > 0 else { return nil }
        return yearsAgo == 1 ? "1 year ago" : "\(yearsAgo) years ago"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    if let yearsAgoLabel {
                        Text(yearsAgoLabel)
                            .font(.title2.weight(.bold))
                    }
                    if let date = asset.creationDate {
                        Text(date.formatted(date: .complete, time: .shortened))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(spacing: 0) {
                    infoRow(
                        label: "Kind",
                        value: asset.mediaType == .video ? "Video" : "Photo",
                        icon: asset.mediaType == .video ? "video" : "photo"
                    )
                    Divider().padding(.leading, 40)
                    infoRow(
                        label: "Dimensions",
                        value: "\(asset.pixelWidth) × \(asset.pixelHeight)",
                        icon: "aspectratio"
                    )
                    if asset.mediaType == .video {
                        Divider().padding(.leading, 40)
                        infoRow(
                            label: "Duration",
                            value: formattedDuration(asset.duration),
                            icon: "timer"
                        )
                    }
                    if let locationName {
                        Divider().padding(.leading, 40)
                        infoRow(label: "Location", value: locationName, icon: "location")
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                if let coordinate = asset.location?.coordinate {
                    Map(position: $mapPosition, interactionModes: [.zoom, .pan]) {
                        Marker("Memory Location", coordinate: coordinate)
                            .tint(.red)
                    }
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .allowsHitTesting(false)
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func infoRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
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
        .onChange(of: isActive) { _, active in
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
            let seconds = time.seconds.isFinite ? time.seconds : nil
            Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
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
                    guard let self, let player else { return }
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
            Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
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
