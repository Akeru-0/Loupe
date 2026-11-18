// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Loupe", targets: ["Loupe"]),
    ],
    targets: [
        .target(name: "LoupeCore"),
        .executableTarget(
            name: "Loupe",
            dependencies: ["LoupeCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "LoupeCoreTests", dependencies: ["LoupeCore"]),
    ]
)
