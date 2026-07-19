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
}
