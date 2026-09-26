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

    // MARK: - crop

    private func wideCrop(_ w: Double, _ h: Double) throws -> WidgetPhotoFraming.Crop {
        try XCTUnwrap(
            WidgetPhotoFraming.crop(
                imageWidth: w, imageHeight: h,
                tileWidth: wideWidth, tileHeight: wideHeight,
                maxZoom: WidgetPhotoFraming.wideMaxZoom
            )
        )
    }

    /// The user's condition for this change: a landscape in the wide tile
    /// must still fill it edge to edge, with no empty space.
    func testCroppedLandscapeStillFillsTheWideTile() throws {
        for (w, h) in [(4032.0, 3024.0), (3000.0, 2000.0), (1920.0, 1080.0)] {
            let crop = try wideCrop(w, h)
            XCTAssertTrue(crop.coversTile)
            XCTAssertEqual(crop.placement.x, 0, accuracy: 0.0001)
            XCTAssertEqual(crop.placement.y, 0, accuracy: 0.0001)
            XCTAssertEqual(crop.placement.width, 1, accuracy: 0.0001)
            XCTAssertEqual(crop.placement.height, 1, accuracy: 0.0001)
        }
    }

    /// Cropping must not change the picture: the kept part has the shape of
    /// the space it is drawn into, so nothing is stretched.
    func testCropKeepsTheShapeOfWhereItIsDrawn() throws {
        for (w, h) in [(4032.0, 3024.0), (3024.0, 4032.0), (1000.0, 1000.0), (6000.0, 1000.0)] {
            let crop = try wideCrop(w, h)
            let sourceAspect = crop.source.width / crop.source.height
            let drawnAspect = (crop.placement.width * wideWidth) / (crop.placement.height * wideHeight)
            XCTAssertEqual(sourceAspect, drawnAspect, accuracy: 0.0001, "\(w)x\(h)")
        }
    }

    /// What is kept is exactly what the uncropped framing shows.
    func testCropMatchesTheUncroppedFraming() throws {
        let frame = try wide(3024, 4032)
        let crop = try wideCrop(3024, 4032)
        // Portrait: full width of the photo, full height of the tile.
        XCTAssertEqual(crop.placement.width * wideWidth, frame.width, accuracy: 0.001)
        XCTAssertEqual(crop.placement.height, 1, accuracy: 0.0001)
        XCTAssertEqual(crop.source.width, 3024, accuracy: 0.01)
        // Two-thirds of the height, 30% of the cut from the top.
        XCTAssertEqual(crop.source.height, 4032 / 1.5, accuracy: 0.01)
        XCTAssertEqual(crop.source.y, (4032 - 4032 / 1.5) * WidgetPhotoFraming.topBias, accuracy: 0.01)
    }

    func testCropNeverReachesOutsideThePhoto() throws {
        for (w, h) in [(4032.0, 3024.0), (3024.0, 4032.0), (1000.0, 1000.0), (6000.0, 1000.0), (1080.0, 1920.0)] {
            let crop = try wideCrop(w, h)
            XCTAssertGreaterThanOrEqual(crop.source.x, -0.0001)
            XCTAssertGreaterThanOrEqual(crop.source.y, -0.0001)
            XCTAssertLessThanOrEqual(crop.source.x + crop.source.width, w + 0.0001)
            XCTAssertLessThanOrEqual(crop.source.y + crop.source.height, h + 0.0001)
        }
    }

    /// The saving is real: a landscape filling the wide tile drops the
    /// third of the photo that was always clipped.
    func testLandscapeCropDropsTheHiddenPart() throws {
        let crop = try wideCrop(4032, 3024)
        let kept = (crop.source.width * crop.source.height) / (4032 * 3024)
        XCTAssertLessThan(kept, 0.7)
    }

    /// The whole-photo placement, for a photo drawn uncropped, lands the
    /// visible part in the same place.
    func testFullPlacementAgreesWithTheCrop() throws {
        let crop = try wideCrop(3024, 4032)
        let full = crop.fullPlacement
        XCTAssertLessThan(full.y, 0, "The top overflows and is clipped.")
        XCTAssertEqual(full.x, crop.placement.x, accuracy: 0.0001)
        let visibleTopInPhoto = (0 - full.y) / full.height * 4032
        XCTAssertEqual(visibleTopInPhoto, crop.source.y, accuracy: 0.01)
    }

    func testSmallTileCropIsASquareFavouringTheTop() throws {
        let crop = try XCTUnwrap(
            WidgetPhotoFraming.crop(
                imageWidth: 3024, imageHeight: 4032,
                tileWidth: 474, tileHeight: 474,
                maxZoom: .infinity
            )
        )
        XCTAssertTrue(crop.coversTile)
        XCTAssertEqual(crop.source.width, crop.source.height, accuracy: 0.01)
        XCTAssertEqual(crop.source.y, (4032 - 3024) * WidgetPhotoFraming.topBias, accuracy: 0.01)
    }
}

