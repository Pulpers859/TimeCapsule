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
}
