import XCTest

/// Solution two of two, and the one that closes the gap the first leaves.
///
/// `ViewerOverlaysTests` proves the pause-playback rule is internally
/// consistent: every field it has is registered, and every registered field
/// blocks. What it cannot see is a `.sheet` or `.alert` added to the viewer
/// that was never given a field in the first place — which is exactly the
/// mistake that has now shipped twice.
///
/// Nothing in Swift's type system catches that, so this reads the source
/// instead. It is deliberately crude: it counts presentation modifiers in
/// `FullScreenPhotoView.swift` and fails if the number moves. A failure is
/// not "you did something wrong" — it is "you added or removed something
/// that covers the viewer, so decide whether it must pause video, then
/// update the count."
///
/// Lives in the package tests rather than the app tests for one practical
/// reason: these run with the repository on disk, so `#filePath` can find
/// the sources. The app's tests run on a simulator, where the repository
/// does not exist.
final class ViewerPresentationTripwireTests: XCTestCase {
    /// Modifiers that put something over the viewer.
    private static let presentationModifiers = [
        ".sheet(",
        ".alert(",
        ".confirmationDialog(",
        ".fullScreenCover(",
    ]

    /// What the file contains today, counted and accounted for:
    ///
    /// - 1 `.confirmationDialog` — "Delete this item?"
    /// - 2 `.sheet` — the share sheet and the info panel
    /// - 2 `.alert` — "Couldn't Delete" and "Couldn't Share"
    /// - 1 `.confirmationDialog` inside `MemoryInfoSheet`, a *different*
    ///   view presented within the info sheet, already covered by the
    ///   `infoSheet` field rather than needing one of its own.
    ///
    /// Five of those six are the viewer's own, which is
    /// `ViewerOverlays.presentationCount`.
    private static let expectedTotal = 6
    private static let accountedForByNestedView = 1

    private func repositoryRoot(file: StaticString = #filePath) -> URL {
        // .../Tests/TimeCapsuleCoreTests/<this file>
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func viewerSource() throws -> String {
        let url = repositoryRoot()
            .appendingPathComponent("TimeCapsule/Features/Gallery/FullScreenPhotoView.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Viewer source not found at \(url.path); repository layout changed.")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testPresentationModifierCountHasNotDrifted() throws {
        let source = try viewerSource()
        var counts: [String: Int] = [:]
        var total = 0
        for modifier in Self.presentationModifiers {
            let n = source.components(separatedBy: modifier).count - 1
            counts[modifier] = n
            total += n
        }

        XCTAssertEqual(
            total,
            Self.expectedTotal,
            """
            The number of things that can cover the full-screen viewer \
            changed (found \(total), expected \(Self.expectedTotal)): \
            \(counts.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value)" }.joined(separator: " ")).

            If you ADDED one: decide whether a video must pause while it is \
            on screen. It almost certainly must — a video playing audibly \
            under an alert has shipped twice. Add a field to ViewerOverlays, \
            fill it in at the construction site in FullScreenPhotoView, and \
            raise both this count and ViewerOverlays.presentationCount.

            If you REMOVED one: drop its field and lower both counts.
            """
        )
    }

    /// The viewer's own presentations, excluding the one nested inside
    /// `MemoryInfoSheet`, must match the fields registered for them.
    func testViewerPresentationsMatchTheRegisteredOverlayCount() throws {
        let overlaysURL = repositoryRoot()
            .appendingPathComponent("TimeCapsule/Features/Gallery/ViewerOverlays.swift")
        guard FileManager.default.fileExists(atPath: overlaysURL.path) else {
            throw XCTSkip("ViewerOverlays source not found; repository layout changed.")
        }
        let overlaysSource = try String(contentsOf: overlaysURL, encoding: .utf8)

        // Read the declared number straight out of the source, so this test
        // cannot pass by agreeing with a stale copy of it.
        let marker = "static let presentationCount = "
        guard let range = overlaysSource.range(of: marker) else {
            return XCTFail("ViewerOverlays no longer declares `presentationCount`.")
        }
        let digits = overlaysSource[range.upperBound...].prefix { $0.isNumber }
        guard let declared = Int(digits) else {
            return XCTFail("Could not read `presentationCount` from ViewerOverlays.")
        }

        XCTAssertEqual(
            declared,
            Self.expectedTotal - Self.accountedForByNestedView,
            """
            ViewerOverlays.presentationCount says \(declared), but the viewer \
            source has \(Self.expectedTotal - Self.accountedForByNestedView) \
            presentation modifiers of its own. One of the two is out of date.
            """
        )
    }
}
