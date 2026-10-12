// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SyntheholKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SyntheholKit", targets: ["SyntheholKit"]),
        .executable(name: "synthehol-dev", targets: ["SyntheholCLI"])
    ],
    targets: [
        .target(
            name: "SyntheholKit",
            resources: [
                .copy("Resources/steamwebhelper-shim.exe"),
                .copy("Resources/NativeSteamPayload")
            ]
        ),
        .executableTarget(name: "SyntheholCLI", dependencies: ["SyntheholKit"]),
        .testTarget(name: "SyntheholKitTests", dependencies: ["SyntheholKit"])
    ]
)
