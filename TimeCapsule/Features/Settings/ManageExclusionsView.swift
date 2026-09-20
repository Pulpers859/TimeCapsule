import SwiftUI

/// The undo path for every "Feature Less Often" tap in the viewer. Without a
/// visible way back, that action would be a one-way door — tap it once by
/// accident and a whole album silently stops appearing, with nothing in the
/// UI ever explaining why.
struct ManageExclusionsView: View {
    @State private var excludedAlbums: [MemoryExclusions.ExcludedAlbum] = []
    @State private var excludedPlaces: [MemoryExclusions.ExcludedPlace] = []
    @State private var excludedAssetCount = 0

    var body: some View {
        Form {
            if excludedAlbums.isEmpty && excludedPlaces.isEmpty && excludedAssetCount == 0 {
                Section {
                    SettingsRowLabel(
                        symbol: "checkmark.circle",
                        tint: .green,
                        title: "Nothing hidden",
                        subtitle: "Everything eligible can turn up as a memory"
                    )
                }
            }

            if !excludedAlbums.isEmpty {
                Section {
                    ForEach(excludedAlbums, id: \.id) { album in
                        rowLabel(title: album.label, symbol: "rectangle.stack", tint: .indigo)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            MemoryExclusions.removeAlbumExclusion(id: excludedAlbums[index].id)
                        }
                        reload()
                        notifyChanged()
                    }
                } header: {
                    Text("Albums")
                } footer: {
                    Text("Photos in these albums are skipped, including ones added later.")
                }
            }

            if !excludedPlaces.isEmpty {
                Section {
                    ForEach(excludedPlaces, id: \.self) { place in
                        rowLabel(title: place.label, symbol: "location.slash", tint: .orange)
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            MemoryExclusions.removePlaceExclusion(excludedPlaces[index])
                        }
                        reload()
                        notifyChanged()
                    }
                } header: {
                    Text("Places")
                } footer: {
                    Text("Photos taken near these locations are skipped.")
                }
            }

            if excludedAssetCount > 0 {
                Section {
                    Button(role: .destructive) {
                        MemoryExclusions.excludedAssetIDs = []
                        reload()
                        notifyChanged()
                    } label: {
                        rowLabel(
                            title: excludedAssetCount == 1
                                ? "1 individual photo"
                                : "\(excludedAssetCount) individual photos",
                            symbol: "photo",
                            tint: .red,
                            trailing: "Restore All"
                        )
                    }
                } header: {
                    Text("Individual Photos")
                } footer: {
                    Text("These were hidden one at a time from the memory viewer.")
                }
            }
        }
        .navigationTitle("Featured Less Often")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    private func reload() {
        excludedAlbums = MemoryExclusions.excludedAlbums
        excludedPlaces = MemoryExclusions.excludedPlaces
        excludedAssetCount = MemoryExclusions.excludedAssetIDs.count
    }

    /// The same signal delete and every memory-affecting setting already
    /// post: the gallery refetches and `NotificationManager` reschedules with
    /// corrected counts, both from the one thing they already listen for.
    private func notifyChanged() {
        NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)
    }

    private func rowLabel(title: String, symbol: String, tint: Color, trailing: String? = nil) -> some View {
        HStack {
            SettingsRowLabel(symbol: symbol, tint: tint, title: title, subtitle: nil)
            if let trailing {
                Spacer(minLength: 8)
                Text(trailing)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.red)
            }
        }
    }
}
