import Foundation
import Photos

/// Hands a memory off to the Photos app so it can be edited there.
///
/// The obvious implementation of this feature does not exist. iOS has no
/// public URL scheme, activity, or view controller that opens the Photos app
/// at a specific `PHAsset` — `assets-library://` was obsoleted in iOS 26, and
/// the undocumented `photos-redirect://` / `photos-navigation://` schemes both
/// launch Photos into whatever it was last showing rather than at an asset.
/// Shipping one of those would put an undocumented scheme in the binary under
/// App Review guideline 2.5.1 and still not land on the right item.
///
/// So this solves the problem the user actually has — "I cannot find this one
/// item again in a library of thousands" — from the other end. It cannot
/// control where Photos opens, but it can control how findable the memory is
/// once the user gets there: the asset is added to a small app-owned album, so
/// the hunt collapses to Albums → Attic Edits → the last item.
///
/// Nothing here runs unless the user taps the button. The library is never
/// mutated in the background.
///
/// `nonisolated` on purpose, matching `MemoryRecapExporter`. This target
/// builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it every
/// synchronous PhotoKit call below — including the album walk in `contains` —
/// would run on the main thread, and this album is designed to accumulate.
nonisolated enum PhotosEditHandoff {
    /// User albums keep insertion order, so the most recently staged memory is
    /// always the last one in this album. That ordering is the whole trick, and
    /// it is why this is an album rather than the Favorites flag: Favorites is
    /// a smart album sorted by capture date, so a memory from six years ago
    /// would land six years back in the list — exactly the hunt being avoided.
    static let albumTitle = "Attic Edits"

    enum Outcome {
        case addedToAlbum
        case alreadyInAlbum
        /// Limited-access libraries cannot create or fetch user albums, so the
        /// date-sorted Favorites flag is the only handoff left.
        case markedFavorite
    }

    enum HandoffError: LocalizedError {
        case notAuthorized
        case albumUnavailable
        /// The album exists, but the memory is not in it after the write.
        ///
        /// Distinct from `albumUnavailable` because the message is what the
        /// user reads: that case says the album "could not be created",
        /// which is plainly untrue here — the album was found, and it was
        /// adding to it that did not take. Reusing it told the user
        /// something false about a failure they might act on.
        case addFailed
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Attic needs access to your photo library to do this."
            case .albumUnavailable:
                return "The \(PhotosEditHandoff.albumTitle) album could not be created."
            case .addFailed:
                return "This memory couldn't be added to the \(PhotosEditHandoff.albumTitle) album."
            case .writeFailed(let reason):
                return reason
            }
        }
    }

    /// `@concurrent`, not just the enum's `nonisolated`.
    ///
    /// The type is marked `nonisolated` to keep the synchronous PhotoKit work
    /// below — the album fetch and the `contains()` walk over every asset in
    /// the album — off the main thread. That is not what `nonisolated` alone
    /// does to an *async* function under this build's
    /// NonisolatedNonsendingByDefault: such a function runs on its caller's
    /// executor, and the caller is a SwiftUI view, so all of it was running on
    /// the main thread anyway. `@concurrent` here moves the whole chain onto
    /// the concurrent pool, and the private helpers inherit it from this entry
    /// point rather than each needing their own annotation.
    @concurrent
    static func stage(_ asset: PHAsset) async throws -> Outcome {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized:
            return try await addToAlbum(asset)
        case .limited:
            // Checked up front rather than by letting the album write fail:
            // under limited access the fetch returns empty and the creation
            // request fails silently, which would read as a bug rather than a
            // deliberate fallback.
            try await markFavorite(asset)
            return .markedFavorite
        default:
            throw HandoffError.notAuthorized
        }
    }

    // MARK: - Album path

    private static func addToAlbum(_ asset: PHAsset) async throws -> Outcome {
        let album = try await fetchOrCreateAlbum()

        if contains(asset, in: album) {
            return .alreadyInAlbum
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCollectionChangeRequest(for: album)?
                    .addAssets([asset] as NSArray)
            }
        } catch {
            throw HandoffError.writeFailed(error.localizedDescription)
        }

        // Confirmed against the album rather than inferred from the write
        // succeeding.
        //
        // `PHAssetCollectionChangeRequest(for:)` returns nil when the album is
        // no longer writable — deleted, or otherwise changed, between the
        // fetch above and this block — and the optional chain then makes the
        // whole change a no-op that `performChanges` still reports as a
        // success. The user was told to open Attic Edits and find their
        // photo there, and it was not in it. Asking the album what it
        // actually contains is the only answer that cannot be wrong.
        guard contains(asset, in: album) else {
            throw HandoffError.addFailed
        }
        return .addedToAlbum
    }

    private static func fetchOrCreateAlbum() async throws -> PHAssetCollection {
        if let existing = existingAlbum() { return existing }

        let box = CreatedAlbumIdentifier()
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCollectionChangeRequest
                    .creationRequestForAssetCollection(withTitle: albumTitle)
                box.identifier = request.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            throw HandoffError.writeFailed(error.localizedDescription)
        }

        guard let identifier = box.identifier,
              let album = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [identifier],
                options: nil
              ).firstObject else {
            // Re-fetch by title as a last resort: the placeholder can fail to
            // resolve if another change landed in between.
            guard let recovered = existingAlbum() else {
                throw HandoffError.albumUnavailable
            }
            return recovered
        }
        return album
    }

    private static func existingAlbum() -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "localizedTitle == %@", albumTitle)
        return PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .albumRegular,
            options: options
        ).firstObject
    }

    /// Enumerated rather than fetched with a `localIdentifier` predicate:
    /// PhotoKit only supports predicates over a documented subset of
    /// properties, and this album is small enough that the walk is cheap.
    private static func contains(_ asset: PHAsset, in album: PHAssetCollection) -> Bool {
        let members = PHAsset.fetchAssets(in: album, options: nil)
        var found = false
        members.enumerateObjects { member, _, stop in
            if member.localIdentifier == asset.localIdentifier {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    // MARK: - Limited-access fallback

    private static func markFavorite(_ asset: PHAsset) async throws {
        guard !asset.isFavorite else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).isFavorite = true
            }
        } catch {
            throw HandoffError.writeFailed(error.localizedDescription)
        }
    }
}

/// `performChanges` takes a `@Sendable` closure, so the placeholder identifier
/// it produces is carried out through a reference rather than a captured `var`.
private nonisolated final class CreatedAlbumIdentifier: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var identifier: String? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
