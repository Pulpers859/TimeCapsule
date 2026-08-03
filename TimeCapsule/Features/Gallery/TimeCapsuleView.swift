import SwiftUI
import Photos
import UIKit

struct TimeCapsuleView: View {
    let yearGroups: [YearGroup]
    let onOpenSettings: () -> Void
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var deleteError: String? = nil
    @State private var isDeleting = false
    @State private var recapProgress: Double? = nil
    @State private var recapShareItem: ShareItem? = nil
    @State private var recapError: String? = nil
    @State private var recapTask: Task<Void, Never>? = nil
    @SceneStorage("TimeCapsule.selectedFilter") private var selectedFilterRawValue = MemoryFilter.all.rawValue

    /// The gallery is built around the *logical* day, so a session that runs
    /// past midnight keeps showing the evening it started in. The header has to
    /// agree with the fetch or the date on screen contradicts the contents.
    private var referenceDate: Date {
        MemoryWindow.logicalDate(for: Date())
    }

    private var dateString: String {
        referenceDate.formatted(.dateTime.month(.wide).day())
    }

    private var selectedCount: Int { selectedIDs.count }
    private var selectedFilter: MemoryFilter {
        get { MemoryFilter(rawValue: selectedFilterRawValue) ?? .all }
        nonmutating set { selectedFilterRawValue = newValue.rawValue }
    }
    private var filteredYearGroups: [YearGroup] {
        yearGroups.compactMap { group in
            let filteredAssets = group.assets.filter(matchesCurrentFilters)
            guard !filteredAssets.isEmpty else { return nil }
            return YearGroup(year: group.year, assets: filteredAssets)
        }
    }
    private var totalFilteredCount: Int {
        filteredYearGroups.reduce(0) { $0 + $1.assets.count }
    }
    private var allFilteredAssets: [PHAsset] {
        filteredYearGroups.flatMap(\.assets)
    }
    private var recapEligiblePhotoCount: Int {
        allFilteredAssets.reduce(0) { $0 + ($1.mediaType == .image ? 1 : 0) }
    }
    private var visibleIdentifierSignature: [String] {
        allFilteredAssets.map(\.localIdentifier)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if filteredYearGroups.isEmpty {
                            FilterEmptyState(
                                selectedFilter: selectedFilter,
                                onResetFilters: resetFilters
                            )
                            .padding(.horizontal, TCMetrics.screenPadding)
                            .padding(.top, 24)
                            .padding(.bottom, 24)
                        } else {
                            MemorySummaryBar(
                                totalCount: totalFilteredCount,
                                yearCount: filteredYearGroups.count,
                                recapPhotoCount: recapEligiblePhotoCount,
                                isBusy: recapProgress != nil,
                                onCreateRecap: createRecap
                            )
                            .padding(.horizontal, TCMetrics.screenPadding)
                            .padding(.top, 8)

                            ForEach(filteredYearGroups) { group in
                                YearSection(
                                    group: group,
                                    allAssets: allFilteredAssets,
                                    isSelecting: isSelecting,
                                    selectedIDs: $selectedIDs
                                )
                                .id(sectionID(for: group))
                            }
                        }
                    }
                    .padding(.bottom, 28)
                }
                .background { AppBackground() }
                .safeAreaInset(edge: .top, spacing: 0) {
                    MemoryControlsBar(
                        dateString: dateString,
                        selectedFilter: selectedFilter,
                        isSelecting: isSelecting,
                        selectedCount: selectedCount,
                        yearGroups: filteredYearGroups,
                        onSelectFilter: { selectedFilter = $0 },
                        onToggleSelecting: {
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                                isSelecting.toggle()
                                if !isSelecting {
                                    selectedIDs.removeAll()
                                }
                            }
                        },
                        onOpenSettings: onOpenSettings,
                        onJumpToYear: { group in
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                                proxy.scrollTo(sectionID(for: group), anchor: .top)
                            }
                        }
                    )
                }
            }
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) {
                if isSelecting && selectedCount > 0 {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Group {
                            if isDeleting {
                                ProgressView().tint(.white)
                            } else {
                                Label(
                                    "Delete \(selectedCount) Item\(selectedCount == 1 ? "" : "s")",
                                    systemImage: "trash"
                                )
                                .font(.headline)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(.red)
                    .padding(.horizontal, TCMetrics.screenPadding)
                    .padding(.bottom, 10)
                    .disabled(isDeleting)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .confirmationDialog(
                "Delete \(selectedCount) Item\(selectedCount == 1 ? "" : "s")?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Move to Recently Deleted", role: .destructive) {
                    deleteSelectedPhotos()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This moves \(selectedCount == 1 ? "this item" : "these items") to Recently Deleted in Photos, where it can still be recovered for a limited time.")
            }
            .onChange(of: selectedFilterRawValue) { _, _ in
                pruneSelectionToVisibleItems()
            }
            .onChange(of: visibleIdentifierSignature) { _, _ in
                pruneSelectionToVisibleItems()
            }
            .sheet(item: $recapShareItem) { item in
                ShareSheet(items: item.items, cleanupURLs: item.cleanupURLs)
            }
            .alert("Couldn't Delete", isPresented: deleteErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "Something went wrong while moving the item to Recently Deleted.")
            }
            .alert("Recap", isPresented: recapErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(recapError ?? "Couldn't create the recap video.")
            }
            .overlay {
                if let progress = recapProgress {
                    RecapExportOverlay(progress: progress, onCancel: cancelRecap)
                }
            }
            .onDisappear {
                recapTask?.cancel()
                recapTask = nil
                recapProgress = nil
            }
        }
    }

    private func createRecap() {
        guard recapProgress == nil else { return }
        let photos = allFilteredAssets.filter { $0.mediaType == .image }
        guard photos.count >= 2 else {
            recapError = "A recap needs at least 2 photos from this day."
            return
        }
        recapProgress = 0
        recapTask?.cancel()
        let title = dateString
        recapTask = Task {
            let url = await MemoryRecapExporter.export(assets: photos, title: title) { value in
                DispatchQueue.main.async {
                    if recapProgress != nil {
                        recapProgress = min(max(value, 0), 1)
                    }
                }
            }
            await MainActor.run {
                guard !Task.isCancelled else {
                    if let url {
                        try? FileManager.default.removeItem(at: url)
                    }
                    return
                }
                recapProgress = nil
                recapTask = nil
                if let url {
                    recapShareItem = ShareItem(items: [url], cleanupURLs: [url])
                } else {
                    recapError = "Couldn't create the recap video. Please try again."
                }
            }
        }
    }

    private func cancelRecap() {
        recapTask?.cancel()
        recapTask = nil
        recapProgress = nil
    }

    private var recapErrorBinding: Binding<Bool> {
        Binding(
            get: { recapError != nil },
            set: { if !$0 { recapError = nil } }
        )
    }

    private func deleteSelectedPhotos() {
        guard !isDeleting else { return }
        // Gather all PHAssets matching selectedIDs
        var assetsToDelete: [PHAsset] = []
        for group in filteredYearGroups {
            for asset in group.assets {
                if selectedIDs.contains(asset.localIdentifier) {
                    assetsToDelete.append(asset)
                }
            }
        }

        guard !assetsToDelete.isEmpty else {
            pruneSelectionToVisibleItems()
            return
        }

        isDeleting = true

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assetsToDelete as NSArray)
        }) { success, error in
            DispatchQueue.main.async {
                isDeleting = false
                if success {
                    withAnimation {
                        selectedIDs.removeAll()
                        isSelecting = false
                    }
                    // Post notification so the model can refresh
                    NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)
                } else {
                    deleteError = error?.localizedDescription ?? "Could not move the selected memories to Recently Deleted."
                }
            }
        }
    }

    private func matchesCurrentFilters(_ asset: PHAsset) -> Bool {
        switch selectedFilter {
        case .all:
            return true
        case .photos:
            return asset.mediaType == .image
        case .videos:
            return asset.mediaType == .video
        }
    }

    private func sectionID(for group: YearGroup) -> String {
        "year-\(group.year)"
    }

    private func pruneSelectionToVisibleItems() {
        let visibleIDs = Set(filteredYearGroups.flatMap { group in
            group.assets.map(\.localIdentifier)
        })
        selectedIDs = GalleryStateLogic.prunedSelection(selectedIDs, visibleIDs: visibleIDs)
        if selectedIDs.isEmpty {
            isSelecting = false
        }
    }

    private func resetFilters() {
        selectedFilter = .all
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )
    }
}

// MARK: - Summary

/// One quiet line above the grid: what today holds, and the recap action.
///
/// This replaced a hero card — eyebrow, 30pt date, tinted background, amber
/// border, full-width filled button — that ran to roughly a fifth of the screen
/// and pushed the first photo well below the fold. Two things were wrong with
/// it. The date it announced was already sitting in the controls bar directly
/// above, so the screen opened by saying the same thing twice at two different
/// sizes. And rendering recap as a full-width prominent button made the app's
/// secondary action the loudest element in the view, competing with the
/// memories the screen exists to show.
///
/// Recap stays visible and labelled here, which is what the card got right —
/// it used to hide behind an unlabelled sparkles glyph in the toolbar. It just
/// no longer outranks the photos.
struct MemorySummaryBar: View {
    let totalCount: Int
    let yearCount: Int
    let recapPhotoCount: Int
    let isBusy: Bool
    let onCreateRecap: () -> Void

    private var summary: String {
        let memories = totalCount == 1 ? "1 memory" : "\(totalCount) memories"
        let years = yearCount == 1 ? "1 year" : "\(yearCount) years"
        return "\(memories) across \(years)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 8)

            if recapPhotoCount >= 2 {
                Button(action: onCreateRecap) {
                    Label("Recap", systemImage: "wand.and.sparkles")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(isBusy)
                .accessibilityLabel("Create recap video")
            }
        }
        .frame(minHeight: 34)
    }
}

// MARK: - Year sections

struct YearSection: View {
    let group: YearGroup
    let allAssets: [PHAsset]
    let isSelecting: Bool
    @Binding var selectedIDs: Set<String>
    @State private var selectedAsset: IdentifiableAsset? = nil

    private let columns = [
        GridItem(.adaptive(minimum: 108, maximum: 180), spacing: TCMetrics.gridSpacing)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            YearSectionHeader(group: group)
                .padding(.horizontal, TCMetrics.screenPadding)
                .padding(.top, 20)

            LazyVGrid(columns: columns, spacing: TCMetrics.gridSpacing) {
                ForEach(group.assets, id: \.localIdentifier) { asset in
                    let isSelected = selectedIDs.contains(asset.localIdentifier)
                    Button {
                        if isSelecting {
                            toggleSelection(asset)
                        } else {
                            selectedAsset = IdentifiableAsset(asset)
                        }
                    } label: {
                        MemoryTile(
                            asset: asset,
                            isSelecting: isSelecting,
                            isSelected: isSelected
                        )
                    }
                    .buttonStyle(PressableButtonStyle(scale: 0.94))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(for: asset))
                    .accessibilityValue(isSelecting ? (isSelected ? "Selected" : "Not selected") : "")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.horizontal, TCMetrics.screenPadding)
        }
        .fullScreenCover(item: $selectedAsset) { wrapper in
            FullScreenPhotoView(asset: wrapper.asset, allAssets: allAssets)
        }
    }

    private func toggleSelection(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func accessibilityLabel(for asset: PHAsset) -> String {
        let type = asset.mediaType == .video ? "Video" : "Photo"
        guard let date = asset.creationDate else { return "\(type) from \(group.year)" }
        return "\(type), \(date.formatted(date: .long, time: .omitted))"
    }
}

/// Weighted numeral against lighter supporting text — enough contrast to read
/// as editorial rather than as a table heading, without the numeral growing
/// large enough to compete with the grid underneath it.
struct YearSectionHeader: View {
    let group: YearGroup

    private var countLabel: String {
        group.assets.count == 1 ? "1 item" : "\(group.assets.count) items"
    }

    var body: some View {
        // Year and elapsed label share one baseline rather than stacking. Two
        // lines of chrome per section, at 38pt, cost more vertical space than
        // the photos they introduce once a day spans several years.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(String(group.year))
                .font(.system(size: 26, design: .rounded).weight(.bold))
                .tracking(-0.4)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            Text(group.label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 8)

            Text(countLabel)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Grid tile

struct MemoryTile: View {
    let asset: PHAsset
    let isSelecting: Bool
    let isSelected: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TCMetrics.thumbnailRadius, style: .continuous)
    }

    var body: some View {
        AssetThumbnailView(asset: asset)
            .overlay(alignment: .bottomLeading) {
                if asset.mediaType == .video {
                    VideoDurationBadge(duration: asset.duration)
                }
            }
            .clipShape(shape)
            // Unselected items recede while picking, so the selection reads at
            // a glance instead of hiding behind a small checkmark.
            .opacity(isSelecting && !isSelected ? 0.55 : 1)
            .overlay {
                shape.strokeBorder(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                    lineWidth: isSelected ? 3 : 0.5
                )
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            isSelected ? Color.white : Color.white.opacity(0.9),
                            isSelected ? Color.accentColor : Color.black.opacity(0.35)
                        )
                        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                        .padding(7)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .scaleEffect(isSelected ? 0.94 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isSelected)
            .animation(.easeInOut(duration: 0.2), value: isSelecting)
            .id(asset.localIdentifier)
    }
}

struct AssetThumbnailView: View {
    let asset: PHAsset
    @State private var image: UIImage? = nil
    @State private var didFail = false

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.width)
                } else if didFail {
                    Color.tcPlaceholder
                        .overlay {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                } else {
                    // A calm placeholder rather than a spinner: at gallery
                    // scale, a dozen spinners is visual noise.
                    Color.tcPlaceholder
                }
            }
            .frame(width: geo.size.width, height: geo.size.width)
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: asset.localIdentifier) {
            image = nil
            didFail = false
            let loadedImage = await loadImage(from: asset, targetSize: CGSize(width: 300, height: 300))
            guard !Task.isCancelled else { return }
            didFail = loadedImage == nil
            withAnimation(.easeOut(duration: 0.28)) {
                image = loadedImage
            }
        }
    }
}

// MARK: - Filter empty state

struct FilterEmptyState: View {
    let selectedFilter: MemoryFilter
    let onResetFilters: () -> Void

    private var title: String {
        "No \(selectedFilter.title.lowercased()) for this day"
    }

    var body: some View {
        VStack(spacing: 0) {
            BrandGlyph(systemName: selectedFilter.symbol, size: 72)
                .padding(.bottom, 20)

            Text(title)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

            Text("Try another filter, or go back to everything from this day.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 22)

            Button(action: onResetFilters) {
                Text("Show All Memories")
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 190)
                    .frame(height: 46)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 34)
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: TCMetrics.cardRadius, style: .continuous)
        )
    }
}

// MARK: - Floating controls

/// Floats over the gallery with no opaque bar behind it. Glass is applied to
/// the individual controls — the navigation layer — while the photo grid below
/// stays plain, which is the split Apple's Liquid Glass guidance asks for.
struct MemoryControlsBar: View {
    let dateString: String
    let selectedFilter: MemoryFilter
    let isSelecting: Bool
    let selectedCount: Int
    let yearGroups: [YearGroup]
    let onSelectFilter: (MemoryFilter) -> Void
    let onToggleSelecting: () -> Void
    let onOpenSettings: () -> Void
    let onJumpToYear: (YearGroup) -> Void

    private var selectTitle: String {
        guard isSelecting else { return "Select" }
        return selectedCount > 0 ? "Done (\(selectedCount))" : "Done"
    }

    var body: some View {
        GlassEffectContainer(spacing: 16) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    GlassIconButton(
                        systemImage: "gearshape",
                        accessibilityLabel: "Settings",
                        action: onOpenSettings
                    )

                    Spacer(minLength: 6)

                    Text(dateString)
                        .font(.system(size: 16, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, 16)
                        .frame(height: TCMetrics.controlHeight)
                        .glassEffect(in: Capsule())
                        .accessibilityAddTraits(.isHeader)

                    Spacer(minLength: 6)

                    Button(action: onToggleSelecting) {
                        Text(selectTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(height: TCMetrics.controlHeight)
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(MemoryFilter.allCases) { filter in
                            FilterChip(
                                filter: filter,
                                isSelected: selectedFilter == filter,
                                action: { onSelectFilter(filter) }
                            )
                        }

                        if yearGroups.count > 1 {
                            Menu {
                                ForEach(yearGroups) { group in
                                    Button {
                                        onJumpToYear(group)
                                    } label: {
                                        Label("\(group.year) · \(group.assets.count)", systemImage: "calendar")
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text("Jump to Year")
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 10, weight: .bold))
                                }
                                .font(.footnote.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .frame(height: 38)
                                .glassEffect(in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel("Jump to year")
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .opacity(isSelecting ? 0.4 : 1)
                .disabled(isSelecting)
                .accessibilityHidden(isSelecting)
            }
            .padding(.horizontal, TCMetrics.screenPadding)
            .padding(.top, 4)
            .padding(.bottom, 12)
        }
    }
}

struct FilterChip: View {
    let filter: MemoryFilter
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(filter.title, systemImage: filter.symbol)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 38)
        }
        .buttonBorderShape(.capsule)
        .filterChipStyle(isSelected: isSelected)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension View {
    /// Switching the whole button style is what gives the selected chip a
    /// genuinely different material, rather than just a recoloured background.
    @ViewBuilder
    func filterChipStyle(isSelected: Bool) -> some View {
        if isSelected {
            self.buttonStyle(.glassProminent).tint(Color.accentColor)
        } else {
            self.buttonStyle(.glass)
        }
    }
}

enum MemoryFilter: String, CaseIterable, Identifiable {
    case all
    case photos
    case videos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All"
        case .photos:
            return "Photos"
        case .videos:
            return "Videos"
        }
    }

    var symbol: String {
        switch self {
        case .all:
            return "square.grid.2x2"
        case .photos:
            return "photo"
        case .videos:
            return "video"
        }
    }
}

struct VideoDurationBadge: View {
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 7, weight: .bold))
            Text(formattedDuration)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(6)
        .accessibilityHidden(true)
    }

    private var formattedDuration: String {
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct RecapExportOverlay: View {
    let progress: Double
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 5)
                    Circle()
                        .trim(from: 0, to: max(min(progress, 1), 0.01))
                        .stroke(
                            TCGradient.brand,
                            style: StrokeStyle(lineWidth: 5, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.25), value: progress)

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 15, design: .rounded).weight(.bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .frame(width: 74, height: 74)
                .padding(.bottom, 18)

                Text("Creating recap")
                    .font(.headline)
                    .padding(.bottom, 4)

                Text("Stitching your photos together")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 20)

                Button(role: .cancel, action: onCancel) {
                    Text("Cancel")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 130)
                        .frame(height: 42)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .padding(40)
        }
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Creating recap")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

struct IdentifiableAsset: Identifiable {
    let id: String
    let asset: PHAsset
    init(_ asset: PHAsset) {
        self.id = asset.localIdentifier
        self.asset = asset
    }
}
