// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypingCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TypingCore", targets: ["TypingCore"]),
        .library(name: "VoiceTypingCore", targets: ["VoiceTypingCore"]),
        .executable(name: "TypingCoreDemo", targets: ["TypingCoreDemo"]),
        .executable(name: "VoiceTypingApp", targets: ["VoiceTypingApp"])
    ],
    targets: [
        .target(name: "TypingCore"),
        .target(name: "VoiceTypingCore", dependencies: ["TypingCore"]),
        .executableTarget(name: "TypingCoreDemo", dependencies: ["TypingCore"]),
        .executableTarget(name: "VoiceTypingApp", dependencies: ["TypingCore", "VoiceTypingCore"]),
        .executableTarget(name: "VoiceTypingCoreChecks", dependencies: ["VoiceTypingCore"]),
        .executableTarget(name: "VoiceTypingBenchmark", dependencies: ["VoiceTypingCore"]),
        .testTarget(
            name: "TypingCoreTests",
            dependencies: ["TypingCore", "VoiceTypingCore"],
            path: "Tests/TypingCoreTests"
        )
    ]
)
