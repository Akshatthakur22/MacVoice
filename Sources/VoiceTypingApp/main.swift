import AppKit
import Carbon
import CoreGraphics
import TypingCore
import VoiceTypingCore

@MainActor
private final class ShortcutCaptureButton: NSButton {
    var onCaptured: ((UInt32, UInt32, String) -> Void)?
    var onCancelled: (() -> Void)?
    var isCapturingShortcut = false

    override func keyDown(with event: NSEvent) {
        guard isCapturingShortcut else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            onCancelled?()
            return
        }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonModifiers: UInt32 = 0
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        guard carbonModifiers & UInt32(controlKey | optionKey | cmdKey) != 0 else {
            NSSound.beep()
            return
        }
        onCaptured?(UInt32(event.keyCode), carbonModifiers, characters)
    }
}

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
    private var installPolisherButton: NSButton!
    private var polisherStatus: NSTextField!
    private var polisherSection: NSStackView!
    private var statusSymbol: NSImageView!
    private var shortcutCaptureButton: ShortcutCaptureButton!
    private var shortcutSummary: NSTextField!
    private var shortcutHomeButton: NSButton!
    private var shortcutDisplay = "⌃⌥Space"

    func applicationDidFinishLaunching(_ notification: Notification) {
        removeRetiredPolishingModel()
        let savedShortcut = UserDefaults.standard.dictionary(forKey: "shortcut")
        if let savedShortcut {
            shortcutDisplay = savedShortcut["display"] as? String ?? "⌃⌥Space"
        }
        buildMenu()
        buildControlWindow()
        let locale = Locale.current
        configureSession()

        let shortcutKeyCode = (savedShortcut?["keyCode"] as? NSNumber)?.uint32Value ?? GlobalShortcut.defaultKeyCode
        let shortcutModifiers = (savedShortcut?["modifiers"] as? NSNumber)?.uint32Value ?? GlobalShortcut.defaultModifiers
        let onShortcut: () -> Void = { [weak self] in
            Task { @MainActor in
                self?.setStatus("Shortcut detected · starting dictation…")
                self?.toggleListening()
            }
        }
        let shortcut = GlobalShortcut(keyCode: shortcutKeyCode, modifiers: shortcutModifiers)
        do {
            try shortcut.start(onPress: onShortcut)
            self.shortcut = shortcut
            setStatus("Idle · \(locale.identifier) · shortcut ready")
        } catch {
            guard savedShortcut != nil else {
                setStatus("Shortcut unavailable: \(error.localizedDescription)")
                return
            }
            let fallback = GlobalShortcut()
            do {
                try fallback.start(onPress: onShortcut)
                self.shortcut = fallback
                UserDefaults.standard.removeObject(forKey: "shortcut")
                shortcutDisplay = "⌃⌥Space"
                updateShortcutUI()
                setStatus("Saved shortcut was unavailable, so MacVoice restored the default · \(shortcutDisplay)")
            } catch {
                setStatus("The saved and default shortcuts are unavailable. Open Shortcut settings after resolving the conflict.")
            }
        }
    }

    private func removeRetiredPolishingModel() {
        let legacyModel = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Typer/MLX/models/smollm2", isDirectory: true)
        guard FileManager.default.fileExists(atPath: legacyModel.path) else { return }
        do {
            try FileManager.default.removeItem(at: legacyModel)
        } catch {
            NSLog("MacVoice could not remove its retired SmolLM2 model: %@", error.localizedDescription)
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

        toggleMenuItem = NSMenuItem(title: "Start Dictation (\(shortcutDisplay))", action: #selector(toggleFromMenu), keyEquivalent: "")
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
        icon.widthAnchor.constraint(equalToConstant: 36).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 36).isActive = true
        let title = NSTextField(labelWithString: "MacVoice")
        title.font = .boldSystemFont(ofSize: 21)
        let subtitle = NSTextField(labelWithString: "Speak naturally. Text appears in your active app.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [icon, title, subtitle])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 10

        statusSymbol = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Dictation status")!)
        statusSymbol.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        statusSymbol.contentTintColor = .tertiaryLabelColor
        windowStatus = NSTextField(wrappingLabelWithString: "Idle")
        windowStatus.font = .systemFont(ofSize: 14, weight: .medium)
        windowStatus.maximumNumberOfLines = 3
        let statusRow = NSStackView(views: [statusSymbol, windowStatus])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 8

        startButton = NSButton(title: "Start Dictation", target: self, action: #selector(toggleFromMenu))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.controlSize = .large

        let modeSummary = NSTextField(labelWithString: "")
        modeSummary.font = .systemFont(ofSize: 13)
        modeSummary.textColor = .secondaryLabelColor
        modeSummary.maximumNumberOfLines = 2
        self.modeSummary = modeSummary

        shortcutHomeButton = NSButton(title: "Shortcut: \(shortcutDisplay)  ·  Change…", target: self, action: #selector(showShortcutTab))
        shortcutHomeButton.bezelStyle = .inline
        shortcutHomeButton.setAccessibilityLabel("Current dictation shortcut \(shortcutDisplay). Open shortcut settings.")
        let dictateHelp = NSTextField(wrappingLabelWithString: "Click a text field in another app, then start dictation. MacVoice stays available in the menu bar when this window is closed.")
        dictateHelp.font = .systemFont(ofSize: 12)
        dictateHelp.textColor = .secondaryLabelColor
        dictateHelp.maximumNumberOfLines = 3
        let dictatePage = makePage([statusRow, startButton, modeSummary, shortcutHomeButton, dictateHelp])

        let modeTitle = NSTextField(labelWithString: "Choose how MacVoice handles recognized speech")
        modeTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        modePicker = NSPopUpButton()
        modePicker.addItems(withTitles: ["Verbatim", "Polished"])
        modePicker.selectItem(at: UserDefaults.standard.string(forKey: "typingMode") == PolishingMode.polished.rawValue ? 1 : 0)
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        modeExplanation = NSTextField(wrappingLabelWithString: "")
        modeExplanation.font = .systemFont(ofSize: 13)
        modeExplanation.textColor = .secondaryLabelColor
        modeExplanation.maximumNumberOfLines = 4
        polisherStatus = NSTextField(wrappingLabelWithString: "")
        polisherStatus.font = .systemFont(ofSize: 12)
        polisherStatus.textColor = .secondaryLabelColor
        polisherStatus.maximumNumberOfLines = 3
        installPolisherButton = NSButton(title: "Set Up Polished Mode…", target: self, action: #selector(installPolisher))
        polisherSection = NSStackView(views: [polisherStatus, installPolisherButton])
        polisherSection.orientation = .vertical
        polisherSection.alignment = .leading
        polisherSection.spacing = 8
        let modesPage = makePage([modeTitle, modePicker, modeExplanation, polisherSection])

        let shortcutTitle = NSTextField(labelWithString: "Global dictation shortcut")
        shortcutTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        shortcutSummary = NSTextField(wrappingLabelWithString: "Press this shortcut from any app to start or stop dictation.")
        shortcutSummary.font = .systemFont(ofSize: 13)
        shortcutSummary.textColor = .secondaryLabelColor
        shortcutSummary.maximumNumberOfLines = 3
        shortcutCaptureButton = ShortcutCaptureButton(title: shortcutDisplay, target: self, action: #selector(beginShortcutRecording))
        shortcutCaptureButton.bezelStyle = .rounded
        shortcutCaptureButton.controlSize = .large
        shortcutCaptureButton.setAccessibilityLabel("Dictation shortcut: \(shortcutDisplay). Press to change.")
        shortcutCaptureButton.onCaptured = { [weak self] keyCode, modifiers, keyName in
            self?.finishShortcutRecording(keyCode: keyCode, modifiers: modifiers, keyName: keyName)
        }
        shortcutCaptureButton.onCancelled = { [weak self] in self?.cancelShortcutRecording() }
        let resetShortcut = NSButton(title: "Restore Default", target: self, action: #selector(resetShortcut))
        resetShortcut.bezelStyle = .rounded
        let shortcutActions = NSStackView(views: [shortcutCaptureButton, resetShortcut])
        shortcutActions.orientation = .horizontal
        shortcutActions.alignment = .centerY
        shortcutActions.spacing = 8
        let shortcutTip = NSTextField(wrappingLabelWithString: "Choose a key combination that includes Control, Option, or Command. If another app already uses it, MacVoice keeps your current shortcut. Press Escape while recording to cancel.")
        shortcutTip.font = .systemFont(ofSize: 12)
        shortcutTip.textColor = .secondaryLabelColor
        shortcutTip.maximumNumberOfLines = 4
        let shortcutPage = makePage([shortcutTitle, shortcutSummary, shortcutActions, shortcutTip])

        let appearanceLabel = NSTextField(labelWithString: "Appearance")
        appearanceLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let appearancePicker = NSPopUpButton()
        appearancePicker.addItems(withTitles: ["System", "Light", "Dark"])
        let savedAppearance = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        appearancePicker.selectItem(at: ["system", "light", "dark"].firstIndex(of: savedAppearance) ?? 0)
        appearancePicker.target = self
        appearancePicker.action = #selector(appearanceChanged(_:))

        let permissionsTitle = NSTextField(labelWithString: "Access and setup")
        permissionsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let accessHelp = NSTextField(wrappingLabelWithString: "Microphone access lets MacVoice hear you. Accessibility allows keyboard events to reach the active app. Speech assets are managed by macOS and may need an explicit download for your language.")
        accessHelp.font = .systemFont(ofSize: 12)
        accessHelp.textColor = .secondaryLabelColor
        accessHelp.maximumNumberOfLines = 4
        let microphone = NSButton(title: "Microphone Access…", target: self, action: #selector(requestMicrophoneAccess))
        let typingAccess = NSButton(title: "Accessibility Settings…", target: self, action: #selector(requestTypingAccess))
        let installSpeech = NSButton(title: "Set Up Offline Speech…", target: self, action: #selector(installSpeechAssets))
        let settingsPage = makePage([appearanceLabel, appearancePicker, permissionsTitle, accessHelp, microphone, typingAccess, installSpeech])

        let aboutTitle = NSTextField(labelWithString: "Speak. Type. Done.")
        aboutTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        let aboutText = NSTextField(wrappingLabelWithString: "MacVoice is a local-first voice typing utility. Audio is held in memory during dictation. Verbatim sends confirmed recognition directly to TypingCore. Polished uses an optional local cleanup model. MacVoice does not keep a transcript history.\n\nRequires macOS 26 or later. Speech recognition uses your system locale; language accuracy and destination-app compatibility vary and are not guaranteed.")
        aboutText.font = .systemFont(ofSize: 13)
        aboutText.textColor = .secondaryLabelColor
        aboutText.maximumNumberOfLines = 12
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Development build"
        let versionLabel = NSTextField(labelWithString: "Version \(version) · Locale \(Locale.current.identifier)")
        versionLabel.font = .systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        let aboutPage = makePage([aboutTitle, aboutText, versionLabel])

        let tabs = NSTabView(frame: .zero)
        tabs.tabViewType = .topTabsBezelBorder
        for (identifier, label, view) in [
            ("dictate", "Dictate", dictatePage),
            ("modes", "Modes", modesPage),
            ("shortcut", "Shortcut", shortcutPage),
            ("settings", "Settings", settingsPage),
            ("about", "About", aboutPage)
        ] {
            let item = NSTabViewItem(identifier: identifier)
            item.label = label
            item.view = view
            tabs.addTabViewItem(item)
        }
        self.tabView = tabs

        let root = NSStackView(views: [heading, tabs])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 510))
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            tabs.widthAnchor.constraint(equalToConstant: 512),
            tabs.heightAnchor.constraint(equalToConstant: 390),
            startButton.widthAnchor.constraint(equalToConstant: 450),
            windowStatus.widthAnchor.constraint(equalToConstant: 430),
            modeSummary.widthAnchor.constraint(equalToConstant: 430),
            dictateHelp.widthAnchor.constraint(equalToConstant: 430),
            modeExplanation.widthAnchor.constraint(equalToConstant: 430),
            polisherStatus.widthAnchor.constraint(equalToConstant: 430),
            shortcutSummary.widthAnchor.constraint(equalToConstant: 430),
            shortcutTip.widthAnchor.constraint(equalToConstant: 430),
            accessHelp.widthAnchor.constraint(equalToConstant: 430),
            aboutText.widthAnchor.constraint(equalToConstant: 430)
        ])

        controlWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        controlWindow.title = "MacVoice"
        controlWindow.contentView = content
        controlWindow.isReleasedWhenClosed = false
        controlWindow.minSize = NSSize(width: 540, height: 500)
        controlWindow.defaultButtonCell = startButton.cell as? NSButtonCell
        updateModeUI()
        applyAppearance(savedAppearance)
        controlWindow.center()
    }

    private var modeSummary: NSTextField!
    private var tabView: NSTabView!

    private func makePage(_ views: [NSView]) -> NSView {
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 490, height: 370))
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 18)
        ])
        return page
    }

    @objc private func showShortcutTab() {
        tabView.selectTabViewItem(withIdentifier: "shortcut")
    }

    @objc private func appearanceChanged(_ sender: NSPopUpButton) {
        let preference = ["system", "light", "dark"][max(0, sender.indexOfSelectedItem)]
        UserDefaults.standard.set(preference, forKey: "appearance")
        applyAppearance(preference)
    }

    private func applyAppearance(_ preference: String) {
        switch preference {
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default: NSApplication.shared.appearance = nil
        }
    }

    private func showControlWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        controlWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func beginShortcutRecording() {
        guard let shortcut else {
            setStatus("The global shortcut could not be registered. Restart MacVoice before changing it.")
            return
        }
        guard let session else { return }
        Task {
            let state = await session.state
            let canEdit: Bool
            if case .idle = state { canEdit = true }
            else if case .failed = state { canEdit = true }
            else { canEdit = false }
            guard canEdit else {
                setStatus("Stop dictation before changing the shortcut")
                return
            }
            shortcut.suspend()
            shortcutCaptureButton.isCapturingShortcut = true
            shortcutCaptureButton.title = "Press a shortcut…  (Esc to cancel)"
            shortcutCaptureButton.setAccessibilityLabel("Press the new dictation shortcut. Press Escape to cancel.")
            controlWindow.makeFirstResponder(shortcutCaptureButton)
            setStatus("Choose a shortcut with Control, Option, or Command")
        }
    }

    private func finishShortcutRecording(keyCode: UInt32, modifiers: UInt32, keyName: String) {
        guard let shortcut else {
            stopShortcutRecording()
            setStatus("The global shortcut is unavailable. Restart MacVoice and try again.")
            return
        }
        let display = Self.formatShortcut(modifiers: modifiers, keyName: keyName)
        do {
            try shortcut.update(keyCode: keyCode, modifiers: modifiers)
            UserDefaults.standard.set(["keyCode": Int(keyCode), "modifiers": Int(modifiers), "display": display], forKey: "shortcut")
            shortcutDisplay = display
            stopShortcutRecording()
            updateShortcutUI()
            setStatus("Shortcut changed to \(display)")
        } catch {
            stopShortcutRecording()
            updateShortcutUI()
            setStatus("That shortcut is already in use. Your previous shortcut is still active.")
        }
    }

    private func cancelShortcutRecording() {
        do { try shortcut?.resume() }
        catch { setStatus("Could not restore shortcut: \(error.localizedDescription)") }
        stopShortcutRecording()
        updateShortcutUI()
        setStatus("Shortcut unchanged · \(shortcutDisplay)")
    }

    private func stopShortcutRecording() {
        shortcutCaptureButton.isCapturingShortcut = false
        shortcutCaptureButton.title = shortcutDisplay
        shortcutCaptureButton.setAccessibilityLabel("Dictation shortcut: \(shortcutDisplay). Press to change.")
    }

    @objc private func resetShortcut() {
        guard let shortcut else {
            setStatus("The global shortcut is unavailable. Restart MacVoice and try again.")
            return
        }
        do {
            try shortcut.update(keyCode: GlobalShortcut.defaultKeyCode, modifiers: GlobalShortcut.defaultModifiers)
            stopShortcutRecording()
            UserDefaults.standard.removeObject(forKey: "shortcut")
            shortcutDisplay = "⌃⌥Space"
            updateShortcutUI()
            setStatus("Default shortcut restored · \(shortcutDisplay)")
        } catch {
            setStatus("Could not restore the default shortcut: \(error.localizedDescription)")
        }
    }

    private func updateShortcutUI() {
        shortcutCaptureButton?.title = shortcutDisplay
        shortcutCaptureButton?.setAccessibilityLabel("Dictation shortcut: \(shortcutDisplay). Press to change.")
        shortcutHomeButton?.title = "Shortcut: \(shortcutDisplay)  ·  Change…"
        shortcutHomeButton?.setAccessibilityLabel("Current dictation shortcut \(shortcutDisplay). Open shortcut settings.")
        shortcutSummary?.stringValue = "Press this anywhere to start or stop dictation. Default: Control + Option + Space."
        toggleMenuItem?.title = "Start Dictation (\(shortcutDisplay))"
    }

    private static func formatShortcut(modifiers: UInt32, keyName: String) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        let normalized: String
        switch keyName {
        case " ": normalized = "Space"
        case "\r", "\n": normalized = "Return"
        case "\t": normalized = "Tab"
        default: normalized = keyName.uppercased()
        }
        return result + normalized
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

    @objc private func installPolisher() {
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
            setStatus("Install Python 3.10+ first, then set up Polished mode again.")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, worker.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHON"] = python.path
        process.environment = environment
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("Typer-mlx-setup-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle
        installPolisherButton.isEnabled = false
        installPolisherButton.title = "Setting Up…"
        setStatus("Setting up Polished mode on this Mac. This may take a few minutes.")
        process.terminationHandler = { [weak self] process in
            try? logHandle?.synchronize()
            try? logHandle?.close()
            let detail = (try? String(contentsOf: logURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            try? FileManager.default.removeItem(at: logURL)
            DispatchQueue.main.async {
                guard let self else { return }
                self.installPolisherButton.isEnabled = true
                self.installPolisherButton.title = "Set Up Polished Mode…"
                self.setStatus(process.terminationStatus == 0 ? "Polished mode is ready · cleanup runs on this Mac" : "Model setup failed: \(detail.suffix(220))")
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
        if let oldPolisher = polisher { Task { await oldPolisher.stop() } }
        let polisher = LocalMLXTranscriptPolisher()
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
        guard polisherStatus != nil else { return }
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Typer/MLX")
        let installed = FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("venv/bin/python3").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("models/qwen025/config.json").path)
        polisherStatus.stringValue = installed
            ? "Polished mode is ready. The local cleanup model runs on this Mac."
            : "Polished mode needs a one-time model setup. Until then, dictation uses Verbatim."
    }

    private func updateModeUI() {
        guard modePicker != nil else { return }
        let polished = modePicker.indexOfSelectedItem == 1
        modeSummary?.stringValue = polished
            ? "Selected: Polished · cleans up phrasing locally and may take a little longer."
            : "Selected: Verbatim · sends recognized words directly with minimal changes."
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
            toggleMenuItem?.title = "Start Dictation (\(shortcutDisplay))"
            modePicker?.isEnabled = true
        case .starting:
            setStatus("Starting dictation…")
            statusSymbol.contentTintColor = .controlAccentColor
            startButton?.title = "Starting…"
            startButton?.isEnabled = false
            toggleMenuItem?.title = "Starting…"
            modePicker?.isEnabled = false
        case .listening:
            setStatus("Listening · \(shortcutDisplay) to stop")
            statusSymbol.contentTintColor = .systemRed
            startButton?.title = "Stop Dictation"
            startButton?.isEnabled = true
            toggleMenuItem?.title = "Stop Dictation (\(shortcutDisplay))"
            modePicker?.isEnabled = false
        case .stopping:
            setStatus("Finishing dictation…")
            statusSymbol.contentTintColor = .controlAccentColor
            startButton?.title = "Finishing…"
            startButton?.isEnabled = false
            toggleMenuItem?.title = "Finishing…"
            modePicker?.isEnabled = false
        case .failed(let message):
            setStatus("Dictation failed: \(message)")
            statusSymbol.contentTintColor = .systemOrange
            startButton?.title = "Try Again"
            startButton?.isEnabled = true
            toggleMenuItem?.title = "Try Dictation Again"
            modePicker?.isEnabled = true
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
