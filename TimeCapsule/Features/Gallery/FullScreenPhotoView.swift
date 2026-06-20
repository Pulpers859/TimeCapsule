import SwiftUI
import Photos
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
    @State private var shareTask: Task<Void, Never>? = nil
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
                        .accessibilityLabel("Close")
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
                        .accessibilityLabel("Share memory")
                        Button(action: { showDeleteConfirm = true }) {
                            Image(systemName: "trash")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Delete memory")
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
                        .accessibilityLabel("Memory info")
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
                        .accessibilityLabel(isAutoPlaying ? "Pause story" : "Play story")
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
            ShareSheet(items: item.items, cleanupURLs: item.cleanupURLs)
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
            shareTask?.cancel()
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
            shareTask?.cancel()
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
            shareTask?.cancel()
            shareTask = Task {
                if let videoURL = await exportVideoToTemporaryFile(from: asset) {
                    await MainActor.run {
                        guard !Task.isCancelled,
                              visibleAssets.indices.contains(currentIndex),
                              visibleAssets[currentIndex].localIdentifier == asset.localIdentifier else {
                            try? FileManager.default.removeItem(at: videoURL)
                            return
                        }
                        shareItem = ShareItem(items: [videoURL, caption], cleanupURLs: [videoURL])
                    }
                }
            }
        } else {
            shareTask?.cancel()
            shareTask = Task {
                if let image = await loadImage(
                    from: asset,
                    targetSize: CGSize(width: 1290, height: 2796),
                    contentMode: .aspectFit
                ) {
                    await MainActor.run {
                        guard !Task.isCancelled,
                              visibleAssets.indices.contains(currentIndex),
                              visibleAssets[currentIndex].localIdentifier == asset.localIdentifier else { return }
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
        shareTask?.cancel()
        reverseGeocodeTask?.cancel()
        stopAutoPlay()

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
    let cleanupURLs: [URL]

    init(items: [Any], cleanupURLs: [URL] = []) {
        self.items = items
        self.cleanupURLs = cleanupURLs
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let cleanupURLs: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            for url in cleanupURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        return controller
    }

    func updateUIViewController(_ uvc: UIActivityViewController, context: Context) {}
}
