# Stash — Launch Backlog

_Last updated: 6 May 2026_

---

## 🚀 Launch 1 — Product (remaining)

- [ ] **Auto-paste short transcripts to focused app (Option C)** — primary delivery mechanism for the short-recording handoff. After a short (<5 min) recording finishes, paste the cleaned transcript directly into the currently-focused text field of the user's active app. Fall back to the floating-pill morph (PR #20) only if no insertable text field is detected. Spec: `docs/superpowers/specs/2026-05-09-auto-paste-active-app-design.md`. **Replaces the morph as the launch-critical UX.** Morph stays as the fallback.
- [ ] **Permissions onboarding screen** — single screen during onboarding that handles ALL system permissions in one place (microphone, accessibility for auto-paste, screen recording if added later, automation/Apple Events if needed). Currently we ask for mic mid-flow on first record, which is jarring. Design as a checklist: each permission has a row with status pill (granted / not granted) and a CTA to trigger the system prompt. User can proceed only after required ones are granted (mic is required; accessibility is required if auto-paste ships in launch 1).
- [ ] **Onboarding step 2** — after login, route to onboarding screen before opening tray
- [ ] **Success page entrance animation** — subtle fade/slide-up on logo + text on `success.html`
- [ ] **Appcast / Sparkle setup** — sign DMG, add `sparkle:edSignature` + `length` to `appcast.xml`, verify `SUFeedURL`

## 🐛 Active bugs (low priority)

_None — all known bugs shipped or moved to Shipped below._

## 🎨 UI polish (post-functional)

- [ ] **Short-pill expanded form UI pass** — typography weight/spacing in the eyebrow, scrollbar styling, footer button visual rhythm, transcript-text padding. Functionality is in (#20); just the visual polish remains. Block: needs a designer/Figma pass before further code changes.

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
