import XCTest
@testable import UpscaleCore

final class ResourceGovernorTests: XCTestCase {
    func testGrowsOnlyAfterStableSamplesAndBacksOffUnderPressure() {
        var governor = ResourceGovernor()
        XCTAssertEqual(governor.coreSide, 64)
        for _ in 0..<5 { governor.observe(secondsPerPixel: 0.001, constrained: false) }
        XCTAssertEqual(governor.coreSide, 64)
        governor.observe(secondsPerPixel: 0.001, constrained: false)
        XCTAssertEqual(governor.coreSide, 128)
        governor.observe(secondsPerPixel: 0.001, constrained: true)
        XCTAssertEqual(governor.coreSide, 64)
    }
    func testSlowdownBacksOffAndDoesNotImmediatelyProbeAgain() {
        var governor = ResourceGovernor()
        for _ in 0..<12 { governor.observe(secondsPerPixel: 0.001, constrained: false) }
        XCTAssertEqual(governor.coreSide, 192)
        governor.observe(secondsPerPixel: 0.003, constrained: false)
        XCTAssertEqual(governor.coreSide, 128)
        for _ in 0..<6 { governor.observe(secondsPerPixel: 0.001, constrained: false) }
        XCTAssertEqual(governor.coreSide, 128)
    }
    func testExtendedScalesHaveExactDimensions() throws {
        for scale in [2, 4, 8, 16] {
            let plan = try JobPlan(width: 7, height: 3, scale: scale, memoryBytes: 16 * 1024 * 1024 * 1024)
            XCTAssertEqual(plan.outputWidth, 7 * scale)
            XCTAssertEqual(plan.outputHeight, 3 * scale)
        }
    }
}
