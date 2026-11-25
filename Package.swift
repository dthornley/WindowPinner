// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WindowPinner",
    platforms: [.macOS(.v13)],
    dependencies: [
        // In-app updates (appcast + EdDSA-signed archives on GitHub Releases).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "WindowPinner",
            dependencies: [.product(name: "Sparkle", package: "sparkle")],
            path: "Sources/WindowPinner"
        )
    ]
)
