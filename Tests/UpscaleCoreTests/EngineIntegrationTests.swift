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
        let output = try await engine.process(url: input, scale: 2, gentle: false) { _ in }
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
}
