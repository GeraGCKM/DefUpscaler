import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import UpscaleCore

final class EngineIntegrationTests: XCTestCase {
    func testCoreMLImagePipeline() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["DEFUPSCALER_TEST_MODEL"] else {
            throw XCTSkip("Run after model conversion with DEFUPSCALER_TEST_MODEL pointing to the compiled model")
        }
        let context = CIContext()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("fixture.png")
        let rect = CGRect(x: 0, y: 0, width: 133, height: 129)
        let lower = CIImage(color: CIColor(red: 0.9, green: 0.1, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 133, height: 64))
        let upper = CIImage(color: CIColor(red: 0.1, green: 0.1, blue: 0.9)).cropped(to: rect)
        try context.writePNGRepresentation(of: lower.composited(over: upper), to: input, format: .RGBA8, colorSpace: space)
        let engine = UpscaleEngine(modelURL: URL(fileURLWithPath: modelPath))
        let output = try await engine.process(url: input, scale: 2, mode: .illustration) { _ in }
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try XCTUnwrap(CIImage(contentsOf: output))
        XCTAssertEqual(Int(result.extent.width), 266)
        XCTAssertEqual(Int(result.extent.height), 258)
        func sample(y: Int) -> [UInt8] {
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                context.render(result, toBitmap: bytes.baseAddress!, rowBytes: 4,
                               bounds: CGRect(x: 64, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: space)
            }
            return rgba
        }
        let bottom = sample(y: 32)
        let top = sample(y: 220)
        XCTAssertGreaterThan(bottom[0], bottom[2], "Red bottom must remain below blue top; no flipped tiles or RGB swap")
        XCTAssertGreaterThan(top[2], top[0])
        XCTAssertEqual(bottom[3], 255)
    }
    func testAlphaAndAllScalesForBothModels() async throws {
        guard let anime = ProcessInfo.processInfo.environment["DEFUPSCALER_TEST_MODEL"],
              let photo = ProcessInfo.processInfo.environment["DEFUPSCALER_PHOTO_MODEL"] else {
            throw XCTSkip("Both compiled models are required")
        }
        let context = CIContext()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("alpha.png")
        let bounds = CGRect(x: 0, y: 0, width: 9, height: 5)
        let clear = CIImage(color: .clear).cropped(to: bounds)
        let half = CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 0.5))
            .cropped(to: CGRect(x: 4, y: 0, width: 5, height: 5))
        try context.writePNGRepresentation(of: half.composited(over: clear), to: input, format: .RGBA8, colorSpace: space)
        for path in [anime, photo] {
            for scale in [2, 4, 8, 16] {
                let engine = UpscaleEngine(modelURL: URL(fileURLWithPath: path))
                let output = try await engine.process(url: input, scale: scale) { _ in }
                defer { try? FileManager.default.removeItem(at: output) }
                let image = try XCTUnwrap(CIImage(contentsOf: output))
                XCTAssertEqual(Int(image.extent.width), 9 * scale)
                XCTAssertEqual(Int(image.extent.height), 5 * scale)
                func alpha(x: Int) -> UInt8 {
                    var pixel = [UInt8](repeating: 0, count: 4)
                    pixel.withUnsafeMutableBytes {
                        context.render(image, toBitmap: $0.baseAddress!, rowBytes: 4,
                            bounds: CGRect(x: x, y: 2 * scale, width: 1, height: 1), format: .RGBA8, colorSpace: space)
                    }
                    return pixel[3]
                }
                XCTAssertEqual(alpha(x: scale), 0)
                XCTAssertLessThanOrEqual(abs(Int(alpha(x: 7 * scale)) - 128), 2)
            }
        }
    }
    func testAlreadyCancelledJobNeverLoadsModel() async throws {
        let engine = UpscaleEngine()
        let task = Task {
            try await Task.sleep(for: .milliseconds(100))
            return try await engine.process(url: URL(fileURLWithPath: "/missing.png"), scale: 4) { _ in }
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

}
