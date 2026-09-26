// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Manifold",
    platforms: [.macOS(.v15)],
    targets: [
        // Built by scripts/build-ghostty.sh.
        .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework"),
        .target(name: "CPTY"),
        .target(name: "ManifoldCore"),
        .executableTarget(name: "manifoldd", dependencies: ["ManifoldCore", "CPTY"]),
        .executableTarget(
            name: "Manifold",
            dependencies: ["ManifoldCore", "CPTY", "GhosttyKit"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreText"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(name: "ManifoldCoreTests", dependencies: ["ManifoldCore"]),
    ],
    swiftLanguageModes: [.v5]
)
