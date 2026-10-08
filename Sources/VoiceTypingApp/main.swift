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
    private var statusLine: NSMenuItem!
    private var controlWindow: NSWindow!
    private var windowStatus: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        buildControlWindow()
        let locale = Locale.current
        let recognizer = AppleSpeechAnalyzerRecognizer(locale: locale)
        let engine = TypingEngine(interCharacterDelay: 0.005, newlineBehavior: .newline)
        let session = VoiceTypingSession(audioCapture: AudioCapture(), recognizer: recognizer, typingEngine: engine)
        self.recognizer = recognizer
        self.session = session
        Task {
            await session.setStateChangeHandler { [weak self] state in
                Task { @MainActor in self?.render(state) }
            }
        }

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
        let stack = NSStackView(views: [title, windowStatus, instructions, start, microphone, typingAccess, install])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 320))
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            windowStatus.widthAnchor.constraint(equalToConstant: 372),
            instructions.widthAnchor.constraint(equalToConstant: 372)
        ])

        controlWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 320),
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func render(_ state: VoiceTypingState) {
        switch state {
        case .idle: setStatus("Idle")
        case .starting: setStatus("Starting…")
        case .listening: setStatus("● Listening · ⌃⌥Space to stop")
        case .stopping: setStatus("Stopping…")
        case .failed(let message): setStatus(message)
        }
    }

    private func setStatus(_ text: String) {
        statusLine?.title = text
        windowStatus?.stringValue = text
        statusItem?.button?.title = text.hasPrefix("●") ? "Voice: Listening" : "Voice: Idle"
    }
}
