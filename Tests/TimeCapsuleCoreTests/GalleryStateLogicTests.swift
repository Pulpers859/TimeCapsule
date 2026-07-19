import XCTest
@testable import TimeCapsuleCore

final class GalleryStateLogicTests: XCTestCase {
    func testPrunesSelectionAfterExternalLibraryChange() {
        XCTAssertEqual(
            GalleryStateLogic.prunedSelection(["kept", "deleted"], visibleIDs: ["kept", "new"]),
            ["kept"]
        )
    }

    func testDeletingCurrentLastItemMovesToPreviousItem() {
        XCTAssertEqual(GalleryStateLogic.indexAfterDeleting(identifier: "c", from: ["a", "b", "c"], currentIndex: 2), 1)
    }

    func testDeletingOnlyItemEndsSession() {
        XCTAssertNil(GalleryStateLogic.indexAfterDeleting(identifier: "only", from: ["only"], currentIndex: 0))
    }
}
