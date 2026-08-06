import SwiftUI
import Photos
import Combine
import UIKit
import CoreLocation
import MapKit

struct FullScreenPhotoView: View {
    let asset: PHAsset
    let allAssets: [PHAsset]
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
    @State private var shareTask: Task<Void, Never>? = nil
    @State private var isDeleting = false
    @State private var isPreparingShare = false
    @State private var shareError: String? = nil
    private let autoPlayTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private var currentAssetIsVideo: Bool {
        visibleAssets.indices.contains(currentIndex) && visibleAssets[currentIndex].mediaType == .video
    }
    /// Drives the location lookup. Keying on the identifier rather than the
    /// index means a delete, which shifts every index after it, re-resolves
    /// only when the memory on screen actually changed.
    private var currentAssetIdentifier: String? {
        visibleAssets.indices.contains(currentIndex) ? visibleAssets[currentIndex].localIdentifier : nil
    }
    private var isPlaybackBlocked: Bool {
        showDeleteConfirm || showInfo || shareItem != nil || isPreparingShare || isDeleting
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
                VStack(spacing: 14) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(.white.opacity(0.65))
                        .symbolEffect(.bounce, options: .nonRepeating)
                    Text("All memories removed")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .transition(.opacity)
            } else {
                GeometryReader { geo in
                    let pageWidth = geo.size.width
                    HStack(spacing: 0) {
                        ForEach(Array(visibleAssets.enumerated()), id: \.element.localIdentifier) { index, a in
                            FullResAssetView(
                                asset: a,
                                isActive: index == currentIndex && !isPlaybackBlocked,
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
                    .gesture(pageDragGesture(pageWidth: pageWidth, isEnabled: !isCurrentAssetZoomed && !isVideoScrubbing && !isDeleting))
                    .animation(.easeOut(duration: 0.25), value: currentIndex)
                }
            }

            if showChrome && !visibleAssets.isEmpty {
                // Lighter than before: the glass controls carry their own
                // legibility now, so the scrim only has to lift them off very
                // bright photos rather than dim the image.
                VStack(spacing: 0) {
                    LinearGradient(colors: [.black.opacity(0.38), .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 140)
                    Spacer()
                    LinearGradient(colors: [.clear, .black.opacity(0.34)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 170)
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
                VStack(spacing: 0) {
                    GlassEffectContainer(spacing: 14) {
                        HStack(spacing: 10) {
                            ChromeButton(
                                systemImage: "xmark",
                                accessibilityLabel: "Close",
                                action: { dismiss() }
                            )

                            Spacer(minLength: 6)

                            VStack(spacing: 1) {
                                // Bounds-checked: a delete can retire the index
                                // between the emptiness guard above and this read.
                                if visibleAssets.indices.contains(currentIndex),
                                   let date = visibleAssets[currentIndex].creationDate {
                                    Text(date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.footnote.weight(.semibold))
                                }
                                if let location = locationName {
                                    HStack(spacing: 3) {
                                        Image(systemName: "location.fill")
                                            .font(.system(size: 8))
                                        Text(location)
                                            .font(.caption2)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                    .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .glassEffect(in: Capsule())

                            Spacer(minLength: 6)

                            ChromeButton(
                                systemImage: "square.and.arrow.up",
                                accessibilityLabel: "Share memory",
                                isBusy: isPreparingShare,
                                action: shareCurrentPhoto
                            )
                            .disabled(isPreparingShare || isDeleting)

                            ChromeButton(
                                systemImage: "trash",
                                accessibilityLabel: "Delete memory",
                                isBusy: isDeleting,
                                action: { showDeleteConfirm = true }
                            )
                            .disabled(isDeleting || isPreparingShare)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)

                    Spacer()

                    GlassEffectContainer(spacing: 14) {
                        HStack(spacing: 10) {
                            ChromeButton(
                                systemImage: "info.circle",
                                accessibilityLabel: "Memory info",
                                action: { showInfo = true }
                            )
                            .disabled(isDeleting || isPreparingShare)

                            Spacer(minLength: 6)

                            Text("\(currentIndex + 1) of \(visibleAssets.count)")
                                .font(.footnote.weight(.medium))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .padding(.horizontal, 16)
                                .frame(height: 44)
                                .glassEffect(in: Capsule())

                            Spacer(minLength: 6)

                            ChromeButton(
                                systemImage: isAutoPlaying ? "pause.fill" : "play.fill",
                                accessibilityLabel: isAutoPlaying ? "Pause story" : "Play story",
                                action: toggleAutoPlay
                            )
                            .disabled(isDeleting || isPreparingShare)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, currentAssetIsVideo ? 92 : 10)
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
        .alert("Couldn't Share", isPresented: shareErrorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareError ?? "The memory could not be prepared for sharing.")
        }
        .sheet(isPresented: $showInfo) {
            if visibleAssets.indices.contains(currentIndex) {
                MemoryInfoSheet(
                    asset: visibleAssets[currentIndex],
                    locationName: locationName
                )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        // Where a memory happened is part of remembering it, so the place name
        // resolves as each one comes into view rather than waiting to be asked
        // for. The pause coalesces a fast swipe through a day into one lookup
        // instead of one per photo, which matters because reverse geocoding is
        // rate limited; anywhere already seen comes back from the cache.
        .task(id: currentAssetIdentifier) {
            locationName = nil
            guard visibleAssets.indices.contains(currentIndex),
                  let coordinate = visibleAssets[currentIndex].location?.coordinate else { return }

            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            let resolved = await PlaceNameLookup.shared.placeName(for: coordinate)
            guard !Task.isCancelled else { return }
            locationName = resolved
        }
        .onChange(of: currentIndex) { _, _ in
            isCurrentAssetZoomed = false
            isVideoScrubbing = false
            autoPlayProgress = 0
            shareTask?.cancel()
            isPreparingShare = false
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            locationName = nil
        }
        .onChange(of: isCurrentAssetZoomed) { _, zoomed in
            if zoomed {
                stopAutoPlay()
            }
        }
        .onReceive(autoPlayTimer) { _ in
            autoPlayTick()
        }
        .onDisappear {
            shareTask?.cancel()
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .preferredColorScheme(.dark)
        .accessibilityAction(named: "Previous memory") {
            moveToPreviousMemory()
        }
        .accessibilityAction(named: "Next memory") {
            moveToNextMemory()
        }
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
        guard shareItem == nil, !showDeleteConfirm, !showInfo, !isPreparingShare, !isDeleting,
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
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    dragOffset = 0
                    return
                }
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
                guard abs(value.translation.width) > abs(value.translation.height) else {
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
        guard currentIndex < visibleAssets.count, !isPreparingShare, !isDeleting else { return }
        let asset = visibleAssets[currentIndex]
        let caption = shareCaption(for: asset)
        isPreparingShare = true
        shareError = nil

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
                        isPreparingShare = false
                    }
                } else if !Task.isCancelled {
                    await MainActor.run {
                        isPreparingShare = false
                        shareError = "The video could not be downloaded or exported. Check its iCloud availability and try again."
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
                        isPreparingShare = false
                    }
                } else if !Task.isCancelled {
                    await MainActor.run {
                        isPreparingShare = false
                        shareError = "The photo could not be downloaded. Check its iCloud availability and try again."
                    }
                }
            }
        }
    }

    private func deleteCurrentPhoto() {
        guard currentIndex < visibleAssets.count, !isDeleting else { return }
        let assetToDelete = visibleAssets[currentIndex]
        let identifier = assetToDelete.localIdentifier
        let identifiers = visibleAssets.map(\.localIdentifier)
        let nextIndex = GalleryStateLogic.indexAfterDeleting(
            identifier: identifier,
            from: identifiers,
            currentIndex: currentIndex
        )
        isDeleting = true
        shareTask?.cancel()
        isPreparingShare = false
        stopAutoPlay()

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets([assetToDelete] as NSArray)
        }) { success, error in
            DispatchQueue.main.async {
                isDeleting = false
                if success {
                    withAnimation {
                        visibleAssets.removeAll { $0.localIdentifier == identifier }
                        isCurrentAssetZoomed = false
                        if let nextIndex {
                            currentIndex = nextIndex
                        }
                    }
                    locationName = nil

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

    private func moveToPreviousMemory() {
        guard !isDeleting, currentIndex > 0 else { return }
        currentIndex -= 1
    }

    private func moveToNextMemory() {
        guard !isDeleting, currentIndex < visibleAssets.count - 1 else { return }
        currentIndex += 1
    }

    private func shareCaption(for asset: PHAsset) -> String {
        guard let creationDate = asset.creationDate else { return "A Time Capsule memory" }
        let years = MemoryWindow.yearsAgo(for: creationDate)
        guard years > 0 else { return "A Time Capsule memory" }
        let timing = MemoryWindow.dayWindow > 0 ? "around this day" : "today"
        return "\(years) year\(years == 1 ? "" : "s") ago \(timing)"
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )
    }

    private var shareErrorBinding: Binding<Bool> {
        Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )
    }
}

/// Circular glass control for the viewer chrome. Glass is the right material
/// here specifically because it floats over full-bleed media — the case Apple
/// designed it for — and it keeps the photo readable underneath.
private struct ChromeButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var isBusy: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(accessibilityLabel)
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
        let yearsAgo = MemoryWindow.yearsAgo(for: date)
        guard yearsAgo > 0 else { return nil }
        return yearsAgo == 1 ? "1 year ago" : "\(yearsAgo) years ago"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    if let yearsAgoLabel {
                        Text(yearsAgoLabel.uppercased())
                            .font(.system(size: 11, weight: .bold))
                            .tracking(1.3)
                            .foregroundStyle(Color.accentColor)
                    }
                    if let date = asset.creationDate {
                        Text(date.formatted(date: .complete, time: .omitted))
                            .font(.system(.title3, design: .rounded, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(date.formatted(date: .omitted, time: .shortened))
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

                    Text("The location name is requested from Apple's Maps service using this photo's coordinates. The coordinates come from the photo itself — Time Capsule never asks for your current location.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
    }

    private func infoRow(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, alignment: .center)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
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
