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
        // The host's terminal emulator (Ghostty's, built by
        // scripts/build-manifold-vt.sh), for manifoldd.
        .target(
            name: "CManifoldVT",
            linkerSettings: [
                .linkedLibrary("manifoldvt"),
                .unsafeFlags(["-L", Context.packageDirectory + "/Frameworks/manifold-vt/macos"], .when(platforms: [.macOS])),
                .unsafeFlags(["-L", Context.packageDirectory + "/Frameworks/manifold-vt/linux"], .when(platforms: [.linux])),
            ]
        ),
        // Zstandard, built from its sources here (Sources/CZstd), for the
        // app and every manifoldd alike: no assembly (the same C everywhere),
        // one thread.
        .target(
            name: "CZstd",
            cSettings: [.define("ZSTD_DISABLE_ASM")]
        ),
        .target(name: "ManifoldCore", dependencies: ["CZstd"]),
        .target(
            name: "ManifoldMarkdown",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        // The `manifold` command (named so in the app bundle).
        .executableTarget(name: "ManifoldCLI", dependencies: ["ManifoldCore"]),
        .executableTarget(name: "manifoldd", dependencies: ["ManifoldCore", "CPTY", "CManifoldVT"]),
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
