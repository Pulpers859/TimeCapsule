import CoreLocation
import Foundation
import MapKit

/// Turns a memory's coordinates into a short, human place name — "Cupertino, CA"
/// at home, "Paris, France" abroad — rather than a street address. A line under
/// a photo wants the place you were, not the postal route to it.
///
/// Results are cached by coordinate because reverse geocoding is a rate-limited
/// network service and a day of memories keeps revisiting the same few places:
/// an event's worth of photos resolves once, and paging back to an earlier one
/// is instant instead of another request. Misses are cached too, so a
/// coordinate the service has no answer for is not asked about again.
actor PlaceNameLookup {
    static let shared = PlaceNameLookup()

    /// Keyed at ~11m of precision: fine enough that two genuinely different
    /// places never share an entry, coarse enough that a burst shot from one
    /// spot resolves once instead of once per frame.
    private var resolved: [String: String?] = [:]

    /// Lookups that have been started but not answered yet, keyed the same
    /// way as the cache.
    ///
    /// Being an actor serialises *execution*, not a whole method: the
    /// `await` below suspends this actor, so a second call for the same
    /// coordinate arriving during that window saw an empty cache and issued
    /// its own `CLGeocoder` request. Each request also builds a fresh
    /// geocoder, which defeats `CLGeocoder`'s own one-request-at-a-time
    /// cancellation, and reverse geocoding is rate limited — so concurrent
    /// callers made throttling more likely, and a throttled result is
    /// deliberately not cached, which produced retries that made it worse
    /// again.
    ///
    /// Today the only caller is the full-screen viewer, which debounces and
    /// cancels on every swipe, so the window is effectively closed. That is
    /// a property of the caller, not of this type, and this is a
    /// `static let shared` singleton that invites a second one.
    private var inFlight: [String: Task<LookupOutcome, Never>] = [:]

    /// The cache never evicted, and is keyed at ~11m, so a day of walking
    /// around a city with geotagged photos added an entry per square visited
    /// for the life of the process. Entries are tiny, so a generous cap
    /// cleared wholesale beats the bookkeeping an LRU would need.
    private static let maxCachedPlaces = 512

    func placeName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let key = Self.cacheKey(for: coordinate)
        if let cached = resolved[key] {
            return cached
        }

        let task: Task<LookupOutcome, Never>
        let isOwner: Bool
        if let existing = inFlight[key] {
            task = existing
            isOwner = false
        } else {
            task = Task { await Self.reverseGeocodedPlaceName(for: coordinate) }
            inFlight[key] = task
            isOwner = true
        }

        let outcome = await task.value
        // Only the call that started it clears it, so a late waiter cannot
        // remove an entry a newer lookup has since installed.
        if isOwner {
            inFlight[key] = nil
        }

        switch outcome {
        case .answered(let name):
            // The service gave a verdict, including "there is no name here".
            // That verdict will not change, so it is worth remembering.
            if resolved.count >= Self.maxCachedPlaces {
                resolved.removeAll(keepingCapacity: true)
            }
            resolved[key] = name
            return name
        case .provisional(let name):
            // Half an answer: the town came back but the landmark search
            // failed, or the other way round. Shown, but not cached, so the
            // next visit asks again and can find the landmark.
            return name
        case .unavailable:
            // Offline, rate limited, or otherwise transient. Caching this would
            // turn a bad minute into a permanent blank for that place: nothing
            // ever retries a cached answer, so the memory would silently never
            // show where it happened again.
            return nil
        }
    }

    private enum LookupOutcome {
        case answered(String?)
        case provisional(String?)
        case unavailable
    }

    private static func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }

    /// The landmark the photo was taken at if there is one — "Lago di
    /// Carezza, Italy" — otherwise the town, "Nova Levante, Italy". The two
    /// questions go to Maps at the same time; neither waits on the other.
    private static func reverseGeocodedPlaceName(
        for coordinate: CLLocationCoordinate2D
    ) async -> LookupOutcome {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        async let townLookup = town(at: location)
        async let landmarkLookup = nearbyLandmarks(around: location)
        let (town, landmarks) = await (townLookup, landmarkLookup)

        let landmark = landmarks.flatMap(PlaceNameText.landmark(among:))
        switch (town, landmark) {
        case (.some(let town), .some(let landmark)):
            return .answered(PlaceNameText.name(landmark: landmark, context: town.context))
        case (.some(let town), nil):
            return landmarks == nil ? .provisional(town.name) : .answered(town.name)
        case (nil, .some(let landmark)):
            return .provisional(landmark)
        case (nil, nil):
            return landmarks == nil ? .unavailable : .provisional(nil)
        }
    }

    /// What reverse geocoding says: the town's display name, and the
    /// context after it that a landmark should carry too.
    private struct Town: Sendable {
        var name: String?
        var context: String?
    }

    /// `nil` when Maps could not be asked: offline or rate limited.
    private static func town(at location: CLLocation) async -> Town? {
        if #available(iOS 26.0, *) {
            return await mapKitTown(at: location)
        } else {
            return await placemarkTown(at: location)
        }
    }

    @available(iOS 26.0, *)
    private static func mapKitTown(at location: CLLocation) async -> Town? {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }

        let found = await withCheckedContinuation { (continuation: CheckedContinuation<Town?, Never>) in
            request.getMapItems { items, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                // `cityWithContext` lets MapKit decide how much context the
                // reader needs, instead of us stitching city/state/country
                // together and getting it wrong outside the US. Any match's
                // city beats every match's anything else, so it is searched
                // across all of them first.
                //
                // The item's `name` and short address are not candidates. For
                // a reverse lookup they are the street address or the postal
                // code, and showed as "Via Principale 3C" and "39056" under
                // photos from villages Maps had no city for. Blank counts as
                // missing; see `PlaceNameText`.
                for item in items ?? [] {
                    guard let representations = item.addressRepresentations,
                          let city = PlaceNameText.best([representations.cityWithContext]) else { continue }
                    let context = PlaceNameText.context(
                        cityWithContext: city,
                        city: representations.cityName
                    ) ?? PlaceNameText.best([representations.regionName])
                    continuation.resume(returning: Town(name: city, context: context))
                    return
                }
                continuation.resume(returning: Town(name: nil, context: nil))
            }
        }

        // No city: ask for the place's areas instead — village, province,
        // landmark, region — and name the smallest one that exists.
        if let found, found.name == nil {
            return await placemarkTown(at: location)
        }
        return found
    }

    /// The pre-iOS 26 path, and the iOS 26 one's fallback when Maps has no
    /// city for a place. `MKReverseGeocodingRequest` and `cityWithContext`
    /// are both iOS 26, and a placemark is the only way to reach the larger
    /// areas around somewhere with no town.
    private static func placemarkTown(at location: CLLocation) async -> Town? {
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return Town(name: nil, context: nil) }
            let area = area(of: placemark)
            return Town(name: PlaceNameText.name(for: area), context: PlaceNameText.context(for: area))
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            // A definite verdict of "nothing is here", which is worth caching.
            return Town(name: nil, context: nil)
        } catch {
            // Offline, rate limited, or cancelled. Must NOT be cached: doing so
            // would turn one bad minute into a permanently blank place name.
            return nil
        }
    }

    /// Approximates what `cityWithContext` does: enough context to place the
    /// town, without reciting a postal address. The rule itself is
    /// `PlaceNameText.name(for:)`, where it is tested.
    private static func area(of placemark: CLPlacemark) -> PlaceNameText.Area {
        PlaceNameText.Area(
            locality: placemark.locality,
            subLocality: placemark.subLocality,
            subAdministrativeArea: placemark.subAdministrativeArea,
            areaOfInterest: placemark.areasOfInterest?.first,
            administrativeArea: placemark.administrativeArea,
            country: placemark.country,
            isHomeCountry: placemark.isoCountryCode == Locale.current.region?.identifier
        )
    }

    /// Places people go *to* within reach of the photo, measured from it.
    /// `[]` when Maps answered with nothing; `nil` when it could not be
    /// asked, so the town is shown but not remembered as the final word.
    private static func nearbyLandmarks(around location: CLLocation) async -> [PlaceNameText.Landmark]? {
        let request = MKLocalPointsOfInterestRequest(
            center: location.coordinate,
            radius: PlaceNameText.landmarkSearchRadius
        )
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: landmarkCategories)

        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch let error as MKError where error.code == .placemarkNotFound {
            return []
        } catch {
            return nil
        }
        return response.mapItems.compactMap { item in
            guard let category = item.pointOfInterestCategory,
                  let kind = landmarkKind(for: category),
                  let point = itemLocation(item) else { return nil }
            return PlaceNameText.Landmark(
                name: item.name,
                kind: kind,
                distance: point.distance(from: location)
            )
        }
    }

    /// The kinds of place a memory is *at*. Everything else — restaurants,
    /// shops, car parks, stations — is a place you pass, and naming a photo
    /// after the nearest café would be worse than naming the town.
    private nonisolated static let landmarkCategories: [MKPointOfInterestCategory] = [
        .landmark, .nationalMonument, .scenicView, .castle, .fortress,
        .beach, .hiking, .skiing, .rockClimbing, .surfing, .kayaking, .nationalPark,
        .park, .campground,
        .museum, .stadium, .zoo, .aquarium, .amusementPark, .planetarium, .theater, .musicVenue
    ]

    private nonisolated static func landmarkKind(
        for category: MKPointOfInterestCategory
    ) -> PlaceNameText.Landmark.Kind? {
        switch category {
        case .landmark, .nationalMonument, .scenicView, .castle, .fortress:
            return .sight
        case .beach, .hiking, .skiing, .rockClimbing, .surfing, .kayaking, .nationalPark:
            return .outdoors
        case .park, .campground:
            return .park
        case .museum, .stadium, .zoo, .aquarium, .amusementPark, .planetarium, .theater, .musicVenue:
            return .venue
        default:
            return nil
        }
    }

    private nonisolated static func itemLocation(_ item: MKMapItem) -> CLLocation? {
        if #available(iOS 26.0, *) {
            return item.location
        } else {
            return item.placemark.location
        }
    }
}
