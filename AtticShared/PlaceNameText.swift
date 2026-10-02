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
        let context = Self.context(for: area)

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

    // MARK: - A landmark you were at

    /// A named place near the photo that people go *to*: a viewpoint, a
    /// lake, a peak, a castle, a park.
    ///
    /// The town is right but rarely what you remember. Two photos from the
    /// Dolomites read "Villnöß, Italy" and "Nova Levante, Italy" — the
    /// municipalities — when they were taken at Seceda and at Lake Carezza.
    /// Reverse geocoding only ever answers with the administrative area, so
    /// a landmark has to come from a separate search around the photo.
    nonisolated struct Landmark: Equatable, Sendable {
        var name: String?
        var kind: Kind
        /// Metres from where the photo was taken to the landmark's point.
        var distance: Double

        init(name: String?, kind: Kind, distance: Double) {
            self.name = name
            self.kind = kind
            self.distance = distance
        }

        /// How far from a landmark's point a photo can be and still have
        /// been taken *at* it. Maps gives each landmark a single point, not
        /// its outline, so this stands in for its size.
        nonisolated enum Kind: Equatable, Sendable {
            /// Viewpoints, monuments, castles: you photograph them from a
            /// little way off.
            case sight
            /// Beaches, ski areas, trails, climbing: spread out.
            case outdoors
            /// Parks and campgrounds. Kept tight on purpose: near home there
            /// is often a park around the corner, and a photo in your own
            /// garden is not a photo of it.
            case park
            /// Museums, stadiums, zoos: you are inside, near its point.
            case venue

            var reach: Double {
                switch self {
                case .sight: return 400
                case .outdoors: return 500
                case .park: return 200
                case .venue: return 250
                }
            }
        }
    }

    /// The farthest any landmark can be and still be chosen; what to search
    /// within.
    static let landmarkSearchRadius: Double = 500

    /// The landmark the photo was taken at, or `nil` to use the town.
    ///
    /// Each candidate is measured against its own reach, so a viewpoint
    /// 300m away beats a park 150m away — the viewpoint is well within its
    /// reach, the park only just within its.
    static func landmark(among candidates: [Landmark]) -> String? {
        let inReach = candidates.compactMap { candidate -> (name: String, closeness: Double)? in
            guard let name = best([candidate.name]),
                  candidate.distance >= 0,
                  candidate.distance <= candidate.kind.reach else { return nil }
            return (name, candidate.distance / candidate.kind.reach)
        }
        return inReach.min { $0.closeness < $1.closeness }?.name
    }

    /// "Lago di Carezza, Italy": the landmark in place of the town, with the
    /// same context the town would have had.
    static func name(landmark: String, context: String?) -> String {
        guard let context = best([context]), context != landmark else { return landmark }
        return "\(landmark), \(context)"
    }

    /// The context Maps put after the city — "Italy" from "Villnöß, Italy",
    /// "MA" from "Boston, MA" — so a landmark can carry it too.
    static func context(cityWithContext: String?, city: String?) -> String? {
        guard let full = best([cityWithContext]), let city = best([city]) else { return nil }
        let prefix = city + ", "
        guard full.hasPrefix(prefix) else { return nil }
        return best([String(full.dropFirst(prefix.count))])
    }

    /// The context for a placemark-based name: state at home, country
    /// abroad.
    static func context(for area: Area) -> String? {
        best([area.isHomeCountry ? area.administrativeArea : area.country])
    }
}
