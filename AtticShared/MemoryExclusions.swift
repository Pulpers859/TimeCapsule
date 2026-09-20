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

    /// A single fetch of every exclusion, taken up front so a caller looping
    /// over many days or many assets — `NotificationManager` schedules 60 of
    /// them — pays the cost of resolving album membership once rather than
    /// once per day. See `MemoryLibrary.count(on:)`, which is exactly the
    /// call site this was built for.
    ///
    /// `Sendable` because it crosses into `Task.detached` bodies (through
    /// `MemoryLibrary`'s default parameter) — plain value types made of
    /// `String`/`Double` collections, so the conformance costs nothing.
    struct Context: Sendable {
        let assetIDs: Set<String>
        let places: [ExcludedPlace]
        let albumMemberIDs: Set<String>

        static func current() -> Context {
            Context(
                assetIDs: excludedAssetIDs,
                places: excludedPlaces,
                albumMemberIDs: excludedAlbumMemberIdentifiers()
            )
        }

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

    static var hasAnyExclusions: Bool {
        !excludedAlbums.isEmpty || !excludedPlaces.isEmpty || !excludedAssetIDs.isEmpty
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

    static func excludePlace(near coordinate: CLLocationCoordinate2D, label: String) {
        var places = excludedPlaces
        let target = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let alreadyCovered = places.contains { place in
            CLLocation(latitude: place.latitude, longitude: place.longitude).distance(from: target) < placeRadiusMeters
        }
        guard !alreadyCovered else { return }
        places.append(ExcludedPlace(latitude: coordinate.latitude, longitude: coordinate.longitude, label: label))
        excludedPlaces = places
    }

    static func removePlaceExclusion(_ place: ExcludedPlace) {
        excludedPlaces.removeAll { $0 == place }
    }

    /// Every asset identifier belonging to a currently-excluded album.
    ///
    /// Re-fetched rather than cached across app launches: albums are few and
    /// small, so the fetch is cheap, and caching membership would mean either
    /// a photo added to an excluded album keeps showing up, or wiring a
    /// PHPhotoLibrary change observer just to invalidate a few dozen strings.
    static func excludedAlbumMemberIdentifiers() -> Set<String> {
        let ids = excludedAlbums.map(\.id)
        guard !ids.isEmpty else { return [] }

        let collections = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil)
        var members: Set<String> = []
        collections.enumerateObjects { collection, _, _ in
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
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

    private static func encode<T: Codable>(_ value: [T], key: String) {
        AtticDefaults.shared.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
