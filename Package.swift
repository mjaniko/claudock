// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Claudock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Claudock", path: "Sources/Claudock")
    ]
)
