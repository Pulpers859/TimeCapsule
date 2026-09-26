import Foundation
import XCTest
@testable import TimeCapsuleCore

final class WidgetPhotoFramingTests: XCTestCase {
    /// The wide tile, in points.
    private let wideWidth = 338.0
    private let wideHeight = 158.0

    private func wide(_ imageWidth: Double, _ imageHeight: Double) throws -> WidgetPhotoFraming.Frame {
        try XCTUnwrap(
            WidgetPhotoFraming.frame(
                imageWidth: imageWidth,
                imageHeight: imageHeight,
                tileWidth: wideWidth,
                tileHeight: wideHeight,
                maxZoom: WidgetPhotoFraming.wideMaxZoom
            )
        )
    }

    /// The complaint that prompted this: a fitted portrait covered a third
    /// of the wide tile. It should now cover about half.
    func testPortraitInTheWideTileIsWiderThanAFit() throws {
        let frame = try wide(3, 4)
        let fittedWidth = wideHeight * 3 / 4
        XCTAssertEqual(frame.width, fittedWidth * 1.5, accuracy: 0.001)
        XCTAssertGreaterThan(frame.width / wideWidth, 0.5)
        XCTAssertFalse(frame.coversTile, "A portrait must not be cropped to a band.")
    }

    /// Two-thirds of a portrait's height stays in view.
    func testPortraitKeepsTwoThirdsOfItsHeight() throws {
        let frame = try wide(3, 4)
        XCTAssertEqual(wideHeight / frame.height, 1 / 1.5, accuracy: 0.001)
    }

    /// Cropped more from the bottom than the top, so heads survive.
    func testPortraitCropFavoursTheTop() throws {
        let frame = try wide(3, 4)
        let top = frame.centerY - frame.height / 2
        let bottom = frame.centerY + frame.height / 2
        let croppedTop = -top
        let croppedBottom = bottom - wideHeight
        XCTAssertGreaterThan(croppedTop, 0)
        XCTAssertGreaterThan(croppedBottom, croppedTop)
        XCTAssertEqual(croppedTop / (croppedTop + croppedBottom), WidgetPhotoFraming.topBias, accuracy: 0.001)
        XCTAssertEqual(frame.centerX, wideWidth / 2, accuracy: 0.001)
    }

    /// Ordinary landscapes just fill: stopping a few points short would
    /// leave slivers of blur down both sides.
    func testOrdinaryLandscapesFillTheWideTile() throws {
        for (w, h) in [(4.0, 3.0), (3.0, 2.0), (16.0, 9.0)] {
            let frame = try wide(w, h)
            XCTAssertTrue(frame.coversTile, "\(w):\(h) should fill")
            XCTAssertEqual(frame.width, wideWidth, accuracy: 0.001)
        }
    }

    func testSquareZoomsButDoesNotFill() throws {
        let frame = try wide(1, 1)
        XCTAssertEqual(frame.width, wideHeight * 1.5, accuracy: 0.001)
        XCTAssertFalse(frame.coversTile)
    }

    /// A panorama wider than the tile fits by width and gets zoomed the
    /// other way; it is never stretched out of shape.
    func testAspectRatioIsAlwaysKept() throws {
        for (w, h) in [(3.0, 4.0), (4.0, 3.0), (1.0, 1.0), (6.0, 1.0), (9.0, 16.0)] {
            let frame = try wide(w, h)
            XCTAssertEqual(frame.width / frame.height, w / h, accuracy: 0.0001)
        }
    }

    func testNeverZoomsPastTheFill() throws {
        for (w, h) in [(3.0, 4.0), (4.0, 3.0), (1.0, 1.0), (6.0, 1.0)] {
            let frame = try wide(w, h)
            let fill = max(wideWidth / w, wideHeight / h)
            XCTAssertLessThanOrEqual(frame.width, w * fill + 0.001)
        }
    }

    /// The small tile always fills, whatever arrives.
    func testUnlimitedZoomAlwaysFills() throws {
        for (w, h) in [(3.0, 4.0), (4.0, 3.0), (1.0, 1.0)] {
            let frame = try XCTUnwrap(
                WidgetPhotoFraming.frame(
                    imageWidth: w, imageHeight: h,
                    tileWidth: 158, tileHeight: 158,
                    maxZoom: .infinity
                )
            )
            XCTAssertTrue(frame.coversTile)
        }
    }

    func testDegenerateSizesReturnNil() {
        XCTAssertNil(WidgetPhotoFraming.frame(imageWidth: 0, imageHeight: 4, tileWidth: 338, tileHeight: 158, maxZoom: 1.5))
        XCTAssertNil(WidgetPhotoFraming.frame(imageWidth: 3, imageHeight: 4, tileWidth: 0, tileHeight: 158, maxZoom: 1.5))
    }
}
