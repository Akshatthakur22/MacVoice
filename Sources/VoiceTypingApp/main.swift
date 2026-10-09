import AppKit
import CoreGraphics
import TypingCore
import VoiceTypingCore

@main
@MainActor
enum VoiceTypingAppMain {
    static func main() {
        guard #available(macOS 26.0, *) else {
            fputs("VoiceTypingApp requires macOS 26 or later.\n", stderr)
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = VoiceTypingAppDelegate()
        application.delegate = delegate
        application.run()
    }
}

@MainActor
@available(macOS 26.0, *)
private final class VoiceTypingAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var shortcut: GlobalShortcut?
    private var session: VoiceTypingSession?
    private var recognizer: AppleSpeechAnalyzerRecognizer?
    private var polisher: LocalMLXTranscriptPolisher?
    private var statusLine: NSMenuItem!
    private var controlWindow: NSWindow!
    private var windowStatus: NSTextField!
    private var modePicker: NSPopUpButton!
    private var modelPicker: NSPopUpButton!
    private var installPolisherButton: NSButton!
    private var polisherStatus: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildControlWindow()
        let locale = Locale.current
        configureSession()

        let shortcut = GlobalShortcut()
        do {
            try shortcut.start { [weak self] in
                Task { @MainActor in
                    self?.setStatus("Shortcut detected · starting dictation…")
                    self?.toggleListening()
                }
            }
            self.shortcut = shortcut
            setStatus("Idle · \(locale.identifier) · shortcut ready")
        } catch {
            setStatus("Shortcut unavailable: \(error.localizedDescription)")
        }
        showControlWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showControlWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        shortcut?.stop()
        if let session { Task { await session.stop() } }
        if let polisher { Task { await polisher.stop() } }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Voice: Idle"

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Start / Stop Voice Typing", action: #selector(toggleFromMenu), keyEquivalent: " ")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.target = self
        menu.addItem(toggle)

        let permission = NSMenuItem(title: "Request Microphone Access", action: #selector(requestMicrophoneAccess), keyEquivalent: "")
        permission.target = self
        menu.addItem(permission)

        let install = NSMenuItem(title: "Install Speech Model for Current Language…", action: #selector(installSpeechAssets), keyEquivalent: "")
        install.target = self
        menu.addItem(install)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func buildControlWindow() {
        let title = NSTextField(labelWithString: "Voice Typing")
        title.font = .boldSystemFont(ofSize: 22)

        windowStatus = NSTextField(wrappingLabelWithString: "Idle")
        windowStatus.font = .systemFont(ofSize: 13)
        windowStatus.maximumNumberOfLines = 3

        let instructions = NSTextField(wrappingLabelWithString: "Choose a text field, then press Control+Option+Space to start or stop dictation.")
        instructions.font = .systemFont(ofSize: 13)
        instructions.maximumNumberOfLines = 3

        let start = NSButton(title: "Start / Stop Dictation", target: self, action: #selector(toggleFromMenu))
        let microphone = NSButton(title: "Request Microphone Access", target: self, action: #selector(requestMicrophoneAccess))
        let typingAccess = NSButton(title: "Allow Keyboard Typing Access", target: self, action: #selector(requestTypingAccess))
        let install = NSButton(title: "Install Speech Model…", target: self, action: #selector(installSpeechAssets))
        let modeLabel = NSTextField(labelWithString: "Typing mode")
        modePicker = NSPopUpButton()
        modePicker.addItems(withTitles: ["Verbatim (fastest)", "Polished (local AI)"])
        modePicker.selectItem(at: UserDefaults.standard.string(forKey: "typingMode") == PolishingMode.polished.rawValue ? 1 : 0)
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        let modelLabel = NSTextField(labelWithString: "Local polish model")
        modelPicker = NSPopUpButton()
        modelPicker.addItems(withTitles: PolishingModel.allCases.map(\.title))
        let savedModel = UserDefaults.standard.string(forKey: "polishingModel") ?? PolishingModel.qwen025.rawValue
        modelPicker.selectItem(at: PolishingModel.allCases.firstIndex(where: { $0.rawValue == savedModel }) ?? 0)
        modelPicker.target = self
        modelPicker.action = #selector(modelChanged)
        installPolisherButton = NSButton(title: "Install Local Polishing Model…", target: self, action: #selector(installPolisher))
        polisherStatus = NSTextField(wrappingLabelWithString: "Local model status: not installed")
        polisherStatus.maximumNumberOfLines = 2
        let stack = NSStackView(views: [title, windowStatus, instructions, start, microphone, typingAccess, install, modeLabel, modePicker, modelLabel, modelPicker, polisherStatus, installPolisherButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 550))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            windowStatus.widthAnchor.constraint(equalToConstant: 392),
            instructions.widthAnchor.constraint(equalToConstant: 392)
        ])

        controlWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 550),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        controlWindow.title = "TypingCore Voice Typing"
        controlWindow.contentView = content
        controlWindow.isReleasedWhenClosed = false
        controlWindow.center()
    }

    private func showControlWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        controlWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleFromMenu() {
        toggleListening()
    }

    private func toggleListening() {
        guard let session else { return }
        Task {
            var currentState = await session.state
            if currentState == .listening || currentState == .starting {
                await session.stop()
                return
            }
            if case .failed = currentState {
                await session.resetFailure()
                currentState = await session.state
            }
            guard currentState == .idle else { return }
            guard await AudioCapture.requestPermission() else {
                setStatus("Microphone access denied")
                return
            }
            do {
                try await session.start()
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }

    @objc private func requestMicrophoneAccess() {
        Task {
            let allowed = await AudioCapture.requestPermission()
            setStatus(allowed ? "Microphone access granted" : "Microphone access denied")
        }
    }

    @objc private func requestTypingAccess() {
        if CGPreflightPostEventAccess() {
            setStatus("Keyboard typing access is already granted")
            return
        }
        let granted = CGRequestPostEventAccess()
        setStatus(granted
            ? "Keyboard typing access granted"
            : "Enable VoiceTyping in System Settings → Privacy & Security → Accessibility, then reopen the app")
    }

    @objc private func installSpeechAssets() {
        guard let recognizer else { return }
        setStatus("Installing on-device speech assets…")
        Task {
            do {
                try await recognizer.installAssets()
                setStatus("Speech assets installed · ready offline")
            } catch {
                setStatus(error.localizedDescription)
            }
        }
    }

    @objc private func modeChanged() {
        let mode: PolishingMode = modePicker.indexOfSelectedItem == 1 ? .polished : .verbatim
        UserDefaults.standard.set(mode.rawValue, forKey: "typingMode")
        configureSession()
        setStatus(mode == .polished ? "Polished mode · local model required" : "Verbatim mode · direct typing")
    }

    @objc private func modelChanged() {
        let model = PolishingModel.allCases[modelPicker.indexOfSelectedItem]
        UserDefaults.standard.set(model.rawValue, forKey: "polishingModel")
        updatePolisherStatus()
        setStatus("Selected \(model.title). Install it before choosing Polished mode.")
        configureSession()
    }

    @objc private func installPolisher() {
        let model = PolishingModel.allCases[modelPicker.indexOfSelectedItem]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let bundledResources = Bundle.main.resourceURL
        let bundledScript = bundledResources?.appendingPathComponent("install_local_polisher.sh")
        let bundledWorker = bundledResources?.appendingPathComponent("mlx_worker.py")
        let script = bundledScript.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? root.appendingPathComponent("scripts/install_local_polisher.sh")
        let worker = bundledWorker.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? root.appendingPathComponent("Resources/mlx_worker.py")
        guard let python = suitablePython() else {
            setStatus("Install Python 3.10+ first, then use Install Local Polishing Model again.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, model.rawValue, worker.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHON"] = python.path
        process.environment = environment
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("Typer-mlx-setup-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        installPolisherButton.isEnabled = false
        setStatus("Setting up Python/MLX and downloading \(model.title)… Internet is used only for this explicit setup.")
        process.terminationHandler = { [weak self] process in
            try? logHandle?.synchronize()
            try? logHandle?.close()
            let detail = (try? String(contentsOf: logURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: logURL)
            DispatchQueue.main.async {
                guard let self else { return }
                self.installPolisherButton.isEnabled = true
                self.setStatus(process.terminationStatus == 0 ? "Local model installed · inference stays on this Mac" : "Model setup failed: \(detail.suffix(220))")
                self.updatePolisherStatus()
            }
        }
        do { try process.run() }
        catch {
            installPolisherButton.isEnabled = true
            setStatus("Could not start model setup: \(error.localizedDescription)")
        }
    }

    private func suitablePython() -> URL? {
        var candidates = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("python3") } ?? []
        candidates += [URL(fileURLWithPath: "/opt/homebrew/bin/python3"), URL(fileURLWithPath: "/usr/local/bin/python3")]
        let pyenvVersions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pyenv/versions")
        if let versions = try? FileManager.default.contentsOfDirectory(at: pyenvVersions, includingPropertiesForKeys: nil) {
            candidates += versions.sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin/python3") }
        }
        return candidates.first { candidate in
            guard FileManager.default.isExecutableFile(atPath: candidate.path) else { return false }
            let probe = Process()
            probe.executableURL = candidate
            probe.arguments = ["-c", "import sys; print('%d.%d' % sys.version_info[:2])"]
            let pipe = Pipe()
            probe.standardOutput = pipe
            probe.standardError = FileHandle.nullDevice
            do { try probe.run() } catch { return false }
            let version = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            probe.waitUntilExit()
            let pieces = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").compactMap { Int($0) }
            return probe.terminationStatus == 0 && pieces.count == 2
                && pieces[0] == 3 && pieces[1] >= 10 && pieces[1] < 14
        }
    }

    private func configureSession() {
        let locale = Locale.current
        let recognizer = AppleSpeechAnalyzerRecognizer(locale: locale)
        let engine = TypingEngine(interCharacterDelay: 0.005, newlineBehavior: .newline)
        let mode = PolishingMode(rawValue: UserDefaults.standard.string(forKey: "typingMode") ?? "verbatim") ?? .verbatim
        let modelKey = UserDefaults.standard.string(forKey: "polishingModel") ?? PolishingModel.qwen025.rawValue
        let model = PolishingModel(rawValue: modelKey) ?? .qwen025
        if let oldPolisher = polisher { Task { await oldPolisher.stop() } }
        let polisher = LocalMLXTranscriptPolisher(model: model)
        self.polisher = polisher
        let session = VoiceTypingSession(
            audioCapture: AudioCapture(), recognizer: recognizer, typingEngine: engine,
            polisher: polisher, polishingMode: mode
        )
        self.recognizer = recognizer
        self.session = session
        updatePolisherStatus()
        Task {
            await session.setStateChangeHandler { [weak self] state in
                Task { @MainActor in self?.render(state) }
            }
            await session.setWarningHandler { [weak self] message in
                Task { @MainActor in self?.setStatus(message) }
            }
        }
    }

    private func updatePolisherStatus() {
        guard polisherStatus != nil, modelPicker != nil else { return }
        let model = PolishingModel.allCases[modelPicker.indexOfSelectedItem]
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Typer/MLX")
        let installed = FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("venv/bin/python3").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("models/\(model.rawValue)/config.json").path)
        polisherStatus.stringValue = installed
            ? "Local model status: \(model.title) installed"
            : "Local model status: \(model.title) not installed · Polished mode will fall back to verbatim"
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func render(_ state: VoiceTypingState) {
        switch state {
        case .idle:
            setStatus("Idle")
            modePicker?.isEnabled = true
            modelPicker?.isEnabled = true
        case .starting:
            setStatus("Starting…")
            modePicker?.isEnabled = false
            modelPicker?.isEnabled = false
        case .listening:
            setStatus("● Listening · ⌃⌥Space to stop")
            modePicker?.isEnabled = false
            modelPicker?.isEnabled = false
        case .stopping:
            setStatus("Stopping…")
            modePicker?.isEnabled = false
            modelPicker?.isEnabled = false
        case .failed(let message):
            setStatus(message)
            modePicker?.isEnabled = true
            modelPicker?.isEnabled = true
        }
    }

    private func setStatus(_ text: String) {
        statusLine?.title = text
        windowStatus?.stringValue = text
        statusItem?.button?.title = text.hasPrefix("●") ? "Voice: Listening" : "Voice: Idle"
    }
}
