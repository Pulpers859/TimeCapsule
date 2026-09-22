import XCTest
@testable import TimeCapsule

/// Solution one of two for a mistake that has shipped twice: a new modal
/// added to the viewer without being added to the rule that pauses video.
///
/// These check the rule is *internally* complete — that every field the type
/// has is registered, and every registered field actually blocks. They
/// cannot see a modal that was never added as a field at all; that is what
/// the source-level tripwire in the package tests is for.
final class ViewerOverlaysTests: XCTestCase {
    private func none() -> ViewerOverlays {
        ViewerOverlays(
            deleteConfirmation: false,
            shareSheet: false,
            deleteFailureAlert: false,
            shareFailureAlert: false,
            infoSheet: false,
            daySheet: false,
            preparingShare: false,
            deleting: false
        )
    }

    func testNothingPresentedAllowsPlayback() {
        XCTAssertFalse(none().blocksPlayback)
    }

    /// The one that matters. Each overlay alone must stop playback — a
    /// registered field the rule ignores fails here rather than shipping.
    func testEveryOverlayOnItsOwnBlocksPlayback() {
        for keyPath in ViewerOverlays.all {
            var overlays = none()
            overlays[keyPath: keyPath] = true
            XCTAssertTrue(
                overlays.blocksPlayback,
                "An overlay is registered in `all` but does not block playback: \(keyPath)"
            )
        }
    }

    /// Catches `all` going stale. Reflection sees the real stored fields, so
    /// a field added without being registered fails here.
    func testEveryStoredFieldIsRegistered() {
        let stored = Mirror(reflecting: none()).children.compactMap(\.label)
        XCTAssertEqual(
            stored.count,
            ViewerOverlays.all.count,
            """
            ViewerOverlays has \(stored.count) stored fields but \
            \(ViewerOverlays.all.count) are registered in `all`. \
            Fields found: \(stored.joined(separator: ", ")). \
            Add the missing one to `all` so it blocks playback.
            """
        )
    }

    func testAllFieldsAreBooleansSoNoneIsSilentlySkipped() {
        for child in Mirror(reflecting: none()).children {
            XCTAssertTrue(
                child.value is Bool,
                "ViewerOverlays.\(child.label ?? "?") is not a Bool; `all` cannot reach it."
            )
        }
    }

    /// Guards the number the source-level tripwire compares against.
    func testPresentationCountIsNotMoreThanTheFieldsAvailable() {
        XCTAssertLessThanOrEqual(ViewerOverlays.presentationCount, ViewerOverlays.all.count)
    }
}
