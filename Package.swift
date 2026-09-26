// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Manifold",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-cmark.git", from: "0.9.0"),
    ],
    targets: [
        // Built by scripts/build-ghostty.sh.
        .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework"),
        .target(name: "CPTY"),
        .target(name: "ManifoldCore"),
        .target(
            name: "ManifoldMarkdown",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        // The `manifold` command (named so in the app bundle).
        .executableTarget(name: "ManifoldCLI", dependencies: ["ManifoldCore"]),
        .executableTarget(name: "manifoldd", dependencies: ["ManifoldCore", "CPTY"]),
        .executableTarget(
            name: "Manifold",
            dependencies: ["ManifoldCore", "ManifoldMarkdown", "CPTY", "GhosttyKit"],
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
        .testTarget(name: "ManifoldMarkdownTests", dependencies: ["ManifoldMarkdown"]),
    ],
    swiftLanguageModes: [.v5]
)
