import Foundation
import XCTest
@testable import TimeCapsuleCore

final class WidgetRotationTests: XCTestCase {
    /// Seeded, so a failure reproduces instead of flickering.
    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    // MARK: - Reservoir

    func testReservoirKeepsEverythingUnderCapacity() {
        var generator = SplitMix64(state: 1)
        var reservoir = WidgetRotation.Reservoir<Int>(capacity: 12)
        for value in 0..<5 { reservoir.offer(value, using: &generator) }
        XCTAssertEqual(reservoir.elements, [0, 1, 2, 3, 4])
    }

    func testReservoirNeverHoldsMoreThanCapacity() {
        var generator = SplitMix64(state: 2)
        var reservoir = WidgetRotation.Reservoir<Int>(capacity: 12)
        for value in 0..<300 { reservoir.offer(value, using: &generator) }
        XCTAssertEqual(reservoir.elements.count, 12)
        XCTAssertEqual(Set(reservoir.elements).count, 12, "A sample must not repeat an item.")
        XCTAssertEqual(reservoir.seen, 300)
    }

    /// The reason this exists: the old cap kept the first few by capture
    /// time, so a busy day never showed anything after its first hour.
    func testReservoirReachesPastTheFirstFewOfALongDay() {
        var generator = SplitMix64(state: 3)
        var reservoir = WidgetRotation.Reservoir<Int>(capacity: 12)
        for value in 0..<300 { reservoir.offer(value, using: &generator) }
        XCTAssertNotEqual(reservoir.elements.sorted(), Array(0..<12))
        XCTAssertTrue(reservoir.elements.contains { $0 >= 150 })
    }

    /// Every item equally likely, not just "something other than the first".
    func testReservoirIsRoughlyUniform() {
        var generator = SplitMix64(state: 4)
        var hits = [Int](repeating: 0, count: 20)
        for _ in 0..<5_000 {
            var reservoir = WidgetRotation.Reservoir<Int>(capacity: 5)
            for value in 0..<20 { reservoir.offer(value, using: &generator) }
            for kept in reservoir.elements { hits[kept] += 1 }
        }
        // Expected 1250 each (5000 × 5 / 20).
        for count in hits {
            XCTAssertEqual(Double(count), 1_250, accuracy: 150)
        }
    }

    func testZeroCapacityReservoirKeepsNothing() {
        var generator = SplitMix64(state: 5)
        var reservoir = WidgetRotation.Reservoir<Int>(capacity: 0)
        for value in 0..<10 { reservoir.offer(value, using: &generator) }
        XCTAssertTrue(reservoir.elements.isEmpty)
    }

    // MARK: - picks

    func testPicksCoverEveryYearBeforeRepeatingOne() {
        var generator = SplitMix64(state: 6)
        let years = [
            (0..<12).map { "2025-\($0)" },
            ["2024-0"],
            (0..<3).map { "2023-\($0)" }
        ]
        let three = WidgetRotation.picks(from: years, limit: 3, using: &generator)
        XCTAssertEqual(Set(three), ["2025-0", "2024-0", "2023-0"])

        // Once the one-photo year is spent, the others take turns.
        let five = WidgetRotation.picks(from: years, limit: 5, using: &generator)
        XCTAssertEqual(Set(five), ["2025-0", "2024-0", "2023-0", "2025-1", "2023-1"])
    }

    func testPicksStopAtLimitAndAtWhatExists() {
        var generator = SplitMix64(state: 7)
        let many = [(0..<12).map { $0 }, (12..<24).map { $0 }]
        XCTAssertEqual(WidgetRotation.picks(from: many, limit: 12, using: &generator).count, 12)

        let few = [[1, 2], [3]]
        XCTAssertEqual(
            WidgetRotation.picks(from: few, limit: 12, using: &generator).sorted(),
            [1, 2, 3]
        )
        XCTAssertTrue(WidgetRotation.picks(from: [[Int]](), limit: 12, using: &generator).isEmpty)
    }

    /// The order is shuffled: over many draws, the newest year does not
    /// always lead.
    func testPicksAreNotAlwaysInYearOrder() {
        var generator = SplitMix64(state: 8)
        let years = [["new"], ["mid"], ["old"]]
        var leaders = Set<String>()
        for _ in 0..<50 {
            if let first = WidgetRotation.picks(from: years, limit: 3, using: &generator).first {
                leaders.insert(first)
            }
        }
        XCTAssertEqual(leaders, ["new", "mid", "old"])
    }

    // MARK: - schedule

    func testTwelvePicksFillSixHoursAtThirtyMinutes() {
        let farBoundary = now.addingTimeInterval(24 * 3600)
        let result = WidgetRotation.schedule(Array(0..<12), from: now, dayBoundary: farBoundary)
        XCTAssertEqual(result.entries.count, 12)
        XCTAssertEqual(result.entries.map { $0.item }, Array(0..<12))
        for (index, entry) in result.entries.enumerated() {
            XCTAssertEqual(entry.date, now.addingTimeInterval(Double(index) * 1800))
        }
        XCTAssertEqual(result.reload, now.addingTimeInterval(6 * 3600))
    }

    /// A day with three photos still fills the six hours, rather than ending
    /// after ninety minutes and burning a reload.
    func testFewerPicksCycleToFillTheRotation() {
        let farBoundary = now.addingTimeInterval(24 * 3600)
        let result = WidgetRotation.schedule(["a", "b", "c"], from: now, dayBoundary: farBoundary)
        XCTAssertEqual(result.entries.count, 12)
        XCTAssertEqual(result.entries.prefix(4).map { $0.item }, ["a", "b", "c", "a"])
        XCTAssertEqual(result.reload, now.addingTimeInterval(6 * 3600))
    }

    func testASinglePickIsASingleEntry() {
        let result = WidgetRotation.schedule(["only"], from: now, dayBoundary: now.addingTimeInterval(86_400))
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.reload, now.addingTimeInterval(6 * 3600))
    }

    /// Today's photos must not be scheduled into tomorrow.
    func testNothingIsScheduledAtOrPastTheDayBoundary() {
        let boundary = now.addingTimeInterval(95 * 60)
        let result = WidgetRotation.schedule(Array(0..<12), from: now, dayBoundary: boundary)
        XCTAssertEqual(result.entries.count, 4) // 0, 30, 60, 90 minutes
        XCTAssertTrue(result.entries.allSatisfy { $0.date < boundary })
        XCTAssertEqual(result.reload, boundary)
    }

    func testABoundarySecondsAwayStillLeavesOneEntry() {
        let boundary = now.addingTimeInterval(5)
        let result = WidgetRotation.schedule(Array(0..<12), from: now, dayBoundary: boundary)
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.reload, boundary)
    }

    func testNoPicksMeansNoEntries() {
        let result = WidgetRotation.schedule([Int](), from: now, dayBoundary: now.addingTimeInterval(86_400))
        XCTAssertTrue(result.entries.isEmpty)
    }

    // MARK: - Memory floor

    private let megabyte = 1024 * 1024

    func testTheFirstPhotoIsAlwaysLoaded() {
        XCTAssertTrue(WidgetRotation.shouldLoadAnother(loadedSoFar: 0, headroomBytes: 1024))
        XCTAssertTrue(WidgetRotation.shouldLoadAnother(loadedSoFar: 0, headroomBytes: -1024))
    }

    func testLoadingStopsBelowTheFloor() {
        let floor = WidgetRotation.memoryFloorBytes
        XCTAssertTrue(WidgetRotation.shouldLoadAnother(loadedSoFar: 5, headroomBytes: floor))
        XCTAssertFalse(WidgetRotation.shouldLoadAnother(loadedSoFar: 5, headroomBytes: floor - 1))
        XCTAssertFalse(WidgetRotation.shouldLoadAnother(loadedSoFar: 5, headroomBytes: -megabyte))
    }

    func testUnknownHeadroomDoesNotStopLoading() {
        XCTAssertTrue(WidgetRotation.shouldLoadAnother(loadedSoFar: 11, headroomBytes: nil))
    }

    /// What was seen on a sideloaded build: the system reported the whole
    /// phone free. The widget's own use against 30 MB must still govern.
    func testAHugeReportedFigureDoesNotHideTheWidgetsOwnUse() throws {
        let headroom = try XCTUnwrap(
            WidgetRotation.headroom(reportedAvailable: 6_628 * megabyte, footprint: 26 * megabyte)
        )
        XCTAssertEqual(headroom, 4 * megabyte)
        XCTAssertFalse(WidgetRotation.shouldLoadAnother(loadedSoFar: 3, headroomBytes: headroom))
    }

    /// A phone that reports a stricter limit than the assumption is obeyed.
    func testAStricterReportedLimitWins() {
        XCTAssertEqual(
            WidgetRotation.headroom(reportedAvailable: 2 * megabyte, footprint: 10 * megabyte),
            2 * megabyte
        )
    }

    /// Seen on device: iOS reported a 60 MB limit. That is the limit the
    /// process has, and the 30 MB assumption must not override it.
    func testABelievableReportedLimitIsTrusted() {
        XCTAssertEqual(
            WidgetRotation.headroom(reportedAvailable: 36 * megabyte, footprint: 24 * megabyte),
            36 * megabyte
        )
    }

    func testHeadroomFromWhicheverInputIsKnown() {
        XCTAssertEqual(WidgetRotation.headroom(reportedAvailable: 0, footprint: 10 * megabyte), 20 * megabyte)
        XCTAssertEqual(WidgetRotation.headroom(reportedAvailable: 8 * megabyte, footprint: 0), 8 * megabyte)
        XCTAssertNil(WidgetRotation.headroom(reportedAvailable: 0, footprint: 0))
    }

    // MARK: - Settling

    func testTheFirstBuildDoesNotWait() {
        XCTAssertFalse(
            WidgetRotation.shouldKeepSettling(current: 8 * megabyte, lowestStart: 8 * megabyte, waited: 0)
        )
    }

    /// The wide widget started at 23.9 MB right after the small one.
    func testABuildOnTopOfLeftoversWaits() {
        XCTAssertTrue(
            WidgetRotation.shouldKeepSettling(current: 24 * megabyte, lowestStart: 8 * megabyte, waited: 0.5)
        )
    }

    /// Waiting for memory must stay a small part of a build, which iOS
    /// expects to finish in seconds.
    func testMidLoadWaitingIsBounded() {
        XCTAssertGreaterThan(WidgetRotation.memoryWaitLimit, 1.5, "Shorter than the release seen on device.")
        XCTAssertLessThanOrEqual(WidgetRotation.memoryWaitLimit + WidgetRotation.settleLimit, 6)
    }

    func testWaitingIsCapped() {
        XCTAssertFalse(
            WidgetRotation.shouldKeepSettling(
                current: 24 * megabyte,
                lowestStart: 8 * megabyte,
                waited: WidgetRotation.settleLimit
            )
        )
    }

    /// The floor has to leave room for one more fetch of the largest photo
    /// the widget asks for, or it protects nothing.
    func testTheFloorCoversOneLargeFetch() {
        let largestDecodedPhoto = 1_092 * 819 * 4
        XCTAssertGreaterThan(WidgetRotation.memoryFloorBytes, largestDecodedPhoto * 3 / 2)
        XCTAssertLessThan(WidgetRotation.memoryFloorBytes, WidgetRotation.assumedLimitBytes / 2)
    }

    /// Seen on device: one fetch cost 7.3 MB at its peak, more than the old
    /// 6 MB floor.
    func testTheFloorCoversTheCostliestFetchSeenOnDevice() {
        XCTAssertGreaterThan(WidgetRotation.memoryFloorBytes, Int(7.3 * 1024 * 1024))
    }

    /// A build that has seen a costly photo asks for more room before the
    /// next one.
    func testACostlyPhotoRaisesTheBar() {
        let costly = 8 * megabyte
        XCTAssertTrue(WidgetRotation.shouldLoadAnother(loadedSoFar: 3, headroomBytes: 11 * megabyte))
        XCTAssertFalse(
            WidgetRotation.shouldLoadAnother(
                loadedSoFar: 3,
                headroomBytes: 11 * megabyte,
                largestPhotoCost: costly
            )
        )
        XCTAssertTrue(
            WidgetRotation.shouldLoadAnother(
                loadedSoFar: 3,
                headroomBytes: 12 * megabyte,
                largestPhotoCost: costly
            )
        )
    }

    // MARK: - Sharpness

    func testAPhotoAtTheRequestedSizeIsSharp() {
        XCTAssertTrue(WidgetRotation.isSharp(returnedWidth: 510, returnedHeight: 680, targetWidth: 510, targetHeight: 680))
    }

    /// The small preview kept on the phone for an iCloud photo, stretched
    /// to fill a 3x tile.
    func testASmallPreviewIsSoft() {
        XCTAssertFalse(WidgetRotation.isSharp(returnedWidth: 256, returnedHeight: 341, targetWidth: 510, targetHeight: 680))
    }

    func testSlightlyUnderSizeStillCountsAsSharp() {
        XCTAssertTrue(WidgetRotation.isSharp(returnedWidth: 400, returnedHeight: 533, targetWidth: 510, targetHeight: 680))
    }

    func testRotationPrefersSharpPhotos() {
        let loaded: [(item: String, isSharp: Bool)] = [
            ("soft1", false), ("sharp1", true), ("soft2", false), ("sharp2", true)
        ]
        XCTAssertEqual(WidgetRotation.rotation(loaded, limit: 12), ["sharp1", "sharp2"])
        XCTAssertEqual(WidgetRotation.rotation(loaded, limit: 1), ["sharp1"])
    }

    /// A soft photo beats an empty widget.
    func testSoftPhotosOnlyWhenNothingIsSharp() {
        let loaded: [(item: String, isSharp: Bool)] = [("soft1", false), ("soft2", false)]
        XCTAssertEqual(WidgetRotation.rotation(loaded, limit: 12), ["soft1", "soft2"])
        XCTAssertTrue(WidgetRotation.rotation([(item: String, isSharp: Bool)](), limit: 12).isEmpty)
    }

    // MARK: - Photo files

    func testPhotoFilesOutliveTheLongestTimeline() {
        let rotation = Double(WidgetRotation.slotCount) * WidgetRotation.slotInterval
        XCTAssertGreaterThan(WidgetRotation.photoFileLifetime, rotation)
        XCTAssertFalse(WidgetRotation.isStale(modified: now, now: now.addingTimeInterval(rotation)))
    }

    func testOldPhotoFilesAreStale() {
        XCTAssertTrue(
            WidgetRotation.isStale(
                modified: now,
                now: now.addingTimeInterval(WidgetRotation.photoFileLifetime + 1)
            )
        )
    }
}

