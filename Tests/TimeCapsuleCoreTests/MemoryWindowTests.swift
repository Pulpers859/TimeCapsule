import Foundation
import XCTest
@testable import TimeCapsuleCore

final class MemoryWindowTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testClampsCorruptPreferenceValues() {
        XCTAssertEqual(MemoryWindow.clampedDayWindow(-1), 0)
        XCTAssertEqual(MemoryWindow.clampedDayWindow(0), 0)
        XCTAssertEqual(MemoryWindow.clampedDayWindow(3), 3)
        XCTAssertEqual(MemoryWindow.clampedDayWindow(8), 7)
    }

    func testExactDayRangeEndsAtFollowingMidnight() throws {
        let referenceDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 17))
        )
        let range = try XCTUnwrap(
            MemoryWindow.range(
                for: referenceDate,
                anniversaryYear: 2020,
                dayWindow: 0,
                calendar: calendar
            )
        )

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.start),
            DateComponents(year: 2020, month: 7, day: 17)
        )
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.end),
            DateComponents(year: 2020, month: 7, day: 18)
        )
    }

    func testWidenedRangeIncludesDaysOnBothSides() throws {
        let referenceDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))
        )
        let range = try XCTUnwrap(
            MemoryWindow.range(
                for: referenceDate,
                anniversaryYear: 2024,
                dayWindow: 2,
                calendar: calendar
            )
        )

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.start),
            DateComponents(year: 2024, month: 2, day: 28)
        )
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.end),
            DateComponents(year: 2024, month: 3, day: 4)
        )
    }

    func testLeapDayIsRejectedInNonLeapAnniversaryYear() throws {
        let leapDay = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2024, month: 2, day: 29))
        )

        XCTAssertNil(
            MemoryWindow.range(
                for: leapDay,
                anniversaryYear: 2023,
                dayWindow: 0,
                calendar: calendar
            )
        )
    }

    func testLeapDayIsAcceptedInLeapAnniversaryYear() throws {
        let leapDay = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2024, month: 2, day: 29))
        )
        let range = try XCTUnwrap(
            MemoryWindow.range(
                for: leapDay,
                anniversaryYear: 2020,
                dayWindow: 0,
                calendar: calendar
            )
        )

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.start),
            DateComponents(year: 2020, month: 2, day: 29)
        )
    }

    func testNegativeDirectWindowInputProducesExactDayRange() throws {
        let referenceDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 7, day: 17))
        )
        let range = try XCTUnwrap(
            MemoryWindow.range(
                for: referenceDate,
                anniversaryYear: 2025,
                dayWindow: -100,
                calendar: calendar
            )
        )

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.start),
            DateComponents(year: 2025, month: 7, day: 17)
        )
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.end),
            DateComponents(year: 2025, month: 7, day: 18)
        )
    }

    func testWidenedRangeCrossesYearBoundary() throws {
        let referenceDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))
        )
        let range = try XCTUnwrap(
            MemoryWindow.range(
                for: referenceDate,
                anniversaryYear: 2025,
                dayWindow: 2,
                calendar: calendar
            )
        )

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.start),
            DateComponents(year: 2024, month: 12, day: 30)
        )
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.end),
            DateComponents(year: 2025, month: 1, day: 4)
        )
    }

    func testDSTTransitionPreservesLocalCalendarDays() throws {
        var newYorkCalendar = Calendar(identifier: .gregorian)
        newYorkCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let referenceDate = try XCTUnwrap(
            newYorkCalendar.date(
                from: DateComponents(year: 2026, month: 3, day: 8, hour: 16, minute: 30)
            )
        )
        let range = try XCTUnwrap(
            MemoryWindow.range(
                for: referenceDate,
                anniversaryYear: 2020,
                dayWindow: 1,
                calendar: newYorkCalendar
            )
        )

        XCTAssertEqual(
            newYorkCalendar.dateComponents([.year, .month, .day, .hour], from: range.start),
            DateComponents(year: 2020, month: 3, day: 7, hour: 0)
        )
        XCTAssertEqual(
            newYorkCalendar.dateComponents([.year, .month, .day, .hour], from: range.end),
            DateComponents(year: 2020, month: 3, day: 10, hour: 0)
        )
    }

    func testRangeAlsoClampsDirectWindowInput() throws {
        let referenceDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 10))
        )
        let range = try XCTUnwrap(
            MemoryWindow.range(
                for: referenceDate,
                anniversaryYear: 2025,
                dayWindow: 100,
                calendar: calendar
            )
        )

        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.start),
            DateComponents(year: 2025, month: 1, day: 3)
        )
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.end),
            DateComponents(year: 2025, month: 1, day: 18)
        )
    }
}
