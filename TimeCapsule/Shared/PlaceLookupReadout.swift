#if ATTIC_SIDELOAD_PLACE_READOUT
import CoreLocation
import MapKit
import SwiftUI

/// Everything Apple Maps says about a photo's coordinates, shown in the info
/// sheet so the rule that picks a place name can be checked against real
/// answers instead of guessed at. Maps cannot be asked from CI, and the
/// places that go wrong — villages, mountains, lakes — are exactly the ones
/// nobody can predict.
///
/// Sideload builds only, and only when the build workflow's `place_readout`
/// input is on. Every request here is made only when the button is tapped:
/// Maps rate-limits, and this asks it several things at once.
struct PlaceLookupReadout: View {
    let coordinate: CLLocationCoordinate2D
    @State private var lines: [String] = []
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(isLoading ? "Asking Maps…" : "Show What Maps Returns") {
                Task { await load() }
            }
            .disabled(isLoading)

            if !lines.isEmpty {
                Text(lines.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var out = [String(format: "AT %.5f, %.5f", coordinate.latitude, coordinate.longitude)]

        if #available(iOS 26.0, *) {
            out.append("")
            out.append("REVERSE GEOCODE (MapKit)")
            out += await reverseGeocode(location)
        }

        out.append("")
        out.append("PLACEMARK (CLGeocoder)")
        out += await placemark(location)

        out.append("")
        out.append("POINTS OF INTEREST within 1 km, any kind")
        out += await pointsOfInterest(location)

        for query in ["lake", "mountain", "peak"] {
            out.append("")
            out.append("PHYSICAL FEATURES \"\(query)\" within 3 km")
            out += await physicalFeatures(query, near: location)
        }
        lines = out
    }

    @available(iOS 26.0, *)
    private func reverseGeocode(_ location: CLLocation) async -> [String] {
        guard let request = MKReverseGeocodingRequest(location: location) else { return ["  (no request)"] }
        do {
            let items = try await request.mapItems
            guard !items.isEmpty else { return ["  (no items)"] }
            return items.map { item in
                let rep = item.addressRepresentations
                return "  name=\(show(item.name)) city=\(show(rep?.cityName)) withContext=\(show(rep?.cityWithContext)) region=\(show(rep?.regionName)) poi=\(show(item.pointOfInterestCategory?.rawValue))"
            }
        } catch {
            return ["  error: \(error.localizedDescription)"]
        }
    }

    private func placemark(_ location: CLLocation) async -> [String] {
        do {
            let marks = try await CLGeocoder().reverseGeocodeLocation(location)
            guard !marks.isEmpty else { return ["  (none)"] }
            return marks.flatMap { mark in
                [
                    "  name=\(show(mark.name))",
                    "  locality=\(show(mark.locality)) subLocality=\(show(mark.subLocality))",
                    "  subAdmin=\(show(mark.subAdministrativeArea)) admin=\(show(mark.administrativeArea)) country=\(show(mark.country))",
                    "  areasOfInterest=\(mark.areasOfInterest?.joined(separator: " | ") ?? "nil")",
                    "  inlandWater=\(show(mark.inlandWater)) ocean=\(show(mark.ocean))"
                ]
            }
        } catch {
            return ["  error: \(error.localizedDescription)"]
        }
    }

    private func pointsOfInterest(_ location: CLLocation) async -> [String] {
        let request = MKLocalPointsOfInterestRequest(center: location.coordinate, radius: 1000)
        return await describe(MKLocalSearch(request: request), from: location)
    }

    private func physicalFeatures(_ query: String, near location: CLLocation) async -> [String] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: location.coordinate, latitudinalMeters: 6000, longitudinalMeters: 6000)
        request.resultTypes = .physicalFeature
        request.regionPriority = .required
        return await describe(MKLocalSearch(request: request), from: location)
    }

    private func describe(_ search: MKLocalSearch, from location: CLLocation) async -> [String] {
        do {
            let items = try await search.start().mapItems
            let rows = items.map { item -> (Double, String) in
                let point: CLLocation? = {
                    if #available(iOS 26.0, *) { return item.location }
                    return item.placemark.location
                }()
                let distance = point?.distance(from: location) ?? -1
                return (distance, "  \(Int(distance))m \(show(item.name)) [\(item.pointOfInterestCategory?.rawValue ?? "no category")]")
            }
            .sorted { $0.0 < $1.0 }
            .prefix(15)
            .map(\.1)
            return rows.isEmpty ? ["  (none)"] : Array(rows)
        } catch {
            return ["  error: \(error.localizedDescription)"]
        }
    }

    private func show(_ value: String?) -> String {
        guard let value else { return "nil" }
        return "\"\(value)\""
    }
}
#endif
