import XCTest
@testable import UpscaleCore

final class ModelCatalogTests: XCTestCase {
    func testNativeTwoXSelectionAndFallback() {
        XCTAssertEqual(ModelCatalog.select(mode: .photo, requestedScale: 2, hasNativePhoto2x: true).nativeScale, 2)
        XCTAssertEqual(ModelCatalog.select(mode: .photo, requestedScale: 2, hasNativePhoto2x: false).nativeScale, 4)
        XCTAssertEqual(ModelCatalog.select(mode: .illustration, requestedScale: 2, hasNativePhoto2x: true).nativeScale, 4)
        XCTAssertEqual(ModelCatalog.select(mode: .photo, requestedScale: 16, hasNativePhoto2x: true).nativeScale, 4)
    }
    func testContractsHaveValidPinnedChecksums() {
        for descriptor in [ModelCatalog.anime4, ModelCatalog.photo4, ModelCatalog.photo2] {
            XCTAssertEqual(descriptor.checkpointSHA256.count, 64)
            XCTAssertEqual(descriptor.context, JobPlan.padding)
            XCTAssertEqual(descriptor.coreTileSizes, [64,128,192])
        }
    }
}
