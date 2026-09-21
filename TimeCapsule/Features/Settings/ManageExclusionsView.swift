import SwiftUI

/// The undo path for every "Feature Less Often" tap in the viewer. Without a
/// visible way back, that action would be a one-way door — tap it once by
/// accident and a whole album silently stops appearing, with nothing in the
/// UI ever explaining why.
struct ManageExclusionsView: View {
    @State private var excludedAlbums: [MemoryExclusions.ExcludedAlbum] = []
    @State private var excludedPlaces: [MemoryExclusions.ExcludedPlace] = []
    @State private var excludedAssetCount = 0
    @State private var confirmRestoreAllPhotos = false

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
                        confirmRestoreAllPhotos = true
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
        // Confirmed, because this row is a one-tap, irreversible bulk undo.
        //
        // Albums and places each need a deliberate swipe-to-delete, and
        // *creating* one of these exclusions is itself confirmed from the
        // viewer — yet restoring every individually hidden photo took a
        // single tap anywhere on the row, including on the descriptive text,
        // with nothing to undo it. Someone who had hidden dozens of photos
        // over months and tapped the row expecting it to expand lost all of
        // them. They are stored as opaque local identifiers with no
        // thumbnails, so there is nothing to restore them from and no
        // per-photo alternative to offer.
        .confirmationDialog(
            excludedAssetCount == 1
                ? "Restore 1 hidden photo?"
                : "Restore all \(excludedAssetCount) hidden photos?",
            isPresented: $confirmRestoreAllPhotos,
            titleVisibility: .visible
        ) {
            Button("Restore All", role: .destructive) {
                MemoryExclusions.excludedAssetIDs = []
                reload()
                notifyChanged()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will start appearing as memories again. This can't be undone.")
        }
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
