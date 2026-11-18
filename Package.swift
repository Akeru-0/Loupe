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
    ],
    targets: [
        .target(name: "LoupeCore"),
        .target(name: "LoupeXMP", dependencies: ["LoupeCore"]),
        .target(name: "LoupeMedia", dependencies: ["LoupeCore"]),
        .target(
            name: "LoupeIndex",
            dependencies: ["LoupeCore", "LoupeXMP", "LoupeMedia", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "LoupeTestSupport", dependencies: ["LoupeCore"]),
        .executableTarget(
            name: "Loupe",
            dependencies: ["LoupeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "LoupeCoreTests", dependencies: ["LoupeCore"]),
        .testTarget(name: "LoupeIndexTests", dependencies: ["LoupeIndex", "LoupeTestSupport"]),
        .testTarget(name: "LoupeMediaTests", dependencies: ["LoupeMedia", "LoupeTestSupport"]),
        .testTarget(
            name: "LoupeXMPTests",
            dependencies: ["LoupeXMP", "LoupeTestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
