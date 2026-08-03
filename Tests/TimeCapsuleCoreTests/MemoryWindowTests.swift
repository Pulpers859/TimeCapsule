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

    // MARK: - yearsAgo

    /// Regression: a photo from 4:59 PM on Aug 3 2024, viewed at 8:03 AM on
    /// Aug 3 2026, was reported as "1 year ago" in the share caption because
    /// elapsed-duration math is still nine hours short of the second
    /// anniversary. The gallery had it grouped under "2 Years Ago".
    func testYearsAgoCountsCalendarYearsNotElapsedDuration() throws {
        let creationDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2024, month: 8, day: 3, hour: 16, minute: 59))
        )
        let viewedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 8, minute: 3))
        )

        XCTAssertEqual(
            MemoryWindow.yearsAgo(
                for: creationDate,
                relativeTo: viewedAt,
                dayStartHour: 0,
                calendar: calendar
            ),
            2
        )

        // The behaviour this replaces, pinned so the regression is unambiguous.
        XCTAssertEqual(
            calendar.dateComponents([.year], from: creationDate, to: viewedAt).year,
            1
        )
    }

    func testYearsAgoIsStableAcrossTheCaptureTimeOfDay() throws {
        let creationDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2024, month: 8, day: 3, hour: 16, minute: 59))
        )

        // Same answer before, at, and after the moment of day the photo was
        // taken. The old math flipped from 1 to 2 as the clock passed 4:59 PM.
        for hour in [0, 8, 16, 17, 23] {
            let viewedAt = try XCTUnwrap(
                calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: hour))
            )
            XCTAssertEqual(
                MemoryWindow.yearsAgo(
                    for: creationDate,
                    relativeTo: viewedAt,
                    dayStartHour: 0,
                    calendar: calendar
                ),
                2,
                "hour \(hour) disagreed"
            )
        }
    }

    /// With a non-midnight day start, a photo taken just after midnight on
    /// Jan 1 belongs to the previous evening. `range(for:anniversaryYear:)`
    /// groups it under the earlier year, so `yearsAgo` must agree.
    func testYearsAgoFollowsDayStartHourAcrossTheNewYearBoundary() throws {
        let afterMidnight = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 0, minute: 30))
        )
        let viewedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 22))
        )

        // Logically New Year's Eve 2024, so one year back from Dec 31 2026.
        XCTAssertEqual(
            MemoryWindow.yearsAgo(
                for: afterMidnight,
                relativeTo: viewedAt,
                dayStartHour: 4,
                calendar: calendar
            ),
            2
        )

        // At midnight it is simply Jan 1 2025, one year closer.
        XCTAssertEqual(
            MemoryWindow.yearsAgo(
                for: afterMidnight,
                relativeTo: viewedAt,
                dayStartHour: 0,
                calendar: calendar
            ),
            1
        )
    }

    func testYearsAgoIsZeroForMemoriesFromTheCurrentYear() throws {
        let creationDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 1, day: 4, hour: 9))
        )
        let viewedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 8))
        )

        XCTAssertEqual(
            MemoryWindow.yearsAgo(
                for: creationDate,
                relativeTo: viewedAt,
                dayStartHour: 0,
                calendar: calendar
            ),
            0
        )
    }

    func testYearsAgoClampsCorruptDayStartHour() throws {
        let creationDate = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2024, month: 8, day: 3, hour: 2))
        )
        let viewedAt = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 8))
        )

        // A negative hour must behave like midnight rather than shifting dates.
        XCTAssertEqual(
            MemoryWindow.yearsAgo(
                for: creationDate,
                relativeTo: viewedAt,
                dayStartHour: -5,
                calendar: calendar
            ),
            2
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
