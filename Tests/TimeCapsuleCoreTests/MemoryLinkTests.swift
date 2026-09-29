import Foundation
import XCTest
@testable import TimeCapsuleCore

final class MemoryLinkTests: XCTestCase {
    /// The shape of a real Photos identifier: slashes in it.
    func testAPhotosIdentifierSurvivesTheRoundTrip() throws {
        let identifier = "9F983DBA-EC35-42B8-8773-B597CF782EDD/L0/001"
        let url = try XCTUnwrap(MemoryLink.url(forAssetID: identifier))
        XCTAssertEqual(url.scheme, "attic")
        XCTAssertEqual(MemoryLink.assetID(from: url), identifier)
    }

    func testAwkwardCharactersSurviveTheRoundTrip() throws {
        for identifier in ["a b", "a+b", "a&id=b", "a?b#c", "a%20b"] {
            let url = try XCTUnwrap(MemoryLink.url(forAssetID: identifier))
            XCTAssertEqual(MemoryLink.assetID(from: url), identifier, identifier)
        }
    }

    func testOtherLinksAreNotMemoryLinks() throws {
        for text in [
            "https://example.com/memory?id=abc",
            "attic://settings?id=abc",
            "attic://memory",
            "attic://memory?id=",
            "attic://memory?other=abc"
        ] {
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertNil(MemoryLink.assetID(from: url), text)
        }
    }

    func testNoLinkForAnEmptyIdentifier() {
        XCTAssertNil(MemoryLink.url(forAssetID: ""))
    }
}
