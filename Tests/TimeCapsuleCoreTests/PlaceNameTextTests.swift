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
}
