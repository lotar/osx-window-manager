// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "osx-window-manager",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "osx-window-manager",
            path: "Sources"
        )
    ]
)
