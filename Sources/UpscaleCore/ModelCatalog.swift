import Foundation

/// Immutable, auditable build-time model contract. No downloads or Python at runtime.
/// A native model is chosen only when its compiled Core ML bundle is present.
public struct ModelDescriptor: Sendable, Equatable {
    public let id: String
    public let version: String
    public let architecture: String
    public let resource: String
    public let source: String
    public let checkpointSHA256: String
    public let license: String
    public let nativeScale: Int
    public let input: String
    public let output: String
    public let normalization: String
    public let precision: String
    public let colorSpace: String
    public let coreTileSizes: [Int]
    public let context: Int
    public let runtime: String
}

public enum ModelCatalog {
    public static let anime4 = ModelDescriptor(
        id: "realesrgan-anime-6b", version: "v0.2.2.4", architecture: "RRDBNet-6",
        resource: "Anime4x",
        source: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.2.4/RealESRGAN_x4plus_anime_6B.pth",
        checkpointSHA256: "f872d837d3c90ed2e05227bed711af5671a6fd1c9f7d7e91c911a61f155e99da",
        license: "BSD-3-Clause", nativeScale: 4,
        input: "BGRA8 pixel buffer; RGB image, fixed 96/160/224",
        output: "NCHW Float32 RGB [0,255]", normalization: "RGB / 255",
        precision: "FP16 internal, Float32 output", colorSpace: "sRGB SDR",
        coreTileSizes: [64, 128, 192], context: 16, runtime: "Core ML macOS 14+")

    public static let photo4 = ModelDescriptor(
        id: "realesrgan-x4plus", version: "v0.1.0", architecture: "RRDBNet-23",
        resource: "Photo4x",
        source: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth",
        checkpointSHA256: "4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1",
        license: "BSD-3-Clause", nativeScale: 4,
        input: "BGRA8 pixel buffer; RGB image, fixed 96/160/224",
        output: "NCHW Float32 RGB [0,255]", normalization: "RGB / 255",
        precision: "FP16 internal, Float32 output", colorSpace: "sRGB SDR",
        coreTileSizes: [64, 128, 192], context: 16, runtime: "Core ML macOS 14+")

    public static let photo2 = ModelDescriptor(
        id: "realesrgan-x2plus", version: "v0.2.1", architecture: "RRDBNet-23 / pixel-unshuffle2",
        resource: "Photo2x",
        source: "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth",
        checkpointSHA256: "49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb",
        license: "BSD-3-Clause", nativeScale: 2,
        input: "BGRA8 pixel buffer; RGB image, fixed 96/160/224",
        output: "NCHW Float32 RGB [0,255]", normalization: "RGB / 255",
        precision: "FP16 internal, Float32 output", colorSpace: "sRGB SDR",
        coreTileSizes: [64, 128, 192], context: 16, runtime: "Core ML macOS 14+")

    public static let webPhoto4 = ModelDescriptor(
        id: "nomos-webphoto-realplksr", version: "2024-05-28", architecture: "RealPLKSR",
        resource: "WebPhoto4x",
        source: "https://huggingface.co/Phips/4xNomosWebPhoto_RealPLKSR",
        checkpointSHA256: "9be0228f98156a100d6636d99b373ed2785b999723f9adc4cca504329ab157f2",
        license: "CC-BY-4.0", nativeScale: 4,
        input: "RGB sRGB BGRA8 pixel buffer named image; fixed 512x512",
        output: "RGB pixel buffer named upscaled; fixed 2048x2048",
        normalization: "RGB / 255 inside compiled model",
        precision: "FP16 internal, image output", colorSpace: "sRGB SDR",
        coreTileSizes: [256, 384], context: 64,
        runtime: "Core ML macOS 14+; optional bundled converted model")

    public static func select(mode: ImageMode, requestedScale: Int,
                              hasNativePhoto2x: Bool) -> ModelDescriptor {
        if mode == .photoDetail { return webPhoto4 }
        if mode == .photo {
            return requestedScale == 2 && hasNativePhoto2x ? photo2 : photo4
        }
        return anime4
    }
}
