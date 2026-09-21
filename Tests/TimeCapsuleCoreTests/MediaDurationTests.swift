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

    func testZeroAndNegativeAndSubSecondValuesReadAsZero() {
        XCTAssertEqual(MediaDuration.formatted(0), "0:00")
        XCTAssertEqual(MediaDuration.formatted(0.4), "0:00")
        XCTAssertEqual(MediaDuration.formatted(0.99), "0:00")
        XCTAssertEqual(MediaDuration.formatted(-5), "0:00")
    }
}
