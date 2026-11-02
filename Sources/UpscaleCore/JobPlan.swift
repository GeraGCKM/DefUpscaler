import Foundation

public enum UpscaleError: LocalizedError {
    case invalidImage, tooLarge, missingModel, invalidPrediction, memoryPressure, unsupportedColor, busy
    public var errorDescription: String? {
        switch self {
        case .unsupportedColor: return "Esta versión exporta SDR sRGB de 8 bits. Convierte primero la imagen HDR o de alta profundidad a SDR."
        case .busy: return "Ya hay una imagen en proceso."
        case .invalidImage: return "No se pudo leer la imagen. Usa PNG, JPEG, HEIC o TIFF."
        case .tooLarge: return "La imagen excede el límite de memoria. Prueba 2× o una imagen más pequeña."
        case .missingModel: return "Falta el modelo incluido. Vuelve a instalar la compilación completa de DefUpscaler."
        case .invalidPrediction: return "El modelo devolvió un resultado incompatible. Consulta el diagnóstico."
        case .memoryPressure: return "Se detuvo el trabajo por presión de memoria. Cierra otras apps e inténtalo de nuevo."
        }
    }
}

public struct Tile: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
}

public struct JobPlan: Sendable {
    public static let tileSide = 128
    public static let padding = 16
    public static let modelSide = tileSide + 2 * padding
    public let width: Int
    public let height: Int
    public let scale: Int
    public let tiles: [Tile]
    public var outputWidth: Int { width * scale }
    public var outputHeight: Int { height * scale }

    public init(width: Int, height: Int, scale: Int, memoryBytes: UInt64) throws {
        guard width > 0, height > 0, [2, 4, 8, 16].contains(scale), width <= 32768, height <= 32768 else {
            throw UpscaleError.tooLarge
        }
        let outputPixels = UInt64(width) * UInt64(height) * UInt64(scale * scale)
        // Includes decoded input, output, preview/export copies and a model working-set reserve.
        let estimatedBytes = outputPixels * 24 + 768 * 1024 * 1024
        guard outputPixels <= 64_000_000, estimatedBytes <= memoryBytes / 3 else {
            throw UpscaleError.tooLarge
        }
        self.width = width
        self.height = height
        self.scale = scale
        self.tiles = stride(from: 0, to: height, by: Self.tileSide).flatMap { y in
            stride(from: 0, to: width, by: Self.tileSide).map { x in
                Tile(x: x, y: y, width: min(Self.tileSide, width - x), height: min(Self.tileSide, height - y))
            }
        }
    }
}
