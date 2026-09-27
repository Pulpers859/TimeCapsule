import Foundation
import XCTest
@testable import TimeCapsuleCore

final class CaptureClockTests: XCTestCase {
    /// 2025-09-26 16:11:00 UTC — the moment of the Nikon photo seen on
    /// device: 11:11 AM on a camera set to UTC-5, 12:11 PM on a phone in
    /// daylight time (UTC-4).
    private let moment = Date(timeIntervalSince1970: 1_758_903_060)

    private func clockReading(_ date: Date, in zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d:%02d:%02d %02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    func testTheMomentIsWhatTheDeviceCaseSays() throws {
        let utcMinus5 = try XCTUnwrap(TimeZone(secondsFromGMT: -5 * 3600))
        XCTAssertEqual(clockReading(moment, in: utcMinus5), "2025:09:26 11:11:00")
    }

    /// The case seen on device: the camera's zone is used, so the time reads
    /// 11:11 as it does in Photos, not 12:11.
    func testTheCamerasZoneIsUsedWhenTheFileAgreesWithTheLibrary() throws {
        let zone = try XCTUnwrap(
            CaptureClock.recordedTimeZone(
                dateTimeOriginal: "2025:09:26 11:11:00",
                offset: "-05:00",
                creationDate: moment
            )
        )
        XCTAssertEqual(zone.secondsFromGMT(for: moment), -5 * 3600)
        XCTAssertEqual(clockReading(moment, in: zone), "2025:09:26 11:11:00")
    }

    /// Changed in Photos with Adjust Date & Time: the library moved, the
    /// file did not, and its zone no longer describes the photo's time.
    func testAnAdjustedDateFallsBackToThePhonesZone() {
        XCTAssertNil(
            CaptureClock.recordedTimeZone(
                dateTimeOriginal: "2025:09:26 11:11:00",
                offset: "-05:00",
                creationDate: moment.addingTimeInterval(3 * 3600)
            )
        )
    }

    func testSubSecondDifferencesStillAgree() {
        XCTAssertNotNil(
            CaptureClock.recordedTimeZone(
                dateTimeOriginal: "2025:09:26 11:11:00",
                offset: "-05:00",
                creationDate: moment.addingTimeInterval(0.8)
            )
        )
    }

    func testMissingFieldsFallBack() {
        XCTAssertNil(CaptureClock.recordedTimeZone(dateTimeOriginal: nil, offset: "-05:00", creationDate: moment))
        XCTAssertNil(CaptureClock.recordedTimeZone(dateTimeOriginal: "2025:09:26 11:11:00", offset: nil, creationDate: moment))
        XCTAssertNil(CaptureClock.recordedTimeZone(dateTimeOriginal: "garbage", offset: "-05:00", creationDate: moment))
    }

    func testOffsetsParse() {
        XCTAssertEqual(CaptureClock.offsetSeconds("-05:00"), -18_000)
        XCTAssertEqual(CaptureClock.offsetSeconds("+05:30"), 19_800)
        XCTAssertEqual(CaptureClock.offsetSeconds("+0000"), 0)
        XCTAssertEqual(CaptureClock.offsetSeconds(" +09:00 "), 32_400)
    }

    func testMalformedOffsetsAreRejected() {
        XCTAssertNil(CaptureClock.offsetSeconds("05:00"))
        XCTAssertNil(CaptureClock.offsetSeconds("-5"))
        XCTAssertNil(CaptureClock.offsetSeconds("+25:00"))
        XCTAssertNil(CaptureClock.offsetSeconds("+05:75"))
        XCTAssertNil(CaptureClock.offsetSeconds(""))
    }

    func testClockReadingsParse() throws {
        let date = try XCTUnwrap(CaptureClock.naiveDate("2025:09:26 11:11:00"))
        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        XCTAssertEqual(clockReading(date, in: utc), "2025:09:26 11:11:00")
        XCTAssertNil(CaptureClock.naiveDate("2025:13:26 11:11:00"))
        XCTAssertNil(CaptureClock.naiveDate("2025-09-26"))
        XCTAssertNil(CaptureClock.naiveDate("    :  :     :  :  "))
    }
}
