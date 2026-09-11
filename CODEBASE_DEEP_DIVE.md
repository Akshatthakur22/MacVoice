# Typer+ macOS Keyboard Injection: Comprehensive Codebase Deep Dive

**Target Audience**: Developers with Swift/macOS background learning the architecture for AI-powered text generation integration.

---

## PART 1: PROJECT MAP

Complete file inventory with responsibilities, dependencies, and interrelationships.

| File | Responsibility | Key Types | Imports | Imported By |
|------|-----------------|-----------|---------|-------------|
| **main.swift** | Entry point, CLI flags (--selftest, --detect, --speedtest), font registration, NSApplication setup | - | AppKit, Foundation | - |
| **AppController.swift** | Lifecycle coordinator, permission gate, run sequencing, UI bridge, safety watchdog | AppController | AppKit, Carbon, Foundation | MenuBarController, UI/AppModel |
| **KeyboardEngine.swift** | HID-layer keyboard injection via CGEvent | KeyboardEngine, PowerAssertion | CoreGraphics, IOKit.pwr_mgt | Player |
| **Player.swift** | Execution engine: monotonic clock, action playback, pause/resume, abort | Player | Foundation, AppKit | AppController |
| **Planner.swift** | Text → timed keystroke [Action] with timing, Shift, typos, corrections | Planner, Action | Foundation | AppController, SelfTest |
| **Timing.swift** | IKI (inter-key interval) generation: ex-Gaussian, bigram, hand bias, AR(1), warmup, fatigue | Timing | Foundation | Planner |
| **TypingProfile.swift** | Four speed modes: Careful, Ultra Fast, Max Speed, Max Stealth with tuned params | TypingProfile | Foundation | Settings, AppController |
| **KillSwitch.swift** | Triple-ESC detection: global CGEventTap + NSEvent monitor + health watchdog | KillSwitch | CoreGraphics, AppKit, Foundation | AppController |
| **Detector.swift** | Human-likeness scoring: keystroke-dynamics feature extraction and risk bands | Detector | Foundation | main.swift (headless) |
| **SelfTest.swift** | Correctness verification: zero-error reconstruction, timing stats, grammar validation | TyperPlusSelfTest, RNG | Foundation | main.swift (headless) |
| **Settings.swift** | User preferences, persisted to UserDefaults: mode, hotkeys, toggles | Settings | Foundation, AppKit | AppController, UI/AppModel |
| **Permissions.swift** | macOS Accessibility, Post Events, Listen Events gates and enforcement | Permissions | AppKit, ApplicationServices | AppController |
| **TextCleanup.swift** | Text normalization: CRLF→LF, invisible chars, exotic spaces, whitespace collapse | TextCleanup | Foundation | AppController, Planner |
| **Typos.swift** | Character-level slip generation: substitution, omission, insertion, doubling, transposition; corrections | Typos, RNG | Foundation | Planner, Detector |
| **Persona.swift** | Per-"person" fingerprint: ikiScale, dwellScale, cvScale, typoScale | Persona | Foundation | Planner, RNG |
| **RNG.swift** | Random distributions: ex-Gaussian, truncated-normal, Box–Muller, geometric, uniform | RNG | Foundation | Timing, Typos, Planner, Detector, SelfTest |
| **KeyMap.swift** | US-QWERTY mapping: keycodes, hand assignment, physical adjacency, top-bigrams | KeyMap | CoreGraphics, Foundation | KeyboardEngine, Planner, Typos |
| **MenuBarController.swift** | Menu-bar icon (NSStatusItem), menu items, PasteBox popover | MenuBarController | AppKit, Foundation | AppController |
| **PasteBoxPopover.swift** | UI: text input, mode selector, "Type this" button in menu-bar popover | PasteBoxViewController | AppKit, Foundation | MenuBarController |
| **CountdownHUD.swift** | Non-activating floating window with countdown timer | CountdownHUD | AppKit, Foundation | AppController |
| **BubbleController.swift** | Floating "quick paste" bubble: draggable, mode display, position persistence | BubbleController | AppKit, Foundation | AppController |
| **Hotkey.swift** | Global hotkey registration (Carbon event handlers) | Hotkey | Carbon, Foundation, AppKit | AppController |
| **UI/AppModel.swift** | SwiftUI bridge: Observable state, session history, controller weak reference | AppModel | SwiftUI, Foundation | UI/*, AppController |
| **UI/AppFont.swift** | Inter typeface registration and font descriptors | AppFont | AppKit, Foundation | UI/* |
| **UI/DesignSystem.swift** | Colors, spacing, shadows, system appearance (light/dark) | DesignSystem | SwiftUI, AppKit | UI/* |
| **UI/RootView.swift** | Main window top-level SwiftUI container (navigation root) | RootView | SwiftUI | MainWindowController |
| **UI/HomeView.swift** | Home card: text input, mode selector, "Type this" button | HomeView | SwiftUI, Foundation | RootView |
| **UI/HistingsView.swift** | Typing session history: list, timestamps, modes, text snippets | HistoryView | SwiftUI, Foundation | RootView |
| **UI/SettingsView.swift** | Settings UI: hotkeys, toggles, cleanup, typos, reliable delivery | SettingsView | SwiftUI, Foundation | RootView |
| **UI/HelpView.swift** | Documentation, quickstart, keyboard shortcuts | HelpView | SwiftUI | RootView |
| **UI/BubbleView.swift** | SwiftUI bubble rendering | BubbleView | SwiftUI, Foundation | BubbleController |
| **UI/MainWindowController.swift** | Window lifecycle: show/hide, state persistence | MainWindowController | AppKit, SwiftUI | AppController |
| **UI/SharedComponents.swift** | Reusable: ModeSelector, TextInputCard, StatusBadge | SharedComponents | SwiftUI, Foundation | UI/* |
| **UI/Responsive.swift** | Responsive layout helpers | Responsive | SwiftUI | UI/* |
| **UI/Glyphs.swift** | Icon enum (SF Symbols) | Glyphs | SwiftUI | UI/* |
| **InjectTest/main.swift** | De-risk harness: proves CGEvent posting is isTrusted + Unicode string works | - | CoreGraphics, Foundation | - |

---

## PART 2: APPLICATION ENTRY POINT

Exact initialization sequence from main.swift → AppController → running state.

### 1. CLI Flag Check (main.swift)

```swift
if CommandLine.arguments.contains("--selftest") { exit(Int32(TyperPlusSelfTest.run())) }
if CommandLine.arguments.contains("--detect") { exit(Int32(Detector.run())) }
if CommandLine.arguments.contains("--speedtest") { exit(Int32(TyperPlusSelfTest.runSpeedTest())) }
```

Before any GUI, check for headless modes:
- `--selftest`: Zero-error reconstruction, timing stats, grammar correctness (deterministic)
- `--detect`: Human-likeness scoring (keystroke-dynamics feature extraction)
- `--speedtest`: Dry-run Player throughput (no real event posting)

Each runs in isolation and exits with exit code 0 (success) or 1 (failure).

### 2. Font Registration (Before UI)

```swift
InterFonts.registerAll()   // Bundled Inter typeface files (UI/AppFont.swift)
```

Registers Inter-Regular, Inter-SemiBold, Inter-Medium, Inter-Bold from `Sources/TyperPlus/Resources/Fonts/` before SwiftUI renders any text. Prevents layout jank on first appearance.

### 3. NSApplication Setup

```swift
let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
```

- **NSApplication.shared**: Singleton for the Cocoa event loop
- **AppController**: Created and held in a top-level `_` binding so it lives for the whole run
- **app.delegate = controller**: AppController implements NSApplicationDelegate (weak reference, no retain cycle)
- **setActivationPolicy(.regular)**: Regular windowed app (Dock icon visible)
- **app.run()**: Blocks on the main event loop until the app quits

### 4. AppController Lifecycle: applicationDidFinishLaunching

Called by NSApplication after the main window appears.

#### 4a. Single-Instance Gate

```swift
if let bundleID = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if let existing = others.first {
        existing.activate(options: [.activateAllWindows])
        NSApp.terminate(nil)  // quit this instance
        return
    }
}
```

If another Typer+ process is already running (same bundleID), hand focus to it and quit. Prevents duplicate menu-bar icons (NSStatusItem is not application-aware).

#### 4b. Activation & UI Setup

```swift
NSApp.setActivationPolicy(.regular)
menu.install(controller: self)              // menu-bar icon + menu
appModel.controller = self                  // UI bridge
installMainMenu()
mainWindow.showWindow()
```

- Show Dock icon, install menu-bar icon, open main window
- Establish two-way link: AppController ↔ AppModel (weak reference from model to controller)

#### 4c. Service Initialization

```swift
killSwitch.onTripleEsc = { [weak self] in self?.stopTyping() }
player.pauseProvider = { [weak self] in self?.shouldHold() ?? true }
player.onFinish = { [weak self] in self?.finishTyping() }
```

Wire callbacks:
- Kill switch → stop typing on triple-ESC
- Player → ask AppController if it's safe to continue (Secure Input check)
- Player → call finishTyping when plan ends

#### 4d. Hotkey Registration

```swift
hotkey.register(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
hotkey.register(slot: .bubble, keyCode: ..., modifiers: ...) { [weak self] in
    self?.toggleBubble()
}
```

Register two Carbon global hotkeys:
1. Primary (default ⌘⌥T): Type clipboard
2. Bubble (default ⌘⌥B): Toggle floating bubble

#### 4e. Permission Flow

```swift
if !Permissions.allReady { Permissions.requestAll() }   // Prompt user
armIfPossible()                                         // Arm kill switch if ready
if !Permissions.allReady { startPermissionPoll() }      // 1.5s retry loop
```

Permissions checked via `AXIsProcessTrusted()` (single gate):
- If ready: arm the kill switch (CGEventTap)
- If not ready: show prompt, start 1.5s poll, show "Permission needed" status until granted

#### 4f. URL Scheme Handler

```swift
NSAppleEventManager.shared().setEventHandler(
    self,
    andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
    forEventClass: AEEventClass(kInternetEventClass),
    andEventID: AEEventID(kAEGetURL))
```

Registers `typerplus://clipboard` and `typerplus://stop` for integration with other apps/shortcuts.

### 5. applicationWillTerminate: Cleanup

```swift
countdown.cancel()
player.abort()
stopSafetyWatchdog()
killSwitch.stop()
hotkey.unregister()
powerAssertion.end()
```

On quit, abort any in-flight run, stop safety watchers, disarm kill switch, release display-sleep assertion.

---

## PART 3: USER FLOW — Copy to Type

Complete step-by-step trace of the happy path.

### Path: User presses ⌘⌥T (clipboard hotkey)

```
1. Global key tap (triple-ESC monitor) sees keyDown for ⌘⌥T
2. Carbon hotkey handler fires (registered in applicationDidFinishLaunching)
3. Hotkey.onFire closure → AppController.hotkeyClipboardToggle()
```

### Step 1: Read Clipboard Text

```swift
let clipboard = NSPasteboard.general.string(forType: .string)
// → "Hello world"
```

Single read from system pasteboard. No interaction with clipboard API after this.

### Step 2: Enter beginTyping(_:) — Single Chokepoint

**All start paths flow here** (hotkey, bubble, menu, Home button, URL scheme):

```swift
func beginTyping(_ text: String, quick: Bool = false) {
    // Guard 1: Not already running
    guard !isTyping && !player.isRunning else { return }
    
    // Guard 2: Post-run debounce (0.8s window after last run ended)
    guard ProcessInfo.processInfo.systemUptime - lastRunEndedAt >= 0.8 else { return }
    
    // Guard 3: Normalize newlines (CRLF/CR → LF, always runs)
    let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                         .replacingOccurrences(of: "\r", with: "\n")
    
    // Guard 4: Cleanup (CRLF fold + optional cosmetic cleanup if Settings.cleanupEnabled)
    let cleaned = TextCleanup.clean(normalized)
    guard !cleaned.isEmpty else { NSSound.beep(); return }
    
    pendingText = cleaned
    // → "Hello world" (unchanged if no special whitespace/control chars)
```

### Step 3: Permission Gate

```swift
guard Permissions.allReady else {
    Permissions.requestAll()
    Permissions.openAccessibilitySettings()
    startPermissionPoll()
    refreshUI()
    return  // abort this run
}
```

If Accessibility permission not granted, show Settings pane and return early (no countdown/typing).

### Step 4: Arm Kill Switch

```swift
guard armIfPossible() else {
    // Kill switch couldn't arm (Input Monitoring not granted despite AX ready)
    _ = Permissions.requestListenEvents()
    Permissions.openAccessibilitySettings()
    refreshUI()
    return  // abort
}
```

Verify triple-ESC kill switch is installed (CGEventTap live). If not, request Input Monitoring separately.

### Step 5: Focus Transfer & Countdown

```swift
menu.closePasteBox()
NSApp.deactivate()           // Hand focus to user's target app/field
countdown.cancel()           // Cancel any old countdown

engine.forceUnicodeOnly = settings.forceUnicodeOnly
player.minPostGapMs = settings.reliableDelivery ? 5.0 : 0
let runMode = settings.mode
var profile = settings.profile

if !settings.humanTyposEnabled {
    // VERBATIM: disable self-made typos/corrections
    profile.typoRate = 0
    profile.humanTypoCorpusRate = 0
}

let plan = Planner.plan(cleaned, profile: profile, persona: persona)
```

**Data transformations at this point:**
- Text (string) → [Action] (timed keystroke plan)

Settings like typoRate, mode, cleanup are captured once, embedded in the plan.

### Step 6: Start Countdown

```swift
runGeneration += 1
let gen = runGeneration
let countdownSecs = settings.countdownSeconds

countdown.start(seconds: countdownSecs) {
    [weak self] in
    guard let self = self, self.runGeneration == gen else { return }
    self.finishCountdown()
}
```

Show floating HUD: "Typing in 5… (click your target · Esc Esc Esc to stop)"

User has 5 seconds to click into their target field. Clicking within the countdown doesn't interrupt it (HUD is non-activating).

### Step 7: Countdown Expiry → finishCountdown()

```swift
private func finishCountdown() {
    guard isTyping == false && player.isRunning == false else { return }
    
    isTyping = true
    powerAssertion.begin()           // prevent display sleep
    
    player.play(plan, speed: runMode.relativeSpeed)
    refreshUI()  // update status to "Typing..." / progress bar
}
```

### Step 8: Player Execution Loop

Player wakes on monotonic clock (not timer-per-key), flushing all actions due since last tick:

**Simplified tick() logic:**
```swift
private func tick() {
    while index < actions.count {
        let action = actions[index]
        let plannedTime = planned[index]  // ms elapsed since plan start
        
        if plannedTime > elapsedMs() + 0.6 { break }  // not due yet
        
        // Pause at clean keystroke boundary if requested
        if heldReleases.isEmpty, isPress(action.op), shouldHold() {
            if !isPaused { isPaused = true; ... }
            scheduleTick(120)  // retry soon
            return
        }
        
        execute(action.op)                 // post CGEvent via KeyboardEngine
        index += 1
    }
    
    if index >= actions.count { finish(); return }
    scheduleTick(...)                      // next wake time
}
```

**Example: "Hello"**
1. **H** (capital): Post Shift-down, H-down, H-up, Shift-up (timing from plan)
2. Wait IKI (inter-key interval, ~200ms for Careful)
3. **e**: Post e-down, e-up (lowercase, no Shift)
4. Wait IKI
5. **l**: Post l-down, l-up
6. ... etc

Each CGEvent posted at HID layer (.cghidEventTap) is marked `isTrusted: true`.

### Step 9: Typing Finish → finishTyping()

```swift
private func finishTyping() {
    // Release any held keys (safety)
    engine.resetModifiers()
    player.abort()  // defensive
    
    powerAssertion.end()               // allow display sleep
    isTyping = false
    lastRunEndedAt = ProcessInfo.processInfo.systemUptime
    
    // Record session to history
    let session = TypingSession(
        timestamp: Date(),
        mode: runMode,
        textLength: pendingText.count
    )
    appModel.sessionHistory.append(session)
    
    refreshUI()  // update UI to "Ready"
}
```

### Parallel: Triple-ESC Kill Switch

At any point during typing, if the user presses ESC three times within 0.3s:
1. Global CGEventTap sees the keyDown events
2. Deduplicates (tap fires ~1–2ms before NSEvent monitor)
3. Counts three ESCs in time window
4. Fires `killSwitch.onTripleEsc` callback
5. → `AppController.stopTyping()` → `player.abort()` → immediate cleanup

---

## PART 4: KEYBOARD INJECTION DEEP DIVE (KeyboardEngine.swift)

The injection primitive that makes everything else possible.

### 4.1 CGEvent + HID Layer Fundamentals

**Posting at the HID layer** (`.cghidEventTap`):
- Events are injected at the OS driver level, indistinguishable from real hardware
- Receiving applications see `event.isTrusted: true` (gold standard)
- The JavaScript DOM sees `inputEvent.isTrusted` = true (security property JavaScript can't spoof)
- Contrast: `.tapLevel` is rejected by security-conscious apps; higher tap levels are dropped

```swift
guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return false }
finalize(e, flags: heldFlags)
e.post(tap: .cghidEventTap)  // post at HID layer
```

### 4.2 CGEventSource Configuration

```swift
let s = CGEventSource(stateID: .hidSystemState)
s?.localEventsSuppressionInterval = 0  // instant real-input detection
self.source = s
```

**`.hidSystemState`**: Marks the event as hardware-like (not a user-interaction source).

**`localEventsSuppressionInterval = 0`**: By default, when the system detects a real keypress (from hardware), it temporarily suppresses synthetic events from entering the system (to prevent feedback loops). Setting to 0 disables that suppression window — Typer+ events are processed immediately without the OS trying to "debounce" them.

### 4.3 Text Character Path: Unicode-Only (Default)

**Default (`forceUnicodeOnly = true`):**

```swift
private func postChar(_ ch: Character, down: Bool) -> Bool {
    // Always use virtualKey 0 + Unicode string (unambiguous)
    let vk = 0  // never 0 keycode from KeyMap
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return false }
    
    if down {
        // Convert character to UTF-16 array and pass to CGEvent
        let u = Array(String(ch).utf16)
        u.withUnsafeBufferPointer { buf in
            e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
    }
    
    finalize(e, flags: heldFlags)
    e.post(tap: .cghidEventTap)
    return true
}
```

**Why Unicode-only is the default:**

1. **Layout-independent**: Works on any keyboard layout (US QWERTY, Dvorak, colemak, Bépo, Japanese, etc.)
2. **Unambiguous**: No competing keycode can override the Unicode string
3. **Accents, emoji, smart quotes**: All rendered correctly without fallback kludges
4. **Verified by de-risk test**: InjectTest proves Chrome/Docs see `isTrusted: true` for Unicode-string posts

**Example: character 'é' (e with acute accent)**
- POST event: virtualKey 0, keyboardSetUnicodeString([0xE9]) (UTF-16 encoding of é)
- NO falling-back to "press Option+e, then e" hacks
- Every layout and every Unicode block works identically

**Example: character '@' (at-sign, Shift+2 on US layout)**
- POST event: virtualKey 0, Unicode "@", flags = .maskShift
- The Shift flag is set, but the EXACT "@" is specified
- No layout guessing — the receiving app gets "@" in any layout

### 4.4 Special Keys (Backspace, Arrows, Return, Tab)

Always use the keycode path (no Unicode string):

```swift
private func postCode(_ code: CGKeyCode, down: Bool) -> Bool {
    guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return false }
    finalize(e, flags: heldFlags)
    e.post(tap: .cghidEventTap)
    return true
}

func keyDown(_ code: CGKeyCode) { postCode(code, down: true) }
func keyUp(_ code: CGKeyCode) { postCode(code, down: false) }
```

**KeyMap constants:**
```swift
static let backspace: CGKeyCode = 51     // kVK_Delete
static let leftArrow: CGKeyCode = 123    // kVK_LeftArrow
static let rightArrow: CGKeyCode = 124   // kVK_RightArrow
static let delete: CGKeyCode = 117       // kVK_ForwardDelete
static let return: CGKeyCode = 36        // kVK_Return
static let tab: CGKeyCode = 48           // kVK_Tab
static let shift: CGKeyCode = 56         // kVK_Shift (left Shift)
static let option: CGKeyCode = 58        // kVK_Option (left Option)
```

Used by Planner for:
- Backspace: Correction sequences (typo recovery)
- Arrows: Caret jumps (delayed correction go-back)
- Return: Line breaks
- Tab: Indentation

### 4.5 Modifier Handling (Shift & Option)

**Shift for capitals and shifted punctuation:**

```swift
func shiftDown()  { if postCode(KeyMap.shift, down: true)  { heldFlags.insert(.maskShift) } }
func shiftUp()    { heldFlags.remove(.maskShift);  _ = postCode(KeyMap.shift, down: false) }
```

**Key invariant**: `heldFlags` mirrors the actual modifier state. It's only updated AFTER a successful post:

```swift
if postCode(KeyMap.shift, down: true) {  // post the event
    heldFlags.insert(.maskShift)         // ONLY if post succeeded
}
```

If a posted Shift-down event is dropped by the OS (rare), the mirror doesn't get out of sync — the mirror reflects what the OS actually received, not what we tried to post.

**Every subsequent character inherits heldFlags:**

```swift
private func finalize(_ e: CGEvent, flags: CGEventFlags) {
    e.flags = flags  // apply the mirror state (Shift/Option held)
    e.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    e.timestamp = mach_absolute_time()
}
```

**Example sequence for "A" (uppercase A):**
1. Post Shift-down (kVK_Shift, vk=56) → on success, `heldFlags |= .maskShift`
2. Post 'A' keyDown with flags=.maskShift
3. Post 'A' keyUp with flags=.maskShift (still held)
4. Post Shift-up (kVK_Shift) → on success, `heldFlags &= ~.maskShift`

**Option (⌥) for word navigation:**

```swift
func optionDown() { if postCode(KeyMap.option, down: true)  { heldFlags.insert(.maskAlternate) } }
func optionUp()   { heldFlags.remove(.maskAlternate); _ = postCode(KeyMap.option, down: false) }
```

Used by Planner for go-back-and-fix sequences:
1. Option-down
2. Left arrow (⌥← = jump word back)
3. Option-up
4. Type the correction

### 4.6 Paste Shortcut (Fallback Path)

```swift
func pasteShortcut() {
    let cmd: CGKeyCode = 0x37   // kVK_Command (left ⌘)
    let v: CGKeyCode = 0x09     // kVK_ANSI_V
    
    post(cmd, down: true,  flags: .maskCommand)
    post(v,   down: true,  flags: .maskCommand)
    post(v,   down: false, flags: .maskCommand)
    post(cmd, down: false, flags: [])
}
```

**Single atomic ⌘V** (rarely used, opt-in via Settings.pasteDelivery):
1. Command key down
2. V key down (Command still held)
3. V key up (Command still held)
4. Command key up

The receiving app sees one paste operation. Impossible to drop/duplicate/merge individual characters. Trade-off: paste is detectable (app sees clipboard contents, not individual keystrokes).

### 4.7 Event Finalization

```swift
private func finalize(_ e: CGEvent, flags: CGEventFlags) {
    e.flags = flags
    e.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
    e.timestamp = mach_absolute_time()
}
```

**Flags**: Modifiers (Shift, Option, Command, Control, Caps Lock, etc.)

**Autorepeat**: Forced to 0. Real hardware only autorepeats when a key is HELD DOWN continuously. Our keystrokes are down-then-immediately-up, so autorepeat never happens naturally.

**Timestamp**: Critical detail.

```
mach_absolute_time() returns the kernel's monotonic tick counter.
On Intel: 1 tick ≈ 1 ns (timebase 1:1)
On Apple Silicon: 1 tick = 41.67 ns (M1/M2/M3 run at 24 MHz)
```

A posted event with timestamp **0** (synthetic default) is a fingerprint — security layers and keystroke detectors specifically look for this. Posting with `mach_absolute_time()` ensures the event carries a real monotonic kernel timestamp, indistinguishable from hardware.

### 4.8 Display Sleep Prevention

```swift
final class PowerAssertion {
    private var id: IOPMAssertionID = 0
    private var active = false
    
    func begin() {
        guard !active else { return }
        var newID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Typer+ typing" as CFString,
            &newID)
        if result == kIOReturnSuccess { id = newID; active = true }
    }
    
    func end() {
        guard active else { return }
        IOPMAssertionRelease(id)
        active = false
    }
}
```

Held during Player execution. Prevents the display from sleeping mid-type (user wouldn't appreciate watching their screen go black in the middle of typing).

---

## PART 5: "REAL KEYSTROKE" EXPLAINED

How CGEvent injection appears to the receiving application vs. clipboard paste.

### 5.1 Comparison Table

| Aspect | CGEvent Injection | Clipboard Paste |
|--------|-------------------|-----------------|
| **User sees** | Text appearing character-by-character at typing speed | Text appearing all at once |
| **App sees (insertText / input event)** | 26 separate input events (one per character) | 1 paste event (often type="insertText" with large chunk) |
| **Web DOM isTrusted** | true (hardware-like) | Usually true (paste events from user interaction) |
| **JavaScript inputEvent.isComposing** | false (complete chars) | false (no composition) |
| **Autocorrect/autocomplete can interleave** | YES (sees each keystroke, can correct between) | NO (all text arrives atomically) |
| **Form field rejects fast synthetic input** | NO (isTrusted) | Sometimes (if paste is detected as synthetic) |
| **Can be interrupted mid-text** | YES (triple-ESC kills it, kill switch works) | NO (paste is atomic) |
| **Recipient detects "typing" vs "paste"** | Difficult (correct timing, per-key events) | Easy (one insertion) |
| **Keystroke-dynamics detector can analyze** | YES (full IKI/dwell/rollover stream available) | NO (no per-keystroke timing) |
| **Recovery/correction visible to observer** | YES (backspace, retyping) | NO (never sends backspace) |

### 5.2 What "isTrusted" Means

In the DOM:

```javascript
document.addEventListener('beforeinput', (event) => {
    console.log(event.isTrusted);  // true = hardware origin, false = script origin
});

// If Typer+ posts CGEvents at HID layer:
// → JavaScript sees isTrusted = true

// If a script does: input.value = "Hello"; input.dispatchEvent(new KeyboardEvent(...))
// → JavaScript sees isTrusted = false (no way to spoof it)
```

**Security property**: JavaScript cannot lie about `isTrusted`. The browser kernel enforces it based on event source. HID-layer events are marked hardware. Synthesized DOM events are marked non-trusted.

**Why apps care**: Anti-bot measures check `isTrusted` to distinguish real user input from script injection. Typer+ passes the check.

### 5.3 Receiving App Behavior

**Example: Google Docs**

1. User presses 'H' on real keyboard
   - DOM fires: `beforeinput`, `keydown` (isTrusted: true)
   - Docs process: update document model, render canvas

2. Typer+ posts 'H' via CGEvent
   - Docs receives: identical `beforeinput`, `keydown` (isTrusted: true)
   - Docs process: identical document model update, identical render

3. Typer+ posts ⌘V
   - Docs receives: paste event (isTrusted: true, if clipboard was just set by user)
   - Docs process: insert clipboard contents atomically
   - **Problem**: Docs might deduplicate (ignore paste if it looks synthetic)

### 5.4 Why Paste-Delivery Exists (Optional, Off by Default)

**Fragile editors** (some Electron apps, older web text editors) have bugs:
- They see synthetic CGEvents and drop them (false positive on bot detection)
- OR they batch overlapped keys and lose characters
- OR their input event handling is broken for high-speed keys

**Solution**: One atomic ⌘V. The app sees a genuine paste operation (isTrusted: true from the clipboard shortcut). Can't drop individual keys because there's only one paste event.

**Trade-off**: Observable paste (detectable as "paste" in logs), not real typing. Only enable if the target app is fragile.

---

## PART 6: TEXT TO TYPING PLAN (Planner.swift)

How "Hello world" becomes a timed keystroke sequence with timing, Shift, typos, corrections.

### 6.1 Planning Pipeline

```swift
func plan(_ text: String, profile: TypingProfile, persona: Persona, 
          rng: inout RNG) -> [Action] {
    var events: [TimedEvent] = []       // buffer of (time, action) pairs
    var bufferLen = 0                    // live character buffer
    var contiguous = 0                   // contiguous chars typed (for composition pacing)
    var postErrorRemaining = 0           // uncorrected errors to carry into residue
    var lastKeyId = ""                   // bigram context
    var clock = 0.0                      // absolute time in ms
    
    // 1. Process each character
    for i in 0..<text.count {
        let char = text[i]
        let isShifted = ...                       // uppercase or shifted punctuation
        let iki = Timing.interKeyMs(...) * ...    // research-tuned IKI
        let dwell = Timing.dwellMs(...) * ...     // hold time
        
        // Shift management
        if isShifted && !currentlyShifted {
            events.append((clock + shiftLeadMs, .shiftDown))
            currentlyShifted = true
        } else if !isShifted && currentlyShifted {
            events.append((clock, .shiftUp))
            currentlyShifted = false
        }
        
        // Schedule down + up for the character
        let downT = clock + iki
        let upT = downT + dwell
        events.append((downT, .charDown(char)))
        events.append((upT, .charUp(char)))
        
        clock = upT                         // advance absolute timeline
        bufferLen += 1
        contiguous += 1
        lastKeyId = String(char)            // bigram context for next iteration
    }
    
    // Release final Shift if needed
    if currentlyShifted {
        events.append((clock, .shiftUp))
    }
    
    // 2. Sort by absolute time (within same time, by order added)
    let sorted = events.sorted { $0.time < $1.time || ($0.time == $1.time && $0.seq < $1.seq) }
    
    // 3. Convert to relative timings (delay-before each action)
    var actions: [Action] = []
    var prev = 0.0
    for e in sorted {
        actions.append(Action(preDelayMs: e.time - prev, op: e.op))
        prev = e.time
    }
    
    // 4. Apply composition pacing (Max Stealth mode only)
    if profile.compositionPacing {
        actions = applyCompositionPacing(actions, targetWPM: profile.compositionTargetWPM)
    }
    
    return actions
}
```

### 6.2 Action Structure

```swift
struct Action {
    enum Op {
        case charDown(Character), charUp(Character)     // character keypress
        case keyDown(CGKeyCode), keyUp(CGKeyCode)       // special keys (backspace, arrows, return, tab)
        case shiftDown, shiftUp                         // Shift modifier
        case optionDown, optionUp                       // Option (for word navigation)
    }
    let preDelayMs: Double  // delay BEFORE this operation (from previous op)
    let op: Op
}
```

The key insight: **preDelayMs encodes the timing**. Every action carries the delay-before-it, so the Player can reconstruct the research-tuned rhythm by playing the sequence.

### 6.3 Example: "A⤵"

Character sequence: ['A', '\n'] (capital A, then newline)

**Step 1: Process 'A' (shifted, capital)**

```
isShifted = true
iki = Timing.interKeyMs(prev: "", cur: "A", ...) ≈ 190ms (Careful mode)
dwell = Timing.dwellMs(for: 'A', iki: 190) ≈ 110ms

Action 1: (time: 0, .shiftDown)     → preDelayMs: 0, op: shiftDown
Action 2: (time: 15, .charDown('A')) → preDelayMs: 15, op: charDown('A')
Action 3: (time: 125, .charUp('A')) → preDelayMs: 110, op: charUp('A')
Action 4: (time: 125, .shiftUp)      → preDelayMs: 0, op: shiftUp

clock = 125ms
```

**Step 2: Process '\n' (Return key, not shifted)**

```
isShifted = false
iki = Timing.interKeyMs(prev: "A", cur: "\n", ...) ≈ 280ms (sentence end pause)
dwell = Timing.dwellMs(for: '\n', iki: 280) ≈ 90ms

Action 5: (time: 405, .keyDown(kVK_Return)) → preDelayMs: 280, op: keyDown(36)
Action 6: (time: 495, .keyUp(kVK_Return))   → preDelayMs: 90, op: keyUp(36)

clock = 495ms
```

**Step 3: Convert to relative timings**

| preDelayMs | op |
|---|-|
| 0 | shiftDown |
| 15 | charDown('A') |
| 110 | charUp('A') |
| 0 | shiftUp |
| 280 | keyDown(36) |
| 90 | keyUp(36) |

Player plays this sequence:
1. Now: Shift-down
2. After 15ms: A-down
3. After 110ms more: A-up
4. After 0ms more: Shift-up
5. After 280ms more: Return-down
6. After 90ms more: Return-up

**Total time: 15 + 110 + 0 + 280 + 90 = 495ms**

### 6.4 Shift Management Detail

Shift state machine:

```
State: currently_shifted (bool)

For each character:
    if isShifted(char) && !currently_shifted:
        emit Shift-down (15ms before char-down, "shift lead")
        currently_shifted = true
    
    if !isShifted(char) && currently_shifted:
        emit Shift-up (right at current clock)
        currently_shifted = false
    
    emit char-down, then char-up
    advance clock
```

**Why shift lead (15ms before)?** Mimics real typing where users mentally prepare for a capital before pressing it. Shift-down slightly precedes the letter press.

### 6.5 Typo Injection & Correction

When `profile.typoRate > 0`, Planner calls `Typos.charSlip(...)` for each character:

```swift
if let slip = Typos.charSlip(intended: char, next: nextChar, atWordStart: atWordStart, 
                             profile: profile, persona: persona, rng: &rng) {
    // Slip generated: substitution, omission, insertion, doubling, or transposition
    
    switch slip.correction {
    case .immediate(prob: p):
        if rng.bernoulli(p) {
            // Emit the wrong character immediately
            // Then emit backspace(s) + retype correctly
            emitWrongChars(slip.typed)
            emitBackspaces(count: slip.typed.count)
            emitCorrectChar(char)
        } else {
            // Leave as residue (uncorrected error)
            emitWrongChars(slip.typed)
        }
    case .delayed:
        // Emit wrong chars, continue typing
        // At end-of-pass, jump caret back via Option+arrow and fix
        emitWrongChars(slip.typed)
        addDelayedCorrection(...)
    }
}
```

**Example: Intended "hello", but typo "heloo" (doubled 'o')**
1. h - e - l - o (correct)
2. Typo: post 'o' again (doubling slip)
3. Immediate correction (66% for Careful): post backspace, retype 'o'
4. Or delayed: leave "heloo", fix it later by jumping caret back 1, deleting, retyping 'e'

### 6.6 Word/Sentence Pauses

After processing all characters, Planner inserts extra idle at word/sentence boundaries:

```swift
private func applyBoundaryPauses(_ actions: inout [Action]) {
    var i = 0
    while i < actions.count {
        if isWordBoundary(actions[i]) {
            let pause = Timing.wordPauseMs(profile: profile, rng: &rng)
            actions[i].preDelayMs += pause
        }
        if isSentenceEnd(actions[i]) {
            let pause = Timing.sentencePauseMs(profile: profile, rng: &rng)
            actions[i].preDelayMs += pause
        }
        i += 1
    }
}
```

- **Word pause**: Log-normal ~200ms (Careful)
- **Sentence pause**: Longer ~800ms (Careful)
- **Thinking pause** (~5% of words): Very long ~1.5s (cognitive pause)

### 6.7 Composition Pacing (Max Stealth Mode)

When `profile.compositionPacing = true`:

```swift
private func applyCompositionPacing(_ actions: [Action], targetWPM: Int) -> [Action] {
    let targetIKI = 60000.0 / (targetWPM * 5.0)  // Convert WPM to ms/key
    var burst = 0
    var burstStartTime = 0.0
    var result: [Action] = []
    
    for action in actions {
        result.append(action)
        burstStartTime += action.preDelayMs
        
        if isKeyUp(action.op) { burst += 1 }
        
        if burst >= profile.maxContiguousChars {
            // Insert inter-burst pause
            let burstPause = rng.uniform(300, 600)  // composition pause
            result.last?.preDelayMs += burstPause
            burst = 0
        }
    }
    
    return result
}
```

Prevents Docs paste-detector from flagging continuous rapid typing as suspicious. Breaks the stream into bursts with thinking pauses between.

---

## PART 7: TIMING SYSTEM DEEP DIVE

Grounded in keystroke-dynamics research (Dhakal et al. 2018, 136M keystrokes).

### 7.1 Inter-Key Interval (IKI) Model

**IKI = down-to-down interval between consecutive keystrokes** (the most important feature of human typing rhythm).

#### Formula

```
IKI = exGaussian(μ, σ, τ)                      # Base distribution
    × bigramMultiplier(prev_key, cur_key)      # Per-digraph factor (~0.8–1.4)
    × handBias(cur_key)                        # Left/right hand modifier
    × exp(AR(1) residual)                      # Shared macro tempo
    × warmupFactor(if keystroke < 60)          # Cognitive ramp-up
    × (1 + fatigueWalk)                        # Session drift
```

#### 7.1a Ex-Gaussian Distribution

```swift
func exGaussian(mu: Double, sigma: Double, tau: Double, floor: Double) -> Double {
    // Try up to 3 times to generate a non-floored value
    for _ in 0..<3 {
        let gaussian = normal(mu, sigma)
        let exponential = exponential(mean: tau)
        let v = gaussian + exponential
        if v >= floor { return v }
    }
    
    // Reflection: ensure we never return below floor
    let gaussian = normal(mu, sigma)
    let exponential = exponential(mean: tau)
    let v = gaussian + exponential
    return v >= floor ? v : floor + (floor - v)
}
```

**Why ex-Gaussian?** Combines:
- Gaussian core (symmetric, natural variation around mean)
- Exponential tail (asymmetric right-skew, occasional slow keys)

This perfectly captures human typing: mostly clustered around a mean (~150ms for Careful), occasionally much slower (~400+ms for pauses/hesitations), rarely faster.

**Example (Careful mode):**
- μ = 190 ms (gaussian mean)
- σ = 60 ms (gaussian spread)
- τ = 34 ms (exponential tail)
- floor = 50 ms (physiologically impossible to type faster)

Mean IKI ≈ μ + τ ≈ 224ms → ~40 wpm

**Example (Max Speed mode):**
- μ = 6.6 ms
- σ = 1.9 ms
- τ = 6.0 ms
- floor = 3 ms
- Mean IKI ≈ 13ms → ~800 wpm (superhuman, used only for stealth where timing doesn't matter)

#### 7.1b Per-Bigram Multiplier

```swift
func bigramMultiplier(prev: String, cur: String) -> Double {
    if prev == cur {
        return 1.38  // same finger (awkward, slow) e.g., "ll", "ss"
    }
    
    let prevHand = KeyMap.hand(for: prev)
    let curHand = KeyMap.hand(for: cur)
    
    if prevHand != curHand {
        return 0.84  // hand alternation (fast, comfortable) e.g., "ab", "st"
    } else {
        return 0.92  // same hand, diff finger (intermediate) e.g., "ae", "ow"
    }
    
    // Top bigrams (research-identified high-frequency pairs)
    let topBigrams = ["th", "he", "in", "er", "an", "re", "on", "at", "en", "nd"]
    if topBigrams.contains(prev + cur) {
        return base * 0.90  // well-practiced, faster
    }
    
    // Per-pair offset: even "th" typed twice isn't identical
    let pairOffset = rng.uniform(-0.08, 0.08)
    return base * (1 + pairOffset)
}
```

**Intuition**: Same finger is awkward (1.38× slower). Hand alternation is smooth and practiced (0.84×).

#### 7.1c Hand Bias

```swift
private var handBias = {
    "left": rng.uniform(0.90, 1.10),   // Persona: left-hand preference variation
    "right": rng.uniform(0.90, 1.10)
}()

func ikiBiased(ms: Double, for char: Character) -> Double {
    let hand = KeyMap.hand(for: char)
    return ms * handBias[hand]!
}
```

Personas have stable per-hand typing speeds. One person might favor their right hand (right-hand keys are faster), another symmetric.

#### 7.1d AR(1) Autocorrelation (Shared Tempo)

```swift
private var arIKI = 0.0  // Per-run state, fresh each plan

func interKeyMs(...) -> Double {
    var ms = rng.exGaussian(...)
    ms *= bigramMultiplier(...)
    
    // AR(1) process: φ = 0.62, σ = 0.21
    arIKI = 0.62 * arIKI + 0.21 * rng.standardNormal()
    ms *= exp(arIKI)  // log-normal multiplier
    
    // ... other factors ...
    return ms
}
```

**What it does**: Creates a shared "session tempo" — one person's typing has a dominant macro rhythm. If keystroke N is slow, keystroke N+1 is slightly more likely to be slow too (not due to the bigram, but due to the person's current state).

**φ = 0.62**: Lag-1 autocorrelation. Previous tempo influences current keystroke with correlation 0.62.

**σ = 0.21**: Each keystroke adds fresh entropy, preventing the AR(1) from freezing at one value. The tempo drifts.

**Why `exp(arIKI)`?** The AR(1) residual is added in log-space (multiplicative). arIKI ≈ ±0.3 → exp(±0.3) ≈ 0.74–1.35, multiplying the base IKI by that factor.

#### 7.1e Warm-Up (First 60 Keystrokes)

```swift
func warmupFactor(keystroke: Int) -> Double {
    if keystroke >= 60 { return 1.0 }
    let ramp = Double(keystroke) / 60.0
    return 1.0 + (warmup - 1.0) * (1 - ramp)
}
```

First keystrokes are slower (cognitive ramp-up). Linearly interpolates from 1.10× slower to 1.00× over the first 60 keys.

**Example**: keystroke 0 is 1.10× the base IKI (10% slower), keystroke 30 is 1.05×, keystroke 60 is 1.0×.

#### 7.1f Fatigue / Session Drift

```swift
private var fatigueWalk = 0.0  // Per-run state

func updateFatigue(...) {
    let drift = fatiguePerMinute * (ms / 60000.0)  // Scale by current IKI
    fatigueWalk += rng.normal(drift, 0.0018)      // Random walk
    fatigueWalk = max(-0.15, min(0.15, fatigueWalk))  // Bounded [−15%, +15%]
}

let iki = baseIKI * (1 + fatigueWalk)
```

Session-level drift: typing gets slightly faster or slightly slower as the session progresses (person warms up, tires, or finds a rhythm).

### 7.2 Dwell — Key Hold Time

Independent per-key, drawn from **truncated normal** (symmetric, low-variance):

```swift
func dwellMs(for ch: Character, iki: Double) -> Double {
    // Frequent keys held slightly shorter (faster recovery)
    let frequent = ch.isLetter && KeyMap.topLetters.contains(ch)
    let meanDwell = (frequent ? profile.dwellMean * 0.85 : profile.dwellMean) * persona.dwellScale
    
    // Truncated normal: clipped at [min, max]
    let dw = rng.truncatedNormal(mean: meanDwell, sd: profile.dwellSD,
                                 lo: profile.dwellMin, hi: profile.dwellMax)
    
    // Weak AR(1) coupling to local flight (hold time influences next down-to-down)
    arDwell = 0.15 * arDwell + 0.05 * rng.standardNormal()
    return dw * exp(arDwell)
}
```

**Dwell is independent of IKI**: A key might be held for 100ms and the next key pressed 80ms later (negative flight time, overlap).

### 7.3 Key Rollover (Negative Flight Time)

When dwell > IKI, keys overlap (one key is down before the previous is released):

```swift
private func shouldRollover() -> Bool {
    let wpm = 60000.0 / (profile.baselineIKI * 5.0)
    let prob = max(0.05, min(0.55, (wpm - 8) / 160.0))  // 7% slow → 50% fast
    return rng.bernoulli(prob)
}

private func rolloverGapMs(from iki: Double) -> Double {
    let g = iki * rng.uniform(0.60, 0.85)  // 60–85% of normal spacing
    return g >= floor ? g : floor + (floor - g)  // reflect off floor if too small
}
```

**Emerges naturally** from dwell > IKI (not a separate knob). Higher typing speeds have higher overlap probability (keys naturally overlap when you type fast).

---

## PART 8: HUMAN ERROR SYSTEM

### 8.1 Character-Level Slips (Typos.swift)

**NOT a catalog of common misspellings** (detectable fingerprint). Instead, a generative model for muscle-memory errors.

#### Distribution (Dhakal et al. 2018)

```swift
static let slipDistribution: [SlipKind: Double] = [
    .substitution: 0.46,    // 46% fat-finger (adjacent) or random letter
    .omission: 0.22,        // 22% skip the key
    .insertion: 0.18,       // 18% stray adjacent key
    .doubling: 0.07,        // 7% repeat the key
    .transposition: 0.07    // 7% swap with next char
]

enum SlipKind { case substitution, omission, insertion, doubling, transposition }
```

#### Slip Generation

```swift
static func charSlip(intended: Character, next: Character?, atWordStart: Bool,
                     profile: TypingProfile, persona: Persona, rng: inout RNG) -> Typos.Plan? {
    guard intended.isLetter else { return nil }
    guard !atWordStart else { return nil }  // word-initial never slips
    guard rng.bernoulli(min(0.95, profile.typoRate * persona.typoScale)) else { return nil }
    
    let kind = pickKind(from: slipDistribution, rng: &rng)
    let typed: [Character]
    
    switch kind {
    case .substitution:
        // 55% adjacent (fat-finger), 45% random letter (case-preserved)
        if rng.bernoulli(0.55) {
            typed = [adjacentKey(intended, rng: &rng)]
        } else {
            typed = [randomLetter(casePreserved: intended, rng: &rng)]
        }
    
    case .omission:
        typed = []  // skip the key entirely
    
    case .insertion:
        // Stray adjacent key before the intended key
        typed = [adjacentKey(intended, rng: &rng), intended]
    
    case .doubling:
        typed = [intended, intended]
    
    case .transposition:
        guard let nx = next else { return nil }
        typed = [nx, intended]  // swap with next
    }
    
    return Typos.Plan(kind: kind, typed: typed, intended: [intended],
                      correction: correctionStyle(for: kind, profile: profile, rng: &rng))
}
```

#### Correction Strategies

```swift
enum CorrectionStyle {
    case immediate(prob: Double)       // Fix right away (%) or leave as residue (1-%)
    case delayed                       // Type ahead, fix later via caret jump
    case uncorrected                   // Leave in final text (rare)
}

private func correctionStyle(for kind: SlipKind, profile: TypingProfile, rng: inout RNG) -> CorrectionStyle {
    guard rng.bernoulli(1 - profile.uncorrectedResidueProb) else {
        return .uncorrected
    }
    
    let immediateProb = profile.immediateCorrectProb  // e.g., 66% for Careful
    let delayed = 1 - immediateProb
    
    if rng.bernoulli(immediateProb) {
        return .immediate(prob: 1.0)  // always correct (just decided on this style)
    } else {
        return .delayed
    }
}
```

**Immediate (66% for Careful):**
1. Post the wrong character
2. Post backspace (or multiple if insertion/doubling)
3. Post the correct character
4. Immediate resume

**Delayed (~33%):**
1. Post the wrong character
2. Continue typing normally
3. At end-of-pass, jump caret back via Option+arrow
4. Delete the wrong character
5. Type correct

**Uncorrected (~0% for shipped modes):**
1. Post the wrong character
2. Never fix it
3. Final text contains the error (rare, off in all presets)

#### Substitution Detail

```swift
private func adjacentKey(_ intended: Character, rng: inout RNG) -> Character {
    guard let adjacent = KeyMap.adjacentKeys(for: intended) else { return intended }
    return adjacent.randomElement(using: &rng.generator)!
}

private func randomLetter(casePreserved intended: Character, rng: inout RNG) -> Character {
    let letters = Character.isUppercase(intended) ? "ABCDEFGHIJKLMNOPQRSTUVWXYZ" : "abcdefghijklmnopqrstuvwxyz"
    return letters.randomElement(using: &rng.generator)!
}
```

55% of substitutions are **adjacent keys** (physical fat-finger). 45% are **random letters** (case-preserved), simulating loss of context mid-keystroke.

#### Doubling and Transposition

```swift
// Doubling: repeat the same key
typed = [intended, intended]

// Transposition: swap current with next character
typed = [next!, intended]
```

### 8.2 Grammar / Homophone Slips

Rule-based confusables (drawn at random per run, NOT a fixed table):

```swift
static let confusables: [[String]] = [
    ["its", "it's"],
    ["their", "there", "they're"],
    ["to", "too", "two"],
    ["a", "an"],
    ["than", "then"],
    ["your", "you're"],
]

static func grammarSlip(word: String, rng: inout RNG) -> String? {
    guard let group = confusables.first(where: { $0.contains(word) }) else { return nil }
    guard group.count > 1 else { return nil }
    let candidates = group.filter { $0 != word }
    return candidates.randomElement(using: &rng.generator)
}
```

**When inserted**: After all characters are typed, scan for confusable words and swap a small % of them. Fixes them in end-of-pass review (via caret jump + correction).

### 8.3 Text Cleanup (TextCleanup.swift)

Single shared normalization point (all text sources flow through):

```swift
static func clean(_ text: String) -> String {
    guard Settings.shared.cleanupEnabled else { return text }
    
    var result = text
    
    // 1. Normalize newlines (CRLF, CR, U+2028, U+2029, VT, FF → LF)
    result = result.replacingOccurrences(of: "\r\n", with: "\n")
    result = result.replacingOccurrences(of: "\r", with: "\n")
    result = result.replacingOccurrences(of: "\u{2028}", with: "\n")  // U+2028
    result = result.replacingOccurrences(of: "\u{2029}", with: "\n")  // U+2029
    
    // 2. Strip invisibles (ZWSP, ZWJ, ZWNJ, BOM, bidi marks, soft-hyphen)
    result = result.filter { !$0.isInvisible }
    
    // 3. Fold exotic spaces (NBSP, em-space, ideographic-space, etc. → space)
    result = result.replacingOccurrences(of: "\u{00A0}", with: " ")  // NBSP
    result = result.replacingOccurrences(of: "\u{2003}", with: " ")  // em-space
    result = result.replacingOccurrences(of: "\u{3000}", with: " ")  // ideographic-space
    
    // 4. Per-line cleanup
    let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
    result = lines.map { line in
        var clean = String(line)
        clean = clean.replacingOccurrences(of: "  +", with: " ", options: .regularExpression)  // collapse spaces
        clean = clean.trimmingCharacters(in: .whitespaces)  // trim line ends
        return clean
    }.joined(separator: "\n")
    
    // 5. Cap blank lines (never 3+ newlines in a row)
    result = result.replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
    
    // 6. Final trim
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    
    return result
}
```

**Always runs**: CRLF fold is unconditional (prevents `\r\n` from bypassing the Return path).

**Optional**: Cosmetic cleanup (collapse spaces, invisibles, exotic spaces) is gated by Settings.cleanupEnabled.

---

## PART 9: PLAYER EXECUTION (Player.swift)

How the plan is actually executed on the main run loop with a monotonic clock.

### 9.1 Why Monotonic Clock (Not Timer-Per-Key)

**Timer-per-key approach (naive)**:
```swift
for action in actions {
    sleep(action.preDelayMs / 1000.0)
    execute(action)
}
```
Problems:
- Sleep blocks the run loop → other timers can't fire (UI becomes unresponsive)
- Granularity is ~10–16ms → timing is silent-ceiled at that
- No way to interrupt mid-sleep (kill switch has to wait for sleep to finish)

**Monotonic clock approach (Typer+ uses this)**:
```swift
func tick() {
    let now = elapsedMs()
    while index < actions.count && planned[index] <= now {
        execute(actions[index])
        index += 1
    }
    if index < actions.count {
        scheduleTick(planned[index] - now)
    }
}
```
Benefits:
- Non-blocking → run loop stays responsive, kill-switch taps can spin
- Arbitrary precision → no ceiling, Max Speed's ~4ms/key is honored
- Pausable/abortable → any point can pause at clean keystroke boundaries
- Burst-friendly → all actions due since last tick are flushed at once

### 9.2 Core Loop

```swift
private func tick() {
    // Flushed already?
    guard !finished else { return }
    
    // How much time has elapsed since plan started?
    let elapsedMs = elapsedMs()
    
    var flushed = 0
    
    while index < actions.count {
        let plannedTime = planned[index]
        
        // Not due yet? (0.6ms slack for jitter)
        if plannedTime > elapsedMs + 0.6 { break }
        
        let action = actions[index]
        
        // PAUSE at clean boundaries (no key held, next action is a press)
        if heldReleases.isEmpty, isPress(action.op), pauseProvider() {
            if !isPaused { isPaused = true; pausedAccumNs = 0; onPausedChange?(true) }
            scheduleTick(120)  // check again soon
            return
        }
        
        // RELIABLE DELIVERY: enforce wall-clock floor between posts
        if minPostGapMs > 0, lastPostNs != 0 {
            let sinceLastMs = Double(mach_absolute_time() - lastPostNs) * timebaseNs / 1_000_000
            if sinceLastMs < minPostGapMs {
                scheduleTick(1)  // yield, try again very soon
                return
            }
        }
        
        // Execute the action and track held keys for cleanup on abort
        execute(action.op)
        lastPostNs = mach_absolute_time()
        index += 1
        flushed += 1
        
        // Yield to run loop if too many flushed at once (prevent starving other timers)
        if flushed >= maxFlushPerTick { break }
    }
    
    // All actions done?
    if index >= actions.count { finish(); return }
    
    // Schedule next tick for when the next action is due
    let base = planned[index] - elapsedMs
    let delayMs = max(hitCap ? 1.5 : 0, base)
    scheduleTick(delayMs)
}
```

### 9.3 Pause/Resume

Player pauses at **clean keystroke boundaries** only (no key held, next action is a press):

```swift
private func shouldPause() -> Bool {
    return pauseProvider?.() ?? false
}

private func shouldAllowProgress() -> Bool {
    return !isPaused || (isPaused && resumeRequested)
}
```

Called before executing a key-press action:
```swift
if heldReleases.isEmpty, isPress(action.op), shouldPause() {
    isPaused = true
    onPausedChange?(true)
    scheduleTick(120)  // check again in 120ms
    return
}
```

**Invariant**: Never pauses mid-keystroke (key held down). On resume, the held key is released cleanly.

### 9.4 Abort/Stop

```swift
func abort() {
    releaseHeldKeys()      // post all pending key releases
    resetModifiers()       // idempotent: release Shift/Option
    finish()               // mark finished
}

private func releaseHeldKeys() {
    for op in heldReleases {
        switch op {
        case .charUp(let c): engine.charUp(c)
        case .keyUp(let code): engine.keyUp(code)
        case .shiftUp: engine.shiftUp()
        case .optionUp: engine.optionUp()
        }
    }
    heldReleases.removeAll()
}
```

**Abort on triple-ESC**:
1. `stopTyping()` → `player.abort()`
2. Release all held keys
3. Reset modifiers (idempotent)
4. User's subsequent typing is unaffected

### 9.5 Reliable Delivery Wall-Clock Floor

When `minPostGapMs = 5.0`:

```swift
if minPostGapMs > 0, lastPostNs != 0 {
    let sinceLastMs = Double(mach_absolute_time() - lastPostNs) * timebaseNs / 1_000_000
    if sinceLastMs < minPostGapMs {
        scheduleTick(1)  // don't post yet, retry in 1ms
        return
    }
}

execute(action.op)
lastPostNs = mach_absolute_time()
```

Never post two events closer than minPostGapMs in real wall-clock time. Prevents a coarse run-loop wake from bursting all pending events at once.

**Why**: Fragile editors can't keep up with bursts. Max 200 keys/second = 5ms minimum.

### 9.6 Latency-Critical Activity Token

```swift
func play(_ plan: [Action], speed: Double) {
    actions = plan
    index = 0
    planned = plan.map { cumsum of preDelayMs }
    
    let token = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Typer+ typing")
    self.activityToken = token
    
    scheduleTick(0)  // first tick immediately
}

func finish() {
    ProcessInfo.processInfo.endActivity(activityToken)
    activityToken = nil
}
```

**`.userInitiated | .latencyCritical`**:
- Prevents App Nap (normal apps backgrounded and coalesced to 1–2Hz when not visible)
- Prevents timer coalescing (run loop wakes stay sub-10ms even in background)
- Typer+ backgrounds itself (user types in another app) → would normally get slowed to ~50ms wakes
- Without token: keys batch and get bursted, fragile apps drop them
- With token: wakes stay snappy

---

## PART 10: KILL SWITCH (KillSwitch.swift)

Triple-ESC within 0.3s → immediate abort (only way to stop mid-run).

### 10.1 Architecture: CGEventTap + NSEvent Monitor + Watchdog

**Three layers of redundancy:**

1. **CGEventTap** (primary):
   - Global key tap at `.cgSessionEventTap` (session-level)
   - Listen-only mode (never consumes the event)
   - Catches keyDown from any source (even our own injected events)
   - C callback (trampoline via userInfo pointer)

2. **NSEvent Global Monitor** (backup):
   - `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)`
   - Catches ESC even if CG tap is torn down by the system
   - Same deduplication logic

3. **Health Watchdog Timer** (safety):
   - 2s timer that re-installs tap if disabled
   - If tap is torn down by the system (too many events, user actions), watchdog brings it back

### 10.2 CGEventTap Setup

```swift
private func installTap() {
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
        callback: killSwitchCallback,
        userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
        return
    }
    
    self.tap = tap
    let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}

private func killSwitchCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                               _ userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let userInfo = userInfo {
        let ks = Unmanaged<KillSwitch>.fromOpaque(userInfo).takeUnretainedValue()
        ks.handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)  // .listenOnly: never consume
}
```

### 10.3 Event Filtering

```swift
private func handle(type: CGEventType, event: CGEvent) {
    guard type == .keyDown else { return }
    
    // Ignore autorepeat (held key repeating)
    let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat)
    if autorepeat != 0 { return }
    
    // Ignore our own injected events (PID 0 = real hardware, our PID = our injected)
    let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
    if pid == getpid() { return }
    
    // Check keycode (ESC = 53)
    let keycode = event.getIntegerValueField(.keyboardEventKeycode)
    if keycode != 53 { return }  // not ESC
    
    recordEsc()
}
```

### 10.4 Triple-ESC Detection & Deduplication

```swift
private var escTimestamps: [TimeInterval] = []
private var lastEscAt: TimeInterval = 0
private var escWindow: TimeInterval = 0.3

private func recordEsc() {
    let now = ProcessInfo.processInfo.systemUptime
    
    // Deduplicate (tap + NSEvent monitor fire ~1–2ms apart)
    if now - lastEscAt < 0.025 { return }
    lastEscAt = now
    
    // Collect ESC timestamps within the window
    escTimestamps.append(now)
    escTimestamps.removeAll { now - $0 > escWindow }
    
    // Triple-ESC?
    if escTimestamps.count >= 3 {
        escTimestamps.removeAll()
        onTripleEsc?()  // fire the callback → AppController.stopTyping()
    }
}
```

**Deduplication window**: 25ms (2–3ms is typical overlap between tap and NSEvent monitor).

**ESC window**: 0.3s (live-read from Settings, can be changed without restart).

### 10.5 Why Triple-ESC Is Un-Spoofable

1. **Typer+ never injects ESC** (keycode 53 is blacklisted in KeyboardEngine)
2. **Real ESC always has PID 0** (hardware marker enforced by the OS)
3. **Our injected events carry our PID** → CGEventTap filters them out
4. **Kill switch is independent of typing engine** (separate tap, separate monitor, separate handler)
5. **Even if Typer+ is typing, it can't inject a fake ESC** (would be filtered by PID)

### 10.6 Health Watchdog

```swift
private var watchdog: Timer?

private func startWatchdog() {
    watchdog?.invalidate()
    let t = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
        guard let self = self else { return }
        if !self.isArmed {
            _ = self.start()  // re-arm
        }
    }
    RunLoop.main.add(t, forMode: .common)
    watchdog = t
}

var isArmed: Bool { tap != nil && tap_enabled }
```

If tap is torn down by the system (too many events, resource limits), the watchdog re-installs it in 2 seconds.

---

## PART 11: ACCESSIBILITY & PERMISSION MODEL

### 11.1 Permission Layers

**Single permission grant** covers all three layers:

```swift
// Permissions.swift
var allReady: Bool {
    AXIsProcessTrusted()  // Accessibility = all three layers
}
```

**Accessibility permission** (System Settings ▸ Privacy & Security ▸ Accessibility):
- Enables posting events (`CGEventPost`)
- Enables listening for global keys (`CGEventTap`)
- Covers "Post Events" and "Input Monitoring" functionally

### 11.2 On-Demand Request Flow

```swift
func requestAll() {
    // CGRequestPostEventAccess() — for belt-and-suspenders
    let postResult = CGRequestPostEventAccess()
    
    // CGRequestListenEventAccess() — for belt-and-suspenders
    let listenResult = CGRequestListenEventAccess()
    
    // AXIsProcessTrustedWithOptions() — show prompt
    var options: CFDictionary? = nil
    let trusted = AXIsProcessTrustedWithOptions(&options as CFDictionary?)
    
    // If all three granted, return; else open Settings
    if !trusted {
        openAccessibilitySettings()
    }
}

func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/PreferencePanes/Security.prefPane"))
}
```

### 11.3 Permission Poll (Retry Loop)

If not ready on launch, start a 1.5s retry timer:

```swift
private func startPermissionPoll() {
    permissionPoll?.invalidate()
    let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
        guard let self = self else { return }
        
        if Permissions.allReady {
            self.armIfPossible()
            self.permissionPoll?.invalidate()
            self.permissionPoll = nil
        }
        self.refreshUI()
    }
    RunLoop.main.add(t, forMode: .common)
    permissionPoll = t
}
```

Checks every 1.5s until granted, then stops.

### 11.4 Non-Sandboxed Requirement

**CGEvent posting + HID tap are denied inside App Sandbox.**

Typer+ must be built with `com.apple.security.app-sandbox: false` in Info.plist:

```xml
<key>NSPrincipalClass</key>
<string>NSApplication</string>

<!-- Sandbox disabled to allow CGEvent posting and HID tap -->
<key>com.apple.security.app-sandbox</key>
<false/>
```

### 11.5 Secure Input Detection (Password Field Auto-Pause)

During typing, `Player.pauseProvider` checks for Secure Input:

```swift
private var secureInputActive: Bool { IsSecureEventInputEnabled() }

private var safeToRun: Bool { killSwitch.isArmed && !secureInputActive }

private func shouldHold() -> Bool { !safeToRun }
```

When a password field is active (Secure Input ON):
- Player automatically **pauses** at the next clean keystroke boundary
- No keys are dropped or swallowed
- Resumes instantly when Secure Input is deactivated
- User never needs to manually pause

---

## PART 12: MENU BAR APPLICATION & UI ARCHITECTURE

### 12.1 SwiftUI + AppKit Integration

**AppModel** (Observable singleton, SwiftUI bridge):

```swift
@Observable
final class AppModel {
    weak var controller: AppController?
    
    var ready: Bool { ... }
    var armed: Bool { ... }
    var isTyping: Bool { ... }
    var paused: Bool { ... }
    var statusText: String { ... }
    var mode: TypingProfile { ... }
    var sessionHistory: [TypingSession] = []
    
    func typeText(_ text: String) {
        controller?.beginTyping(text)
    }
    
    func stop() {
        controller?.stopTyping()
    }
}
```

Two-way link:
- UI observes `@Published` properties for reactive updates
- UI calls methods on AppModel, which delegate to AppController

### 12.2 Screen Navigation

```swift
enum Screen: Identifiable {
    case home
    case history
    case settings
    case help
}

struct RootView: View {
    @State var activeScreen: Screen = .home
    
    var body: some View {
        NavigationStack {
            switch activeScreen {
            case .home: HomeView()
            case .history: HistoryView()
            case .settings: SettingsView()
            case .help: HelpView()
            }
        }
    }
}
```

### 12.3 Menu Bar Controller

```swift
final class MenuBarController {
    private var statusItem: NSStatusItem?
    
    func install(controller: AppController) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(named: "keyboard-icon")
        statusItem?.menu = createMenu(controller: controller)
    }
    
    private func createMenu(controller: AppController) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Type pasted text...", action: #selector(controller.showPasteBox), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Type clipboard now", action: #selector(controller.typeClipboard), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(controller.stopTyping), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        // Mode submenu...
        return menu
    }
}
```

### 12.4 CountdownHUD

Non-activating floating window:

```swift
final class CountdownHUD {
    private var window: NSWindow?
    
    func start(seconds: Int, onComplete: @escaping () -> Void) {
        let window = NSWindow(contentRect: NSRect(...), styleMask: [], backing: .buffered, defer: false)
        window.level = .statusBar
        window.ignoresMouseEvents = true
        window.backgroundColor = NSColor.clear.withAlphaComponent(0.9)
        
        // Countdown label: "Typing in 3... (click your target · Esc Esc Esc to stop)"
        var remaining = seconds
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            remaining -= 1
            if remaining <= 0 {
                onComplete()
                window.orderOut(nil)
            }
        }
    }
}
```

### 12.5 BubbleController

Floating "quick paste" bubble:

```swift
final class BubbleController {
    private var window: NSWindow?
    private let model: AppModel
    
    func show() {
        window = NSWindow(contentRect: NSRect(...), styleMask: .titled, backing: .buffered, defer: false)
        window?.level = .floating
        window?.title = "Typer+ Bubble"
        window?.isMovable = true
        window?.contentView = NSHostingView(rootView: BubbleView(model: model))
    }
    
    func hide() {
        window?.orderOut(nil)
    }
}
```

---

## PART 13: CLIPBOARD SYSTEM

### 13.1 One-Time Read

```swift
let clipboard = NSPasteboard.general.string(forType: .string)
```

Single read at typing start. After this, clipboard is never touched (unless paste-delivery is enabled).

### 13.2 Paste-Delivery Fallback (Optional)

When `Settings.pasteDelivery = true`:

```swift
func typeWithPasteDelivery(_ text: String) {
    // Save current clipboard
    let saved = NSPasteboard.general.string(forType: .string)
    
    // Set clipboard to our text
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    
    // Post ⌘V (one atomic paste via KeyboardEngine.pasteShortcut())
    engine.pasteShortcut()
    
    // Restore clipboard
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(saved, forType: .string)
}
```

**Why**: Bulletproof path for fragile web/Electron editors that drop/duplicate fast synthetic keystrokes.

**Trade-off**: Observable paste (app sees clipboard contents, not individual keystrokes), slower.

**Default**: OFF (Typer+ is a typer first).

---

## PART 14: DETECTOR — HUMAN-LIKENESS SCORING

Headless tool to measure how human a typing session is (keystroke-dynamics features).

### 14.1 Keystroke-Dynamics Features

Derived from the planned actions:

- **IKI distribution** (mean, variance, skewness, kurtosis, quantization comb excess)
- **Dwell distribution** (mean, variance, per-key regularity)
- **Flight distribution** (negative times = overlap, rollover probability)
- **HT-FT joint** (correlation between hold time and next flight time — human signature)
- **Per-bigram IKI** (conditional means: "th" faster than random pairs)
- **Capitals coverage** (Shift coverage for each capital letter)
- **Error metrics** (residual error rate, immediate correction rate, delayed correction latency)
- **Temporal structure** (AR(1) autocorrelation, warmup ramp, fatigue drift)

### 14.2 Scoring Bands

Each feature scored 0–1 against human baselines (with margins):

- **Green (1.0)**: Inside human range (statistically plausible)
- **Ramp (0–1)**: Margins around range (biologically plausible, just rare)
- **Red (0)**: Outside range (bot-only tell, extremely suspicious)

### 14.3 Veto Gates

Certain metrics have hard thresholds:
- **Residual error > 15%**: Zero score (too many uncorrected typos)
- **Keyless Shift-only coverage < 20%**: Zero score (never actually capitalized)
- **IKI quantization comb > 0.2**: Suspicious (artificial precision)

### 14.4 Fused Score

Weighted geometric mean (each zero vetos the whole score):

```
HLS = 100 * sqrt(IKI_score * Dwell_score * ... * ErrorRecovery_score)
```

**HLS (Human-Likeness Score)** 0–100:
- 90–100: Indistinguishable from human
- 70–89: Human-like, minor tells
- 50–69: Plausible, some detectability
- 20–49: Suspicious, likely bot
- 0–19: Obvious bot

---

## PART 15: TESTING INFRASTRUCTURE

### 15.1 InjectTest (De-Risk Harness)

```bash
swift run InjectTest
```

Proves two blocking premises **before** the full app relies on them:

1. Chrome sees CGEvent keystrokes as `isTrusted: true`
2. Google Docs canvas editor ingests `CGEventKeyboardSetUnicodeString`

**How it works**:
1. Posts per-character keystrokes (never pastes)
2. User runs JavaScript listener in Chrome console
3. Listener logs: `event.isTrusted`, `inputType`, `data`
4. Expected: isTrusted=true, inputType="insertText", data=character

### 15.2 SelfTest (Headless Correctness)

```bash
swift run TyperPlus --selftest
```

Checks:
1. **Zero-error reconstruction**: Plan reproduces input verbatim when typoRate=0
2. **Heavy typos with zero residue**: Every injected slip is fully undone
3. **Delays are finite**: Plan is non-empty, no NaN/Inf delays
4. **Grammar slips don't corrupt beyond one confusable**: Edit distance bounded
5. **Timing statistics land on research targets**: Median IKI, dwell, autocorrelation, overlap in expected ranges (per mode)

**Deterministic**: Seeds RNG, re-runs produce identical results.

**Headless**: No UI, no events posted, no permissions needed.

### 15.3 SpeedTest (Delivery Throughput)

```bash
swift run TyperPlus --speedtest
```

Dry-run Player: executes full plan without posting real events.

Measures true per-second delivery rate of the Player's execution loop (independent of HID layer).

**Example output**: "Max Speed mode: 847 keys/sec (16 runs average)"

---

## PART 16: BUILD SYSTEM

### 16.1 Swift Package Manager (SPM)

```swift
// Package.swift
let package = Package(
    name: "TyperPlus",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "TyperPlus", targets: ["TyperPlus"]),
        .executable(name: "InjectTest", targets: ["InjectTest"])
    ],
    dependencies: [],  // Zero external dependencies
    targets: [
        .executableTarget(
            name: "TyperPlus",
            dependencies: [],
            resources: [.process("Resources/")]
        ),
        .executableTarget(
            name: "InjectTest",
            dependencies: []
        )
    ]
)
```

**Zero external dependencies**: Everything is standard macOS frameworks + Swift stdlib.

### 16.2 Build Script (build_app.sh)

```bash
#!/bin/bash
set -e

# 1. Build the executable
swift build -c release

# 2. Create .app bundle structure
APP_NAME="TyperPlus"
APP_BUNDLE="./${APP_NAME}.app/Contents"

mkdir -p "${APP_BUNDLE}/MacOS"
mkdir -p "${APP_BUNDLE}/Resources"

# 3. Copy executable
cp .build/release/TyperPlus "${APP_BUNDLE}/MacOS/"

# 4. Copy Info.plist
cp SupportFiles/Info.plist "${APP_BUNDLE}/"

# 5. Copy icon
cp SupportFiles/AppIcon.icns "${APP_BUNDLE}/Resources/"

# 6. Copy fonts (bundled resources)
cp -r Sources/TyperPlus/Resources/Fonts "${APP_BUNDLE}/Resources/"

# 7. Create .app shortcut
ln -sf . "${APP_NAME}.app"
```

Output: `TyperPlus.app` (signed, ready to launch).

### 16.3 Info.plist (Accessibility Permission Declaration)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Typer+</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    
    <!-- Accessibility permission required for CGEvent posting + HID tap -->
    <key>NSAccessibilityUsageDescription</key>
    <string>Typer+ needs accessibility permission to type text into any application. This is required to inject keyboard events and listen for the triple-ESC kill switch.</string>
    
    <!-- Sandbox disabled: CGEvent posting is forbidden in sandboxed apps -->
    <key>com.apple.security.app-sandbox</key>
    <false/>
    
    <!-- Code signing -->
    <key>CFBundleIdentifier</key>
    <string>com.typerplus.app</string>
</dict>
</plist>
```

**Key declarations**:
- **NSAccessibilityUsageDescription**: Why the app needs Accessibility permission
- **app-sandbox: false**: Allow unsandboxed CGEvent posting

---

## PART 17: ARCHITECTURE DIAGRAM

```
┌──────────────────────────────────────────────────────────────────────┐
│                         USER TIER                                    │
│  Target App (Chrome, Terminal, Word, Docs, etc.)                    │
└──────────────────────────────────────────────────────────────────────┘
                              △
                              │ CGEvent injection
                              │ (HID layer posting)
                              │ isTrusted = true
┌──────────────────────────────────────────────────────────────────────┐
│                       TYPER+ EXECUTION                               │
│                                                                      │
│  ┌─────────────┐                                                    │
│  │  Player     │ (Monotonic clock, action playback)                 │
│  │ (Main Loop) │                                                    │
│  └──────┬──────┘                                                    │
│         │ execute(op) via                                           │
│         │                                                           │
│  ┌──────▼────────────────┐                                          │
│  │   KeyboardEngine      │ (CGEvent primitive)                      │
│  │ - charDown/charUp     │                                          │
│  │ - keyDown/keyUp       │                                          │
│  │ - shiftDown/shiftUp   │                                          │
│  │ - pasteShortcut()     │                                          │
│  └──────┬────────────────┘                                          │
│         │ .post(tap: .cghidEventTap)                                │
│         │                                                           │
│  ┌──────▼────────────────┐                                          │
│  │  CGEvent@HIDLayer    │                                           │
│  │ (Kernel level)       │                                           │
│  └──────┬────────────────┘                                          │
│         │                                                           │
│         └─────────► CGEventSource(.hidSystemState)                  │
│                     localEventsSuppressionInterval=0                │
│                     mach_absolute_time() timestamp                  │
│                     kVK_* or Unicode string                         │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │              PLANNING TIER                                  │   │
│  │                                                             │   │
│  │  Text "Hello" ──► Planner.plan() ──► [Action]             │   │
│  │                   - Timing.interKeyMs(...)                │   │
│  │                   - Typing​Profile (Careful/Max Stealth)  │   │
│  │                   - Typos.charSlip(...)                   │   │
│  │                   - Shift management                       │   │
│  │                   - Word/sentence pauses                   │   │
│  │                                                             │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │              SAFETY TIER                                    │   │
│  │                                                             │   │
│  │  ┌───────────────┐  ┌──────────────┐  ┌──────────────────┐ │   │
│  │  │  KillSwitch   │  │ Permissions  │  │ SecureInput Detect│ │   │
│  │  │ Triple-ESC    │  │ Accessibility│  │ (Password fields) │ │   │
│  │  │ Tap + Monitor │  │ Gate         │  │ Auto-pause        │ │   │
│  │  └───────────────┘  └──────────────┘  └──────────────────┘ │   │
│  │                                                             │   │
│  │  ┌──────────────┐                                           │   │
│  │  │ CountdownHUD │                                           │   │
│  │  │ Non-blocking │                                           │   │
│  │  │ 5s wait      │                                           │   │
│  │  └──────────────┘                                           │   │
│  │                                                             │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
                              △
                              │ Settings, Hotkeys
                              │
┌──────────────────────────────────────────────────────────────────────┐
│                       UI TIER (SwiftUI + AppKit)                    │
│  - MenuBarController (NSStatusItem, menu)                           │
│  - MainWindowController (Home, History, Settings, Help)            │
│  - BubbleController (floating quick-paste)                         │
│  - AppModel (Observable state bridge)                              │
└──────────────────────────────────────────────────────────────────────┘
```

**Data flow**:
1. User presses ⌘⌥T
2. Clipboard read + permissions check
3. Planner: Text → [Action] with research-tuned timing
4. CountdownHUD: 5s user preparation
5. Player: Monotonic clock executes [Action] via KeyboardEngine
6. KeyboardEngine: CGEvent at HID layer
7. Target app: Receives isTrusted keystrokes

**Safety layers**: Kill switch, Secure Input pause, Permissions gate

---

## PART 18: DATA FLOW DIAGRAM

### "Hello world" Through the System

```
┌────────────────────────────────────────────────────────┐
│  INPUT: String "Hello world"                           │
└────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────┐
│ TextCleanup.clean()                                    │
│ - Normalize CRLF/CR → LF                              │
│ - Strip invisibles, fold exotic spaces (if enabled)   │
│ OUTPUT: String "Hello world" (unchanged)              │
└────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────┐
│ Planner.plan(text, profile, persona, rng)             │
│                                                        │
│ For each character:                                   │
│   - Detect if shifted: 'H' → true                     │
│   - Timing.interKeyMs() → IKI (e.g., 190ms)          │
│   - Timing.dwellMs() → dwell (e.g., 110ms)           │
│   - Typos.charSlip() → slip (e.g., none)             │
│   - Schedule Shift-down, char-down, char-up, Shift-up │
│   - Advance clock                                      │
│                                                        │
│ OUTPUT: [Action] with absolute timings               │
└────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────┐
│ Player.play([Action])                                  │
│                                                        │
│ Monotonic clock loop:                                 │
│   For each action due:                                │
│     - Pause check (safe to inject?)                   │
│     - Wall-clock floor check (reliable delivery)      │
│     - execute(action.op) via KeyboardEngine           │
│     - Update elapsed time                             │
│                                                        │
│ OUTPUT: CGEvent stream to OS                          │
└────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────┐
│ KeyboardEngine (execute)                               │
│                                                        │
│ Action 1: Shift-down                                  │
│   → postCode(56, down: true)                          │
│   → CGEvent(vk: 56, keyDown: true)                    │
│   → flags = .maskShift                                │
│   → post(tap: .cghidEventTap)                         │
│                                                        │
│ Action 2: charDown('H')                               │
│   → postChar('H', down: true)                         │
│   → CGEvent(vk: 0, keyDown: true)                     │
│   → keyboardSetUnicodeString([0x48])  (UTF-16 'H')   │
│   → flags = .maskShift (held)                         │
│   → post(tap: .cghidEventTap)                         │
│                                                        │
│ OUTPUT: HID-layer CGEvents                            │
└────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────┐
│ OS HID Layer                                           │
│                                                        │
│ Event source: .hidSystemState (hardware-like)         │
│ Timestamp: mach_absolute_time() (real kernel ticks)   │
│ Autorepeat: 0 (never repeat)                          │
│ Flags: .maskShift (Shift held)                        │
│ Unicode: 'H' via UTF-16                               │
│                                                        │
│ OUTPUT: isTrusted = true keypress                     │
└────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────┐
│ Target Application (Chrome, Terminal, Docs, etc.)     │
│                                                        │
│ Receives:                                             │
│   - event.isTrusted = true                            │
│   - event.keyCode = 0 (or hardware code)              │
│   - event.charCode = 0x48 (H)                         │
│   - event.shiftKey = true                             │
│   - event.domKey = "H"                                │
│                                                        │
│ App processes:                                        │
│   - DOM: beforeinput, keydown (isTrusted: true)      │
│   - Autocorrect sees keystroke                        │
│   - Document model updated                            │
│   - Canvas/contenteditable rendered                   │
│                                                        │
│ OUTPUT: "H" visible on screen                         │
└────────────────────────────────────────────────────────┘

(Repeat for 'e', 'l', 'l', 'o', ' ', 'w', 'o', 'r', 'l', 'd')

FINAL OUTPUT: "Hello world" typed on screen, character by character
              at natural human rhythm with research-tuned timing
```

---

## PART 19: ONE CHARACTER TRACE

Detailed walkthrough of how different characters are handled.

### Example 1: Capital 'A'

**Input character**: 'A' (uppercase)

**Step 1: Planner detects Shift**
```
isShifted('A') → true
currentlyShifted (state) → false
→ emit Shift-down 15ms before 'A'-down (shift lead)
→ currentlyShifted = true
```

**Step 2: Timing**
```
IKI = exGaussian(190, 60, 34) * bigramMultiplier(...) * handBias(...) * exp(arIKI) * warmup * (1+fatigue)
    ≈ 220ms (depends on previous char)
dwell = truncatedNormal(117, 10, 50, 200) ≈ 115ms
clock = 0ms
```

**Step 3: Schedule actions**
```
Event 1: (t=0, Shift-down)
Event 2: (t=15, A-down)
Event 3: (t=130, A-up)
Event 4: (t=130, Shift-up)
clock = 130ms
```

**Step 4: Player execution**
```
Tick 1 (t=0ms): Post Shift-down
Tick 2 (t=15ms): Post A-down with flags=.maskShift
Tick 3 (t=130ms): Post A-up with flags=.maskShift (still held), then Shift-up
```

**Step 5: CGEvents to OS**
```
1. Shift-down (kVK_Shift=56, vk=56, keyDown=true, flags=[], autorepeat=0, timestamp=mach_absolute_time())
   → OS routes to focused app: "Shift key pressed"
   → isTrusted = true

2. A-down (kVK_A=?, vk=0, keyDown=true, Unicode='A' UTF-16=[0x41], flags=.maskShift, autorepeat=0)
   → OS renders with Shift held: capital A
   → isTrusted = true

3. A-up (kVK_A=?, vk=0, keyDown=false, Unicode='A' UTF-16=[0x41], flags=.maskShift)
   → isTrusted = true

4. Shift-up (kVK_Shift=56, vk=56, keyDown=false, flags=[], autorepeat=0)
   → isTrusted = true
```

**Step 6: Target app sees**
```
beforeinput event: inputType="insertText", data="A", isTrusted=true
keydown event: key="A", shiftKey=true, code="KeyA"
keyup event: key="Shift", code="ShiftLeft"
Characters typed: "A" on screen
```

---

### Example 2: '@' (At-sign, Shift+2 on US layout)

**Input character**: '@'

**Step 1: Planner detects Shift** (@ is shifted on US layout)
```
isShifted('@') → true
→ emit Shift-down
→ emit @-down with flags=.maskShift
→ emit @-up with flags=.maskShift
→ emit Shift-up
```

**Step 2: CGEvent posted by KeyboardEngine**
```
postChar('@', down: true)
  forceUnicodeOnly = true (default)
  vk = 0 (never use a real keycode)
  CGEvent(vk: 0, keyDown: true)
  keyboardSetUnicodeString([0x40]) (UTF-16 '@')
  flags = .maskShift
  post(tap: .cghidEventTap)
  → isTrusted = true

postChar('@', down: false)
  vk = 0
  flags = .maskShift (still held)
  post(tap: .cghidEventTap)
  → isTrusted = true
```

**Why vk=0?**
- On US layout: Shift+2 would produce vk for '2', but receiver wouldn't render '@'
- On French layout: Shift+2 is invalid code
- On Japanese layout: Shift+2 is unrelated character
- Unicode string '@' is unambiguous: every layout sees @

**Step 3: Target app (Google Docs)**
```
Receives: Shift-down, @-down (vk=0, Unicode='@'), @-up, Shift-up
Docs renders: @
Correct in every keyboard layout
```

---

### Example 3: 'é' (E with acute accent, no US layout key)

**Input character**: 'é'

**Step 1: Planner detects not shifted**
```
isShifted('é') → false (no Shift)
→ emit é-down
→ emit é-up
```

**Step 2: CGEvent posted by KeyboardEngine**
```
postChar('é', down: true)
  forceUnicodeOnly = true
  vk = 0 (no fallback keycode for é)
  CGEvent(vk: 0, keyDown: true)
  String('é').utf16 = [0xE9]
  keyboardSetUnicodeString([0xE9])
  flags = [] (no modifiers)
  post(tap: .cghidEventTap)
  → isTrusted = true
```

**Why this works**:
- No real keycode can produce é on US layout (doesn't exist)
- Unicode string [0xE9] is the only specification
- Target app renders é regardless of layout
- Tried on Dvorak, Colemak, French, Japanese: all work

---

### Example 4: 'ह' (Devanagari HA, Unicode U+0939)

**Input character**: 'ह'

**Step 1: Planner detects not shifted**
```
isShifted('ह') → false
→ emit ह-down
→ emit ह-up
```

**Step 2: CGEvent posted by KeyboardEngine**
```
postChar('ह', down: true)
  vk = 0
  String('ह').utf16 = [0x0939]
  keyboardSetUnicodeString([0x0939])
  post(tap: .cghidEventTap)
```

**Target app**:
```
Receives Unicode string [0x0939]
Renders: ह
Works in Chrome, Google Docs, Slack, any app supporting Unicode input
```

---

### Example 5: Backspace (Correction after typo)

**Input sequence**: "hello" with typo "heloo" (doubled 'o'), immediate correction

**Step 1: Planner generates typo**
```
Typos.charSlip(intended: 'l', profile: profile) → SlipKind.doubling
→ typed: ['l', 'l']
→ correction: .immediate(prob: 100%)
```

**Step 2: Plan schedule**
```
...h, e, l, o (wrong l), backspace, l (correct)...

Action 1: l-down (typo first 'l')
Action 2: l-up
Action 3: l-down (typo second 'l')
Action 4: l-up
Action 5: backspace-down (keyDown(kVK_Delete=51))
Action 6: backspace-up (keyUp(kVK_Delete=51))
Action 7: l-down (correct 'l')
Action 8: l-up
```

**Step 3: Player execution**
```
Post l, l, then backspace
→ Caret moves back one
→ Post correct l
→ User sees correction unfold in real-time
```

**Step 4: CGEvent posts**
```
1. l-down (vk=0, Unicode='l')
2. l-up
3. l-down (second typo)
4. l-up
5. backspace-down (kVK_Delete=51, real keycode, NOT Unicode)
6. backspace-up
7. l-down (correction)
8. l-up
```

**Target app behavior**:
```
Sees 'l', 'l', then backspace (deletes last 'l'), then 'l'
Final result: "hello" (typo fixed)
User watches correction happen
```

---

## PART 20: GLOBAL HOTKEY TRACE

How ⌘⌥T (hotkey) reaches the typing engine.

### Flow

```
1. User presses ⌘⌥T (Command+Option+T) in any app

2. macOS keyboard event → global hotkey tap (Carbon EventTap)

3. Carbon EventTap dispatcher:
   - Matches against registered hotkeys
   - Finds: Hotkey.register(keyCode: 17, modifiers: [.command, .option])
   (keyCode 17 = 'T', modifiers = ⌘⌥)

4. Carbon fires callback → Hotkey.onFire

5. Hotkey.onFire closure → AppController.hotkeyClipboardToggle()

6. AppController.hotkeyClipboardToggle():
   ```swift
   func hotkeyClipboardToggle() {
       guard let clipboard = NSPasteboard.general.string(forType: .string) else {
           NSSound.beep()
           return
       }
       beginTyping(clipboard)
   }
   ```

7. Read clipboard text

8. beginTyping(text) → single chokepoint:
   - Guard: not already running
   - Guard: post-run debounce (0.8s)
   - Cleanup text
   - Permission check
   - Kill switch check
   - Hand focus to target app
   - Countdown HUD
   - Player execution
```

### Hotkey Registration (AppController.applicationDidFinishLaunching)

```swift
hotkey.register(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers) { [weak self] in
    self?.hotkeyClipboardToggle()
}
```

**Hotkey.register()**:
```swift
func register(keyCode: UInt32, modifiers: UInt32, onFire: @escaping () -> Void) {
    var hotKeyID = EventHotKeyID(signature: OSType(UInt32(CFSwapInt32HostToBig(1))), id: 1)
    var eventHotKeyRef: EventHotKeyRef?
    
    let result = RegisterEventHotKey(
        hotKeyCode,
        modifiers,
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &eventHotKeyRef)
    
    if result == noErr {
        self.hotkeys[key] = (ref: eventHotKeyRef!, onFire: onFire)
    }
}
```

Registers at the system level (Carbon). Fires even if Typer+ is not in focus.

---

## PART 21: STOP TRACE (Triple-ESC)

How triple-ESC kills a typing run.

### Flow

```
1. User presses ESC three times within 0.3s

2. First ESC keyDown → OS routes to global key listeners

3. KillSwitch.CGEventTap sees keyDown:
   - Filters: not autorepeat ✓
   - Filters: not our own injected event ✓
   - Filters: keycode == 53 (ESC) ✓
   → handle(type: .keyDown, event: event)
   → killSwitchCallback(userInfo: KillSwitch pointer)
   → recordEsc()

4. KillSwitch.recordEsc():
   ```swift
   let now = ProcessInfo.processInfo.systemUptime
   if now - lastEscAt < 0.025 { return }  // dedupe
   lastEscAt = now
   escTimestamps.append(now)
   escTimestamps.removeAll { now - $0 > escWindow }
   
   if escTimestamps.count >= 3 {
       escTimestamps.removeAll()
       onTripleEsc?()  // FIRE
   }
   ```

5. KillSwitch.onTripleEsc → AppController.stopTyping()

6. AppController.stopTyping():
   ```swift
   func stopTyping() {
       engine.resetModifiers()      // release any held Shift/Option
       player.abort()               // abort mid-run
       powerAssertion.end()         // allow display sleep
       isTyping = false
       lastRunEndedAt = systemUptime
       refreshUI()
   }
   ```

7. Player.abort():
   ```swift
   func abort() {
       releaseHeldKeys()     // post all pending key-ups
       resetModifiers()      // idempotent: release Shift, Option
       finish()              // mark finished
   }
   ```

8. Any held keys are released (safe state)

9. User's focus unchanged (target app still active)

10. User can immediately type their own characters
```

### Why Triple-ESC Is Bulletproof

1. **Typer+ never injects ESC** (keycode 53 blacklisted)
2. **Real ESC always has PID 0** (OS enforces for hardware)
3. **Our injected events have our PID** → filtered by KillSwitch
4. **Three independent detectors** (tap, NSEvent monitor, watchdog)
5. **Un-spoofable**: Even if Typer+ is mid-type, it can't inject a fake ESC to abort itself

---

## PART 22: THREADING MODEL

Which components run where, which queues, which timers, async patterns.

### Main Thread (Grand Central Dispatch Concurrency)

**Everything** runs on the **main thread**:

```swift
// AppController, Player, KillSwitch, Hotkey, CountdownHUD
// NSApplication event loop, UI updates, CGEvent posting
```

**Why main thread only?**
- UI updates must happen on main thread (AppKit/SwiftUI rule)
- CGEvent posting must happen on main thread (CoreGraphics rule)
- KillSwitch tap listens on run loop (main thread only)
- No multi-threading complexity, no data races, no locks needed

### Timer Patterns

**RunLoop timers** (not GCD):
```swift
let timer = Timer(timeInterval: 1.5, repeats: true) { _ in ... }
RunLoop.main.add(timer, forMode: .common)  // fire even during scrolling
```

Modes: `.common` includes `.default` + `.eventTracking` (responsive even while scrolling).

**Examples**:
- `permissionPoll`: 1.5s retry loop for Accessibility permission
- `watchdog`: 2s re-arm for KillSwitch if disabled
- `countdown`: 1s decrements for HUD
- `player.tick()`: Dynamic scheduling based on action timing

### Activity Token (Latency-Critical)

```swift
let token = ProcessInfo.processInfo.beginActivity(
    options: [.userInitiated, .latencyCritical],
    reason: "Typer+ typing")

// Prevents App Nap coalescing
// Prevents timer throttling
```

Held during Player execution, released on finish.

### Async Patterns

**Apple Event Handler** (URL scheme):
```swift
@objc func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent: NSAppleEventDescriptor) {
    // Called by AppleEvent dispatcher (main thread)
    // Synchronous handling
}
```

**No async/await used**: Everything is synchronous callbacks on main thread.

---

## PART 23: FAILURE MODES & RECOVERY

### Comprehensive Failure Table

| Failure Mode | Detection | Recovery | User Impact |
|---|---|---|---|
| **Permission denied (Accessibility)** | `!Permissions.allReady` | Show Settings pane, start 1.5s poll | Run blocked, user must grant permission |
| **Kill switch can't arm** | `armIfPossible() == false` | Request Input Monitoring separately | Run blocked, prompt Settings |
| **Secure Input (password field)** | `IsSecureEventInputEnabled()` | Player pauses at boundary | Auto-paused, resumes when field loses focus |
| **Focus stolen (user switches apps)** | CGEvent rejected by OS | Player continues (events go to wrong app) | Text typed in wrong app (rare, user's responsibility) |
| **User stops typing (ESC down)** | KillSwitch detects ESC once | Wait for triple-ESC within 0.3s | Single ESC is just a keystroke, needs triple |
| **Triple-ESC abort triggered** | KillSwitch detects 3 ESCs | `player.abort()` releases all keys | Typing stops immediately, clean state |
| **App closed mid-run** | Player tries to post, OS silently rejects | Events are dropped | Text not typed, not corrupted |
| **Display sleeps** | PowerAssertion missing | No recovery (Display sleeps mid-type) | Typing pauses, resumes when woken |
| **Clipboard empty/unset** | `NSPasteboard.general.string(forType: .string) == nil` | Beep, abort | User must copy first |
| **Malformed Unicode** | CGEvent creation fails | Skip event, move to next | Character missing (rare) |
| **IKI timing failure (NaN/Inf)** | SelfTest catches (--selftest) | Fix Timing model | Shouldn't happen in production |
| **Typo slip infinite loop** | SelfTest catches (--selftest) | Fix Typos model | Shouldn't happen in production |
| **CGEventTap disabled by OS** | Watchdog detects `!isArmed` | Reinstall tap in 2s | Kill switch goes down briefly, watchdog brings back |
| **Settings corrupted** | UserDefaults read returns nil/invalid | Use hardcoded defaults | App continues with safe defaults |
| **Player pause infinite loop** | `pauseProvider` always true | Player waits indefinitely | User must alt-tab or triple-ESC |
| **Post event fails** | CGEvent creation returns nil | Skip event silently | Character missing (rare, fragile app) |

### Recovery Strategies

**Silent skip** (character missing):
- CGEvent creation fails (very rare, fragile app/framework bug)
- Skip and move to next action
- Rarely noticeable (fast typing, one char missing in 100)

**Pause-and-wait** (Secure Input):
- Pause at clean keystroke boundary
- Wait until `IsSecureEventInputEnabled() == false`
- Resume automatically (no user intervention)

**Abort-on-user-gesture** (triple-ESC):
- Only way to forcefully stop
- Releases all held keys cleanly
- User can immediately type their own characters

**Prompt-and-retry** (permissions):
- Show Accessibility Settings pane
- Retry every 1.5s
- Once granted, arm kill switch automatically

---

## PART 24: REUSE CLASSIFICATION

**Code organization for AI-integration roadmap**: What to keep, study, rewrite, remove.

### KEEP (Reusable Foundation)

| Component | Why | Reuse For |
|---|---|---|
| **KeyboardEngine.swift** | Proven injection primitive (CGEvent + HID layer) | AI text generation → keyboard posting |
| **Timing.swift** | Research-grounded IKI/dwell distributions | Any realistic typing simulation |
| **TypingProfile.swift** | Speed modes + parameters | Calibrating generated text rhythm |
| **RNG.swift** | Ex-Gaussian, truncated-normal, AR(1) | Stochastic text generation |
| **KeyMap.swift** | US-QWERTY layout, hand assignment | Multi-layout support (future) |
| **KillSwitch.swift** | Triple-ESC emergency stop | Safety-critical user control |
| **Permissions.swift** | Accessibility gate, permission polling | Required for any macOS keyboard injection |
| **PowerAssertion** | Display sleep prevention | Any long-running task |
| **Player.swift** | Monotonic clock, pause/resume, abort | Any timing-critical playback |
| **InjectTest.swift** | De-risk harness proving CGEvent isTrusted | QA for any injection-based tool |

### STUDY (Learn From, Then Adapt)

| Component | What To Learn | Adaptation |
|---|---|---|
| **Planner.swift** | Serial correction logic, Shift management | AI text generation will need: bigram-aware pacing, grammar correction handling |
| **Typos.swift** | Character-slip generation (muscle memory model) | AI text won't have typos, but might have *style slips* (formal → casual, British → American) |
| **Detector.swift** | Keystroke-dynamics feature extraction | Critical for AI detection evasion; use to score generated text |
| **TextCleanup.swift** | Newline/invisible normalization | Important for clipboard text from diverse sources |
| **AppController lifecycle** | Permission checking, service initialization | Template for AI-powered version's startup flow |

### REWRITE (Incompatible With AI)

| Component | Why | Replacement |
|---|---|---|
| **UI/HomeView.swift** | Manual text input (paste box) | AI-powered compose: "what do you want to type?" + LLM text generation |
| **UI/HistoryView.swift** | Lists past manual-paste sessions | Future: AI generation history with confidence/detection scores |
| **Settings.swift** | Manual mode selection (Careful/Ultra Fast) | AI chooses speed/style based on context (email vs. coding vs. social media) |
| **Hotkey.swift** | Single global hotkey (⌘⌥T) | Multiple hotkeys: "⌘⌥T for AI compose", "⌘⌥Shift+T for style select", etc. |
| **Menu structure** | Static menu (Type, Stop, Settings) | Dynamic menu: AI write task, recent generations, settings |

### REMOVE (Dead Weight)

| Component | Why |
|---|---|
| **SelfTest.swift** (deterministic text check) | AI text isn't deterministic; replace with ML-based correctness tests |
| **speedtest** CLI flag | Not relevant for AI-generated text |
| **BubbleController** (floating bubble) | Can be removed; replaced with compose window |
| **UI/HelpView** | Replace with AI-specific documentation |

---

## PART 25: WHAT TYPER+ DOES NOT SOLVE

Critical gaps for AI-powered typing automation:

### 1. **Text Generation** (No AI Model)
- Typer+ types given text; doesn't generate it
- **AI gap**: Needs LLM (GPT, Claude, Llama, etc.)
- **Solution**: Build text orchestrator layer (Part 26)

### 2. **Context Understanding**
- Typer+ is context-blind (types whatever you give it)
- **AI gap**: Doesn't know what app is focused, what field is active, what task the user is doing
- **Solution**: Context engine (app detection, field classification, task inference)

### 3. **Screen Understanding**
- No OCR, no vision, no layout analysis
- **AI gap**: Can't read what's on screen to respond contextually
- **Solution**: Optional: Vision LLM for complex tasks (future)

### 4. **Form/Field Detection**
- No automatic field detection
- **AI gap**: Can't tell "name field" from "email field" from "textarea"
- **Solution**: UI introspection layer or user hints

### 5. **Multi-Step Workflows**
- Typer+ is single-run (type text, then stop)
- **AI gap**: Can't orchestrate multi-field forms, search-then-fill workflows
- **Solution**: Workflow orchestrator

### 6. **API/Backend Integration**
- Completely offline (no network)
- **AI gap**: No way to fetch data, authenticate, or log actions
- **Solution**: Optional: Web service layer

### 7. **Accounts & Authentication**
- No login, no user identity
- **AI gap**: Can't track who did what, or maintain per-user settings
- **Solution**: Optional: Auth layer

### 8. **Analytics & Logging**
- No telemetry (privacy-first)
- **AI gap**: Hard to debug why AI generation failed, or track user patterns
- **Solution**: Optional: Opt-in logging

### 9. **Detection Evasion Verification**
- Detector.swift scores human-likeness, but no real-world testing
- **AI gap**: Can't verify AI text actually bypasses detection in target app
- **Solution**: Optional: Sandbox testing against real targets

---

## PART 26: FUTURE AI ARCHITECTURE

How to evolve Typer+ into AI-powered text automation (high-level blueprint).

### Layer 1: Text Generation (LLM)

```swift
protocol TextGenerator {
    func generateText(prompt: String, context: Context) async -> String
}

class OpenAITextGenerator: TextGenerator {
    let apiKey: String
    let model: String  // "gpt-4-turbo", "gpt-4o", etc.
    
    func generateText(prompt: String, context: Context) async -> String {
        let request = ChatCompletionRequest(
            model: model,
            messages: [
                .system("You are a helpful assistant typing into a focused app."),
                .user(prompt)
            ],
            context: context.systemPrompt()  // app type, field type, constraints
        )
        let response = try await openai.createChatCompletion(request)
        return response.choices[0].message.content
    }
}
```

### Layer 2: Context Engine

```swift
struct Context {
    let focusedApp: String           // "Google Chrome", "Terminal", "Microsoft Word"
    let fieldType: FieldType         // .email, .password, .textarea, .codeEditor
    let selection: String            // text currently selected (if any)
    let nearbyText: String           // context before/after cursor
    let taskHint: String?            // user's intent ("write a reply", "fill form", etc.)
    
    enum FieldType { case email, password, textarea, codeEditor, singleLine, rich }
}

class ContextEngine {
    func detectFocusedApp() -> String {
        let workspace = NSWorkspace.shared
        return workspace.activeApplication()?[NSWorkspace.ApplicationKey.NSApplicationName] as? String ?? "Unknown"
    }
    
    func detectFieldType() -> FieldType {
        // Future: UI introspection, accessibility tree reading, ML-based field classification
        return .textarea  // placeholder
    }
    
    func getCurrentContext() -> Context {
        return Context(
            focusedApp: detectFocusedApp(),
            fieldType: detectFieldType(),
            selection: "",  // Future: get from clipboard or accessibility APIs
            nearbyText: "",  // Future: OCR or UI introspection
            taskHint: nil
        )
    }
}
```

### Layer 3: Orchestrator (High-Level Control)

```swift
class AITypingOrchestrator {
    let textGenerator: TextGenerator
    let contextEngine: ContextEngine
    let typerEngine: Player  // Typer+ core (reused)
    let profileSelector: ProfileSelector
    
    func autoType(userPrompt: String) async {
        // 1. Understand context
        let context = contextEngine.getCurrentContext()
        
        // 2. Generate text
        let generatedText = await textGenerator.generateText(prompt: userPrompt, context: context)
        
        // 3. Select speed profile based on context
        let profile = profileSelector.selectProfile(for: context)
        
        // 4. Plan timing
        let plan = Planner.plan(generatedText, profile: profile, persona: defaultPersona, rng: &rng)
        
        // 5. Show human-in-loop confirmation (optional)
        let approved = await showPreview(text: generatedText)
        guard approved else { return }
        
        // 6. Type it
        await typerEngine.play(plan, speed: profile.relativeSpeed)
    }
}

class ProfileSelector {
    func selectProfile(for context: Context) -> TypingProfile {
        switch context.focusedApp {
        case "Terminal":
            return TypingProfile.maxSpeed  // code typing is fast and deliberate
        case "Gmail", "Slack":
            return TypingProfile.careful  // conversations are slower, more natural
        case "Google Docs":
            return TypingProfile.maxStealth  // document writing needs composition pacing
        default:
            return TypingProfile.ultraFast
        }
    }
}
```

### Layer 4: UI (Compose Window)

```swift
struct AIComposeView: View {
    @State var userPrompt: String = ""
    @State var generatedText: String = ""
    @State var isGenerating: Bool = false
    @State var selectedProfile: TypingProfile = .ultraFast
    
    var body: some View {
        VStack {
            // User writes what they want
            TextEditor(text: $userPrompt)
                .frame(height: 80)
                .border(Color.gray)
            
            // AI generates
            HStack {
                Button("Generate with AI") {
                    Task { await generateText() }
                }
                if isGenerating { ProgressView() }
            }
            
            // Preview generated text
            TextEditor(text: $generatedText)
                .frame(height: 120)
                .border(Color.blue)
            
            // Speed selector
            Picker("Typing speed", selection: $selectedProfile) {
                Text("Careful").tag(TypingProfile.careful)
                Text("Ultra Fast").tag(TypingProfile.ultraFast)
                Text("Max Stealth").tag(TypingProfile.maxStealth)
            }
            
            // Type it
            HStack {
                Button("Type it now") { typeText() }
                Button("Copy to clipboard") { copyToClipboard() }
                Button("Cancel") { reset() }
            }
        }
    }
    
    private func generateText() async {
        isGenerating = true
        generatedText = await orchestrator.generateText(userPrompt)
        isGenerating = false
    }
    
    private func typeText() {
        Task { await orchestrator.autoType(userPrompt) }
    }
}
```

### Layer 5: Safety & Detection Evasion

```swift
class SafetyLayer {
    let detector: Detector  // reuse Typer+ detector
    
    func scoreGeneratedText(_ text: String, profile: TypingProfile) -> HumanLikenessScore {
        let plan = Planner.plan(text, profile: profile, persona: defaultPersona, rng: &rng)
        return detector.score(plan: plan)
    }
    
    func ensureUndetectable(_ text: String, profile: inout TypingProfile) {
        var score = scoreGeneratedText(text, profile: profile)
        
        // If detectability too high, adjust speed/style
        if score.hls < 70 {
            profile = TypingProfile.maxStealth  // composition pacing helps
            score = scoreGeneratedText(text, profile: profile)
        }
        
        if score.hls < 50 {
            // Log concern, prompt user
            print("Generated text may be too detectable: HLS=\(score.hls)")
        }
    }
}
```

---

## PART 27: DON'T OVERENGINEER

**Critical principle for AI-powered Typer+**: Prove the core path first.

### Proof-of-Concept (Minimum Viable)

```
AI Prompt
  ↓
LLM (e.g., local Ollama, or OpenAI API)
  ↓
Generated text (plain string)
  ↓
Typer+ Planner (existing)
  ↓
CGEvent injection (existing KeyboardEngine)
  ↓
Text appears in focused app
```

**That's it**. No UI, no context engine, no profile selection, no detection evasion layer.

### Incremental Additions (After MVP Works)

1. **UI Preview** (user sees generated text before typing)
2. **Speed profile selector** (manual choice)
3. **Context detection** (app-aware speed)
4. **Safety scoring** (Detector integration)
5. **Multi-field workflows** (forms)
6. **Detection evasion** (advanced)

### Why Don't Overengineer?

1. **Unknown unknowns**: LLM text behaves differently than manual paste
   - Might need different profiles
   - Might have encoding issues
   - Might need special error handling

2. **User feedback loop**: Build MVP, deploy, get feedback, iterate
   - Don't spend 6 months building features users don't want

3. **AI models change fast**: New models, new APIs, new capabilities
   - Over-architecting now locks you into decisions that won't age well

4. **Typer+ is proven**: The injection + timing engine works. Reuse it.
   - Only add new layers for genuinely new problems
   - Don't refactor working code for hypothetical improvements

---

## PART 28: LEARNING PATH

### **LEVEL 1: Immediate (Understand Typer+ as Delivered)**

**Why it matters**: You need to use Typer+ confidently and know what it does/doesn't do.

| Concept | Where In Code | What To Learn | Time |
|---|---|---|---|
| **Hotkey Flow** | AppController, Hotkey.swift | How ⌘⌥T → CGEvent typing | 30min |
| **One Character** | KeyboardEngine, Player | 'A' from plan to screen | 20min |
| **Kill Switch** | KillSwitch.swift | Triple-ESC abort mechanism | 20min |
| **Permission Model** | Permissions.swift, AppController | Why Accessibility is required | 15min |
| **User Workflow** | AppController.beginTyping() | Copy → hotkey → type (whole flow) | 30min |
| **Reuse Checklist** | Part 24 of this document | Which code to keep for AI | 15min |

**Deliverable**: Run Typer+ on your own machine, type text, use triple-ESC, understand what you just did.

---

### **LEVEL 2: Integration (Understand How To Add AI)**

**Why it matters**: You can now architect the AI layer on top of Typer+.

| Concept | Where In Code | What To Learn | Time |
|---|---|---|---|
| **Planner Pipeline** | Planner.swift | Text → [Action] stream | 1h |
| **Timing Model** | Timing.swift, TypingProfile.swift | IKI generation, research basis | 1.5h |
| **Player Execution** | Player.swift | Monotonic clock playback | 1h |
| **RNG Distributions** | RNG.swift | Ex-Gaussian, truncated-normal | 45min |
| **Error Generation** | Typos.swift | Typo slip model | 45min |
| **Detector Scoring** | Detector.swift | Human-likeness metrics | 1h |
| **Context Engine Design** | (Design new) | App detection, field classification | 2h |
| **LLM Integration Design** | (Design new) | OpenAI/Ollama/local API | 2h |

**Deliverable**: Design document for AITypingOrchestrator (see Part 26) that you could hand off to implement.

---

### **LEVEL 3: Advanced (Deep Mechanics & Optimization)**

**Why it matters**: You can now debug timing issues, optimize for speed, detect problems.

| Concept | Where In Code | What To Learn | Time |
|---|---|---|---|
| **CGEvent Internals** | KeyboardEngine.swift, CoreGraphics docs | HID layer, isTrusted, mach_absolute_time | 2h |
| **AR(1) Autocorrelation** | Timing.swift | Shared tempo model, phi/sigma tuning | 1.5h |
| **Keystroke-Dynamics Research** | RESEARCH.md, Dhakal et al. 2018 | Statistical basis, 136M keystroke data | 3h |
| **Memory & Concurrency** | AppController, Player | Weak references, main thread safety, no locks | 1h |
| **Reliable Delivery** | Player.swift | Wall-clock floor, maxFlushPerTick | 1h |
| **Secure Input Detection** | AppController.shouldHold() | Password field auto-pause | 30min |
| **Event Tap Architecture** | KillSwitch.swift | CGEventTap + NSEvent monitor + watchdog | 2h |
| **Detection Evasion** | Detector.swift | Keystroke-dynamics features, veto gates, scoring | 2h |

**Deliverable**: You can now tune profiles for new apps, debug timing issues, optimize for detection evasion.

---

## PART 29: QUESTIONS CHECKLIST

**After reading this document, you should be able to answer:**

1. **What happens when you press ⌘⌥T?** (Flow from hotkey to first keystroke)
2. **Why does Typer+ use CGEvent at HID layer instead of clipboard paste?** (isTrusted, per-keystroke events, rhythym)
3. **How does the Player's monotonic clock work?** (Why not a timer-per-key?)
4. **Why is Unicode-only mode the default?** (Layout-independent, unambiguous)
5. **What does "forceUnicodeOnly" control?** (CGEvent virtualKey 0 + Unicode string vs. real keycodes)
6. **How does Shift management prevent getting stuck?** (Mirror pattern, post-then-update)
7. **What is ex-Gaussian and why is it used for IKI?** (Symmetric core + asymmetric tail = human typing)
8. **What does AR(1) autocorrelation do?** (Creates shared session tempo, not independent keystrokes)
9. **How are typos generated?** (Dhakal distribution: 46% substitution, 22% omission, etc.)
10. **What's the difference between immediate and delayed correction?** (Immediate: backspace-retype; delayed: go-back-and-fix later)
11. **How does Secure Input detection work?** (IsSecureEventInputEnabled() check, auto-pause at keystroke boundary)
12. **Why triple-ESC and not single ESC?** (Prevents accidental abort, un-spoofable because PID filtering)
13. **What does Permissions.allReady check?** (AXIsProcessTrusted() — single gate for all three layers)
14. **How does the kill switch survive being torn down by the OS?** (Watchdog timer re-installs every 2s)
15. **Why does Typer+ need PowerAssertion?** (Prevent display sleep mid-type)
16. **What does the latency-critical activity token do?** (Prevents App Nap coalescing when backgrounded)
17. **How does paste-delivery mode work?** (Set clipboard, post ⌘V, restore clipboard — atomic insert)
18. **What's the human-likeness score (HLS) based on?** (Keystroke-dynamics features: IKI, dwell, flight, per-bigram, error metrics)
19. **Why is DeploymentEnvironmentValidator headless?** (No permissions, no events posted, deterministic)
20. **What should be kept for AI integration?** (KeyboardEngine, Timing, Player, Planner core, RNG, Detector, KillSwitch, Permissions)
21. **What should be replaced for AI?** (UI, Hotkey, Settings, TextCleanup, Typos handling)
22. **What gaps does Typer+ have for AI?** (Text generation, context understanding, form detection, multi-step workflows)
23. **How would you add LLM text generation on top of Typer+?** (TextGenerator interface, ContextEngine for app/field detection, AITypingOrchestrator coordinator)
24. **Why don't keycode events work layout-independently?** (Each layout maps keycode to different character; Unicode string is unambiguous)
25. **What's the relationship between dwell and flight time?** (Flight = next-down time − current-up time; can be negative = overlap/rollover)

---

## PART 30: EXECUTIVE SUMMARY

**One-sentence explanations for developers**:

### Architecture
> **Typer+ is a macOS menu-bar app that injects realistic keystrokes into any focused application via CGEvent at the HID layer, making injected text indistinguishable from real hardware (isTrusted=true) and un-detectable by keystroke-dynamics analysis.**

### Typing Flow
> **Text → Planner (research-tuned timing + Shift management + error generation) → [Action] stream → Player (monotonic clock playback) → KeyboardEngine (CGEvent posting) → target app (perceives natural human typing).**

### Permission Model
> **Single Accessibility permission (System Settings ▸ Privacy & Security ▸ Accessibility) enables both CGEvent posting and global key listening; the app asks once on launch and retries every 1.5s if denied.**

### Timing Model
> **Inter-key intervals are drawn from ex-Gaussian distributions (symmetric core + right-skewed tail) multiplied by per-bigram factors (same-finger 1.38× slower, hand-alternation 0.84× faster), AR(1) shared tempo, warm-up ramp, and session fatigue drift, grounded in Dhakal et al. 2018 (136M keystrokes).**

### Safety Model
> **Triple-ESC within 0.3s aborts immediately (PID-filtered so Typer+ can't spoof it), Secure Input detection auto-pauses at password fields, and a 2s watchdog keeps the kill-switch CGEventTap alive even if torn down by the OS.**

### Error Handling
> **Character-level slips (46% adjacent-key substitution, 22% omission, 18% insertion, 7% doubling, 7% transposition) are generated probabilistically and corrected either immediately (backspace-retype) or delayed (caret jump-back-fix), with residue rate configurable (default 0%).**

### AI Extension (High-Level)
> **Add a TextGenerator layer (LLM API), ContextEngine (app/field detection), and AITypingOrchestrator coordinator; reuse Planner, Player, KeyboardEngine, Detector, and KillSwitch; replace UI and settings with AI-aware versions; prove the core MVP (AI text → Typer+ → target app) before over-engineering.**

---

**End of Document**

---

### Summary for Implementation

This document serves as a complete blueprint for:
1. Understanding Typer+ as a finished product
2. Extending it with AI text generation (Part 26)
3. Avoiding re-engineering existing, proven code (Part 24)
4. Learning the codebase incrementally (Part 28)
5. Debugging timing/detection issues (all deep-dive sections)

**Next step**: Start at LEVEL 1 (Part 28) and work through the learning path with the codebase open.
