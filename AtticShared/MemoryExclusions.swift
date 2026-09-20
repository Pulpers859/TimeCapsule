import Foundation
import Photos
import CoreLocation

/// "Feature this less often" — the user telling Attic that a photo, a whole
/// album, or somewhere they went should stop turning up as a memory.
///
/// Stored through the same App Group suite as the memory window, for the same
/// reason: the widget builds its own picks straight from `MemoryLibrary`
/// rather than from anything the app leaves behind, so an exclusion written
/// to the app's own `UserDefaults.standard` would be invisible to it.
///
/// Album membership and place proximity are resolved from the *current* state
/// of the library on every call rather than cached at the moment of
/// exclusion. That is what makes "this album" and "this place" mean what a
/// person expects them to mean: a photo added to an already-excluded album
/// next month is excluded too, not just the one that was on screen when the
/// button was tapped.
nonisolated enum MemoryExclusions {
    private static let albumsKey = "Attic.excludedAlbums"
    private static let placesKey = "Attic.excludedPlaces"
    private static let assetsKey = "Attic.excludedAssetIDs"

    /// Roughly the footprint of a single venue. Tight enough that excluding
    /// one coffee shop does not blank out the whole neighbourhood around it;
    /// loose enough that ordinary GPS drift between two visits to the same
    /// place still counts as "here again".
    static let placeRadiusMeters: CLLocationDistance = 400


    struct ExcludedAlbum: Codable, Equatable, Sendable {
        let id: String
        let label: String
    }

    struct ExcludedPlace: Codable, Equatable, Hashable, Sendable {
        let latitude: Double
        let longitude: Double
        let label: String
    }

    /// Every exclusion resolved once, so a caller testing many assets does
    /// not re-read defaults or re-query albums per asset.
    ///
    /// Normally built by `MemoryLibrary` itself, scoped to the dates it is
    /// about to fetch. A caller that already holds the assets it wants to
    /// test — the full-screen viewer filtering what is on screen — builds an
    /// unscoped one instead, off the main actor.
    ///
    /// `Sendable` because it crosses into detached task bodies — plain value
    /// types made of `String`/`Double` collections, so the conformance costs
    /// nothing.
    struct Context: Sendable {
        let assetIDs: Set<String>
        let places: [ExcludedPlace]
        let albumMemberIDs: Set<String>

        /// `predicate` bounds the album-membership lookup to the assets the
        /// caller is actually asking about — see
        /// `excludedAlbumMemberIdentifiers(matching:)` for why that matters.
        /// Passing nil resolves membership across the whole album, which is
        /// only appropriate off the main actor in the app itself.
        static func current(matching predicate: NSPredicate? = nil) -> Context {
            Context(
                assetIDs: excludedAssetIDs,
                places: excludedPlaces,
                albumMemberIDs: excludedAlbumMemberIdentifiers(matching: predicate)
            )
        }

        /// Excludes nothing. Lets a caller ask what a day holds *before* the
        /// user's exclusions are applied, which is the only way to tell "this
        /// day is empty because nothing was taken" from "this day is empty
        /// because it was hidden".
        ///
        /// Deliberately not named `none`. Every parameter that takes a
        /// `Context` takes it as an optional, and in that position `.none`
        /// resolves to `Optional.none` — plain `nil` — because the exact type
        /// match beats promoting a `Context` into an optional. It compiles,
        /// it type-checks, and it silently means the opposite: `nil` makes
        /// the callee build the real context and apply every exclusion. There
        /// is no warning either, since this is a `static let` rather than an
        /// enum case. That mistake shipped once already.
        static let unfiltered = Context(assetIDs: [], places: [], albumMemberIDs: [])

        var isEmpty: Bool {
            assetIDs.isEmpty && places.isEmpty && albumMemberIDs.isEmpty
        }

        func excludes(_ asset: PHAsset) -> Bool {
            if assetIDs.contains(asset.localIdentifier) { return true }
            if albumMemberIDs.contains(asset.localIdentifier) { return true }
            guard let coordinate = asset.location?.coordinate, !places.isEmpty else { return false }
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return places.contains { place in
                location.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude))
                    < placeRadiusMeters
            }
        }
    }

    static var excludedAlbums: [ExcludedAlbum] {
        get { decode(albumsKey) }
        set { encode(newValue, key: albumsKey) }
    }

    static var excludedPlaces: [ExcludedPlace] {
        get { decode(placesKey) }
        set { encode(newValue, key: placesKey) }
    }

    static var excludedAssetIDs: Set<String> {
        get { Set(AtticDefaults.shared.stringArray(forKey: assetsKey) ?? []) }
        set { AtticDefaults.shared.set(Array(newValue), forKey: assetsKey) }
    }

    static func excludeAsset(_ asset: PHAsset) {
        var ids = excludedAssetIDs
        ids.insert(asset.localIdentifier)
        excludedAssetIDs = ids
    }

    static func removeAssetExclusion(id: String) {
        var ids = excludedAssetIDs
        ids.remove(id)
        excludedAssetIDs = ids
    }

    /// No-ops if this album, or one close enough to be the same place, is
    /// already excluded — otherwise re-tapping the button would pile up
    /// duplicate rows in the Settings list.
    static func excludeAlbum(_ collection: PHAssetCollection) {
        var albums = excludedAlbums
        guard !albums.contains(where: { $0.id == collection.localIdentifier }) else { return }
        let label = collection.localizedTitle?.isEmpty == false ? collection.localizedTitle! : "Untitled Album"
        albums.append(ExcludedAlbum(id: collection.localIdentifier, label: label))
        excludedAlbums = albums
    }

    static func removeAlbumExclusion(id: String) {
        excludedAlbums.removeAll { $0.id == id }
    }

    /// Rejects coordinates that cannot be stored or matched. A photo's GPS
    /// metadata is not guaranteed sane, and `kCLLocationCoordinate2DInvalid`
    /// is literally (NaN, NaN) — which `JSONEncoder` refuses to encode.
    static func excludePlace(near coordinate: CLLocationCoordinate2D, label: String) {
        guard coordinate.latitude.isFinite,
              coordinate.longitude.isFinite,
              CLLocationCoordinate2DIsValid(coordinate) else { return }

        var places = excludedPlaces
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        // Deduplicated at the same radius that matching uses, deliberately.
        //
        // A tighter radius looks like it closes a coverage gap — a second
        // centre just inside the first one's radius would extend the hidden
        // area outward — but that gap cannot be reached: a photo within
        // `placeRadiusMeters` of an existing centre is already excluded, so
        // it is not in the grid or the pager for anyone to open and exclude
        // again. All a tighter radius really does is let GPS drift at one
        // venue pile up several identical-looking rows in Settings.
        let isDuplicate = places.contains { place in
            CLLocation(latitude: place.latitude, longitude: place.longitude)
                .distance(from: target) < placeRadiusMeters
        }
        guard !isDuplicate else { return }
        places.append(ExcludedPlace(latitude: coordinate.latitude, longitude: coordinate.longitude, label: label))
        excludedPlaces = places
    }

    static func removePlaceExclusion(_ place: ExcludedPlace) {
        excludedPlaces.removeAll { $0 == place }
    }

    /// Asset identifiers belonging to a currently-excluded album, optionally
    /// narrowed to the assets a caller actually cares about.
    ///
    /// Re-resolved rather than cached: albums change, and caching membership
    /// would mean either a photo added to an excluded album keeps showing up,
    /// or wiring a PHPhotoLibrary change observer just to invalidate a set of
    /// strings.
    ///
    /// `matching` is what keeps that affordable. Unbounded, this materialises
    /// a `PHAsset` for every member of every excluded album — exclude a
    /// 10,000-photo album and that is 10,000 objects plus a set of their
    /// identifiers, rebuilt on every gallery fetch, every notification
    /// schedule, and every widget timeline. The widget is the one that
    /// actually breaks: it runs in an extension with a jetsam limit small
    /// enough that this can kill it mid-timeline, and a killed timeline never
    /// installs its next reload, so the home screen silently freezes on a
    /// stale photo with nothing connecting it to the album the user excluded.
    ///
    /// Callers that know the date range they are querying pass the same
    /// predicate here, which turns the walk into one small indexed query per
    /// excluded album instead of a full enumeration.
    static func excludedAlbumMemberIdentifiers(matching predicate: NSPredicate? = nil) -> Set<String> {
        let ids = excludedAlbums.map(\.id)
        guard !ids.isEmpty else { return [] }

        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil)
        let options = PHFetchOptions()
        options.predicate = predicate

        var members: Set<String> = []
        collections.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, _ in
                members.insert(asset.localIdentifier)
            }
        }
        return members
    }

    private static func decode<T: Codable>(_ key: String) -> [T] {
        guard let data = AtticDefaults.shared.data(forKey: key),
              let decoded = try? JSONDecoder().decode([T].self, from: data) else { return [] }
        return decoded
    }

    /// Leaves the stored list untouched if encoding fails, rather than
    /// clearing it.
    ///
    /// `set(nil, forKey:)` *removes* a key, so passing `try?` straight in
    /// meant one unencodable entry deleted every exclusion the user had ever
    /// made. That was reachable: `JSONEncoder` throws on a non-finite Double
    /// by default, and a place is stored as a raw latitude/longitude pair
    /// taken from a photo's own metadata. Failing to add one place is a
    /// tolerable outcome; silently un-hiding all of them is not.
    private static func encode<T: Codable>(_ value: [T], key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        AtticDefaults.shared.set(data, forKey: key)
    }
}
