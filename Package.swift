// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Glass",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Glass",
            path: "Sources"
        )
    ]
)