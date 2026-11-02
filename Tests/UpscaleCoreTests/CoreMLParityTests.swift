import XCTest
import CoreML
import CoreImage
import CoreVideo
@testable import UpscaleCore

// PROVISIONAL: Compare actual native Core ML predictions against untouched
// official Real-ESRGAN weights evaluated independently using PyTorch.
// The model conversion and inference must both pass; no interpolation fallback.
final class CoreMLParityTests: XCTestCase {
    func testNativeParityForEveryFixedProfile() throws {
        let env = ProcessInfo.processInfo.environment
        guard let anime = env["DEFUPSCALER_TEST_MODEL"],
              let photo = env["DEFUPSCALER_PHOTO_MODEL"],
              let fixtureRoot = env["DEFUPSCALER_PARITY_DIR"] else {
            throw XCTSkip("Compiled models and independently computed parity fixtures required")
        }
        let context = CIContext()
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        for (name, path) in [("Anime4x", anime), ("Photo4x", photo)] {
            let base = URL(fileURLWithPath: path)
            for inputSide in [96, 160, 224] {
                let variant = inputSide == 96 ? name : "\(name)-\(inputSide)"
                let modelURL = inputSide == 96 ? base :
                    base.deletingLastPathComponent().appendingPathComponent(variant + ".mlmodelc")
                XCTAssertTrue(FileManager.default.fileExists(atPath: modelURL.path),
                              "Missing compiled fixed profile \(variant)")
                let config = MLModelConfiguration()
                config.computeUnits = .cpuOnly
                let model = try MLModel(contentsOf: modelURL, configuration: config)
                let outputSide = inputSide * 4
                let folder = URL(fileURLWithPath: fixtureRoot).appendingPathComponent(variant)
                for sample in 0..<2 {
                    let imageURL = folder.appendingPathComponent("input-\(sample).png")
                    let expectedURL = folder.appendingPathComponent("expected-\(sample).f32")
                    guard let image = CIImage(contentsOf: imageURL) else {
                        XCTFail("Missing PyTorch input fixture: \(imageURL.lastPathComponent)")
                        continue
                    }
                    var pixelBuffer: CVPixelBuffer?
                    let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:]]
                    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, inputSide, inputSide,
                        kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer), kCVReturnSuccess)
                    let buffer = try XCTUnwrap(pixelBuffer)
                    context.render(image, to: buffer,
                                   bounds: CGRect(x: 0, y: 0, width: inputSide, height: inputSide),
                                   colorSpace: colorSpace)
                    let features = try MLDictionaryFeatureProvider(
                        dictionary: ["input": MLFeatureValue(pixelBuffer: buffer)])
                    let prediction = try model.prediction(from: features)
                    let array = try XCTUnwrap(prediction.featureValue(for: "output")?.multiArrayValue)
                    XCTAssertEqual(array.dataType, .float32)
                    XCTAssertEqual(array.shape.map(\.intValue), [1, 3, outputSide, outputSide])
                    let expected = try Data(contentsOf: expectedURL)
                    XCTAssertEqual(expected.count, 3 * outputSide * outputSide * 4)
                    let strides = array.strides.map(\.intValue)
                    let values = array.dataPointer.assumingMemoryBound(to: Float.self)
                    var errorSum = 0.0
                    var valid = true
                    expected.withUnsafeBytes { bytes in
                        for c in 0..<3 {
                            for y in 0..<outputSide {
                                for x in 0..<outputSide {
                                    let index = (c * outputSide * outputSide + y * outputSide + x)
                                    let reference = bytes.loadUnaligned(
                                        fromByteOffset: index * 4, as: Float.self)
                                    let actual = values[c * strides[1] + y * strides[2] + x * strides[3]]
                                    if !actual.isFinite { valid = false; continue }
                                    errorSum += abs(Double(reference - actual))
                                }
                            }
                        }
                    }
                    XCTAssertTrue(valid, "Non-finite Core ML output in \(variant)")
                    let mae = errorSum / Double(3 * outputSide * outputSide)
                    XCTAssertLessThanOrEqual(mae, 2.0,
                        "Core ML/PyTorch divergence for \(variant), sample \(sample): MAE \(mae)/255")
                }
            }
        }
    }
}
