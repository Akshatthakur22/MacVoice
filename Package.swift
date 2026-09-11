// swift-tools-version:5.9
// Swift 5 language mode (default for tools 5.9) is deliberate: this is a
// single-main-thread, timer/callback-driven menu-bar agent.
import PackageDescription

let package = Package(
    name: "Typer",
    platforms: [.macOS(.v14)],
    targets: [
        // The app.
        .executableTarget(
            name: "Typer",
            path: "Sources/Typer",
            resources: [
                .copy("Resources/Fonts")   // bundled Inter faces (registered at launch)
            ]
        ),
        // De-risk harness: proves CGEvent injection is seen as isTrusted.
        .executableTarget(
            name: "InjectTest",
            path: "Sources/InjectTest"
        ),
    ]
)
