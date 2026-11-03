import CoreML
import CoreGraphics
import CoreImage

/// Uses actual strides; never assumes a contiguous MLMultiArray layout.
/// The model contract is RGB NCHW Float32 in [0,255].
enum TensorImage {
    static func make(_ array: MLMultiArray, side: Int, colorSpace: CGColorSpace) throws -> CGImage {
        guard array.dataType == .float32, array.shape.map(\.intValue) == [1, 3, side, side],
            let canvas = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = canvas.data else { throw UpscaleError.invalidPrediction }
        let src = array.dataPointer.assumingMemoryBound(to: Float.self)
        let dst = data.assumingMemoryBound(to: UInt8.self)
        let stride = array.strides.map(\.intValue)
        for y in 0..<side {
            for x in 0..<side {
                let source = y * stride[2] + x * stride[3]
                let target = (y * side + x) * 4
                for c in 0..<3 {
                    let value = src[source + c * stride[1]]
                    guard value.isFinite else { throw UpscaleError.invalidPrediction }
                    dst[target + c] = UInt8(max(0, min(255, value.rounded())))
                }
                dst[target + 3] = 255
            }
        }
        guard let image = canvas.makeImage() else { throw UpscaleError.invalidPrediction }
        return image
    }
}

/// Preserves fractional neural output through Core Image resizing. The
/// 8-bit PNG quantization is performed once, after scale and alpha compositing.
/// The tensor contract is RGB Float32 [0,255], opaque unpremultiplied RGB.
extension TensorImage {
    static func makeFloating(_ array: MLMultiArray, side: Int,
                             colorSpace: CGColorSpace) throws -> CIImage {
        guard array.dataType == .float32,
              array.shape.map(\.intValue) == [1, 3, side, side] else {
            throw UpscaleError.invalidPrediction
        }
        let input = array.dataPointer.assumingMemoryBound(to: Float.self)
        let strides = array.strides.map(\.intValue)
        var data = Data(count: side * side * 4 * MemoryLayout<Float16>.size)
        try data.withUnsafeMutableBytes { bytes in
            guard let pointer = bytes.baseAddress?.assumingMemoryBound(to: UInt16.self) else {
                throw UpscaleError.invalidPrediction
            }
            for y in 0..<side {
                for x in 0..<side {
                    let inputOffset = y * strides[2] + x * strides[3]
                    let outputOffset = (y * side + x) * 4
                    for c in 0..<3 {
                        let sample = input[inputOffset + c * strides[1]]
                        guard sample.isFinite else { throw UpscaleError.invalidPrediction }
                        let normalized = max(Float(0), min(Float(255), sample)) / 255
                        pointer[outputOffset + c] = Float16(normalized).bitPattern.littleEndian
                    }
                    pointer[outputOffset + 3] = Float16(1).bitPattern.littleEndian
                }
            }
        }
        return CIImage(bitmapData: data, bytesPerRow: side * 8,
                       size: CGSize(width: side, height: side),
                       format: .RGBAh, colorSpace: colorSpace)
    }
}
