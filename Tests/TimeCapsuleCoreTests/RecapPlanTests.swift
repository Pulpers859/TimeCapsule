import XCTest
@testable import TimeCapsuleCore

final class RecapPlanTests: XCTestCase {
    func testSamplingPreservesFirstLastAndMaximum() {
        let indices = RecapPlan.sampleIndices(itemCount: 100, maximum: 30)
        XCTAssertEqual(indices.count, 30)
        XCTAssertEqual(indices.first, 0)
        XCTAssertEqual(indices.last, 99)
        XCTAssertEqual(Set(indices).count, indices.count)
    }

    func testShortRecapKeepsEveryItemInOrder() {
        XCTAssertEqual(RecapPlan.sampleIndices(itemCount: 4, maximum: 30), [0, 1, 2, 3])
    }

    // MARK: - Motion

    func testEasingPinsBothEndsAndMidpoint() {
        XCTAssertEqual(RecapPlan.easedProgress(0), 0, accuracy: 0.0001)
        XCTAssertEqual(RecapPlan.easedProgress(1), 1, accuracy: 0.0001)
        XCTAssertEqual(RecapPlan.easedProgress(0.5), 0.5, accuracy: 0.0001)
    }

    func testEasingClampsOutOfRangeProgress() {
        XCTAssertEqual(RecapPlan.easedProgress(-2), 0, accuracy: 0.0001)
        XCTAssertEqual(RecapPlan.easedProgress(4), 1, accuracy: 0.0001)
    }

    func testEasingStartsAndEndsSlowerThanLinear() {
        // The whole point of easing: early progress lags a linear ramp and
        // late progress leads it. A linear curve would fail both of these.
        XCTAssertLessThan(RecapPlan.easedProgress(0.2), 0.2)
        XCTAssertGreaterThan(RecapPlan.easedProgress(0.8), 0.8)
    }

    func testZoomFactorTravelsBetweenItsEndpoints() {
        XCTAssertEqual(RecapPlan.zoomFactor(from: 1, to: 1.08, progress: 0), 1, accuracy: 0.0001)
        XCTAssertEqual(RecapPlan.zoomFactor(from: 1, to: 1.08, progress: 1), 1.08, accuracy: 0.0001)
        XCTAssertEqual(RecapPlan.zoomFactor(from: 1.08, to: 1, progress: 1), 1, accuracy: 0.0001)
    }

    func testUnityZoomLeavesTheFrameExactlyWhereItWas() {
        let base = RecapPlan.Rect(x: 0, y: 420, width: 1080, height: 1080)
        XCTAssertEqual(RecapPlan.framedRect(base: base, zoom: 1), base)
    }

    func testZoomKeepsTheFocusPointFixed() {
        // The invariant the whole effect rests on: whatever the zoom, the
        // focus point must land on the same screen position. If this drifts,
        // a face-anchored push would slide off the face.
        let base = RecapPlan.Rect(x: 0, y: 420, width: 1080, height: 1080)
        for focusX in [0.0, 0.25, 0.5, 0.9, 1.0] {
            for focusY in [0.0, 0.5, 0.75, 1.0] {
                for zoom in [1.0, 1.08, 1.4, 0.8] {
                    let framed = RecapPlan.framedRect(
                        base: base,
                        zoom: zoom,
                        focusX: focusX,
                        focusY: focusY
                    )
                    XCTAssertEqual(
                        framed.x + framed.width * focusX,
                        base.x + base.width * focusX,
                        accuracy: 0.0001,
                        "focus drifted horizontally at zoom \(zoom)"
                    )
                    XCTAssertEqual(
                        framed.y + framed.height * focusY,
                        base.y + base.height * focusY,
                        accuracy: 0.0001,
                        "focus drifted vertically at zoom \(zoom)"
                    )
                }
            }
        }
    }

    func testZoomGrowsTheFrame() {
        let base = RecapPlan.Rect(x: 0, y: 0, width: 1080, height: 1920)
        let framed = RecapPlan.framedRect(base: base, zoom: 1.08)
        XCTAssertEqual(framed.width, 1080 * 1.08, accuracy: 0.0001)
        XCTAssertEqual(framed.height, 1920 * 1.08, accuracy: 0.0001)
    }

    func testFocusOutsideTheFrameIsClamped() {
        let base = RecapPlan.Rect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(
            RecapPlan.framedRect(base: base, zoom: 1.2, focusX: 5, focusY: -3),
            RecapPlan.framedRect(base: base, zoom: 1.2, focusX: 1, focusY: 0)
        )
    }

    func testInteriorSlidesAreVisibleThroughBothCrossfades() {
        let hold = 43
        let fade = 12
        // First and last slides only ever fade on one side.
        XCTAssertEqual(
            RecapPlan.visibleFrameCount(slideIndex: 0, slideCount: 5, holdFrames: hold, fadeFrames: fade),
            hold + fade
        )
        XCTAssertEqual(
            RecapPlan.visibleFrameCount(slideIndex: 4, slideCount: 5, holdFrames: hold, fadeFrames: fade),
            hold + fade
        )
        XCTAssertEqual(
            RecapPlan.visibleFrameCount(slideIndex: 2, slideCount: 5, holdFrames: hold, fadeFrames: fade),
            hold + fade * 2
        )
    }

    func testVisibleFrameCountRejectsOutOfRangeSlides() {
        XCTAssertEqual(
            RecapPlan.visibleFrameCount(slideIndex: 9, slideCount: 3, holdFrames: 43, fadeFrames: 12),
            0
        )
        XCTAssertEqual(
            RecapPlan.visibleFrameCount(slideIndex: -1, slideCount: 3, holdFrames: 43, fadeFrames: 12),
            0
        )
    }

    /// The encoder allocates its progress denominator from this arithmetic, so
    /// a mismatch between it and the frame loop would show as a progress bar
    /// that never reaches 1 or overshoots it.
    func testTotalFrameBudgetMatchesPerSlideVisibility() {
        let slideCount = 6
        let hold = 43
        let fade = 12
        let totalAppends = slideCount * hold + (slideCount - 1) * fade
        let summedVisibility = (0..<slideCount).reduce(0) { running, index in
            running + RecapPlan.visibleFrameCount(
                slideIndex: index,
                slideCount: slideCount,
                holdFrames: hold,
                fadeFrames: fade
            )
        }
        // Every crossfade frame shows two slides, so summed visibility counts
        // those frames twice.
        XCTAssertEqual(summedVisibility - (slideCount - 1) * fade, totalAppends)
    }
}
