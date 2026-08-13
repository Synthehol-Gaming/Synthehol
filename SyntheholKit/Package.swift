// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SyntheholKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SyntheholKit", targets: ["SyntheholKit"])
    ],
    targets: [
        .target(name: "SyntheholKit"),
        .testTarget(name: "SyntheholKitTests", dependencies: ["SyntheholKit"])
    ]
)
