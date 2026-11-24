// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "talkflow-diarize",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "talkflow-diarize", targets: ["talkflow-diarize"])
    ],
    dependencies: [
        // Pinned to an exact release. Only the Diarizer trait is enabled, so the TTS
        // backends and the NeMo text-normalization engine are not compiled or linked
        // (the trait syntax needs tools >= 6.2; older toolchains build everything).
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.18.4",
            traits: ["Diarizer"]
        )
    ],
    targets: [
        .executableTarget(
            name: "talkflow-diarize",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/talkflow-diarize"
        )
    ]
)
