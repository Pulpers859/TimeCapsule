import Foundation
import Photos

/// Pins a memory in a one-photo album so it can be found in the Photos app.
///
/// The obvious implementation of this feature does not exist. iOS has no
/// public URL scheme, activity, or view controller that opens the Photos app
/// at a specific `PHAsset`. Photos itself has one — an internal
/// `photos://edit/enter?assetUUID=` route it uses for Lock Screen Photo
/// Shuffle and Handoff — but the `photos://` scheme is not openable from a
/// third-party app. The undocumented `photos-redirect://` only launches the
/// app, and `photos-navigation://` accepts a fixed list of six built-in album
/// names, so an app-created album can never be targeted by name. Shipping
/// either would put an undocumented scheme in the binary under App Review
/// guideline 2.5.1 and still land the user on the Photos home screen.
///
/// So this solves the problem the user actually has — "I cannot find this one
/// item again in a library of thousands" — from the other end. It cannot
/// control where Photos opens, but it can control how findable the memory is
/// once the user gets there.
///
/// The album holds **exactly one** photo. It used to accumulate, which made
/// the instruction "it's the last one in there" — an instruction that gets
/// worse every time the feature is used, and eventually means scrolling. One
/// slot makes it "it's the only one in there", which never degrades, and it
/// bounds what this leaves behind in someone's Photos app to a single album
/// with a single entry.
///
/// Nothing here runs unless the user taps the button. The library is never
/// mutated in the background, and no photo is ever copied: an album holds
/// references, so there is still exactly one of each photo afterwards.
///
/// `nonisolated` on purpose, matching `MemoryRecapExporter`. This target
/// builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it every
/// synchronous PhotoKit call below would run on the main thread.
nonisolated enum PhotosEditHandoff {
    /// Named for the app, not for "edits", because nothing here edits anything
    /// and the previous name ("Attic Edits") read as a folder of copies.
    static let albumTitle = "Attic"

    enum Outcome: Equatable {
        /// The album now holds this memory and nothing else.
        case pinned
        /// It was already the only photo in the album; nothing was written.
        case alreadyPinned
    }

    enum HandoffError: LocalizedError {
        case notAuthorized
        /// A limited library cannot create or fetch user albums at all, so
        /// there is no album path to fall back to.
        ///
        /// This used to set the Favorites flag instead. That was wrong twice
        /// over: it silently rewrote a user-curated, iCloud-synced flag from a
        /// button about editing, with no way to undo it from Attic — and
        /// Favorites is sorted by capture date, so a memory from six years ago
        /// landed six years back in the list, which is the exact hunt this
        /// feature exists to avoid.
        case limitedAccess
        case albumUnavailable
        /// The album exists, but the memory is not in it after the write.
        case addFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Attic needs access to your photo library to do this."
            case .limitedAccess:
                return "Attic only has limited access to your library, so it can't make an album. The details above still say where this memory lives."
            case .albumUnavailable:
                return "The \(PhotosEditHandoff.albumTitle) album could not be created."
            case .addFailed:
                return "This memory couldn't be pinned to the \(PhotosEditHandoff.albumTitle) album."
            case .writeFailed:
                // Deliberately not the underlying `localizedDescription`.
                // PhotoKit's is "The operation couldn't be completed.
                // (PHPhotosErrorDomain error 3300.)", which tells the user
                // nothing and looks like a crash report.
                return "Your photo library wouldn't accept that change. Nothing was altered."
            }
        }
    }

    /// `@concurrent`, not just the enum's `nonisolated`.
    ///
    /// The type is marked `nonisolated` to keep the synchronous PhotoKit work
    /// below — the album fetch and the membership read — off the main thread. That is not what `nonisolated` alone
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
            return try await pin(asset)
        case .limited:
            throw HandoffError.limitedAccess
        default:
            throw HandoffError.notAuthorized
        }
    }

    // MARK: - Album path

    private static func pin(_ asset: PHAsset) async throws -> Outcome {
        let album = try await fetchOrCreateAlbum()

        let existing = members(of: album)
        if existing.count == 1, existing[0] == asset.localIdentifier {
            return .alreadyPinned
        }

        // Clearing and adding in one change block, so the album is never
        // briefly empty and the user is asked for permission once rather
        // than twice.
        do {
            try await PHPhotoLibrary.shared().performChanges {
                guard let request = PHAssetCollectionChangeRequest(for: album) else { return }
                let current = PHAsset.fetchAssets(in: album, options: nil)
                if current.count > 0 {
                    request.removeAssets(current)
                }
                request.addAssets([asset] as NSArray)
            }
        } catch {
            throw HandoffError.writeFailed
        }

        // Confirmed against the album rather than inferred from the write
        // succeeding.
        //
        // `PHAssetCollectionChangeRequest(for:)` returns nil when the album is
        // no longer writable — deleted, or otherwise changed, between the
        // fetch above and this block — and the guard then makes the whole
        // change a no-op that `performChanges` still reports as a success. The
        // user was told to open the album and find their photo there, and it
        // was not in it. Asking the album what it actually contains is the
        // only answer that cannot be wrong.
        guard members(of: album) == [asset.localIdentifier] else {
            throw HandoffError.addFailed
        }
        return .pinned
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
            throw HandoffError.writeFailed
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
    /// properties, and this album holds at most one item.
    private static func members(of album: PHAssetCollection) -> [String] {
        let result = PHAsset.fetchAssets(in: album, options: nil)
        var identifiers: [String] = []
        result.enumerateObjects { member, _, _ in
            identifiers.append(member.localIdentifier)
        }
        return identifiers
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
