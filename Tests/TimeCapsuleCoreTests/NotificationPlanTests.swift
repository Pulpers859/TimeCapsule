import Foundation
import XCTest
@testable import TimeCapsuleCore

final class NotificationPlanTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testSkipsTodaysPastFireTimeAndKeepsRequestedCount() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 19, hour: 20)))
        let slots = NotificationPlan.slots(now: now, calendar: calendar, hour: 9, minute: 30, count: 3, identifierPrefix: "daily.")
        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots.map(\.identifier), ["daily.20260720", "daily.20260721", "daily.20260722"])
    }

    func testIncludesTodaysFutureFireTime() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 19, hour: 8)))
        let slots = NotificationPlan.slots(now: now, calendar: calendar, hour: 9, minute: 30, count: 1, identifierPrefix: "daily.")
        XCTAssertEqual(slots.first?.identifier, "daily.20260719")
    }

    func testZeroCountCreatesNoSlots() {
        XCTAssertTrue(NotificationPlan.slots(now: Date(), calendar: calendar, hour: 9, minute: 0, count: 0, identifierPrefix: "daily.").isEmpty)
    }

    func testBodyHandlesExactAndNearbyWindows() {
        XCTAssertEqual(NotificationPlan.body(memoryCount: 1, dayWindow: 0), "You have 1 memory from this day in a past year.")
        XCTAssertEqual(NotificationPlan.body(memoryCount: 3, dayWindow: 2), "You have 3 memories from around this day in past years.")
    }

    /// The branch that ships a notification about nothing.
    ///
    /// It used to say "Check today's memories from this day in past years"
    /// on a day holding none, so the reminder promised something the app
    /// contradicted as soon as it opened. A reminder on a quiet day is
    /// wanted; a wrong one is not. This was also the only branch of `body`
    /// with no test at all.
    func testEmptyDayBodySaysThereIsNothingRatherThanPromisingMemories() {
        for window in [0, 3] {
            let body = NotificationPlan.body(memoryCount: 0, dayWindow: window)
            XCTAssertFalse(
                body.lowercased().contains("check"),
                "An empty day must not invite the user to check memories that do not exist: \(body)"
            )
            XCTAssertTrue(
                body.lowercased().contains("nothing"),
                "An empty day should say so plainly: \(body)"
            )
        }
    }

    func testNonEmptyDaysStillStateTheCount() {
        XCTAssertTrue(NotificationPlan.body(memoryCount: 1, dayWindow: 0).contains("1 memory"))
        XCTAssertTrue(NotificationPlan.body(memoryCount: 7, dayWindow: 0).contains("7 memories"))
    }

    /// A free user's quiet-day reminder must not claim there is nothing in
    /// *past years* when only the recent ones were searched — their 2016 may
    /// be full.
    func testQuietDayNamesTheYearsSearchedWhenHistoryIsLimited() {
        let body = NotificationPlan.body(memoryCount: 0, dayWindow: 0, lookbackYears: 2)
        XCTAssertFalse(body.contains("in past years"), body)
        XCTAssertTrue(body.contains("last 2 years"), body)
    }

    /// Pro, and every caller that predates the gate, keeps the original copy.
    func testQuietDayKeepsOriginalCopyForFullHistory() {
        XCTAssertEqual(
            NotificationPlan.body(memoryCount: 0, dayWindow: 0, lookbackYears: 20),
            NotificationPlan.body(memoryCount: 0, dayWindow: 0)
        )
        XCTAssertTrue(NotificationPlan.body(memoryCount: 0, dayWindow: 0).contains("in past years"))
    }

    /// A day that has memories reads the same whatever the lookback: they are
    /// from past years either way.
    func testDaysWithMemoriesAreUnaffectedByTheLookback() {
        XCTAssertEqual(
            NotificationPlan.body(memoryCount: 3, dayWindow: 0, lookbackYears: 2),
            NotificationPlan.body(memoryCount: 3, dayWindow: 0)
        )
    }
}
