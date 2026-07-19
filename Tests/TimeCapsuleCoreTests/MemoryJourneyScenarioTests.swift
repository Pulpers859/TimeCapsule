import Foundation
import XCTest
@testable import TimeCapsuleCore

final class MemoryJourneyScenarioTests: XCTestCase {
    func testEmptyExactDayCanWidenThenScheduleAndDeleteSafely() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 8)))

        var visibleIDs: [String] = []
        XCTAssertTrue(visibleIDs.isEmpty, "The exact-day journey begins in the empty state.")

        let widened = try XCTUnwrap(MemoryWindow.range(for: today, anniversaryYear: 2025, dayWindow: 2, calendar: calendar))
        XCTAssertEqual(calendar.component(.day, from: widened.start), 30)
        visibleIDs = ["old-photo", "old-video", "newer-photo"]

        let slots = NotificationPlan.slots(now: today, calendar: calendar, hour: 9, minute: 0, count: 2, identifierPrefix: "daily.")
        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(NotificationPlan.body(memoryCount: visibleIDs.count, dayWindow: 2), "You have 3 memories from around this day in past years.")

        var selection = Set(["old-photo", "old-video"])
        let nextIndex = GalleryStateLogic.indexAfterDeleting(
            identifier: "old-photo",
            from: visibleIDs,
            currentIndex: 0
        )
        visibleIDs.removeAll { $0 == "old-photo" }
        selection = GalleryStateLogic.prunedSelection(selection, visibleIDs: Set(visibleIDs))
        XCTAssertEqual(nextIndex, 0)
        XCTAssertEqual(selection, ["old-video"])
        XCTAssertEqual(NotificationPlan.body(memoryCount: visibleIDs.count, dayWindow: 2), "You have 2 memories from around this day in past years.")
        XCTAssertEqual(RecapPlan.sampleIndices(itemCount: 40, maximum: 30).count, 30)
    }
}
