import XCTest
@testable import TimeCapsuleCore

final class LivePhotoPlaybackTests: XCTestCase {
    private func update(
        _ state: inout LivePhotoPlayback.State,
        request: Int = 0,
        arrived: Bool = false,
        hasMotion: Bool = false,
        canPlay: Bool = true
    ) -> LivePhotoPlayback.Action {
        LivePhotoPlayback.update(
            &state,
            request: request,
            motionArrived: arrived,
            hasMotion: hasMotion,
            canPlay: canPlay
        )
    }

    /// A page built after the LIVE button was last pressed must not play on
    /// arriving: the count it sees first is history, not a press.
    func testAPressFromBeforeThePageExistedIsNotReplayed() {
        var state = LivePhotoPlayback.State()
        XCTAssertEqual(update(&state, request: 3, hasMotion: true), .nothing)
        XCTAssertEqual(update(&state, request: 3, hasMotion: true), .nothing)
    }

    func testAPressPlaysTheWholeLivePhoto() {
        var state = LivePhotoPlayback.State()
        _ = update(&state, request: 0, hasMotion: true)
        XCTAssertEqual(update(&state, request: 1, hasMotion: true), .full)
        // Asked again with nothing changed, as SwiftUI does: no replay.
        XCTAssertEqual(update(&state, request: 1, hasMotion: true), .nothing)
    }

    /// Seen on device: playing on arrival read as the photo moving on its
    /// own. It moves only when asked.
    func testArrivingPlaysNothing() {
        var state = LivePhotoPlayback.State()
        _ = update(&state)
        XCTAssertEqual(update(&state, arrived: true, hasMotion: true), .nothing)
        XCTAssertEqual(update(&state, hasMotion: true), .nothing)
    }

    /// Pressed while the motion was still downloading: it plays in full as
    /// soon as it lands.
    func testAPressBeforeTheMotionLoadsPlaysWhenItArrives() {
        var state = LivePhotoPlayback.State()
        _ = update(&state, request: 0)
        XCTAssertEqual(update(&state, request: 1), .nothing)
        XCTAssertEqual(update(&state, request: 1, arrived: true, hasMotion: true), .full)
        XCTAssertFalse(state.isFullPending)
    }

    /// A sheet over the viewer, or swiping away, stops it and forgets a
    /// press that had not played yet.
    func testBlockedStopsAndForgetsAWaitingPress() {
        var state = LivePhotoPlayback.State()
        _ = update(&state, request: 0)
        _ = update(&state, request: 1)
        XCTAssertTrue(state.isFullPending)
        XCTAssertEqual(update(&state, request: 1, canPlay: false), .stop)
        XCTAssertFalse(state.isFullPending)
        XCTAssertEqual(update(&state, request: 1, arrived: true, hasMotion: true), .nothing)
    }

    /// A press while blocked is used up, not saved for later.
    func testAPressWhileBlockedDoesNotPlayLater() {
        var state = LivePhotoPlayback.State()
        _ = update(&state, request: 0, hasMotion: true)
        XCTAssertEqual(update(&state, request: 1, hasMotion: true, canPlay: false), .stop)
        XCTAssertEqual(update(&state, request: 1, hasMotion: true), .nothing)
    }
}
