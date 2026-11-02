// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DefUpscaler",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "DefUpscaler", targets: ["DefUpscaler"])],
    targets: [
        .target(name: "UpscaleCore"),
        .executableTarget(name: "DefUpscaler", dependencies: ["UpscaleCore"]),
        .testTarget(name: "UpscaleCoreTests", dependencies: ["UpscaleCore"])
    ]
)
