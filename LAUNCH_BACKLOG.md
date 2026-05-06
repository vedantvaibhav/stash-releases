# Stash — Launch Backlog

_Last updated: 6 May 2026_

---

## 🚀 Launch 1 — Product (remaining)

- [ ] **Onboarding step 2** — after login, route to onboarding screen before opening tray
- [ ] **Success page entrance animation** — subtle fade/slide-up on logo + text on `success.html`
- [ ] **Appcast / Sparkle setup** — sign DMG, add `sparkle:edSignature` + `length` to `appcast.xml`, verify `SUFeedURL`

## 🐛 Active bugs (low priority)

_None — all known bugs shipped or moved to Shipped below._

---

## 📣 Launch 1 — Marketing

_To be filled in next session_

---

## 🔮 Launch 2

_To be filled in next session_

---

## ✅ Shipped

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
