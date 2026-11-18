import AppKit
import Carbon
import CoreGraphics
import ServiceManagement
import Speech
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
    private var currentConfiguredLocale: Locale?
    /// System locale identifier the current session was prepared for. The
    /// configured speech locale may differ (e.g. en_IN system using an installed
    /// en_US model), so compare against this to decide whether to rebuild.
    private var preparedForSystemLocaleID: String?
    private let sessionStartCoordinator = SessionStartCoordinator()
    private var recognizer: AppleSpeechAnalyzerRecognizer?
    private var previousState: VoiceTypingState = .idle
    private var accessibilityPollTimer: Timer?
    private var launchAtLoginCheckbox: NSButton!
    private var soundFeedbackCheckbox: NSButton!
    private var compatibilityTypingCheckbox: NSButton!
    private var accessibilityStatusLabel: NSTextField!
    private var statusLine: NSMenuItem!
    private var toggleMenuItem: NSMenuItem!
    private var controlWindow: NSWindow!
    private var windowStatus: NSTextField!
    private var modeExplanation: NSTextField!
    private var startButton: NSButton!
    private var modePicker: NSPopUpButton!
    private var polisherStatus: NSTextField!
    private var polisherSection: NSStackView!
    private var statusSymbol: NSImageView!
    private var shortcutCaptureButton: ShortcutCaptureButton!
    private var shortcutSummary: NSTextField!
    private var shortcutHomeButton: NSButton!
    private var shortcutDisplay = "⌃⌥Space"
    private var customWordsTextView: NSTextView!
    private var replacementsTextView: NSTextView!
    private var vocabularyStatus: NSTextField!
    /// Settings changed while dictating; rebuild the session once it is idle.
    private var needsSessionRebuild = false
    /// Menu bar recording indicator: pulse and elapsed time while listening.
    private var menuBarPulseTimer: Timer?
    private var listeningStartedAt: Date?
    private var menuBarPulseDimmed = false

    /// Replaces the old "typeOneCharacterAtATime" key so everyone gets the
    /// letter-by-letter typing animation back by default.
    private static let animatedTypingKey = "animatedTyping"
    private static var animatedTyping: Bool {
        UserDefaults.standard.object(forKey: animatedTypingKey) as? Bool ?? true
    }
    private static let vocabularyWordsKey = "vocabularyWords"
    private static let vocabularyReplacementsKey = "vocabularyReplacements"
    private static let defaultWordsText = "# One word or phrase per line. Examples:\nAPI\nMacVoice"
    private static let defaultReplacementsText = "# What you say => what to type. Example:\nmac voice => MacVoice"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let savedShortcut = UserDefaults.standard.dictionary(forKey: "shortcut")
        if let savedShortcut {
            shortcutDisplay = savedShortcut["display"] as? String ?? "⌃⌥Space"
        }
        buildMenu()
        buildControlWindow()
        registerSleepWakeNotifications()
        Task { @MainActor in
            await self.configureSession()
            // Proactively warm up and verify speech assets in background so dictation is instant
            try? await self.prepareSpeechAssetsAndSession()
        }

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
            setStatus("Idle · \(Locale.current.identifier) · shortcut ready")
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

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showControlWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityPollTimer?.invalidate()
        shortcut?.stop()
        let currentSession = session
        let startCoordinator = sessionStartCoordinator
        Task { @MainActor in
            await startCoordinator.cancelAndWait()
            await currentSession?.stop()
        }
    }

    private func registerSleepWakeNotifications() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        guard let session = self.session else { return }
        Task { @MainActor in
            let state = await session.state
            if state == .listening || state == .starting {
                await self.sessionStartCoordinator.cancelAndWait()
                await session.stop()
                self.setStatus("Dictation paused for system sleep")
            }
        }
    }

    @objc private func systemDidWake(_ notification: Notification) {
        // Re-arm the session on wake to refresh stale speech-daemon connections,
        // but never replace a session that is still running (it would keep the
        // microphone open with no way to stop it).
        rebuildSessionWhenIdle()
        Task { @MainActor in
            if await self.session?.state == .idle {
                self.setStatus("Idle · \(Locale.current.identifier) · shortcut ready")
            }
        }
    }

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // Icon only, like system menu bar items; the elapsed time appears
            // next to it while listening.
            button.image = MenuBarIcon.image(for: .idle)
            button.imagePosition = .imageLeading
            button.title = ""
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
            button.toolTip = "MacVoice"
        }

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        toggleMenuItem = NSMenuItem(title: "Start Dictation (\(shortcutDisplay))", action: #selector(toggleFromMenu), keyEquivalent: "")
        toggleMenuItem.target = self
        toggleMenuItem.image = Self.menuSymbol("mic")
        menu.addItem(toggleMenuItem)

        let settings = NSMenuItem(title: "MacVoice Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = Self.menuSymbol("gearshape")
        menu.addItem(settings)

        let permission = NSMenuItem(title: "Microphone Access…", action: #selector(requestMicrophoneAccess), keyEquivalent: "")
        permission.target = self
        permission.image = Self.menuSymbol("lock.shield")
        menu.addItem(permission)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MacVoice", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func buildControlWindow() {
        // The bundle's .icns already contains every size; no separate PNG needed.
        let iconImage = NSApplication.shared.applicationIconImage
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
        let dictateHelp = NSTextField(wrappingLabelWithString: "Click any text field in any app, press your shortcut, and speak. Text streams live to your cursor.")
        dictateHelp.font = .systemFont(ofSize: 12)
        dictateHelp.textColor = .secondaryLabelColor
        dictateHelp.maximumNumberOfLines = 3

        let testSandboxLabel = NSTextField(labelWithString: "Try it now in this test box:")
        testSandboxLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        testSandboxLabel.textColor = .secondaryLabelColor

        let testSandbox = NSTextField()
        testSandbox.placeholderString = "Click here, press \(shortcutDisplay), and speak to test…"
        testSandbox.font = .systemFont(ofSize: 13)
        testSandbox.widthAnchor.constraint(equalToConstant: 450).isActive = true

        let dictatePage = makePage([statusRow, startButton, modeSummary, shortcutHomeButton, dictateHelp, testSandboxLabel, testSandbox])

        let modeTitle = NSTextField(labelWithString: "Choose how MacVoice handles recognized speech")
        modeTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        modePicker = NSPopUpButton()
        modePicker.addItems(withTitles: ["Verbatim", "Polished"])
        modePicker.selectItem(at: (UserDefaults.standard.string(forKey: "typingMode") ?? PolishingMode.polished.rawValue) == PolishingMode.polished.rawValue ? 1 : 0)
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
        polisherSection = NSStackView(views: [polisherStatus])
        polisherSection.orientation = .vertical
        polisherSection.alignment = .leading
        polisherSection.spacing = 8
        let modesPage = makePage([modeTitle, modePicker, modeExplanation, polisherSection])

        let wordsTitle = NSTextField(labelWithString: "Custom words")
        wordsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let wordsHelp = NSTextField(wrappingLabelWithString: "One per line: names, product terms, jargon. Apple's on-device recognizer will prefer these spellings. Works in both modes.")
        wordsHelp.font = .systemFont(ofSize: 11)
        wordsHelp.textColor = .secondaryLabelColor
        wordsHelp.maximumNumberOfLines = 2
        let (wordsEditor, wordsTextView) = makeTextEditor(
            UserDefaults.standard.string(forKey: Self.vocabularyWordsKey) ?? Self.defaultWordsText)
        customWordsTextView = wordsTextView
        let replacementsTitle = NSTextField(labelWithString: "Replacements")
        replacementsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let replacementsHelp = NSTextField(wrappingLabelWithString: "One per line: what you say => what to type. Whole words, any capitalization. Polished mode only. Use \\n for a line break.")
        replacementsHelp.font = .systemFont(ofSize: 11)
        replacementsHelp.textColor = .secondaryLabelColor
        replacementsHelp.maximumNumberOfLines = 2
        let (replacementsEditor, replacementsView) = makeTextEditor(
            UserDefaults.standard.string(forKey: Self.vocabularyReplacementsKey) ?? Self.defaultReplacementsText)
        replacementsTextView = replacementsView
        let saveWords = NSButton(title: "Save Words", target: self, action: #selector(saveVocabulary))
        saveWords.bezelStyle = .rounded
        vocabularyStatus = NSTextField(wrappingLabelWithString: "")
        vocabularyStatus.font = .systemFont(ofSize: 11)
        vocabularyStatus.textColor = .secondaryLabelColor
        vocabularyStatus.maximumNumberOfLines = 2
        let saveRow = NSStackView(views: [saveWords, vocabularyStatus])
        saveRow.orientation = .horizontal
        saveRow.alignment = .centerY
        saveRow.spacing = 10
        let wordsPage = makePage([wordsTitle, wordsHelp, wordsEditor, replacementsTitle, replacementsHelp, replacementsEditor, saveRow], spacing: 7)

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

        let generalTitle = NSTextField(labelWithString: "General Preferences")
        generalTitle.font = .systemFont(ofSize: 13, weight: .semibold)

        launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch MacVoice at login", target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchAtLoginCheckbox.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        soundFeedbackCheckbox = NSButton(checkboxWithTitle: "Play sound cues on start & stop", target: self, action: #selector(toggleSoundFeedback(_:)))
        let soundPref = UserDefaults.standard.object(forKey: "soundFeedbackEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "soundFeedbackEnabled")
        soundFeedbackCheckbox.state = soundPref ? .on : .off

        compatibilityTypingCheckbox = NSButton(checkboxWithTitle: "Animated typing (letter by letter). Turn off to insert text instantly.", target: self, action: #selector(toggleCompatibilityTyping(_:)))
        compatibilityTypingCheckbox.state = Self.animatedTyping ? .on : .off

        let permissionsTitle = NSTextField(labelWithString: "Permissions & Setup")
        permissionsTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let accessHelp = NSTextField(wrappingLabelWithString: "Microphone access lets MacVoice hear you. Accessibility allows keyboard events to reach the active app. Live polling detects permissions immediately when toggled in System Settings.")
        accessHelp.font = .systemFont(ofSize: 12)
        accessHelp.textColor = .secondaryLabelColor
        accessHelp.maximumNumberOfLines = 3

        accessibilityStatusLabel = NSTextField(wrappingLabelWithString: "")
        accessibilityStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        updateAccessibilityStatusUI()

        let permissionsButtons = NSStackView(views: [
            NSButton(title: "Microphone Access…", target: self, action: #selector(requestMicrophoneAccess)),
            NSButton(title: "Accessibility Settings…", target: self, action: #selector(requestTypingAccess))
        ])
        permissionsButtons.orientation = .horizontal
        permissionsButtons.spacing = 10

        let settingsPage = makePage([
            appearanceLabel, appearancePicker,
            generalTitle, launchAtLoginCheckbox, soundFeedbackCheckbox, compatibilityTypingCheckbox,
            permissionsTitle, accessHelp, accessibilityStatusLabel, permissionsButtons
        ])

        let aboutTitle = NSTextField(labelWithString: "Speak. Type. Done.")
        aboutTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        let aboutText = NSTextField(wrappingLabelWithString: "MacVoice is a local-first voice typing utility. Audio is processed completely on-device in memory during dictation. Verbatim sends confirmed recognition directly to TypingCore. Polished uses high-performance native Swift cleanup. MacVoice never sends your audio to cloud servers and never stores transcript histories.\n\nRequires macOS 26 or later.")
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
            ("words", "Words", wordsPage),
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
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 590))
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
            root.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            tabs.widthAnchor.constraint(equalToConstant: 512),
            tabs.heightAnchor.constraint(equalToConstant: 470),
            wordsHelp.widthAnchor.constraint(equalToConstant: 450),
            replacementsHelp.widthAnchor.constraint(equalToConstant: 450),
            vocabularyStatus.widthAnchor.constraint(equalToConstant: 330),
            startButton.widthAnchor.constraint(equalToConstant: 450),
            windowStatus.widthAnchor.constraint(equalToConstant: 430),
            modeSummary.widthAnchor.constraint(equalToConstant: 430),
            dictateHelp.widthAnchor.constraint(equalToConstant: 430),
            testSandboxLabel.widthAnchor.constraint(equalToConstant: 430),
            modeExplanation.widthAnchor.constraint(equalToConstant: 430),
            polisherStatus.widthAnchor.constraint(equalToConstant: 430),
            shortcutSummary.widthAnchor.constraint(equalToConstant: 430),
            shortcutTip.widthAnchor.constraint(equalToConstant: 430),
            accessHelp.widthAnchor.constraint(equalToConstant: 430),
            accessibilityStatusLabel.widthAnchor.constraint(equalToConstant: 430),
            aboutText.widthAnchor.constraint(equalToConstant: 430)
        ])

        controlWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        controlWindow.title = "MacVoice"
        controlWindow.contentView = content
        controlWindow.isReleasedWhenClosed = false
        controlWindow.minSize = NSSize(width: 540, height: 580)
        controlWindow.defaultButtonCell = startButton.cell as? NSButtonCell
        updateModeUI()
        applyAppearance(savedAppearance)
        controlWindow.center()
    }

    private var modeSummary: NSTextField!
    private var tabView: NSTabView!

    private func makePage(_ views: [NSView], spacing: CGFloat = 13) -> NSView {
        let page = NSView(frame: NSRect(x: 0, y: 0, width: 490, height: 440))
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 18),
            stack.topAnchor.constraint(equalTo: page.topAnchor, constant: 18)
        ])
        return page
    }

    private func makeTextEditor(_ text: String) -> (NSScrollView, NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 450).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 92).isActive = true
        return (scroll, textView)
    }

    private func storedVocabulary() -> Vocabulary {
        Vocabulary(
            wordsText: UserDefaults.standard.string(forKey: Self.vocabularyWordsKey) ?? "",
            replacementsText: UserDefaults.standard.string(forKey: Self.vocabularyReplacementsKey) ?? ""
        )
    }

    @objc private func saveVocabulary() {
        let wordsText = customWordsTextView.string
        let replacementsText = replacementsTextView.string
        UserDefaults.standard.set(wordsText, forKey: Self.vocabularyWordsKey)
        UserDefaults.standard.set(replacementsText, forKey: Self.vocabularyReplacementsKey)
        let vocabulary = Vocabulary(wordsText: wordsText, replacementsText: replacementsText)
        var message = "Saved \(vocabulary.words.count) word\(vocabulary.words.count == 1 ? "" : "s") and \(vocabulary.replacements.count) replacement\(vocabulary.replacements.count == 1 ? "" : "s")."
        if let bad = vocabulary.invalidLines.first {
            message += " Skipped \"\(bad)\" (use =>)."
        }
        vocabularyStatus.stringValue = message
        vocabularyStatus.textColor = vocabulary.invalidLines.isEmpty ? .secondaryLabelColor : .systemOrange
        rebuildSessionWhenIdle()
    }

    /// Applies new settings now if idle, otherwise right after this dictation.
    private func rebuildSessionWhenIdle() {
        Task { @MainActor in
            let state = await self.session?.state
            switch state {
            case .listening?, .starting?, .stopping?:
                self.needsSessionRebuild = true
            default:
                await self.configureSession(locale: self.currentConfiguredLocale ?? Locale.current)
            }
        }
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
        sessionStartCoordinator.begin(operation: { [weak self] in
            guard let self else { return }
            try await self.performToggle()
        }, onFailure: { [weak self] error in
            self?.setStatus(error.localizedDescription)
        })
    }

    private func performToggle() async throws {
        try Task.checkCancellation()
        var currentState: VoiceTypingState = .idle
        var wasFailed = false
        if let currentSession = self.session {
            currentState = await currentSession.state
            try Task.checkCancellation()
            if currentState == .listening || currentState == .starting || currentState == .stopping {
                await currentSession.stop()
                return
            }
            if case .failed = currentState {
                await currentSession.resetFailure()
                wasFailed = true
                currentState = .idle
            }
        }
        guard currentState == .idle else { return }
        let hasMicrophonePermission = await AudioCapture.requestPermission()
        try Task.checkCancellation()
        guard hasMicrophonePermission else {
            setStatus("Microphone access denied")
            return
        }
        guard CGPreflightPostEventAccess() else {
            setStatus("Enable MacVoice under Privacy & Security → Accessibility, then reopen the app")
            requestTypingAccess()
            return
        }
        if IsSecureEventInputEnabled() {
            setStatus("Secure input active — cannot type into password or secure fields")
            return
        }

        // If previously failed (e.g. Try Again clicked), or session is nil, or locale changed:
        // thoroughly prepare speech assets and build a clean, fresh session.
        if wasFailed || self.session == nil || self.preparedForSystemLocaleID != Locale.current.identifier {
            setStatus("Preparing on-device speech for \(Locale.current.identifier)…")
            try await prepareSpeechAssetsAndSession()
        }
        try Task.checkCancellation()
        guard let activeSession = self.session else {
            throw SpeechRecognizerError.modelLoadFailed("Could not initialize voice typing session.")
        }
        do {
            try await activeSession.start()
        } catch VoiceTypingSessionError.invalidState {
            // Hotkey toggled rapidly while session was in transition; safely ignore without destroying handles
            return
        } catch {
            // Re-arm session on genuine failure so subsequent attempts create fresh recognizer handles
            self.session = nil
            self.recognizer = nil
            throw error
        }
    }

    /// Finds and prepares an Apple-supported locale for the Mac's language.
    /// Already-installed same-language assets win, avoiding an unnecessary
    /// download when a compatible regional model is already on the device.
    private func prepareSpeechAssetsAndSession() async throws {
        try Task.checkCancellation()
        let systemLocale = Locale.current
        let systemLanguage = systemLocale.language.languageCode?.identifier
        let targetID = Self.normalizedLocaleID(systemLocale.identifier)

        let installedLocales = await SpeechTranscriber.installedLocales
        try Task.checkCancellation()

        // 1. If an exact match is already installed on disk (e.g. en_IN), use it immediately!
        if let exactInstalled = installedLocales.first(where: { Self.normalizedLocaleID($0.identifier) == targetID }) {
            await configureSession(locale: exactInstalled)
            preparedForSystemLocaleID = systemLocale.identifier
            return
        }

        // 2. If another regional match of the same language is already installed (e.g. en_US or en_GB), use it!
        let installedSameLanguage = installedLocales.filter {
            $0.language.languageCode?.identifier == systemLanguage
        }
        if let preferred = installedSameLanguage.first {
            await configureSession(locale: preferred)
            preparedForSystemLocaleID = systemLocale.identifier
            return
        }

        // 3. Not installed on disk at all: attempt download for the system locale once
        setStatus("Checking Apple speech model · \(systemLocale.identifier)… First setup may download it.")
        let candidateRecognizer = AppleSpeechAnalyzerRecognizer(locale: systemLocale)
        try await candidateRecognizer.installAssets()
        await configureSession(locale: systemLocale)
        preparedForSystemLocaleID = systemLocale.identifier
    }

    private static func normalizedLocaleID(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "-", with: "_").lowercased()
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
            updateAccessibilityStatusUI()
            return
        }
        let granted = CGRequestPostEventAccess()
        if granted {
            setStatus("Keyboard typing access granted")
            updateAccessibilityStatusUI()
            return
        }

        setStatus("Opening System Settings… Toggle MacVoice ON under Accessibility")
        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(settingsURL)
        }
        startAccessibilityPolling()
    }

    private func startAccessibilityPolling() {
        accessibilityPollTimer?.invalidate()
        let deadline = Date().addingTimeInterval(120)
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self else {
                    timer.invalidate()
                    return
                }
                if Date() > deadline {
                    timer.invalidate()
                    self.accessibilityPollTimer = nil
                    self.updateAccessibilityStatusUI()
                    return
                }
                if CGPreflightPostEventAccess() {
                    timer.invalidate()
                    self.accessibilityPollTimer = nil
                    self.setStatus("Keyboard typing access granted! Ready to dictate.")
                    self.updateAccessibilityStatusUI()
                    let soundEnabled = UserDefaults.standard.object(forKey: "soundFeedbackEnabled") == nil || UserDefaults.standard.bool(forKey: "soundFeedbackEnabled")
                    if soundEnabled {
                        NSSound(named: "Glass")?.play()
                    }
                }
            }
        }
    }

    private func updateAccessibilityStatusUI() {
        guard accessibilityStatusLabel != nil else { return }
        let hasAccess = CGPreflightPostEventAccess()
        accessibilityStatusLabel.stringValue = hasAccess
            ? "Accessibility: Granted · MacVoice can type text into active apps"
            : "Accessibility: Missing · toggle MacVoice ON in System Settings"
        accessibilityStatusLabel.textColor = hasAccess ? .systemGreen : .systemOrange
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
                setStatus("Launch at login enabled")
            } else {
                try SMAppService.mainApp.unregister()
                setStatus("Launch at login disabled")
            }
        } catch {
            setStatus("Could not update launch at login: \(error.localizedDescription)")
            sender.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
    }

    @objc private func toggleCompatibilityTyping(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: Self.animatedTypingKey)
        setStatus(sender.state == .on ? "Animated typing enabled" : "Instant typing enabled")
        rebuildSessionWhenIdle()
    }

    @objc private func toggleSoundFeedback(_ sender: NSButton) {
        let enabled = sender.state == .on
        UserDefaults.standard.set(enabled, forKey: "soundFeedbackEnabled")
        setStatus(enabled ? "Sound cues enabled" : "Sound cues disabled")
    }

    @objc private func modeChanged() {
        let mode: PolishingMode = modePicker.indexOfSelectedItem == 1 ? .polished : .verbatim
        UserDefaults.standard.set(mode.rawValue, forKey: "typingMode")
        updateModeUI()
        Task { @MainActor in
            await self.configureSession(locale: self.currentConfiguredLocale ?? Locale.current)
            self.setStatus(mode == .polished ? "Polished mode selected" : "Verbatim mode selected")
        }
    }

    private func configureSession(locale: Locale = Locale.current) async {
        let mode = PolishingMode(rawValue: UserDefaults.standard.string(forKey: "typingMode") ?? PolishingMode.polished.rawValue) ?? .polished
        let vocabulary = storedVocabulary()
        let recognizer = AppleSpeechAnalyzerRecognizer(
            locale: locale,
            streamsVolatileWords: mode == .verbatim,
            contextualStrings: vocabulary.contextualStrings
        )
        let engine = TypingEngine(
            interCharacterDelay: 0.005, newlineBehavior: .smartChatAware, smartLeadingSpace: true,
            // Letter by letter shows text being typed and works in every app;
            // instant mode sends up to 20 characters per key event.
            charactersPerEvent: Self.animatedTyping ? 1 : 20
        )
        let polisher = NativeSwiftTranscriptPolisher(locale: locale, replacements: vocabulary.replacements)
        let session = VoiceTypingSession(
            audioCapture: AudioCapture(), recognizer: recognizer, typingEngine: engine,
            polisher: polisher, polishingMode: mode
        )
        self.recognizer = recognizer
        self.session = session
        self.currentConfiguredLocale = locale
        self.needsSessionRebuild = false
        updatePolisherStatus()
        await session.setStateChangeHandler { [weak self] state in
            Task { @MainActor in self?.render(state) }
        }
        await session.setWarningHandler { [weak self] message in
            Task { @MainActor in self?.setStatus(message) }
        }
    }

    private func updatePolisherStatus() {
        guard polisherStatus != nil else { return }
        polisherStatus.stringValue = "Polished mode is built in. Cleanup runs on your Mac in under a millisecond, with no AI model and no network."
    }

    private func updateModeUI() {
        guard modePicker != nil else { return }
        let polished = modePicker.indexOfSelectedItem == 1
        modeSummary?.stringValue = polished
            ? "Selected: Polished (Default) · removes fillers, fixes capitalization, and follows spoken commands."
            : "Selected: Verbatim · sends recognized words directly with minimal changes."
        modeExplanation.stringValue = polished
            ? "Removes fillers (um, uh), collapses stutters (\"the the\"), adds missing apostrophes, and capitalizes sentences. Say \"new line\", \"new paragraph\", \"bullet point\", \"comma\", \"question mark\", or end with \"period\". Say \"scratch that\" to remove the last sentence. In Terminal, only fillers are removed. Text is typed one sentence at a time."
            : "Types recognized words live, as you speak, with no changes."
        polisherSection.isHidden = !polished
        polisherSection.setAccessibilityElement(true)
        polisherSection.setAccessibilityLabel("Polished mode cleanup settings")
        updatePolisherStatus()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func playSoundFeedback(for state: VoiceTypingState) {
        let soundEnabled = UserDefaults.standard.object(forKey: "soundFeedbackEnabled") == nil || UserDefaults.standard.bool(forKey: "soundFeedbackEnabled")
        guard soundEnabled else { return }

        switch (previousState, state) {
        case (.idle, .listening), (.starting, .listening):
            NSSound(named: "Tink")?.play()
        case (.listening, .stopping), (.listening, .idle), (.listening, .failed):
            NSSound(named: "Pop")?.play()
        default:
            break
        }
    }

    private func render(_ state: VoiceTypingState) {
        playSoundFeedback(for: state)
        previousState = state

        switch state {
        case .idle:
            if needsSessionRebuild {
                needsSessionRebuild = false
                Task { @MainActor in await self.configureSession(locale: self.currentConfiguredLocale ?? Locale.current) }
            }
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
        updateMenuBarItem(statusTitle: statusTitle, detail: text)
        statusSymbol?.contentTintColor = statusTitle == "Attention" ? .systemOrange : (statusTitle == "Listening" ? .systemRed : .tertiaryLabelColor)
        statusItem?.button?.setAccessibilityLabel("MacVoice, \(statusTitle)")
        statusLine?.setAccessibilityLabel("MacVoice status: \(text)")
    }

    // MARK: Menu bar indicator

    private static func menuSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func updateMenuBarItem(statusTitle: String, detail: String) {
        guard let button = statusItem?.button else { return }
        button.toolTip = "MacVoice · \(detail)"
        toggleMenuItem?.image = Self.menuSymbol(statusTitle == "Listening" ? "stop.circle" : "mic")
        if statusTitle == "Listening" {
            if listeningStartedAt == nil { startListeningIndicator() }
            return
        }
        stopListeningIndicator()
        let state: MenuBarIcon.State
        switch statusTitle {
        case "Attention": state = .attention
        case "Starting", "Finishing": state = .busy
        default: state = .idle
        }
        button.image = MenuBarIcon.image(for: state)
        button.title = ""
    }

    private func startListeningIndicator() {
        listeningStartedAt = Date()
        menuBarPulseDimmed = false
        renderListeningIndicator()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            Task { @MainActor [weak self] in
                guard let self, self.listeningStartedAt != nil else { timer.invalidate(); return }
                self.menuBarPulseDimmed.toggle()
                self.renderListeningIndicator()
            }
        }
        // .common keeps the pulse running while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        menuBarPulseTimer = timer
    }

    private func stopListeningIndicator() {
        menuBarPulseTimer?.invalidate()
        menuBarPulseTimer = nil
        listeningStartedAt = nil
    }

    private func renderListeningIndicator() {
        guard let button = statusItem?.button, let start = listeningStartedAt else { return }
        let seconds = Int(Date().timeIntervalSince(start))
        button.image = MenuBarIcon.image(for: .listening(dimmed: menuBarPulseDimmed))
        button.title = String(format: " %d:%02d", seconds / 60, seconds % 60)
    }
}
