import Foundation

/// Which of the names Apple Maps offers for a place to show.
///
/// Maps can answer a field with an empty string rather than none at all.
/// Seen on device for a photo taken on a plane at Logan Airport: the viewer
/// caption read "1 year ago ·" with nothing after the dot, and the info
/// sheet showed a Location row with no value. An empty name had been taken
/// as a name, which also stopped the lookup from trying Maps' other ones.
///
/// Framework-free, so the rule is tested on every CI run.
nonisolated enum PlaceNameText {
    /// The first candidate with something in it, trimmed; `nil` if none has.
    static func best(_ candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { continue }
            return trimmed
        }
        return nil
    }

    /// The parts of a reverse-geocoded place that name an *area*.
    ///
    /// Deliberately missing: the street, house number, postal code and the
    /// result's own `name`. For a reverse lookup that `name` is the address
    /// itself. Falling back to it put "Via Principale 3C" and "39056" under
    /// two photos from rural South Tyrol, where Maps had no town to give —
    /// the opposite of what a line under a memory is for. When there is no
    /// town, the next larger area is the answer, never the smaller one.
    nonisolated struct Area: Equatable {
        var locality: String?
        /// A village or district. Only reached when there is no locality,
        /// which in a city there always is, so this names hamlets rather
        /// than neighbourhoods.
        var subLocality: String?
        /// Province or county.
        var subAdministrativeArea: String?
        /// A park, lake or landmark, for somewhere with no town at all.
        var areaOfInterest: String?
        /// State or region.
        var administrativeArea: String?
        var country: String?
        /// At home the reader wants the state; abroad, the country.
        var isHomeCountry: Bool

        init(
            locality: String? = nil,
            subLocality: String? = nil,
            subAdministrativeArea: String? = nil,
            areaOfInterest: String? = nil,
            administrativeArea: String? = nil,
            country: String? = nil,
            isHomeCountry: Bool
        ) {
            self.locality = locality
            self.subLocality = subLocality
            self.subAdministrativeArea = subAdministrativeArea
            self.areaOfInterest = areaOfInterest
            self.administrativeArea = administrativeArea
            self.country = country
            self.isHomeCountry = isHomeCountry
        }
    }

    /// "Town, State" at home, "Town, Country" abroad; failing a town, the
    /// landmark, then the region. `nil` only when Maps named no area at all.
    static func name(for area: Area) -> String? {
        let context = best([area.isHomeCountry ? area.administrativeArea : area.country])

        if let town = best([area.locality, area.subLocality, area.subAdministrativeArea]) {
            guard let context, context != town else { return town }
            return "\(town), \(context)"
        }
        if let landmark = best([area.areaOfInterest]) {
            return landmark
        }
        if let region = best([area.administrativeArea]) {
            guard !area.isHomeCountry, let country = best([area.country]), country != region else {
                return region
            }
            return "\(region), \(country)"
        }
        return best([area.country])
    }
}
