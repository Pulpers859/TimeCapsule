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

    func testCorporateSuffixInMakeStillCountsAsAMatch() {
        // Nikon's real EXIF. Testing the whole make against the model finds
        // no overlap and yields "NIKON CORPORATION NIKON D850"; only the
        // first word of the make is a fair comparison.
        let exif = PhotoEXIF(
            make: "NIKON CORPORATION", model: "NIKON D850", lensModel: nil,
            fNumber: nil, exposureTime: nil, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(exif?.cameraModel, "NIKON D850")
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

    func testSubSecondExposuresNeedingAFractionalDenominatorKeepOne() {
        // 0.8s is 1/1.25. Rounding the denominator printed "1/1 s" — a whole
        // different exposure. Apple's Photos shows 1/1.3 here.
        let slow = PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: nil, exposureTime: 0.8, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(slow?.shutterSpeedDisplay, "1/1.3 s")

        // 1/2.5 used to round to "1/3 s".
        let quick = PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: nil, exposureTime: 0.4, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(quick?.shutterSpeedDisplay, "1/2.5 s")
    }

    func testWholeDenominatorsStayWhole() {
        let exif = PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: nil, exposureTime: 1.0 / 8000.0, iso: nil, focalLength35mm: nil
        )
        XCTAssertEqual(exif?.shutterSpeedDisplay, "1/8000 s")
    }

    func testNonFiniteMeasurementsAreTreatedAsAbsent() {
        // An EXIF rational with a zero denominator arrives as infinity. This
        // used to pass the `> 0` check and then trap in `Int(_:)`, crashing
        // the app as the info sheet drew.
        let exif = PhotoEXIF(
            make: "Apple", model: "iPhone 15 Pro", lensModel: nil,
            fNumber: .infinity, exposureTime: .infinity, iso: nil, focalLength35mm: nil
        )
        XCTAssertNil(exif?.apertureDisplay)
        XCTAssertNil(exif?.shutterSpeedDisplay)
        XCTAssertEqual(exif?.cameraModel, "Apple iPhone 15 Pro")
    }

    func testNaNAndAbsurdMeasurementsAreTreatedAsAbsent() {
        XCTAssertNil(PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: .nan, exposureTime: 1e30, iso: nil, focalLength35mm: nil
        ))
    }

    func testVanishinglySmallExposureCannotOverflowTheDenominator() {
        // 1/1e-30 is far past Int64; the reciprocal used to be forced through
        // `Int(_:)`.
        XCTAssertNil(PhotoEXIF(
            make: nil, model: nil, lensModel: nil,
            fNumber: nil, exposureTime: 1e-30, iso: nil, focalLength35mm: nil
        ))
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
