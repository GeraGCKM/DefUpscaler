import XCTest
import CoreGraphics
import CoreImage
import ImageIO
@testable import UpscaleCore

/// Reproducible, deliberately synthetic comparison. PSNR on these patterns is
/// not evidence of subjective photographic superiority or hallucination-free SR.
final class QualityComparisonTests: XCTestCase {
    func testSyntheticModelComparison() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let real4 = env["DEFUPSCALER_PHOTO_MODEL"],
              let real2 = env["DEFUPSCALER_PHOTO2_MODEL"],
              let plksr = env["DEFUPSCALER_WEBPHOTO_MODEL"] else {
            throw XCTSkip("Requires all three compiled photographic model candidates")
        }
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/quality", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let width = 256
        let height = 256
        guard let image = CGContext(data: nil, width: width, height: height,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw UpscaleError.invalidImage
        }
        image.setFillColor(CGColor(red: 0.91, green: 0.88, blue: 0.81, alpha: 1))
        image.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for i in 0..<16 {
            for j in 0..<16 where (i + j).isMultiple(of: 2) {
                image.setFillColor(CGColor(red: 0.11, green: 0.17, blue: 0.24, alpha: 1))
                image.fill(CGRect(x: i * 4, y: j * 4, width: 4, height: 4))
            }
        }
        var seed: UInt32 = 0x9e3779b9
        for i in 0..<550 {
            seed = 1664525 &* seed &+ 1013904223
            let x = CGFloat((seed >> 8) % 256)
            seed = 1664525 &* seed &+ 1013904223
            let y = CGFloat((seed >> 8) % 256)
            let intensity = CGFloat((seed >> 16) & 255) / 255
            image.setStrokeColor(CGColor(red: intensity * 0.6,
                                         green: intensity * 0.48,
                                         blue: intensity * 0.25, alpha: 1))
            image.setLineWidth(i.isMultiple(of: 5) ? 1.5 : 0.6)
            image.move(to: CGPoint(x: x, y: y))
            image.addLine(to: CGPoint(x: min(255, x + CGFloat(i % 15) - 7),
                                      y: min(255, y + CGFloat(i % 29) - 14)))
            image.strokePath()
        }
        image.setFillColor(CGColor(red: 0.86, green: 0.21, blue: 0.18, alpha: 1))
        image.fillEllipse(in: CGRect(x: 70, y: 80, width: 105, height: 105))
        image.setStrokeColor(CGColor(red: 0.08, green: 0.12, blue: 0.18, alpha: 1))
        image.setLineWidth(2)
        for x in stride(from: 80, through: 180, by: 4) {
            image.move(to: CGPoint(x: x, y: 100))
            image.addLine(to: CGPoint(x: x, y: 190))
            image.strokePath()
        }
        guard let reference = image.makeImage() else { throw UpscaleError.invalidImage }
        let context = CIContext(options: [.cacheIntermediates: false])
        let referenceURL = folder.appendingPathComponent("reference.png")
        let inputURL = folder.appendingPathComponent("input.png")
        try context.writePNGRepresentation(of: CIImage(cgImage: reference), to: referenceURL,
                                           format: .RGBA8, colorSpace: space)
        let smaller = CIImage(cgImage: reference).applyingFilter("CILanczosScaleTransform",
                        parameters: [kCIInputScaleKey: 0.25, kCIInputAspectRatioKey: 1])
        try context.writePNGRepresentation(of: smaller, to: inputURL, format: .RGBA8, colorSpace: space)
        for (name, path, scale, native, mode) in [
            ("realesrgan4", real4, 4, 4, ImageMode.photo),
            ("realesrgan2", real2, 2, 2, ImageMode.photo),
            ("realplksr4", plksr, 4, 4, ImageMode.photoDetail)
        ] {
            let engine = UpscaleEngine(modelURL: URL(fileURLWithPath: path), modelScale: native)
            let output = try await engine.process(url: inputURL, scale: scale, mode: mode) { _ in }
            defer { try? FileManager.default.removeItem(at: output) }
            let target = folder.appendingPathComponent(name + ".png")
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: output, to: target)
            guard let result = CIImage(contentsOf: target) else {
                XCTFail("Empty output for \(name)"); continue
            }
            XCTAssertEqual(Int(result.extent.width), 64 * scale)
            XCTAssertEqual(Int(result.extent.height), 64 * scale)
        }
    }
}
