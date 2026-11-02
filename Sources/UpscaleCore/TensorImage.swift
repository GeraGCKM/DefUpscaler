import CoreML
import CoreGraphics

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
