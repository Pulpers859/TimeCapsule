import XCTest

/// Per-page viewer state must be reset in exactly one place.
///
/// The full-screen viewer holds two kinds of state: state about the viewer
/// (is a sheet up, is a delete in flight) and state about the one memory on
/// screen (is it zoomed, is its scrubber held, is a share being prepared,
/// what is its place name). The second kind has to be cleared whenever the
/// memory on screen changes, and it used to be cleared by hand in four
/// different places, each clearing a different subset.
///
/// The differences were bugs, not intent. The "Feature Less Often" path
/// cleared the zoom flag and not the scrubbing flag — and a stuck
/// `isVideoScrubbing` disables the page gesture, so excluding a video while
/// its scrubber was held left the pager unswipeable with no way out but
/// closing the viewer.
///
/// So this guards the arrangement rather than the behaviour, which is all CI
/// can reach: the app's own tests need a simulator and a photo library.
///
/// A failure here means a reset has been written somewhere other than
/// `resetPerPageState()`. The fix is to move it into that function, not to
/// raise the number.
final class ViewerPerPageStateTests: XCTestCase {
    /// State belonging to the memory on screen, with the value that clears it.
    private static let perPageResets = [
        "isCurrentAssetZoomed = false",
        "isVideoScrubbing = false",
    ]

    private func viewerSource(file: StaticString = #filePath) throws -> String {
        // .../Tests/TimeCapsuleCoreTests/<this file>
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent(
            "TimeCapsule/Features/Gallery/FullScreenPhotoView.swift"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Viewer source not found at \(url.path); repository layout changed.")
        }
        let source = try String(contentsOf: url, encoding: .utf8)

        // Comment lines are dropped for the reason the sibling tripwire
        // documents: this reads text, not syntax, so prose describing a reset
        // would otherwise count as one. Property declarations are dropped too
        // — `@State private var isCurrentAssetZoomed = false` is the initial
        // value, not a reset.
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                let line = $0.trimmingCharacters(in: .whitespaces)
                return !line.hasPrefix("//") && !line.contains("@State")
            }
            .joined(separator: "\n")
    }

    func testPerPageStateIsResetInExactlyOnePlace() throws {
        let source = try viewerSource()
        for reset in Self.perPageResets {
            let count = source.components(separatedBy: reset).count - 1
            XCTAssertEqual(
                count,
                1,
                """
                `\(reset)` appears \(count) times in FullScreenPhotoView.swift; \
                it should appear once, inside resetPerPageState(). Resetting \
                page state anywhere else is how these fell out of step before: \
                one path cleared the zoom flag and not the scrubbing flag, and \
                a stuck scrubbing flag disables the page swipe entirely.
                """
            )
        }
    }

    /// The reset has to be driven by *which memory* is on screen, not by its
    /// position in the list. A delete can leave the index untouched while a
    /// different photo slides into it, and an earlier delete can change the
    /// index while the photo on screen does not.
    func testResetIsKeyedOnTheAssetIdentifierNotTheIndex() throws {
        let source = try viewerSource()
        XCTAssertTrue(
            source.contains(".onChange(of: currentAssetIdentifier)"),
            "Per-page state must be reset when the displayed asset's identity changes."
        )
        XCTAssertEqual(
            source.components(separatedBy: "resetPerPageState()").count - 1,
            2,
            """
            Expected resetPerPageState to be declared once and called once. \
            More than one caller means the single-reset-point guarantee is gone.
            """
        )
    }
}
