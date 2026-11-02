import XCTest
@testable import UpscaleCore

final class JobPlanTests: XCTestCase {
    func testOddEdgesCoverImageExactlyOnce() throws {
        let plan = try JobPlan(width: 259, height: 133, scale: 4, memoryBytes: 16 * 1024 * 1024 * 1024)
        XCTAssertEqual(plan.tiles.count, 6)
        var covered = Set<Int>()
        for tile in plan.tiles {
            for y in tile.y..<(tile.y + tile.height) {
                for x in tile.x..<(tile.x + tile.width) {
                    XCTAssertTrue(covered.insert(y * plan.width + x).inserted)
                }
            }
        }
        XCTAssertEqual(covered.count, 259 * 133)
        XCTAssertEqual(plan.outputWidth, 1036)
        XCTAssertEqual(plan.outputHeight, 532)
    }
    func testRejectsInvalidAndExcessiveDimensionsBeforeAllocation() {
        for (width, height, scale) in [(0, 10, 4), (-1, 10, 4), (10, 10, 16), (Int.max, 10, 4), (10000, 10000, 4)] {
            XCTAssertThrowsError(try JobPlan(width: width, height: height, scale: scale, memoryBytes: .max))
        }
        XCTAssertThrowsError(try JobPlan(width: 2000, height: 2000, scale: 4, memoryBytes: 4 * 1024 * 1024 * 1024))
    }
    func testTinyInputAndTwoTimesScale() throws {
        let plan = try JobPlan(width: 1, height: 1, scale: 2, memoryBytes: 8 * 1024 * 1024 * 1024)
        XCTAssertEqual(plan.tiles.count, 1)
        XCTAssertEqual(plan.outputWidth, 2)
    }
}
