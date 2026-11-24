// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "talkflowd",
    platforms: [.macOS(.v13)],
    targets: [
        // A lock-free single-producer/single-consumer ring in C11 atomics: the Core Audio IOProc runs on a
        // real-time thread that must never lock or allocate, and Swift has no atomics before macOS 15.
        .target(name: "CaptureRing", path: "Sources/CaptureRing"),
        .executableTarget(name: "talkflowd", dependencies: ["CaptureRing"], path: "Sources/talkflowd"),
    ]
)
