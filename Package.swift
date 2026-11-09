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
        .target(
            name: "CPTY",
            linkerSettings: [
                .linkedFramework("IOKit", .when(platforms: [.macOS])),
                .linkedFramework("CoreFoundation", .when(platforms: [.macOS])),
            ]
        ),
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
        // What a build was made from (scripts/stamp-build.sh), for the app,
        // its servers and `mani` to say.
        .target(name: "CBuildStamp"),
        .target(name: "ManifoldCore", dependencies: ["CZstd", "CBuildStamp"]),
        // Tree-sitter, fetched by scripts/fetch-tree-sitter.sh: its runtime
        // (lib.c, which includes the rest) and the grammars code is parsed with.
        .target(
            name: "CTreeSitter",
            path: "vendor/tree-sitter/runtime",
            sources: ["src/lib.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("src"), .unsafeFlags(["-w"])]
        ),
        .target(
            name: "CTreeSitterGrammars",
            path: "vendor/tree-sitter/grammars",
            cSettings: [.unsafeFlags(["-w"])]
        ),
        // Code parsed: its trees, kept as it's edited, and what they say.
        .target(name: "ManifoldSyntax", dependencies: ["ManifoldCore", "CTreeSitter", "CTreeSitterGrammars"]),
        .target(
            name: "ManifoldMarkdown",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        // The `mani` command (named so in the app bundle).
        .executableTarget(name: "ManifoldCLI", dependencies: ["ManifoldCore"]),
        .executableTarget(name: "manifoldd", dependencies: ["ManifoldCore", "CPTY", "CManifoldVT"]),
        .executableTarget(
            name: "Manifold",
            dependencies: ["ManifoldCore", "ManifoldMarkdown", "ManifoldSyntax", "CPTY", "GhosttyKit"],
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
        .testTarget(name: "ManifoldSyntaxTests", dependencies: ["ManifoldSyntax"]),
        .testTarget(name: "ManifoldAppTests", dependencies: ["Manifold"]),
        .testTarget(name: "ManifolddTests", dependencies: ["manifoldd"]),
    ],
    swiftLanguageModes: [.v5]
)
