import AppKit

// Headless correctness checks (no GUI): `swift run Typer --selftest`.
if CommandLine.arguments.contains("--selftest") {
    exit(Int32(TyperSelfTest.run()))
}

// Objective detector scorecard (no GUI): `swift run Typer --detect`.
if CommandLine.arguments.contains("--detect") {
    exit(Int32(Detector.run()))
}

// Real-delivery throughput check (no GUI): `swift run Typer --speedtest`.
if CommandLine.arguments.contains("--speedtest") {
    exit(Int32(TyperSelfTest.runSpeedTest()))
}

// Entry point. Typer is a regular windowed app (Dock icon + main window) that also
// keeps a menu-bar item, global hotkey, and triple-Esc kill switch running in background.
InterFonts.registerAll()   // register bundled Inter before any UI renders

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
