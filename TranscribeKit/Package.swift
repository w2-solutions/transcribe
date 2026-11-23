// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "TranscribeKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v27), .macOS(.v27)],
    products: [
        .library(name: "TranscribeCore", targets: ["TranscribeCore"]),
        .library(name: "TranscribeKit", targets: ["TranscribeKit"]),
        .library(name: "TranscribeDesign", targets: ["TranscribeDesign"]),
        .library(name: "TranscribeFluid", targets: ["TranscribeFluid"]),
        .library(name: "TranscribeFakes", targets: ["TranscribeFakes"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: ["Diarizer"]),
    ],
    targets: [
        .target(name: "TranscribeCore"),
        .target(name: "TranscribeKit", dependencies: ["TranscribeCore"]),
        .target(name: "TranscribeDesign", dependencies: ["TranscribeCore"]),
        .target(name: "TranscribeFluid", dependencies: [
            "TranscribeCore", .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .target(name: "TranscribeFakes", dependencies: ["TranscribeCore", "TranscribeKit"]),
        .testTarget(name: "TranscribeCoreTests", dependencies: ["TranscribeCore"]),
        .testTarget(name: "TranscribeKitTests", dependencies: ["TranscribeKit", "TranscribeFakes"]),
        .testTarget(name: "TranscribeFluidTests", dependencies: ["TranscribeFluid"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]   // NO .defaultIsolation(MainActor.self): toolchain pitfall 2
)
