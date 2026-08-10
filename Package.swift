// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "talkflowd",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "talkflowd", path: "Sources/talkflowd")
    ]
)
