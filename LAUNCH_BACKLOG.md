# Stash — Launch Backlog

_Last updated: 9 May 2026_

---

## 🚀 Launch 1 — Product (remaining)

- [ ] **Permissions onboarding screen** — single screen during onboarding that handles ALL system permissions in one place (microphone, accessibility for auto-paste, screen recording if added later, automation/Apple Events if needed). Currently we ask for mic mid-flow on first record, which is jarring. Design as a checklist: each permission has a row with status pill (granted / not granted) and a CTA to trigger the system prompt. Mic is required; Accessibility is strongly recommended (without it, every short-recording delivery falls to "Saved" instead of "Pasted ✓").
- [ ] **Onboarding step 2** — after login, route to onboarding screen before opening tray
- [ ] **Success page entrance animation** — subtle fade/slide-up on logo + text on `success.html`
- [ ] **Appcast / Sparkle setup** — sign DMG, add `sparkle:edSignature` + `length` to `appcast.xml`, verify `SUFeedURL`

## 🐛 Active bugs (low priority)

_None — all known bugs shipped or moved to Shipped below._

## 🎨 UI polish (post-functional)

- [ ] **Recent dictations section visual pass** — eyebrow typography, row density, hover wash tuning, copy-flash animation polish. Functionality is in; visual rhythm wants a designer pass.

---

## 📣 Launch 1 — Marketing

_To be filled in next session_

---

## 🔮 Launch 2

- [ ] **Latency: skip LLM cleanup for sub-5-second recordings** — short clips currently round-trip through Whisper AND the LLM cleanup pass (~1–2s extra). For clips under ~5s, paste raw Whisper output directly and skip the cleanup. Quality trade-off: no filler removal ("um", "you know") on short clips. Worth measuring user perception — short clips usually don't have filler anyway, and the latency win is significant for the "say a word, paste it" flow.
- [ ] **Repaste from a dictation entry** — re-deliver an old dictation as if it were just recorded (paste + clipboard refresh + maybe new history entry). Needs intent-capture architecture: at moment of repaste, capture frontmost app, switch focus back to it, paste. Non-trivial because the user is in Stash's UI when triggering the repaste.
- [ ] **Search across dictations** — text-content search over `DictationsStorage.entries`. Likely a header search field above the Recent dictations section, scoped to dictations only. Cheap with current dataset sizes (~MB-class JSON).
- [ ] **Pin / favorite dictations** — boolean flag on `DictationEntry` + sticky-top sort for pinned entries. Useful for templates / standing snippets.
- [ ] **Audio storage + playback for dictations** — keep the `.m4a` recording alongside the JSON entry, expose a play button on each row. Significant storage cost (~100KB–1MB per entry) so likely behind a setting toggle. Open question: how long to retain audio after the user has the cleaned text.
- [ ] **Dictations retention policy** — auto-prune entries older than N days / cap at M entries. Unbounded growth is fine at current scale (~2MB per 10k entries) but eventual hygiene matters.
- [ ] **Mix dictations into the All tab feed** — currently dictations only appear under Notes. Consider making them first-class artifacts in the All-tab aggregate list.

---

## ✅ Shipped

- [x] ~~Always-paste delivery (triple-redundant)~~ — short transcripts deliver through three channels on every recording: (1) system pasteboard, (2) `DictationsStorage` persistent history, (3) best-effort `AutoPasteService` direct paste. Pill confirms "Pasted ✓" or "Saved" honestly. Replaces the cursor-driven expand/collapse pill morph (~610 LOC removed).
- [x] ~~Dictations history under Notes~~ — collapsible "Recent dictations (N)" section above NotesListView. Always visible (even with zero entries) so the recovery surface is discoverable. Per-row tap-to-copy and right-click Delete.
- [x] ~~Recording start/stop sounds~~ — system Tink (start) + Pop (stop), embodied feedback for record state.
- [x] ~~Source-app capture at intent-time~~ — DictationEntry attributes the dictation to whatever was frontmost at startRecording, not stop. Survives focus shifts during the multi-second Whisper round-trip.
- [x] ~~Auto-paste service~~ — dual strategy (AX value write + CGEvent ⌘V), pasteboard preservation with token + changeCount guards, 5s timeout, concurrent-paste cancellation, in-app Permissions section in Settings.
- [x] ~~Recording error messages~~ — `userFacingMessage(for:)` maps URLError + AVFoundation throws to friendly banner strings; raw CFNetwork text no longer leaks
- [x] ~~`UserDefaults` key "onboardingCompleted"~~ — key already removed from codebase; entry retired
- [x] ~~Success page redesign~~ — Inter embedded, background full-bleed, correct copy, deep-link intact
- [x] ~~Slack error reporting~~ — all 6 transcription failure sites report to #stash-errors with user, device, OS, version
- [x] ~~Transcription URL filter over-rejection~~ — no longer drops transcripts containing .com/.io etc in speech
- [x] ~~Auth gate redesign~~ — PNG assets, Inter font, hover state, correct spacing
- [x] ~~Tray stays open on desktop file click~~ — NSWorkspace.didActivateApplicationNotification replaces all CGWindowList/AX approaches
- [x] ~~AirPods / external audio input~~ — dynamic sample rate via AVAudioEngine probe; guard on record() return value
- [x] ~~Tray drag/snap broken~~
- [x] ~~Transcript/Overview tabs alignment~~
- [x] ~~Under-5-min recording produces garbage~~ — hallucination filter
- [x] ~~Processing stuck at "Processing"~~ — defer + watchdog + shorter timeouts
- [x] ~~Auth logout → re-login failing~~ — server-side sign-out + prompt=select_account
- [x] ~~Settings window not active on open~~
- [x] ~~Floating pill redesign~~
- [x] ~~Double-tap hotkey recorder~~
- [x] ~~LLM prompt injection~~ — anti-content-generation guards on all three prompts
- [x] ~~Drag-to-snap broken~~ — snapDragMonitor lifetime fix
- [x] ~~Right-click menu cleanup~~ — icons removed, key equivalents removed
- [x] ~~Apple Developer account + notarization~~
- [x] ~~Final app icon~~
- [x] ~~Sparkle appcast + SUPublicEDKey~~
- [x] ~~Bundle ID consistency~~
