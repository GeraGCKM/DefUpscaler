import XCTest
import CoreML
import CoreImage
@testable import UpscaleCore

final class TensorImageTests: XCTestCase {
    func testRGBLayoutAndOpaqueAlpha() throws {
        let array = try MLMultiArray(shape: [1, 3, 2, 2], dataType: .float32)
        for y in 0..<2 { for x in 0..<2 {
            array[[0, 0, NSNumber(value: y), NSNumber(value: x)]] = 240
            array[[0, 1, NSNumber(value: y), NSNumber(value: x)]] = 30
            array[[0, 2, NSNumber(value: y), NSNumber(value: x)]] = 10
        } }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let image = try TensorImage.make(array, side: 2, colorSpace: space)
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes {
            CIContext().render(CIImage(cgImage: image), toBitmap: $0.baseAddress!, rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: space)
        }
        XCTAssertEqual(pixel, [240, 30, 10, 255])
    }
    func testRejectsIncompatibleShapeAndNonFiniteOutput() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let array = try MLMultiArray(shape: [1, 3, 1, 1], dataType: .float32)
        XCTAssertThrowsError(try TensorImage.make(array, side: 2, colorSpace: space))
        array[0] = NSNumber(value: Float.nan)
        XCTAssertThrowsError(try TensorImage.make(array, side: 1, colorSpace: space))
    }
    func testFloatingBufferPreservesFractionalNetworkOutput() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let array = try MLMultiArray(shape: [1, 3, 1, 1], dataType: .float32)
        array[0] = 127.5
        array[1] = 32.25
        array[2] = 220.75
        let image = try TensorImage.makeFloating(array, side: 1, colorSpace: space)
        var pixel = [Float](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { buffer in
            CIContext().render(image, toBitmap: buffer.baseAddress!, rowBytes: 16,
                               bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBAf, colorSpace: space)
        }
        XCTAssertEqual(pixel[0] * 255, 127.5, accuracy: 0.3)
        XCTAssertEqual(pixel[1] * 255, 32.25, accuracy: 0.3)
        XCTAssertEqual(pixel[2] * 255, 220.75, accuracy: 0.3)
        XCTAssertEqual(pixel[3], 1, accuracy: 0.001)
    }

}
