// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Loupe", targets: ["Loupe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Updates for the installed app (EdDSA-signed releases on GitHub; see scripts/release.sh).
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        .target(name: "LoupeCore"),
        .target(name: "LoupeXMP", dependencies: ["LoupeCore"]),
        .target(name: "LoupeMedia", dependencies: ["LoupeCore"]),
        .target(
            name: "LoupeIndex",
            dependencies: ["LoupeCore", "LoupeXMP", "LoupeMedia", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "LoupeFeatures",
            dependencies: ["LoupeCore", "LoupeXMP", "LoupeMedia", "LoupeIndex"]
        ),
        .target(
            name: "LoupeImport",
            dependencies: ["LoupeCore", "LoupeMedia", "LoupeIndex", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        // ONNX Runtime's C API, loaded at run time from Homebrew (never linked): see include/loupe_ort.h.
        .target(name: "COnnxRuntime"),
        .target(
            name: "LoupeFaces",
            dependencies: ["LoupeCore", "LoupeMedia", "LoupeIndex", "COnnxRuntime", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "LoupeUI",
            dependencies: ["LoupeCore", "LoupeXMP", "LoupeMedia", "LoupeIndex", "LoupeFeatures", "LoupeImport", "LoupeFaces"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "LoupeTestSupport", dependencies: ["LoupeCore"]),
        .executableTarget(
            name: "Loupe",
            dependencies: ["LoupeUI", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "LoupeCoreTests", dependencies: ["LoupeCore"]),
        .testTarget(name: "LoupeFeaturesTests", dependencies: ["LoupeFeatures", "LoupeTestSupport"]),
        .testTarget(name: "LoupeImportTests", dependencies: ["LoupeImport", "LoupeTestSupport"]),
        .testTarget(name: "LoupeFacesTests", dependencies: ["LoupeFaces", "LoupeIndex", "LoupeTestSupport"]),
        .testTarget(name: "LoupeIndexTests", dependencies: ["LoupeIndex", "LoupeTestSupport"]),
        .testTarget(name: "LoupeMediaTests", dependencies: ["LoupeMedia", "LoupeTestSupport"]),
        .testTarget(name: "LoupeUITests", dependencies: ["LoupeUI", "LoupeImport", "LoupeTestSupport"]),
        .testTarget(
            name: "LoupeXMPTests",
            dependencies: ["LoupeXMP", "LoupeTestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
