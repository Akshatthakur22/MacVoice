import AppKit
import CoreGraphics
import TypingCore
import VoiceTypingCore

@main
@MainActor
enum VoiceTypingAppMain {
    static func main() {
        guard #available(macOS 26.0, *) else {
            fputs("MacVoice requires macOS 26 or later.\n", stderr)
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
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
    private var toggleMenuItem: NSMenuItem!
    private var controlWindow: NSWindow!
    private var windowStatus: NSTextField!
    private var modeExplanation: NSTextField!
    private var startButton: NSButton!
    private var modePicker: NSPopUpButton!
    private var modelPicker: NSPopUpButton!
    private var installPolisherButton: NSButton!
    private var polisherStatus: NSTextField!
    private var polisherSection: NSStackView!
    private var statusSymbol: NSImageView!

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
        if let button = statusItem.button {
            button.title = "MacVoice"
            button.image = brandImage(named: "MacVoiceMenuBar") ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "MacVoice status")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.toolTip = "MacVoice voice typing status"
        }

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        toggleMenuItem = NSMenuItem(title: "Start Dictation", action: #selector(toggleFromMenu), keyEquivalent: " ")
        toggleMenuItem.keyEquivalentModifierMask = [.control, .option]
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        let settings = NSMenuItem(title: "MacVoice Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let permission = NSMenuItem(title: "Microphone Access…", action: #selector(requestMicrophoneAccess), keyEquivalent: "")
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
        let iconImage = brandImage(named: "MacVoiceAppIcon")
            ?? NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "MacVoice")!
        let icon = NSImageView(image: iconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityLabel("MacVoice app icon")
        icon.widthAnchor.constraint(equalToConstant: 38).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 38).isActive = true
        let title = NSTextField(labelWithString: "MacVoice")
        title.font = .boldSystemFont(ofSize: 22)
        let subtitle = NSTextField(labelWithString: "Speak naturally. Text appears in your active app.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [icon, title])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10

        statusSymbol = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Idle")!)
        statusSymbol.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        statusSymbol.contentTintColor = .tertiaryLabelColor
        windowStatus = NSTextField(wrappingLabelWithString: "Ready · Control+Option+Space to dictate")
        windowStatus.font = .systemFont(ofSize: 13, weight: .medium)
        windowStatus.maximumNumberOfLines = 3
        let statusRow = NSStackView(views: [statusSymbol, windowStatus])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        startButton = NSButton(title: "Start Dictation", target: self, action: #selector(toggleFromMenu))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"

        let modeLabel = NSTextField(labelWithString: "Dictation style")
        modeLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        modePicker = NSPopUpButton()
        modePicker.addItems(withTitles: ["Verbatim", "Polished"])
        modePicker.selectItem(at: UserDefaults.standard.string(forKey: "typingMode") == PolishingMode.polished.rawValue ? 1 : 0)
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        modeExplanation = NSTextField(wrappingLabelWithString: "Types recognized words with minimal changes.")
        modeExplanation.font = .systemFont(ofSize: 12)
        modeExplanation.textColor = .secondaryLabelColor
        modeExplanation.maximumNumberOfLines = 2

        let modelLabel = NSTextField(labelWithString: "Cleanup model")
        modelLabel.font = .systemFont(ofSize: 12, weight: .medium)
        modelPicker = NSPopUpButton()
        modelPicker.addItems(withTitles: PolishingModel.allCases.map { $0 == .qwen025 ? "Recommended · Qwen 0.5B" : $0.title })
        let savedModel = UserDefaults.standard.string(forKey: "polishingModel") ?? PolishingModel.qwen025.rawValue
        modelPicker.selectItem(at: PolishingModel.allCases.firstIndex(where: { $0.rawValue == savedModel }) ?? 0)
        modelPicker.target = self
        modelPicker.action = #selector(modelChanged)
        polisherStatus = NSTextField(wrappingLabelWithString: "Cleanup model is not installed.")
        polisherStatus.font = .systemFont(ofSize: 12)
        polisherStatus.textColor = .secondaryLabelColor
        polisherStatus.maximumNumberOfLines = 2
        installPolisherButton = NSButton(title: "Download Cleanup Model…", target: self, action: #selector(installPolisher))
        polisherSection = NSStackView(views: [modelLabel, modelPicker, polisherStatus, installPolisherButton])
        polisherSection.orientation = .vertical
        polisherSection.alignment = .leading
        polisherSection.spacing = 7

        let modeStack = NSStackView(views: [modeLabel, modePicker, modeExplanation, polisherSection])
        modeStack.orientation = .vertical
        modeStack.alignment = .leading
        modeStack.spacing = 8

        let permissionsTitle = NSTextField(labelWithString: "Access")
        permissionsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let microphone = NSButton(title: "Microphone Access…", target: self, action: #selector(requestMicrophoneAccess))
        let typingAccess = NSButton(title: "Accessibility Settings…", target: self, action: #selector(requestTypingAccess))
        let installSpeech = NSButton(title: "Set Up Offline Speech…", target: self, action: #selector(installSpeechAssets))
        let accessStack = NSStackView(views: [permissionsTitle, microphone, typingAccess, installSpeech])
        accessStack.orientation = .vertical
        accessStack.alignment = .leading
        accessStack.spacing = 7

        let instructions = NSTextField(wrappingLabelWithString: "Click in a text field first. Use Control+Option+Space to start and stop.")
        instructions.font = .systemFont(ofSize: 12)
        instructions.textColor = .secondaryLabelColor
        instructions.maximumNumberOfLines = 2
        let stack = NSStackView(views: [heading, subtitle, statusRow, startButton, modeStack, accessStack, instructions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 500))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            windowStatus.widthAnchor.constraint(equalToConstant: 350),
            modeExplanation.widthAnchor.constraint(lessThanOrEqualToConstant: 350),
            polisherStatus.widthAnchor.constraint(lessThanOrEqualToConstant: 350),
            instructions.widthAnchor.constraint(lessThanOrEqualToConstant: 350),
            startButton.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        controlWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        controlWindow.title = "MacVoice"
        controlWindow.contentView = content
        controlWindow.isReleasedWhenClosed = false
        controlWindow.minSize = NSSize(width: 390, height: 440)
        controlWindow.defaultButtonCell = startButton.cell as? NSButtonCell
        updateModeUI()
        controlWindow.center()
    }

    private func showControlWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        controlWindow?.makeKeyAndOrderFront(nil)
    }

    private func brandImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    @objc private func toggleFromMenu() {
        toggleListening()
    }

    @objc private func openSettings() {
        showControlWindow()
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
        guard !granted else {
            setStatus("Keyboard typing access granted")
            return
        }

        setStatus("Enable MacVoice under Privacy & Security → Accessibility, then reopen the app")
        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(settingsURL)
        }
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
        updateModeUI()
        configureSession()
        setStatus(mode == .polished ? "Polished mode selected" : "Verbatim mode selected")
    }

    @objc private func modelChanged() {
        let model = PolishingModel.allCases[modelPicker.indexOfSelectedItem]
        UserDefaults.standard.set(model.rawValue, forKey: "polishingModel")
        updatePolisherStatus()
        setStatus("Cleanup model changed")
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
        installPolisherButton.title = "Downloading…"
        setStatus("Downloading the cleanup model. This may take a few minutes.")
        process.terminationHandler = { [weak self] process in
            try? logHandle?.synchronize()
            try? logHandle?.close()
            let detail = (try? String(contentsOf: logURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: logURL)
            DispatchQueue.main.async {
                guard let self else { return }
                self.installPolisherButton.isEnabled = true
                self.installPolisherButton.title = "Download Cleanup Model…"
                self.setStatus(process.terminationStatus == 0 ? "Cleanup model installed · processing stays on this Mac" : "Model setup failed: \(detail.suffix(220))")
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
            ? "Cleanup model is installed and runs on this Mac."
            : "Cleanup model is not installed. Polished mode will use Verbatim until setup is complete."
    }

    private func updateModeUI() {
        guard modePicker != nil else { return }
        let polished = modePicker.indexOfSelectedItem == 1
        modeExplanation.stringValue = polished
            ? "Tidies punctuation and phrasing on this Mac; it can take a little longer."
            : "Types recognized words with minimal changes."
        polisherSection.isHidden = !polished
        polisherSection.setAccessibilityElement(true)
        polisherSection.setAccessibilityLabel("Polished mode cleanup model settings")
        updatePolisherStatus()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func render(_ state: VoiceTypingState) {
        switch state {
        case .idle:
            setStatus("Idle")
            statusSymbol.contentTintColor = .tertiaryLabelColor
            startButton?.title = "Start Dictation"
            startButton?.isEnabled = true
            toggleMenuItem?.title = "Start Dictation"
            modePicker?.isEnabled = true
            modelPicker?.isEnabled = true
        case .starting:
            setStatus("Starting dictation…")
            statusSymbol.contentTintColor = .controlAccentColor
            startButton?.title = "Starting…"
            startButton?.isEnabled = false
            toggleMenuItem?.title = "Starting…"
            modePicker?.isEnabled = false
            modelPicker?.isEnabled = false
        case .listening:
            setStatus("Listening · Control+Option+Space to stop")
            statusSymbol.contentTintColor = .systemRed
            startButton?.title = "Stop Dictation"
            startButton?.isEnabled = true
            toggleMenuItem?.title = "Stop Dictation"
            modePicker?.isEnabled = false
            modelPicker?.isEnabled = false
        case .stopping:
            setStatus("Finishing dictation…")
            statusSymbol.contentTintColor = .controlAccentColor
            startButton?.title = "Finishing…"
            startButton?.isEnabled = false
            toggleMenuItem?.title = "Finishing…"
            modePicker?.isEnabled = false
            modelPicker?.isEnabled = false
        case .failed(let message):
            setStatus("Dictation failed: \(message)")
            statusSymbol.contentTintColor = .systemOrange
            startButton?.title = "Try Again"
            startButton?.isEnabled = true
            toggleMenuItem?.title = "Try Dictation Again"
            modePicker?.isEnabled = true
            modelPicker?.isEnabled = true
        }
    }

    private func setStatus(_ text: String) {
        statusLine?.title = text
        windowStatus?.stringValue = text
        let normalized = text.lowercased()
        let statusTitle: String
        if normalized.contains("listen") { statusTitle = "Listening" }
        else if normalized.contains("start") { statusTitle = "Starting" }
        else if normalized.contains("finish") || normalized.contains("stopp") { statusTitle = "Finishing" }
        else if normalized.contains("fail") || normalized.contains("denied") || normalized.contains("unavailable") || normalized.contains("enable macvoice") || normalized.contains("could not") { statusTitle = "Attention" }
        else { statusTitle = "Ready" }
        statusItem?.button?.title = "MacVoice · \(statusTitle)"
        statusSymbol?.contentTintColor = statusTitle == "Attention" ? .systemOrange : (statusTitle == "Listening" ? .systemRed : .tertiaryLabelColor)
        statusItem?.button?.setAccessibilityLabel("MacVoice, \(statusTitle)")
        statusLine?.setAccessibilityLabel("MacVoice status: \(text)")
    }
}
