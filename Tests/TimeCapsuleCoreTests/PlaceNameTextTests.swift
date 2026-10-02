import XCTest
@testable import TimeCapsuleCore

final class PlaceNameTextTests: XCTestCase {
    /// The device case: an empty city was shown as a name, as a caption
    /// ending in "·" and a Location row with nothing in it.
    func testAnEmptyNameFallsThroughToTheNext() {
        XCTAssertEqual(
            PlaceNameText.best(["", "Boston Logan International Airport"]),
            "Boston Logan International Airport"
        )
    }

    func testWhitespaceCountsAsEmpty() {
        XCTAssertEqual(PlaceNameText.best(["  \n", nil, "East Boston"]), "East Boston")
    }

    func testTheFirstRealNameWins() {
        XCTAssertEqual(PlaceNameText.best(["Boston, MA", "Logan Airport"]), "Boston, MA")
    }

    func testNamesAreTrimmed() {
        XCTAssertEqual(PlaceNameText.best([" Boston, MA "]), "Boston, MA")
    }

    /// Nothing usable means no name at all, so the caption and the info
    /// sheet leave the place out rather than showing an empty one.
    func testNothingUsableIsNil() {
        XCTAssertNil(PlaceNameText.best([nil, "", "   "]))
        XCTAssertNil(PlaceNameText.best([]))
    }

    // MARK: - Naming an area, never an address

    /// The device case: a village Maps had no town for. The result's own
    /// name, "Via Principale 3C", was shown; the village is what belongs.
    func testAVillageIsNamedWhenThereIsNoTown() {
        let area = PlaceNameText.Area(
            subLocality: "Collepietra",
            subAdministrativeArea: "Bolzano",
            administrativeArea: "Trentino-Alto Adige",
            country: "Italy",
            isHomeCountry: false
        )
        XCTAssertEqual(PlaceNameText.name(for: area), "Collepietra, Italy")
    }

    /// The other device case, which showed the postal code "39056": with no
    /// village either, the province is the next larger area.
    func testTheProvinceIsNamedWhenThereIsNoVillage() {
        let area = PlaceNameText.Area(
            subAdministrativeArea: "South Tyrol",
            administrativeArea: "Trentino-Alto Adige",
            country: "Italy",
            isHomeCountry: false
        )
        XCTAssertEqual(PlaceNameText.name(for: area), "South Tyrol, Italy")
    }

    func testATownWinsOverItsDistrict() {
        let area = PlaceNameText.Area(
            locality: "Boston",
            subLocality: "East Boston",
            administrativeArea: "MA",
            country: "United States",
            isHomeCountry: true
        )
        XCTAssertEqual(PlaceNameText.name(for: area), "Boston, MA")
    }

    func testALandmarkNamesSomewhereWithNoTown() {
        let area = PlaceNameText.Area(
            areaOfInterest: "Yosemite National Park",
            administrativeArea: "CA",
            isHomeCountry: true
        )
        XCTAssertEqual(PlaceNameText.name(for: area), "Yosemite National Park")
    }

    func testOnlyARegionLeftIsStillAnArea() {
        XCTAssertEqual(
            PlaceNameText.name(for: .init(administrativeArea: "Tyrol", country: "Austria", isHomeCountry: false)),
            "Tyrol, Austria"
        )
        XCTAssertEqual(
            PlaceNameText.name(for: .init(administrativeArea: "Maine", country: "United States", isHomeCountry: true)),
            "Maine"
        )
    }

    /// Singapore and the like: the town and its context are the same word.
    func testContextIsNotRepeated() {
        let area = PlaceNameText.Area(locality: "Singapore", country: "Singapore", isHomeCountry: false)
        XCTAssertEqual(PlaceNameText.name(for: area), "Singapore")
    }

    func testBlankPartsAreSkipped() {
        let area = PlaceNameText.Area(locality: " ", subLocality: "", subAdministrativeArea: "Bolzano", country: "", isHomeCountry: false)
        XCTAssertEqual(PlaceNameText.name(for: area), "Bolzano")
    }

    func testNoAreaAtAllIsNil() {
        XCTAssertNil(PlaceNameText.name(for: .init(isHomeCountry: false)))
    }

    // MARK: - Landmarks

    /// The device case: Seceda, not the municipality it sits in.
    func testALandmarkInReachIsChosen() {
        let found = PlaceNameText.landmark(among: [
            .init(name: "Seceda", kind: .sight, distance: 180)
        ])
        XCTAssertEqual(found, "Seceda")
        XCTAssertEqual(PlaceNameText.name(landmark: "Seceda", context: "Italy"), "Seceda, Italy")
    }

    func testNothingInReachMeansTheTown() {
        XCTAssertNil(PlaceNameText.landmark(among: [
            .init(name: "Far Viewpoint", kind: .sight, distance: 450),
            .init(name: "Corner Park", kind: .park, distance: 260)
        ]))
        XCTAssertNil(PlaceNameText.landmark(among: []))
    }

    /// Closeness is relative to each kind's reach: a viewpoint well within
    /// its reach beats a park only just within its own.
    func testTheClosestForItsKindWins() {
        let found = PlaceNameText.landmark(among: [
            .init(name: "Corner Park", kind: .park, distance: 180),
            .init(name: "Lago di Carezza", kind: .sight, distance: 120)
        ])
        XCTAssertEqual(found, "Lago di Carezza")
    }

    func testABlankLandmarkNameIsSkipped() {
        let found = PlaceNameText.landmark(among: [
            .init(name: " ", kind: .sight, distance: 10),
            .init(name: "Seceda", kind: .outdoors, distance: 300)
        ])
        XCTAssertEqual(found, "Seceda")
    }

    func testContextIsWhatFollowsTheCity() {
        XCTAssertEqual(PlaceNameText.context(cityWithContext: "Villnöß, Italy", city: "Villnöß"), "Italy")
        XCTAssertEqual(PlaceNameText.context(cityWithContext: "Boston, MA", city: "Boston"), "MA")
        XCTAssertNil(PlaceNameText.context(cityWithContext: "Boston", city: "Boston"))
        XCTAssertNil(PlaceNameText.context(cityWithContext: "Boston, MA", city: nil))
    }

    func testALandmarkNamedLikeItsContextIsNotRepeated() {
        XCTAssertEqual(PlaceNameText.name(landmark: "Monaco", context: "Monaco"), "Monaco")
        XCTAssertEqual(PlaceNameText.name(landmark: "Fenway Park", context: nil), "Fenway Park")
    }
}
