// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypingCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TypingCore", targets: ["TypingCore"]),
        .executable(name: "TypingCoreDemo", targets: ["TypingCoreDemo"])
    ],
    targets: [
        .target(name: "TypingCore"),
        .executableTarget(name: "TypingCoreDemo", dependencies: ["TypingCore"]),
        .testTarget(name: "TypingCoreTests", dependencies: ["TypingCore"])
    ]
)
