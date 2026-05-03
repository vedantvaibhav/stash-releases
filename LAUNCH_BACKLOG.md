# Stash — Launch Backlog

_Last updated: 4 May 2026_

## 🚀 Pending — product

- [ ] **Push `success.html` fix** — user count removed locally, not yet committed + pushed to GitHub Pages.
- [ ] **Onboarding step 2** — after login, route to onboarding screen before opening tray.

## ✅ Shipped

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

## 🐛 Active bugs (low priority)

- [ ] **Recording error messages** — raw API error text still surfaces occasionally. `TranscriptionService.swift`.
- [ ] **`UserDefaults` key "onboardingCompleted"** — stale key, clean up reads/writes.

## Post-launch

- [ ] Panel open/close animations
- [ ] Notes detail view redesign
- [ ] Meeting note tabs UI polish
- [ ] macOS notifications
- [ ] Crash reporter (Sentry)
- [ ] Trial + paywall
