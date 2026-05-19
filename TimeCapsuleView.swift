import SwiftUI
import Photos

struct TimeCapsuleView: View {
    let yearGroups: [YearGroup]
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var showSettings = false
    @State private var deleteError: String? = nil
    @SceneStorage("TimeCapsule.selectedFilter") private var selectedFilterRawValue = MemoryFilter.all.rawValue

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d"
        return formatter.string(from: Date())
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
                            .padding(.horizontal, 16)
                            .padding(.top, 24)
                            .padding(.bottom, 24)
                        } else {
                            OverviewHeader(totalCount: totalFilteredCount, yearCount: filteredYearGroups.count)
                                .padding(.horizontal, 16)
                                .padding(.top, 10)
                                .padding(.bottom, 10)

                            ForEach(filteredYearGroups) { group in
                                YearSection(
                                    group: group,
                                    isSelecting: isSelecting,
                                    selectedIDs: $selectedIDs
                                )
                                .id(sectionID(for: group))
                            }
                        }
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    MemoryControlsBar(
                        dateString: dateString,
                        selectedFilter: selectedFilter,
                        isSelecting: isSelecting,
                        yearGroups: filteredYearGroups,
                        onSelectFilter: { selectedFilter = $0 },
                        onToggleSelecting: {
                            withAnimation {
                                isSelecting.toggle()
                                if !isSelecting {
                                    selectedIDs.removeAll()
                                }
                            }
                        },
                        onOpenSettings: {
                            showSettings = true
                        },
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
                        Label("Delete \(selectedCount) Item\(selectedCount == 1 ? "" : "s")", systemImage: "trash")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .background(.ultraThinMaterial)
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
            .onChange(of: selectedFilterRawValue) { _ in
                pruneSelectionToVisibleItems()
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .alert("Couldn't Delete", isPresented: deleteErrorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(deleteError ?? "Something went wrong while moving the item to Recently Deleted.")
            }
        }
    }

    private func deleteSelectedPhotos() {
        // Gather all PHAssets matching selectedIDs
        var assetsToDelete: [PHAsset] = []
        for group in filteredYearGroups {
            for asset in group.assets {
                if selectedIDs.contains(asset.localIdentifier) {
                    assetsToDelete.append(asset)
                }
            }
        }

        guard !assetsToDelete.isEmpty else { return }

        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(assetsToDelete as NSArray)
        }) { success, error in
            DispatchQueue.main.async {
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
        selectedIDs = selectedIDs.intersection(visibleIDs)
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

struct YearSection: View {
    let group: YearGroup
    let isSelecting: Bool
    @Binding var selectedIDs: Set<String>
    @State private var selectedAsset: IdentifiableAsset? = nil

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Year header
            VStack(alignment: .leading, spacing: 2) {
                Text(String(group.year))
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(group.label)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemGroupedBackground))

            // Photo grid
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(group.assets, id: \.localIdentifier) { asset in
                    ZStack(alignment: .topTrailing) {
                        AssetThumbnailView(asset: asset)
                            .overlay(alignment: .bottomLeading) {
                                if asset.mediaType == .video {
                                    VideoDurationBadge(duration: asset.duration)
                                }
                            }
                            .onTapGesture {
                                if isSelecting {
                                    toggleSelection(asset)
                                } else {
                                    selectedAsset = IdentifiableAsset(asset)
                                }
                            }
                            .id(asset.localIdentifier)

                        if isSelecting {
                            let isSelected = selectedIDs.contains(asset.localIdentifier)
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(isSelected ? .white : .white.opacity(0.7))
                                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                                .padding(6)
                        }
                    }
                }
            }
        }
        .fullScreenCover(item: $selectedAsset) { wrapper in
            FullScreenPhotoView(asset: wrapper.asset, allAssets: group.assets)
        }
    }

    private func toggleSelection(_ asset: PHAsset) {
        let id = asset.localIdentifier
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }
}

struct AssetThumbnailView: View {
    let asset: PHAsset
    @State private var image: UIImage? = nil

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.width)
                } else {
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .frame(width: geo.size.width, height: geo.size.width)
                        .overlay(ProgressView().scaleEffect(0.7))
                }
            }
            .clipped()
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: asset.localIdentifier) {
            image = nil
            let loadedImage = await loadImage(from: asset, targetSize: CGSize(width: 300, height: 300))
            guard !Task.isCancelled else { return }
            image = loadedImage
        }
    }
}

struct OverviewHeader: View {
    let totalCount: Int
    let yearCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Text(totalCount == 1 ? "1 memory today" : "\(totalCount) memories today")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            if yearCount > 0 {
                Text(yearCount == 1 ? "across 1 year" : "across \(yearCount) years")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct FilterEmptyState: View {
    let selectedFilter: MemoryFilter
    let onResetFilters: () -> Void

    private var title: String {
        "No \(selectedFilter.title.lowercased()) memories for this day"
    }

    private var message: String {
        "Try another filter or return to all memories."
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Show All Memories", action: onResetFilters)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 28)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct MemoryControlsBar: View {
    let dateString: String
    let selectedFilter: MemoryFilter
    let isSelecting: Bool
    let yearGroups: [YearGroup]
    let onSelectFilter: (MemoryFilter) -> Void
    let onToggleSelecting: () -> Void
    let onOpenSettings: () -> Void
    let onJumpToYear: (YearGroup) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Text(dateString)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)

                HStack(spacing: 12) {
                    HeaderIconButton(systemImage: "gearshape", action: onOpenSettings)
                    Spacer()
                    Button(isSelecting ? "Done" : "Select", action: onToggleSelecting)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                        .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                ForEach(MemoryFilter.allCases) { filter in
                    FilterChip(
                        title: filter.title,
                        isSelected: selectedFilter == filter,
                        action: { onSelectFilter(filter) }
                    )
                }

                Spacer(minLength: 0)

                Menu {
                    ForEach(yearGroups) { group in
                        Button {
                            onJumpToYear(group)
                        } label: {
                            Label("\(group.year) • \(group.assets.count)", systemImage: "calendar")
                        }
                    }
                } label: {
                    SecondaryControlLabel(title: "Year")
                }
            }
            .opacity(isSelecting ? 0.55 : 1)
            .allowsHitTesting(!isSelecting)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .white : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct SecondaryControlLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct HeaderIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 38, height: 38)
                .background(Color(.secondarySystemGroupedBackground), in: Circle())
        }
        .buttonStyle(.plain)
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

}

struct VideoDurationBadge: View {
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                .font(.system(size: 8))
            Text(formattedDuration)
                .font(.caption2.monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.6), in: Capsule())
        .padding(4)
    }

    private var formattedDuration: String {
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
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

extension Notification.Name {
    static let timeCapsulePhotosDidChange = Notification.Name("timeCapsulePhotosDidChange")
}
