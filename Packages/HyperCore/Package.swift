// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HyperCore",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "HyperCore", targets: ["HyperCore"]),
    ],
    targets: [
        .target(name: "HyperCore"),
        .testTarget(
            name: "HyperCoreTests",
            dependencies: ["HyperCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
