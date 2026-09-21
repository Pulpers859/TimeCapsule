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
        case unavailable
    }

    private static func cacheKey(for coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }

    private static func reverseGeocodedPlaceName(
        for coordinate: CLLocationCoordinate2D
    ) async -> LookupOutcome {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        if #available(iOS 26.0, *) {
            return await mapKitPlaceName(for: location)
        } else {
            return await placemarkPlaceName(for: location)
        }
    }

    @available(iOS 26.0, *)
    private static func mapKitPlaceName(for location: CLLocation) async -> LookupOutcome {
        guard let request = MKReverseGeocodingRequest(location: location) else { return .unavailable }

        return await withCheckedContinuation { (continuation: CheckedContinuation<LookupOutcome, Never>) in
            request.getMapItems { items, error in
                guard error == nil else {
                    continuation.resume(returning: .unavailable)
                    return
                }
                let bestMatch = items?.first
                // `cityWithContext` lets MapKit decide how much context the
                // reader needs, instead of us stitching city/state/country
                // together and getting it wrong outside the US. The
                // point-of-interest name is the fallback, which keeps somewhere
                // like a national park readable when there is no city to name.
                let name = bestMatch?.addressRepresentations?.cityWithContext ?? bestMatch?.name
                continuation.resume(returning: .answered(name))
            }
        }
    }

    /// Pre-iOS 26 path. `MKReverseGeocodingRequest` and `cityWithContext` are
    /// both iOS 26, so below that the name has to be assembled from a
    /// `CLPlacemark` by hand.
    private static func placemarkPlaceName(for location: CLLocation) async -> LookupOutcome {
        do {
            let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return .answered(nil) }
            return .answered(composedName(from: placemark))
        } catch let error as CLError where error.code == .geocodeFoundNoResult {
            // A definite verdict of "nothing is here", which is worth caching
            // exactly like the iOS 26 path's nil answer.
            return .answered(nil)
        } catch {
            // Offline, rate limited, or cancelled. Must NOT be cached: doing so
            // would turn one bad minute into a permanently blank place name.
            return .unavailable
        }
    }

    /// Approximates what `cityWithContext` does: enough context to place the
    /// city, without reciting a postal address.
    private static func composedName(from placemark: CLPlacemark) -> String? {
        guard let city = placemark.locality ?? placemark.subAdministrativeArea else {
            // Somewhere with no town at all — a national park, open water.
            // The point-of-interest name is the best available, which is the
            // same fallback the iOS 26 path uses.
            return placemark.name ?? placemark.areasOfInterest?.first
        }

        // At home the reader wants the state; abroad they want the country.
        // That is the distinction MapKit makes for us on iOS 26.
        let isHomeCountry = placemark.isoCountryCode == Locale.current.region?.identifier
        if let context = isHomeCountry ? placemark.administrativeArea : placemark.country {
            return "\(city), \(context)"
        }
        return city
    }
}
