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
        .library(name: "TranscribeCloudKit", targets: ["TranscribeCloudKit"]),
        .library(name: "TranscribeMCP", targets: ["TranscribeMCP"]),
        .library(name: "TranscribeMCPHost", targets: ["TranscribeMCPHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: ["Diarizer"]),
    ],
    targets: [
        .target(name: "TranscribeCore"),
        // Network: NWPathMonitor for audio sync's network rules (`LiveDeviceConditions`).
        .target(name: "TranscribeKit", dependencies: ["TranscribeCore"], linkerSettings: [.linkedFramework("Network")]),
        .target(name: "TranscribeDesign", dependencies: ["TranscribeCore"]),
        .target(name: "TranscribeFluid", dependencies: [
            "TranscribeCore", .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        .target(name: "TranscribeFakes", dependencies: ["TranscribeCore", "TranscribeKit"]),
        // The only target that imports CloudKit (D23): CKSyncEngine behind `SyncTransport`, the record codec and the
        // account observer. Everything else in sync is tested over the fake in TranscribeKitTests.
        .target(name: "TranscribeCloudKit", dependencies: ["TranscribeKit"],
                linkerSettings: [.linkedFramework("CloudKit")]),
        // Pure MCP: JSON-RPC, tool text, HMAC, the loopback HTTP server and the stdio bridge. Foundation, Network and
        // CryptoKit only; linked by the Mac app and the transcribe-mcp helper. Never imports SwiftData or UI.
        .target(name: "TranscribeMCP", dependencies: ["TranscribeCore"], linkerSettings: [.linkedFramework("Network")]),
        // The Mac app's side: reads the SwiftData library into TranscribeMCP's DTOs and owns the switch, key and port.
        .target(name: "TranscribeMCPHost", dependencies: ["TranscribeKit", "TranscribeMCP"]),
        .testTarget(name: "TranscribeCoreTests", dependencies: ["TranscribeCore"]),
        .testTarget(name: "TranscribeKitTests", dependencies: ["TranscribeKit", "TranscribeFakes"], resources: [.copy("Fixtures")]),
        .testTarget(name: "TranscribeCloudKitTests", dependencies: ["TranscribeCloudKit", "TranscribeKit", "TranscribeFakes"]),
        .testTarget(name: "TranscribeMCPTests", dependencies: ["TranscribeMCP"]),
        .testTarget(name: "TranscribeMCPHostTests", dependencies: ["TranscribeMCPHost", "TranscribeMCP", "TranscribeKit", "TranscribeFakes"]),
        .testTarget(name: "TranscribeFluidTests", dependencies: ["TranscribeFluid"], resources: [.copy("Fixtures")]),
    ],
    swiftLanguageModes: [.v6]   // NO .defaultIsolation(MainActor.self): toolchain pitfall 2
)
