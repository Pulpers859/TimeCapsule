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
}
