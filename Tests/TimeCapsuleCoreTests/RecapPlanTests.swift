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
}
