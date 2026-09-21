import XCTest
@testable import TimeCapsuleCore

final class MediaDurationTests: XCTestCase {
    func testShortDurationsUseMinutesAndSeconds() {
        XCTAssertEqual(MediaDuration.formatted(1), "0:01")
        XCTAssertEqual(MediaDuration.formatted(59), "0:59")
        XCTAssertEqual(MediaDuration.formatted(60), "1:00")
        XCTAssertEqual(MediaDuration.formatted(95), "1:35")
        XCTAssertEqual(MediaDuration.formatted(599), "9:59")
    }

    /// The case none of the three copies this replaced handled: past an hour
    /// they all kept counting in minutes, so a 75-minute recording read
    /// "75:00".
    func testAnHourOrMoreGrowsAnHoursField() {
        XCTAssertEqual(MediaDuration.formatted(3600), "1:00:00")
        XCTAssertEqual(MediaDuration.formatted(3661), "1:01:01")
        XCTAssertEqual(MediaDuration.formatted(4500), "1:15:00")
        XCTAssertEqual(MediaDuration.formatted(86_399), "23:59:59")
    }

    /// Truncated, not rounded, so the label never claims a second the video
    /// does not have — and so the scrubber's running time never briefly
    /// displays a value past the duration beside it.
    func testFractionsTruncateRatherThanRound() {
        XCTAssertEqual(MediaDuration.formatted(59.9), "0:59")
        XCTAssertEqual(MediaDuration.formatted(3599.99), "59:59")
    }

    /// `Int(_:)` traps on these rather than returning a wrong number, and
    /// only one of the three previous copies guarded against it.
    func testNonFiniteAndOutOfRangeValuesDoNotTrap() {
        XCTAssertEqual(MediaDuration.formatted(.nan), "0:00")
        XCTAssertEqual(MediaDuration.formatted(.infinity), "0:00")
        XCTAssertEqual(MediaDuration.formatted(-.infinity), "0:00")
        XCTAssertEqual(MediaDuration.formatted(.greatestFiniteMagnitude), "0:00")
    }

    // MARK: - Spoken form, for accessibility labels

    /// "1:05" is read aloud by VoiceOver as "one colon zero five", so any
    /// duration going into an accessibility label needs words instead.
    func testSpokenDurationUsesWords() {
        XCTAssertEqual(MediaDuration.spokenDuration(1), "1 second")
        XCTAssertEqual(MediaDuration.spokenDuration(42), "42 seconds")
        XCTAssertEqual(MediaDuration.spokenDuration(60), "1 minute")
        XCTAssertEqual(MediaDuration.spokenDuration(61), "1 minute 1 second")
        XCTAssertEqual(MediaDuration.spokenDuration(90), "1 minute 30 seconds")
        XCTAssertEqual(MediaDuration.spokenDuration(3600), "1 hour")
        XCTAssertEqual(MediaDuration.spokenDuration(3661), "1 hour 1 minute 1 second")
        XCTAssertEqual(MediaDuration.spokenDuration(4500), "1 hour 15 minutes")
        XCTAssertEqual(MediaDuration.spokenDuration(86_399), "23 hours 59 minutes 59 seconds")
    }

    /// A whole number of minutes drops the seconds, but a sub-minute
    /// duration still says them — otherwise a 42-second clip would announce
    /// nothing at all.
    func testSpokenDurationOmitsZeroSecondsOnlyWhenSomethingElseIsSaid() {
        XCTAssertEqual(MediaDuration.spokenDuration(300), "5 minutes")
        XCTAssertEqual(MediaDuration.spokenDuration(1), "1 second")
    }

    func testSpokenDurationRefusesUnusableValues() {
        XCTAssertEqual(MediaDuration.spokenDuration(0), "no length")
        XCTAssertEqual(MediaDuration.spokenDuration(0.5), "no length")
        XCTAssertEqual(MediaDuration.spokenDuration(-5), "no length")
        XCTAssertEqual(MediaDuration.spokenDuration(.nan), "no length")
        XCTAssertEqual(MediaDuration.spokenDuration(.infinity), "no length")
    }

    func testZeroAndNegativeAndSubSecondValuesReadAsZero() {
        XCTAssertEqual(MediaDuration.formatted(0), "0:00")
        XCTAssertEqual(MediaDuration.formatted(0.4), "0:00")
        XCTAssertEqual(MediaDuration.formatted(0.99), "0:00")
        XCTAssertEqual(MediaDuration.formatted(-5), "0:00")
    }
}
