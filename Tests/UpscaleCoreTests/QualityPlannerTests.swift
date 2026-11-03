import XCTest
@testable import UpscaleCore

final class QualityPlannerTests: XCTestCase {
    func testNormalModesRemainExactlyAsBefore() {
        for mode in ImageMode.allCases {
            for scale in [2, 4, 8, 16] {
                let plan = QualityPlanner.make(mode: mode, scale: scale, pro: false, hasWebPhoto: true)
                XCTAssertEqual(plan.mode, mode)
                XCTAssertEqual(plan.neuralWeight, 1)
                XCTAssertFalse(plan.isPro)
            }
        }
    }

    func testProForPhotosUsesExistingModelsWithoutNewWeights() {
        let native2 = QualityPlanner.make(mode: .photo, scale: 2, pro: true, hasWebPhoto: true)
        XCTAssertEqual(native2.mode, .photo)
        XCTAssertEqual(native2.neuralWeight, 0.25)
        XCTAssertTrue(native2.isPro)

        for scale in [4, 8, 16] {
            let plksr = QualityPlanner.make(mode: .photo, scale: scale, pro: true, hasWebPhoto: true)
            XCTAssertEqual(plksr.mode, .photoDetail)
            XCTAssertEqual(plksr.neuralWeight, 0.25)
            XCTAssertTrue(plksr.isPro)
        }
    }

    func testSafeFallbackAndIllustrationNeverBecomePro() {
        for scale in [2, 4, 8, 16] {
            let noOptionalModel = QualityPlanner.make(mode: .photo, scale: scale,
                                                      pro: true, hasWebPhoto: false)
            XCTAssertEqual(noOptionalModel.mode, .photo)
            XCTAssertEqual(noOptionalModel.neuralWeight, 0.25)
            let illustration = QualityPlanner.make(mode: .illustration, scale: scale,
                                                   pro: true, hasWebPhoto: true)
            XCTAssertEqual(illustration.mode, .illustration)
            XCTAssertEqual(illustration.neuralWeight, 1)
            XCTAssertFalse(illustration.isPro)
        }
    }
}
