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

    func placeName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let key = Self.cacheKey(for: coordinate)
        if let cached = resolved[key] {
            return cached
        }

        switch await Self.reverseGeocodedPlaceName(for: coordinate) {
        case .answered(let name):
            // The service gave a verdict, including "there is no name here".
            // That verdict will not change, so it is worth remembering.
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
