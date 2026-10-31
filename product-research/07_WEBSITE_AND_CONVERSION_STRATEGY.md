# MacVoice: Website Architecture, Copywriting & Conversion Optimization

**Document Version:** 1.0.0  
**Research Date:** October 31, 2026  
**Auditor / Roles:** Technical Documentation Engineer & Conversion Optimization Specialist  
**Classification:** Website Specification & Conversion Blueprint  

---

## 1. Executive Website Strategy

The MacVoice website has a single, unwavering conversion objective:

> **Get the visitor to click `Download MacVoice.dmg` within 30 seconds of landing on the page.**

Because MacVoice is an ultra-compact **784 KB** download with **no sign-up, no email capture, and no credit card required**, our conversion rate will be substantially higher than typical SaaS websites (industry average: 3–5%). A clean, high-performance, developer-aesthetic website can realistically achieve an **18% to 25% visitor-to-download conversion rate**.

---

## 2. Information Architecture & Page Structure

The website should be a high-speed, single-page static site (hosted on Cloudflare Pages or Vercel) structured into 8 deliberate sections:

```
+--------------------------------------------------------------------------+
|  [Logo] MacVoice              Features   Privacy   Compare   FAQ   [Download DMG]
+--------------------------------------------------------------------------+
|  SECTION 1: HERO                                                         |
|  • Badge: "Apple Silicon Native · 784 KB · 100% On-Device"                |
|  • Headline: "Speak. Type. Done."                                        |
|  • Subheadline: Live voice typing for VS Code, Slack, and every Mac app.  |
|  • Primary CTA: [Download for Mac (Free DMG — 784 KB)]                   |
|  • Video / Looping Demo: Typing into VS Code & Slack with zero lag        |
+--------------------------------------------------------------------------+
|  SECTION 2: PROOF BAR / METRICS                                          |
|  • 784 KB Bundle   |   ~60 MB RAM   |   < 150 ms Latency   |   $0 Cloud   |
+--------------------------------------------------------------------------+
|  SECTION 3: THE 3 CORE PILLARS                                           |
|  1. Sub-150ms Live Streaming      2. Instant Native Polish               |
|  3. Chat-Aware Safety (Shift+Enter in Slack/WhatsApp)                    |
+--------------------------------------------------------------------------+
|  SECTION 4: THE DILEMMA (WHY NOT WISPR FLOW OR APPLE DICTATION?)          |
|  • Interactive comparison matrix: MacVoice vs Apple vs Wispr vs Superwhisper |
+--------------------------------------------------------------------------+
|  SECTION 5: PRIVACY & AIR-GAP GUARANTEE                                  |
|  • In-Memory Audio   |   Zero Cloud Sockets   |   Zero Telemetry          |
+--------------------------------------------------------------------------+
|  SECTION 6: 3-STEP ONBOARDING WALKTHROUGH                                |
|  • 1. Drag to Applications   2. Grant Permissions   3. Press ⌃⌥Space     |
+--------------------------------------------------------------------------+
|  SECTION 7: FREQUENTLY ASKED QUESTIONS (FAQ)                             |
|  • Clear, honest technical answers addressing objections                 |
+--------------------------------------------------------------------------+
|  SECTION 8: FINAL CALL TO ACTION & FOOTER                                |
|  • [Download MacVoice.dmg] · macOS 26+ · Open Source / Indie Made        |
+--------------------------------------------------------------------------+
```

---

## 3. Complete Section-by-Section Copywriting

### Section 1: Hero Section

* **Pill Badge:**
  `⚡ Built for macOS 26+ · 100% Apple Silicon Native · Pure Swift`
* **H1 Primary Headline:**
  **Speak. Type. Done.**
* **Sub-headline:**
  *The ultra-lightweight, on-device voice typing utility for Mac power users. Types live at your cursor across VS Code, Slack, Obsidian, and every native Mac app. Instant filler removal. Zero cloud servers. No accounts required.*
* **Primary Button:**
  `Download MacVoice for macOS (Free DMG — 784 KB)`
* **Secondary Button:**
  `View Source on GitHub`
* **Micro-Copy Beneath CTA:**
  *Requires macOS 26 or later on Apple Silicon. Downloads in < 1 second.*
* **Hero Visual Demonstration:**
  An auto-playing, crisp MP4/WebM loop showing a split-screen:
  * Left: User speaking naturally (*"hey team um we need to refactor the database schema new line bullet point run migrations"*).
  * Right: MacVoice typing directly into VS Code and Slack, automatically stripping *"um"*, inserting line breaks without triggering message send, and formatting clean bullet points.

---

### Section 2: Metric Proof Bar

Four clean metric cards highlighting technical superiority:
* **784 KB** — Entire DMG package size. Smaller than a screenshot.
* **~60 MB** — Active resident RAM. Zero battery or thermal drain.
* **< 150 ms** — Live word streaming directly to cursor.
* **0 Bytes** — Cloud audio exfiltration. 100% local in-memory processing.

---

### Section 3: The Three Core Value Pillars

#### Pillar 1: Sub-150ms Live Cursor Streaming
* **Header:** *Speak at 150 WPM. Watch text appear in real time.*
* **Body:** *Most local speech tools force you into an awkward batch loop: you record, press stop, wait 4 seconds for an AI model to think, and paste. MacVoice types words progressively into your active text field the moment you utter them.*

#### Pillar 2: In-Process Swift Polisher (< 0.1 ms Latency)
* **Header:** *No more "um", "uh", or awkward stutters in your docs.*
* **Body:** *Apple's built-in dictation writes down every vocal hesitation and throat-clearing sound. MacVoice’s native Swift polisher strips fillers, fixes unpunctuated contractions ("dont" $\to$ "don't"), and normalizes punctuation spacing in less than 0.1 milliseconds with zero extra RAM.*

#### Pillar 3: Universal & Chat-Safe
* **Header:** *Types everywhere. Never accidentally sends your Slack message.*
* **Body:** *Saying "new line" in Slack, WhatsApp, or Discord usually sends an unfinished message to your team. MacVoice detects your active window and automatically sends `Shift + Return` in messaging apps, keeping your conversations safe.*

---

### Section 4: The Comparison Table

| Feature | MacVoice | Apple Dictation | Wispr Flow | Superwhisper |
| :--- | :---: | :---: | :---: | :---: |
| **Download Size** | **784 KB** | Built-in | ~80 MB | 1.5 GB+ |
| **RAM Footprint** | **~60 MB** | System daemon | ~180 MB | 500 MB – 1.8 GB |
| **Speed / Latency** | **< 150 ms Live** | ~200 ms Live | ~1.0 s Cloud | 2.5 s Batch Wait |
| **Filler Stripping (um/uh)** | **Instant** | ❌ None | Cloud LLM | Local LLM |
| **Slack / Chat Safety** | **✅ Shift+Enter** | ❌ Sends message | ❌ Sends message | ❌ Sends message |
| **Audio Privacy** | **100% On-Device** | Local / Apple Cloud | Cloud Exfiltration | 100% On-Device |
| **Price** | **Free** | Free | $144 / year | $250 Lifetime |

---

### Section 5: The Privacy & Security Guarantee

* **Header:** *What happens on your Mac, stays on your Mac.*
* **Grid of 4 Guarantees:**
  1. **Zero Cloud Sockets:** MacVoice contains no external networking libraries. Your voice never touches the internet.
  2. **In-Memory Audio Processing:** Audio frames are held in temporary RAM buffers and released immediately after transcription. No audio files are ever written to your disk or `/tmp`.
  3. **Zero History / Logging:** We don't save what you say. Once characters are typed to your cursor, MacVoice retains no record.
  4. **Zero Telemetry or Analytics:** No Google Analytics, no tracking SDKs, no user accounts, and no identifiers. Complete peace of mind for software engineers, lawyers, and healthcare professionals.

---

### Section 6: Three-Step Setup Guide

* **Step 1: Download & Install (3 seconds)**
  * Download `MacVoice.dmg`, open it, and drag MacVoice to your `/Applications` folder.
* **Step 2: Grant Permissions (10 seconds)**
  * Open MacVoice from Applications. Allow Microphone access (so it can hear speech) and Accessibility access (so it can type keystrokes into other apps).
* **Step 3: Press `⌃⌥Space` and Speak**
  * Click any text box in VS Code, Slack, or Safari. Press `Control + Option + Space` and start talking. Text streams live to your cursor!

---

### Section 7: Frequently Asked Questions (FAQ)

**Q: How is MacVoice different from Apple's built-in dictation?**  
*A: Apple Dictation types out all your vocal fillers ("um", "uh", stutters), opens an intrusive floating microphone bubble that blocks your screen, and frequently breaks inside VS Code and terminals. Saying "new line" in Slack also accidentally sends your message. MacVoice fixes all of these: it strips fillers instantly, has no floating clutter, works in every app, and intelligently sends Shift+Return in chat apps.*

**Q: Why is the download only 784 KB? Are there hidden downloads?**  
*A: Unlike tools that bundle Python runtimes, Electron, or gigabytes of Whisper models, MacVoice is written in pure native Swift and utilizes Apple's high-performance SpeechTranscriber APIs built directly into macOS. The binary is compact, blistering fast, and uses almost no RAM.*

**Q: Does MacVoice send my voice or text to any server?**  
*A: Absolutely not. MacVoice operates 100% on-device in memory. It makes zero outbound network connections during voice typing. Your private code, emails, and notes never leave your computer.*

**Q: Which macOS versions and Macs are supported?**  
*A: MacVoice requires macOS 26.0 or later running on Apple Silicon (M1, M2, M3, M4 Macs). It leverages Apple's modern SpeechAnalyzer and Neural Engine frameworks available in macOS 26.*

**Q: Can I change the keyboard shortcut?**  
*A: Yes! Open MacVoice Settings from the menu bar, navigate to the "Shortcut" tab, and record any key combination you prefer.*

---

## 4. Download Friction Reduction & Conversion Best Practices

To guarantee maximum conversion from site traffic to active users:

1. **Direct DMG Download (Zero Form Gates):**
   * Do NOT ask for an email address.
   * Do NOT ask for a GitHub login or OAuth.
   * The primary hero button triggers the direct download of `MacVoice.dmg` immediately.
2. **Post-Download Guidance Page / Modal:**
   * The moment the download begins, display an elegant 2-step visual modal:
     1. *"Open the downloaded MacVoice.dmg and drag MacVoice into your Applications folder."*
     2. *"Press `⌃⌥Space` in any text box to begin."*
3. **Codesigning & Gatekeeper Compliance:**
   * Sign the DMG using a valid Apple Developer ID Certificate and notarize via Apple's `notarytool` so users never see macOS Gatekeeper warning dialogs (*"Apple cannot check it for malicious software"*).

