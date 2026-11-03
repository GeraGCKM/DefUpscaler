import Foundation

/// Pro is a conservative fidelity preset, not another model to download.
///
/// For the 4× photo path it selects the already bundled RealPLKSR checkpoint
/// and mixes a small portion of its prediction with a source-preserving
/// Lanczos enlargement. At 2× it uses the native RealESRGAN x2plus model.
/// This is intended to limit invented textures, NOT to promise ground truth.
public struct QualityPlan: Sendable, Equatable {
    public let mode: ImageMode
    public let neuralWeight: Double
    public let isPro: Bool

    public var explanation: String {
        if !isPro { return "Modelo estándar: 100 % inferencia." }
        if mode == .photoDetail {
            return "Pro · fidelidad: RealPLKSR 25 % y reescalado original 75 %."
        }
        return "Pro · fidelidad: Real-ESRGAN 25 % y reescalado original 75 %."
    }
}

public enum QualityPlanner {
    /// The existing standard and experimental internal modes remain untouched.
    /// The optional third-party model is never required for functional 2× Pro.
    public static func make(mode: ImageMode, scale: Int, pro: Bool,
                            hasWebPhoto: Bool) -> QualityPlan {
        guard pro, mode == .photo, [2, 4, 8, 16].contains(scale) else {
            return QualityPlan(mode: mode, neuralWeight: 1, isPro: false)
        }
        let engineMode: ImageMode = scale != 2 && hasWebPhoto ? .photoDetail : .photo
        return QualityPlan(mode: engineMode, neuralWeight: 0.25, isPro: true)
    }
}
