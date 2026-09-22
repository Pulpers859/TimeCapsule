import Foundation
import XCTest
@testable import TimeCapsuleCore

final class MemoryWindowTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    // MARK: - dayBounds / dayKey

    func testDayBoundsIsMidnightToMidnightByDefault() throws {
        let noon = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2025, month: 9, day: 21, hour: 12))
        )
        let bounds = try XCTUnwrap(
            MemoryWindow.dayBounds(containing: noon, dayStartHour: 0, calendar: calendar)
        )
        XCTAssertEqual(
            bounds.start,
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 9, day: 21)))
        )
        XCTAssertEqual(
            bounds.end,
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 9, day: 22)))
        )
    }

    /// The case the setting exists for: an evening that ran past midnight.
    func testDayBoundsPutsTheSmallHoursWithThePreviousEvening() throws {
        let afterMidnight = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2025, month: 9, day: 22, hour: 1, minute: 30))
        )
        let bounds = try XCTUnwrap(
            MemoryWindow.dayBounds(containing: afterMidnight, dayStartHour: 4, calendar: calendar)
        )
        // Belongs to the 21st, from 4am, not to the 22nd.
        XCTAssertEqual(
            bounds.start,
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 9, day: 21, hour: 4)))
        )
        XCTAssertEqual(
            bounds.end,
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 9, day: 22, hour: 4)))
        )
        XCTAssertTrue(bounds.start <= afterMidnight && afterMidnight < bounds.end)
    }

    /// The whole reason this is not `range(for:anniversaryYear:)`: the Pro
    /// recall setting must not turn one day into seven.
    func testDayBoundsIsNeverWidenedByTheMemoryWindow() throws {
        let noon = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2025, month: 9, day: 21, hour: 12))
        )
        let bounds = try XCTUnwrap(
            MemoryWindow.dayBounds(containing: noon, dayStartHour: 0, calendar: calendar)
        )
        let span = calendar.dateComponents([.day], from: bounds.start, to: bounds.end).day
        XCTAssertEqual(span, 1, "dayBounds must always be exactly one day wide.")
    }

    /// Adding 86,400 seconds would make this 23 or 25 hours long, and the
    /// day would silently start an hour early or late.
    func testDayBoundsSurvivesADaylightSavingTransition() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        // 8 March 2026 is a US spring-forward day: it has 23 hours.
        let duringTheDay = try XCTUnwrap(
            local.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))
        )
        let bounds = try XCTUnwrap(
            MemoryWindow.dayBounds(containing: duringTheDay, dayStartHour: 0, calendar: local)
        )
        XCTAssertEqual(
            bounds.start,
            try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        )
        XCTAssertEqual(
            bounds.end,
            try XCTUnwrap(local.date(from: DateComponents(year: 2026, month: 3, day: 9))),
            "The day must end at the next local midnight, not 24 hours later."
        )
        XCTAssertEqual(
            local.dateComponents([.hour], from: bounds.start, to: bounds.end).hour,
            23,
            "A spring-forward day is 23 hours; anything else means seconds were added."
        )
    }

    func testDayBoundsHandlesTheLeapDayItself() throws {
        let leapDay = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2024, month: 2, day: 29, hour: 9))
        )
        let bounds = try XCTUnwrap(
            MemoryWindow.dayBounds(containing: leapDay, dayStartHour: 0, calendar: calendar)
        )
        XCTAssertEqual(calendar.component(.day, from: bounds.start), 29)
        XCTAssertEqual(calendar.component(.month, from: bounds.end), 3)
        XCTAssertEqual(calendar.component(.day, from: bounds.end), 1)
    }

    func testDayBoundsCrossesAYearBoundary() throws {
        let newYearsEve = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 22))
        )
        let bounds = try XCTUnwrap(
            MemoryWindow.dayBounds(containing: newYearsEve, dayStartHour: 0, calendar: calendar)
        )
        XCTAssertEqual(calendar.component(.year, from: bounds.end), 2026)
        XCTAssertEqual(calendar.component(.day, from: bounds.end), 1)
    }

    /// Two instants in the same logical day must key the same, and the
    /// boundary must actually separate them.
    func testDayKeyGroupsALateNightWithTheEveningItBeganIn() throws {
        let evening = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2025, month: 9, day: 21, hour: 23))
        )
        let afterMidnight = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2025, month: 9, day: 22, hour: 1))
        )
        let morningAfter = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2025, month: 9, day: 22, hour: 9))
        )

        let eveningKey = MemoryWindow.dayKey(containing: evening, dayStartHour: 4, calendar: calendar)
        XCTAssertEqual(
            eveningKey,
            MemoryWindow.dayKey(containing: afterMidnight, dayStartHour: 4, calendar: calendar)
        )
        XCTAssertNotEqual(
            eveningKey,
            MemoryWindow.dayKey(containing: morningAfter, dayStartHour: 4, calendar: calendar)
        )
    }

    func testDayKeyAndDayBoundsAgreeOnWhichDayItIs() throws {
        let afterMidnight = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2025, month: 9, day: 22, hour: 2))
        )
        let bounds = try XCTUnwrap(
            MemoryWindow.dayBounds(containing: afterMidnight, dayStartHour: 4, calendar: calendar)
        )
        XCTAssertEqual(
            MemoryWindow.dayKey(containing: afterMidnight, dayStartHour: 4, calendar: calendar),
            MemoryWindow.dayKey(containing: bounds.start, dayStartHour: 4, calendar: calendar)
        )
    }

    func testDayBoundsClampsCorruptDayStartHour() throws {
        let noon = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2025, month: 9, day: 21, hour: 12))
        )
        let negative = try XCTUnwrap(
            MemoryWindow.dayBounds(containing: noon, dayStartHour: -5, calendar: calendar)
        )
        XCTAssertEqual(calendar.component(.hour, from: negative.start), 0)

        let huge = try XCTUnwrap(
            MemoryWindow.dayBounds(containing: noon, dayStartHour: 99, calendar: calendar)
        )
        XCTAssertEqual(calendar.component(.hour, from: huge.start), 6)
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

    /// Regression: the existence check used to run *before* the window was
    /// applied, so a user on Feb 29 with a widened range lost every non-leap
    /// year — 15 of the last 20 — even though the range they asked for
    /// (Feb 26 - Mar 3) exists in all of them.
    func testLeapDayWithWindowStillCoversNonLeapAnniversaryYear() throws {
        let leapDay = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2024, month: 2, day: 29))
        )
        let range = try XCTUnwrap(
            MemoryWindow.range(
                for: leapDay,
                anniversaryYear: 2023,
                dayWindow: 3,
                calendar: calendar
            )
        )

        // Anchored on Feb 28 2023, the last real day of that month.
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.start),
            DateComponents(year: 2023, month: 2, day: 25)
        )
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day], from: range.end),
            DateComponents(year: 2023, month: 3, day: 4)
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

// MARK: - Non-Gregorian system calendars

/// iOS lets someone choose Japanese, Buddhist, Hebrew, Islamic or Persian as
/// their system calendar from Settings, and `Calendar.current` then reports
/// year numbers in that calendar. Two assumptions in `MemoryWindow` broke on
/// that: that a year number is absolute, and that subtracting two of them
/// gives elapsed years. Neither holds across a Japanese era boundary.
///
/// These assert outcomes rather than the era numbers themselves, so they are
/// not hostage to how a given platform's ICU spells Reiwa.
final class MemoryWindowNonGregorianTests: XCTestCase {
    private func calendar(_ identifier: Calendar.Identifier) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        calendar(.gregorian).date(
            from: DateComponents(year: year, month: month, day: day, hour: 12)
        ) ?? Date(timeIntervalSince1970: 0)
    }

    /// The headline case. Under the Japanese calendar a 2018 photo is Heisei
    /// 30 and 2026 is Reiwa 8, so the old subtraction produced -22. Every
    /// caller guards on `> 0`, so the failure was silent: the "N years ago"
    /// caption, the info-sheet strapline and the share caption all vanished
    /// for anything older than the era change.
    func testYearsAgoIsTheSameUnderEveryCalendar() {
        let reference = date(year: 2026, month: 9, day: 21)
        for identifier in [Calendar.Identifier.gregorian, .japanese, .buddhist, .republicOfChina] {
            XCTAssertEqual(
                MemoryWindow.yearsAgo(
                    for: date(year: 2018, month: 9, day: 21),
                    relativeTo: reference,
                    dayStartHour: 0,
                    calendar: calendar(identifier)
                ),
                8,
                "yearsAgo disagreed under \(identifier)"
            )
        }
    }

    /// Crossing the Reiwa boundary (1 May 2019) used to split one Gregorian
    /// year in two: a March 2019 photo read as Heisei 31 and a September one
    /// as Reiwa 1, so two photos from the same year behaved differently.
    func testYearsAgoDoesNotSplitAYearAtAnEraBoundary() {
        let reference = date(year: 2026, month: 9, day: 21)
        let japanese = calendar(.japanese)
        XCTAssertEqual(
            MemoryWindow.yearsAgo(for: date(year: 2019, month: 3, day: 21), relativeTo: reference, dayStartHour: 0, calendar: japanese),
            7
        )
        XCTAssertEqual(
            MemoryWindow.yearsAgo(for: date(year: 2019, month: 9, day: 21), relativeTo: reference, dayStartHour: 0, calendar: japanese),
            7
        )
    }

    /// The fetch window itself must land on the same instants regardless of
    /// the reader's calendar, or the photos found would differ too.
    func testAnniversaryRangeIsIdenticalUnderEveryCalendar() {
        let reference = date(year: 2026, month: 9, day: 21)
        let expected = MemoryWindow.range(
            for: reference, anniversaryYear: 2006, dayWindow: 0, calendar: calendar(.gregorian)
        )
        XCTAssertNotNil(expected)
        for identifier in [Calendar.Identifier.japanese, .buddhist, .republicOfChina] {
            let actual = MemoryWindow.range(
                for: reference, anniversaryYear: 2006, dayWindow: 0, calendar: calendar(identifier)
            )
            XCTAssertEqual(actual?.start, expected?.start, "start differed under \(identifier)")
            XCTAssertEqual(actual?.end, expected?.end, "end differed under \(identifier)")
        }
    }

    func testAnniversaryCalendarLeavesAGregorianOneAlone() {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        let result = MemoryWindow.anniversaryCalendar(gregorian)
        XCTAssertEqual(result.identifier, .gregorian)
        XCTAssertEqual(result.timeZone, gregorian.timeZone)
    }

    /// The time zone must survive the swap, or a day would start at a
    /// different instant for these users than for everyone else.
    func testAnniversaryCalendarKeepsTheTimeZone() {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
        let result = MemoryWindow.anniversaryCalendar(japanese)
        XCTAssertEqual(result.identifier, .gregorian)
        XCTAssertEqual(result.timeZone, japanese.timeZone)
    }
}
