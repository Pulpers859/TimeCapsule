import XCTest
@testable import TimeCapsuleCore

final class PhotoEXIFTests: XCTestCase {
    func testEverythingEmptyFailsInit() {
        XCTAssertNil(PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: nil, exposureTime: nil, iso: nil, focalLength35mm: nil
        ))
    }

    func testBlankStringsCountAsEmpty() {
        XCTAssertNil(PhotoEXIF(
            make: "  ", model: "", lensModel: "   ",
            fNumber: nil, exposureTime: nil, iso: nil, focalLength35mm: nil
        ))
    }

    func testZeroOrNegativeNumbersAreTreatedAsMissing() {
        // A malformed or placeholder EXIF block sometimes reports 0 rather
        // than omitting the tag; showing "ƒ/0" would be actively misleading.
        let exif = PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: 0, exposureTime: -1, iso: 0, focalLength35mm: 0
        )
        XCTAssertNil(exif)
    }

    func testModelAlreadyContainingMakeIsNotDuplicated() {
        // Some manufacturers fold the make into Model themselves.
        let exif = PhotoEXIF(
            make: "Canon", model: "Canon EOS R5", lensModel: nil,
            fNumber: nil, exposureTime: nil, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(exif?.cameraModel, "Canon EOS R5")
    }

    func testMakeIsPrependedWhenModelDoesNotIncludeIt() {
        // Apple's own EXIF: Make "Apple", Model "iPhone 15 Pro" — no overlap,
        // so both belong in the display string.
        let exif = PhotoEXIF(
            make: "Apple", model: "iPhone 15 Pro", lensModel: nil,
            fNumber: nil, exposureTime: nil, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(exif?.cameraModel, "Apple iPhone 15 Pro")
    }

    func testMakeAloneIsUsedWhenModelIsMissing() {
        let exif = PhotoEXIF(
            make: "Apple", model: nil, lensModel: nil,
            fNumber: nil, exposureTime: nil, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(exif?.cameraModel, "Apple")
    }

    func testApertureDisplayDropsTrailingZero() {
        let exif = PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: 8, exposureTime: nil, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(exif?.apertureDisplay, "\u{0192}/8")
    }

    func testApertureDisplayKeepsOneDecimalPlace() {
        let exif = PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: 1.8, exposureTime: nil, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(exif?.apertureDisplay, "\u{0192}/1.8")
    }

    func testShutterSpeedUnderOneSecondIsAFraction() {
        let exif = PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: nil, exposureTime: 1.0 / 125.0, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(exif?.shutterSpeedDisplay, "1/125 s")
    }

    func testShutterSpeedOfOneSecondOrLongerIsNotAFraction() {
        let exif = PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: nil, exposureTime: 2, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(exif?.shutterSpeedDisplay, "2 s")
    }

    func testISODisplay() {
        let exif = PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: nil, exposureTime: nil, iso: 400, focalLength35mm: nil
        )
        XCTAssertEqual(exif?.isoDisplay, "ISO 400")
    }

    func testFocalLengthDisplay() {
        let exif = PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: nil, exposureTime: nil, iso: nil, focalLength35mm: 26
        )
        XCTAssertEqual(exif?.focalLengthDisplay, "26 mm")
    }

    func testOnlyLensModelStillProducesAValue() {
        let exif = PhotoEXIF(
            make: nil, model: nil, lensModel: "  iPhone 15 Pro back camera 6.765mm f/1.78  ",
            fNumber: nil, exposureTime: nil, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(exif?.lensModel, "iPhone 15 Pro back camera 6.765mm f/1.78")
        XCTAssertNil(exif?.apertureDisplay)
    }
}
