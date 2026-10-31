# MacVoice: Marketing, Launch Playbook & 30-Day Go-to-Market Plan

**Document Version:** 1.0.0  
**Research Date:** October 31, 2026  
**Auditor / Roles:** Product Marketing Strategist & Independent Software Growth Lead  
**Classification:** Go-to-Market Execution Roadmap  

---

## 1. Executive Launch Strategy

MacVoice has the ideal DNA for a viral grassroots developer launch:
* It solves an acute, everyday annoyance (typing fatigue, slow dictation, bad built-in tools).
* It has visceral technical bragging rights (784 KB download, 60 MB RAM, < 150 ms latency, zero cloud).
* It challenges an expensive, venture-backed incumbent (Wispr Flow, $180/year) with a free native solution.

Our strategy bypasses paid advertising entirely. Instead, we execute a **high-impact, multi-channel developer launch** across **Hacker News, Product Hunt, Reddit (`r/macapps`), Twitter/X, and Homebrew**.

---

## 2. Channel-by-Channel Execution Playbooks

### Channel 1: Hacker News ("Show HN")
Hacker News is the single highest-leverage platform for native developer tools. The HN community venerates small native binaries, despises Electron bloat, and respects privacy.

* **Title Format:**
  `Show HN: MacVoice – A 784 KB on-device voice typing utility in native Swift`
* **Maker First Comment Structure:**
  1. *The Origin:* "Hi HN, I built MacVoice because I loved the idea of voice typing in VS Code and Slack, but I hated paying $15/month for cloud tools that sent all my code and private audio to remote servers. Built-in Apple Dictation kept typing 'um', popping up floating bubbles, and breaking in my terminal."
  2. *The Architecture:* Explain the technical stack honestly:
     * Built in 100% native Swift 5.9+.
     * Total DMG size is 784 KB; active memory is ~60 MB.
     * Uses macOS 26 `SpeechTranscriber` running on Apple Silicon Neural Engine.
     * In-process native text polisher strips fillers (`um/uh`) and fixes contractions in < 0.1 ms with 0 MB extra RAM.
     * Uses CoreGraphics HID CGEvents; includes bundle introspection to automatically send `Shift + Return` in Slack and WhatsApp to prevent accidental message sending.
  3. *Privacy:* "Zero telemetry, zero analytics, zero external network sockets during typing. In-memory audio processing only."
  4. *The Ask:* "It’s completely free. Would love your feedback, bug reports, or edge cases!"

---

### Channel 2: Product Hunt (The Public Launch)
* **Launch Timing:** Tuesday or Wednesday at 12:01 AM PST.
* **Tagline:** *"Speak naturally. Live on-device voice typing for every Mac app."*
* **Primary Category:** Developer Tools / Productivity / Mac Apps.
* **Asset Checklist:**
  * App Icon: Clean 512x512 rounded squircle (from `Brand/Exports/macvoice-icon-light-1024.png`).
  * 30-Second Video: Screen recording demonstrating the 784 KB DMG download, double-clicking, granting permissions, and dictating seamlessly between VS Code and Slack.
  * 5 Gallery Slides (1270x760):
    1. Hero: Speak. Type. Done. (VS Code & Slack demo)
    2. Slide 2: 784 KB Download vs 1.5 GB Competitors.
    3. Slide 3: Never accidentally send a Slack message (Shift+Enter chat safety).
    4. Slide 4: 100% In-Memory Privacy. Zero Cloud Exfiltration.
    5. Slide 5: Native Menu Bar utility with customizable hotkeys.

---

### Channel 3: Reddit Community Strategy
Target subreddits with tailored messaging (never spam; provide authentic technical utility):

1. **`r/macapps` (450k+ Mac enthusiasts):**
   * *Angle:* "I built an ultra-lightweight (784 KB) native voice typing app in Swift to replace Apple's bloated dictation."
   * *Focus:* Native macOS feel, zero Electron, menu bar integration, fast startup, lightweight RAM.
2. **`r/productivity` (2.5M+ members):**
   * *Angle:* "How I write at 150 WPM across all my Mac apps without paying $180/year for Wispr Flow."
   * *Focus:* Speed of thought, writing Slack and emails by voice, saving time.
3. **`r/swift` & `r/programming`:**
   * *Angle:* "Building an append-only speech typing engine using macOS SpeechTranscriber and Quartz CGEvents in Swift."
   * *Focus:* Deep architectural lessons, async streams, dealing with Apple Speech progressive boundaries.

---

### Channel 4: Twitter / X (The Developer Virality Engine)
* **The Hook Tweet (Video Demo):**
  * Post a 20-second screen recording showing:
    1. A Terminal showing `ls -lh MacVoice.dmg` (784 KB).
    2. Pressing `⌃⌥Space` and speaking rapid code comments into VS Code with instant streaming.
    3. Switching to Slack, speaking *"new line"*, and showing it safely inserting a line break rather than sending the message.
  * *Copy:*
    > "Tired of cloud voice tools that cost $180/yr and spy on your audio?
    >
    > I built MacVoice:
    > ⚡ 784 KB download
    > ⚡ 60 MB RAM
    > ⚡ < 150 ms latency
    > ⚡ Automatic filler removal
    > ⚡ Chat-safe (Shift+Enter in Slack)
    > ⚡ 100% on-device & free
    >
    > Download DMG: macvoice.app"

---

### Channel 5: Homebrew Cask Distribution
Developers love installing macOS apps via terminal. Creating an official Homebrew Cask makes MacVoice an instant one-line install:

```bash
brew install --cask macvoice
```
* Deploy the cask to `homebrew/cask` repository or an official tap (`brew tap yourname/macvoice`).

---

## 3. Thirty-Day Go-to-Market Calendar

```
+-------------------------------------------------------------------------------+
| PHASE 1: PRE-LAUNCH POLISH (Days 1 - 7)                                       |
| • Day 1: Finalize Apple Developer ID Notarization and codesigning.            |
| • Day 3: Deploy official static website (macvoice.app) to Cloudflare Pages.   |
| • Day 5: Test release DMG on 5 clean Apple Silicon Macs (M1/M2/M3/M4).        |
| • Day 7: Prepare Product Hunt assets, demo video, and screenshots.           |
+-------------------------------------------------------------------------------+
| PHASE 2: SOFT LAUNCH & DEVELOPER VALIDATION (Days 8 - 14)                     |
| • Day 8: Publish GitHub repository with comprehensive README and release DMG. |
| • Day 10: Submit "Show HN: MacVoice" on Hacker News at 8:00 AM EST.           |
| • Day 11: Engage actively in HN comments; fix any immediate edge-case reports. |
| • Day 13: Submit Homebrew Cask formula for review.                            |
+-------------------------------------------------------------------------------+
| PHASE 3: THE PUBLIC LAUNCH (Days 15 - 21)                                     |
| • Day 15: Product Hunt Launch (12:01 AM PST). Post launch thread on X.        |
| • Day 16: Post dedicated walkthrough on Reddit r/macapps and r/productivity.  |
| • Day 18: Reach out to prominent Mac tech bloggers (John Gruber, 9to5Mac).   |
| • Day 21: Release v1.0.1 maintenance patch addressing top community requests. |
+-------------------------------------------------------------------------------+
| PHASE 4: MOMENTUM & COMMUNITY EXPANSION (Days 22 - 30)                        |
| • Day 23: Publish technical deep-dive blog post on Swift & CoreGraphics.      |
| • Day 26: Add "Support MacVoice Development" tip jar in Settings.             |
| • Day 30: Review 30-day analytics: total downloads, active retention, & KPIs. |
+-------------------------------------------------------------------------------+
```

---

## 4. Key Performance Indicators (KPIs) to Track

Because MacVoice has zero telemetry, privacy-preserving KPIs must be tracked at the distribution and community layers:

1. **Total DMG Downloads:** Tracked via Cloudflare / GitHub Releases asset download counters (Target: 15,000+ downloads in Month 1).
2. **Product Hunt Ranking:** Top 3 Product of the Day.
3. **Hacker News Engagement:** Front-page placement (> 150 points, 80+ constructive comments).
4. **GitHub Stars:** 1,000+ stars on repository.
5. **Community Retention & Feedback:** Low issue report rate (< 2% crash reports) and enthusiastic user word-of-mouth.

