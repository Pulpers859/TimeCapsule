import Photos
import SwiftUI

/// Everything else from the day a memory was taken.
///
/// The most common reason to leave Attic for the Photos app is not editing —
/// it is "what else did I shoot that day?". This answers that without the
/// trip, which is the only way to genuinely remove a step rather than
/// shorten one.
///
/// Deliberately its own file. The tripwire in `ViewerPresentationTripwireTests`
/// counts presentation modifiers in `FullScreenPhotoView.swift` by reading the
/// source, so a view declared inside that file would add its own `.sheet` and
/// `.alert` to a count that is meant to track only what covers the viewer.
struct DayContextView: View {
    let anchor: PHAsset
    /// Opening one of these is the parent's job: it swaps the pager's contents
    /// rather than presenting a second viewer on top of the first. Two live
    /// viewers would mean two `AVPlayer`s and two claims on the shared audio
    /// session.
    let onOpen: (PHAsset, DayContents.Result) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var contents: DayContents.Result?
    @State private var isLoading = true
    @State private var accessIsLimited = false

    private static let columns = [GridItem(.adaptive(minimum: 96), spacing: 3)]

    var body: some View {
        NavigationStack {
            Group {
                if let contents, !contents.assets.isEmpty {
                    grid(contents)
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    empty
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Keyed on the anchor's identity, not on the view appearing: if the
        // sheet is ever reused for a different memory this reloads rather
        // than showing the previous day's photos under the new day's title.
        .task(id: anchor.localIdentifier) {
            isLoading = true
            accessIsLimited = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited
            // Everything below is read from the value that comes back, never
            // from state captured before the await — `.task(id:)` holds the
            // View struct as it was when the task started.
            let loaded = await loadDayContents(containing: anchor.creationDate ?? Date())
            guard !Task.isCancelled else { return }
            contents = loaded
            isLoading = false
        }
    }

    private func grid(_ contents: DayContents.Result) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: Self.columns, spacing: 3) {
                    ForEach(contents.assets, id: \.localIdentifier) { asset in
                        Button {
                            onOpen(asset, contents)
                        } label: {
                            DayTile(
                                asset: asset,
                                isAnchor: asset.localIdentifier == anchor.localIdentifier
                            )
                        }
                        .buttonStyle(.plain)
                        .id(asset.localIdentifier)
                    }
                }
                .padding(.horizontal, 3)

                footer(contents)
            }
            .onAppear {
                // Opens where the user already was, rather than at 7am on a
                // day they were looking at the evening of.
                proxy.scrollTo(anchor.localIdentifier, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func footer(_ contents: DayContents.Result) -> some View {
        VStack(spacing: 6) {
            Text(countLabel(contents))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if accessIsLimited {
                Text("Attic can only see the photos you've chosen to share with it, so this may not be the whole day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var empty: some View {
        ContentUnavailableView(
            "Nothing else from that day",
            systemImage: "photo.on.rectangle",
            description: Text("This is the only photo or video Attic can find from \(title).")
        )
    }

    private var title: String {
        guard let date = anchor.creationDate else { return "That day" }
        return date.formatted(date: .complete, time: .omitted)
    }

    private func countLabel(_ contents: DayContents.Result) -> String {
        // Never "memories". These are not memories — no anniversary window and
        // no exclusions were applied, and calling them that would put a second
        // meaning on a word the gallery and the widget already share.
        if contents.assets.count < contents.totalCount {
            return "Showing the first \(contents.assets.count) of \(contents.totalCount) items"
        }
        return contents.totalCount == 1 ? "1 item" : "\(contents.totalCount) items"
    }
}

/// One cell. Its own view so the image request is scoped to the cell and
/// cancelled by `LazyVGrid` when it scrolls away.
private struct DayTile: View {
    let asset: PHAsset
    let isAnchor: Bool

    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if asset.mediaType == .video {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(5)
                }
            }
            .overlay {
                if isAnchor {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .accessibilityLabel(accessibilityLabel)
            .task(id: asset.localIdentifier) {
                image = await loadImage(from: asset, targetSize: CGSize(width: 300, height: 300))
            }
    }

    private var accessibilityLabel: String {
        var parts: [String] = [asset.mediaType == .video ? "Video" : "Photo"]
        if let date = asset.creationDate {
            parts.append(date.formatted(date: .omitted, time: .shortened))
        }
        if isAnchor { parts.append("the memory you were viewing") }
        return parts.joined(separator: ", ")
    }
}
