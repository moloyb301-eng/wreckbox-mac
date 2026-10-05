// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DJLibrary",
    platforms: [.macOS(.v13)],
    targets: [
        // Fonts in Sources/djlib/Resources are copied into the .app by scripts/make-app.sh.
        .executableTarget(name: "djlib", path: "Sources/djlib", exclude: ["Resources"])
    ]
)
