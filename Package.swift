// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WindowPinner",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "WindowPinner",
            path: "Sources/WindowPinner"
        )
    ]
)
