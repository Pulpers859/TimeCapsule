import XCTest

/// The gallery and the widget must count the same photos.
///
/// They did not. On the same day, with the same library and nothing
/// excluded, the widget said "28 memories" while the gallery let you page
/// through 29. The cause was not a mistake in either number: it was that
/// there were two of them. `yearGroups` fetched on dates and decided what
/// counted in Swift; `count` pushed an extra predicate into the fetch and
/// trusted `PHFetchResult.count` without examining an asset. Two rules, kept
/// in step by hand, until they weren't.
///
/// `MemoryLibrary` now has one rule, in `enumerateMemories`, and both
/// callers walk it. This guards that arrangement rather than the numbers it
/// produces, because the numbers need a photo library and CI has none.
///
/// A failure here is not "you did something wrong". It is "a second way of
/// deciding what counts as a memory has appeared — make sure both answers
/// still come from one place."
///
/// Lives in the package tests because those run with the repository on disk,
/// so `#filePath` can find the source. The app's tests run on a simulator,
/// where it does not exist.
final class MemoryCountSourceTests: XCTestCase {
    private func librarySource(file: StaticString = #filePath) throws -> String {
        // .../Tests/TimeCapsuleCoreTests/<this file>
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = root
            .appendingPathComponent("AtticShared")
            .appendingPathComponent("MemoryLibrary.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }

    /// One fetch, in the shared function. A second one anywhere in this file
    /// is a second definition of what counts.
    func testOnlyOneFetchDecidesMembership() throws {
        let source = try librarySource()
        let fetches = source.components(separatedBy: "PHAsset.fetchAssets(").count - 1
        XCTAssertEqual(
            fetches,
            1,
            """
            MemoryLibrary.swift performs \(fetches) asset fetches; it should \
            perform exactly one, inside enumerateMemories. A second fetch is \
            a second rule for what counts as a memory, which is how the \
            gallery and the widget came to disagree.
            """
        )
    }

    /// Both public entry points go through the shared function.
    func testBothCountersUseTheSharedEnumeration() throws {
        let source = try librarySource()
        let calls = source.components(separatedBy: "enumerateMemories(").count - 1
        XCTAssertEqual(
            calls,
            3,
            """
            Expected enumerateMemories to be declared once and called by \
            both yearGroups and count — three occurrences. Found \(calls).
            """
        )
    }

    /// The media-type test belongs in the shared function, where both
    /// callers get it. It used to sit in a predicate only `count` applied,
    /// which is the specific divergence that produced the off-by-one.
    func testMediaTypeFilterIsNotBackInAPredicate() throws {
        let source = try librarySource()
        XCTAssertFalse(
            source.contains("mediaTypePredicate"),
            """
            A media-type predicate is back in MemoryLibrary.swift. Filtering \
            media type in the fetch for one caller and in Swift for the other \
            is what made the widget's count and the gallery's count disagree.
            """
        )
        XCTAssertEqual(
            source.components(separatedBy: "asset.mediaType == .image").count - 1,
            1,
            "The media-type test should appear once, in enumerateMemories."
        )
    }
}
