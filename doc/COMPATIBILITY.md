# Destination compatibility status

CGEvent posting and target-app insertion are separate. `CGEvent.post()` has no
acknowledgement that a target accepted the Unicode payload. Do not treat a
`TypingReport` as proof of inserted text.

## Observed status

Environment available for this audit: macOS 26 / Apple Silicon. The manual
TextEdit attempt did not produce a valid readback: the scripted document could
not be retrieved after the run; an earlier attempt returned only `S`. This is
inconclusive and is not a passing result. No other destination was tested.

| Feature | TextEdit | Chrome textarea | Chrome input | Safari | VS Code | Terminal | Chat-style field |
|---|---|---|---|---|---|---|---|
| ASCII | Inconclusive | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Punctuation | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Unicode scripts | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Combining marks | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Emoji / ZWJ | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Spaces / tabs | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| LF / CR / CRLF | Inconclusive | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |
| Long text | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested | Not tested |

## VoiceTyping status

VoiceTyping has passed one user-reported English dictation smoke test in
TextEdit on macOS 26.6.2 / Apple Silicon. The user installed the system speech
assets, granted microphone access, started/stopped with Control+Option+Space,
and confirmed text was typed. This confirms one end-to-end path; other apps,
languages, punctuation, long sessions, and accuracy are not validated. The host
uses the current system locale and checks support at runtime; Hindi/Hinglish are
not marked verified.

## Reproducible manual harness

Focus the target field, choose a sample and newline policy, then run:

```sh
swift run TypingCoreDemo basic --delay=5
swift run TypingCoreDemo unicode --delay=5
swift run TypingCoreDemo combining --delay=5
swift run TypingCoreDemo emoji --delay=5
swift run TypingCoreDemo whitespace --newline=newline
swift run TypingCoreDemo newline --newline=enter
swift run TypingCoreDemo speech --delay=1
swift run TypingCoreDemo long --delay=0
swift run TypingCoreDemo stream --delay=5
swift run TypingCoreDemo cancel --delay=1
swift run TypingCoreDemo cancel-now --delay=1
```

For each app, compare its resulting text with the selected sample. Record OS/app
versions, exact output, whether focus changed, and whether a chat field submitted.
Never run the `.enter` or `.newline` policy in a live chat composer unless you
are prepared for it to submit. The `.newline` policy is only a Unicode-payload
attempt; it cannot promise newline insertion in an arbitrary app.
