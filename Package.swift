// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DJLibrary",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "djlib", path: "Sources/djlib")
    ]
)
