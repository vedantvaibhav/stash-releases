# Stash — Codebase Architecture

> **Audience:** Any LLM (or human) opening this repo for the first time.
> **Purpose:** Understand what the app does, how it is structured, and which file owns which feature — before touching code.
> **See also:** `CLAUDE.md` for session rules, conventions, and landmines. This file answers _what exists and where_; `CLAUDE.md` answers _how to work on it_.

---

## 1. What Stash is

Stash is a **macOS menu-bar app** (`LSUIElement = true`, no Dock icon) that gives the user a single global-hotkey panel containing:

- Clipboard history (with pins)
- Notes (rich-text, RTF)
- File shelf (drag in, drag out, Quick Look)
- Meeting transcription (record → Whisper → cleaned notes)

Sign-in is required (Supabase + Google OAuth PKCE). Auto-updates via Sparkle. Two layout styles: single wide panel (default) and stacked expandable cards.

---

## 2. Tech stack

- **Language / UI:** Swift 5.9+, SwiftUI + AppKit hybrid
- **Deployment target:** macOS 13+
- **SPM dependencies:** Sparkle only
- **Auth:** Supabase REST + Auth API, called directly via `URLSession` (no external SDK). Google OAuth with PKCE.
- **Transcription + chat:** OpenAI-compatible API. Provider auto-detected from API-key prefix — `gsk_` → Groq, `sk-` / `sk-proj-` → OpenAI, `xai-` → xAI. Default host is Groq.
- **Persistence:** `UserDefaults` for settings + tokens; JSON files under `~/Library/Application Support/Stash/` for notes and file shelf.
- **Global hotkey:** Carbon `RegisterEventHotKey`.
- **Window:** `NSPanel` subclass (`KeyablePanel`) hosting SwiftUI via `NSHostingView`.

---

## 3. Entry points

- **`@main`** is `QuickPanelApp` in `StashApp.swift`. It declares only a `Settings { SettingsView() }` scene (menu-bar-only app — no `WindowGroup`). Real lifecycle lives in `AppDelegate` in the same file.
- **`AppDelegate`** sets up:
  1. URL-scheme handler (for OAuth callback) — registered in `applicationWillFinishLaunching` so pending `quickpanel://` / `stash://` events are delivered correctly.
  2. Single-instance guard — terminates if another copy is already running.
  3. Status item (menu-bar icon) — left-click toggles panel, right-click opens a context menu.
  4. Global hotkeys — main panel toggle (default ⌘⇧Space) and quick-record (⌘⇧R).
  5. `PanelController` — the panel window.
  6. Session restore via `AuthService.shared.checkSession()`; then either open the panel or run onboarding.

**User interactions reach the app through:**

| Trigger | Path |
|---|---|
| Menu-bar click (left) | `AppDelegate.statusItemClicked` → `PanelController.togglePanel()` |
| Menu-bar click (right) | `AppDelegate.showStatusMenu` (Open/Close, Check for Updates, Settings…, Quit) |
| Main hotkey | `GlobalHotKey` callback → `PanelController.togglePanel()` |
| Quick-record hotkey | `GlobalHotKey` callback → `TranscriptionService.startRecording/stopRecording` (panel stays hidden; floating pill appears) |
| OAuth deep link | `AppDelegate.application(_:open:)` **and** `NSAppleEventManager` handler → `AuthService.handleOAuthCallback(url:)` |

---

## 4. Feature map

| Feature | Primary file(s) |
|---|---|
| App lifecycle, status item, hotkey registration, URL scheme | `StashApp.swift` |
| Panel window (show/hide, snap zones, drag, idle auto-hide, key handling) | `PanelController.swift` |
| Alternate layout — stacked expandable floating cards | `CardsModeAppKit.swift` |
| Tab bar (All / Clipboard / Notes / Files / Transcribe) | `TabBarView.swift` |
| Shared column UIs reused across panel + cards | `PanelSharedSections.swift` |
| Clipboard history (polling, pin, paste) | `ClipboardManager.swift` |
| Notes model + storage | `NotesStorage.swift` |
| Notes rich-text editor (RTF) | `NotesEditorView.swift` |
| File shelf — drop, drag-out, grid, selection, hover | `FileDropStorage.swift`, `FileDropZoneView.swift` |
| File Quick Look (spacebar preview, arrow nav) | `FileQuickLookController.swift` |
| Meeting transcription — record + pipeline | `TranscriptionService.swift` |
| Floating transcription pill (Recording / Processing / Copied) | `TranscriptionFloatingWidget.swift` |
| Auth (Supabase + Google OAuth PKCE, session restore) | `AuthService.swift`, `AppUser.swift`, `SupabaseConfig.swift` |
| First-run onboarding (5 slides) | `Onboarding.swift` |
| Settings window (hotkey recorder, layout, auto-hide, clear data) | `SettingsView.swift`, `AppSettings.swift` |
| Global hotkey registration (Carbon) | `GlobalHotKey.swift` |
| Sparkle auto-updates | `UpdaterManager.swift`, `appcast.xml` |
| API-key resolution + provider detection | `APIKeys.swift`, `APIConstants.swift` |
| Design tokens (colors, sizes, typography) | `DesignTokens.swift` |
| Reusable icon CTA buttons | `HeaderIconButton.swift` |

---

## 5. File-by-file reference

_Alphabetical. All Swift files live under `Stash/`._

- **`APIConstants.swift`** — Picks transcription / chat base URLs, model names, and a provider label by sniffing the API-key prefix. No networking; pure derivation.
- **`APIKeys.swift`** — Key resolution chain: env var → embedded `Secrets.plist` → `~/Library/Application Support/Stash/Secrets.plist`. Resolves three keys (inference, transcription, OAuth). **Do not modify the chain without approval** — see `CLAUDE.md`.
- **`AppSettings.swift`** — `ObservableObject` singleton; persists layout style, main hotkey, quick-record hotkey, auto-hide timer, panel dimensions, launch-at-login. Posts `Notification.Name` events (`quickPanelHotkeyChanged`, `quickPanelClearClipboard`, etc.).
- **`AppUser.swift`** — `Codable` user model; mirrors the `users` table in Supabase.
- **`AuthService.swift`** — `@MainActor` singleton (`AuthService.shared`). Google OAuth PKCE, Supabase sign-in/out, session restore, token storage in `UserDefaults` under `sb.accessToken` / `sb.refreshToken`, user upsert on first sign-in. Guards against duplicate callback delivery.
- **`CardsModeAppKit.swift`** — AppKit-native expandable-cards layout. `PanelInteractionState` is shared UI state (editor sheet, delete alerts). `CardsExpansionCoordinator` enforces "one card open at a time" with sequential collapse → expand. `ExpandableCardView` + `CardsModeContainerView` host SwiftUI content via `NSHostingView`.
- **`ClipboardManager.swift`** — Polls `NSPasteboard.general.changeCount`; emits `ClipboardEntry` history; supports pin/unpin; paste helper.
- **`DesignTokens.swift`** — App-wide colors, sizes, paddings, `Color(hex:)` helper. No hardcoded colors or sizes anywhere else.
- **`FileDropStorage.swift`** — Persistence + model (`DroppedFileItem`) for the file shelf. Copies user drops into Application Support; exposes paste-from-pasteboard.
- **`FileDropZoneView.swift`** — Biggest file (~1,200 lines). Contains: SwiftUI grid (`FileDropListContent`), AppKit draggable card view (`DraggableFileView`), drop container (`FileDropContainerView`), hover/selection state, QuickLook thumbnails, and the `NSViewRepresentable` bridges.
- **`FileQuickLookController.swift`** — `QLPreviewPanel` data source + delegate. Spacebar toggle, arrow-key navigation, focus clears on panel tab switch or outside-grid click.
- **`GlobalHotKey.swift`** — Thin wrapper over Carbon `RegisterEventHotKey`. Four-char signature distinguishes each hotkey (`'QPHK'` for panel, `'QPRK'` for quick-record). **Do not modify registration logic without approval.**
- **`HeaderIconButton.swift`** — Reusable icon + CTA button. Do not duplicate; reuse this.
- **`Info.plist`** — Bundle config. `LSUIElement = true`, URL scheme, Sparkle `SUPublicEDKey`, `SUFeedURL`.
- **`NotesEditorView.swift`** — `NSTextView` + RTF single-note editor with a compact formatting bar.
- **`NotesStorage.swift`** — `ObservableObject`. `NoteItem` model (id, content, timestamps, origin) with `NoteOrigin` distinguishing manual vs from-transcription notes. RTF round-trip.
- **`Onboarding.swift`** — First-run flow: Welcome → Hotkey → Microphone → Launch at Login → Google Sign In. Managed by `OnboardingManager.shared.showIfNeeded`. `OnboardingHotkeyRecorder` mirrors the one in `SettingsView`.
- **`PanelController.swift`** — Core (~1,250 lines). Owns `KeyablePanel` (NSPanel subclass that can become key so text fields work), `PanelSnapZone` enum, `PanelMouseTrackingView`, drag tracking, auto-hide idle timer, and the `NSHostingView` wrapping `QuickPanelRootView`. Wires together clipboard, notes, files, transcription, and auth gate. The `onNoteCreated` callback is owned here — do not override it elsewhere.
- **`PanelSharedSections.swift`** — Reusable column views consumed by both panel and cards layouts: clipboard column, pinned cards, notes column + list, files column, transcription page, "All" tab combined view. Also shared visual tokens (`PanelSectionHeaderStyle`, etc.).
- **`Secrets.example.plist`** — Template for the gitignored `Secrets.plist`. Lists expected key names only — no real values.
- **`SettingsView.swift`** — SwiftUI Settings content (layout picker, hotkey recorder, auto-hide, clear data actions, sign-out). `SettingsWindowController` hosts it in a standalone window for the right-click menu path.
- **`StashApp.swift`** — `@main` (`QuickPanelApp`) + `AppDelegate`. URL-scheme handler, single-instance guard, status item, hotkey registration, `PanelController` ownership, onboarding/panel gate on launch.
- **`SupabaseConfig.swift`** — Project URL + anon key constants. Anon key is public by design — safe to commit.
- **`TabBarView.swift`** — `PanelMainTab` enum (All / Clipboard / Notes / Files / Transcribe) + horizontal tab bar view.
- **`TranscriptionFloatingWidget.swift`** — Standalone borderless floating pill window. Three states (`PillMode`: recording / processing / copied). Draggable, snaps to tray zones on drag end. Independent of the main panel.
- **`TranscriptionService.swift`** — `@MainActor`. Audio capture via `AVAudioRecorder`, duration / level timers, Whisper transcription call, chat cleanup step. Short-vs-long branching: recordings under ~5 min get a fast clean via `chatModelForShortClean`; longer recordings get full meeting-note structuring via `chatModel`. Exposes `@Published` state consumed by the pill and banner.
- **`UpdaterManager.swift`** — Sparkle `SPUStandardUpdaterController` wrapper. `checkForUpdates()` for the menu item.

---

## 6. Runtime flows (what calls what)

**App launch**

```
QuickPanelApp (@main)
  → AppDelegate.applicationWillFinishLaunching
      • Register NSAppleEventManager URL handler (OAuth callback)
      • Single-instance guard
  → AppDelegate.applicationDidFinishLaunching
      • setActivationPolicy(.accessory)
      • APIKeys.validateKeys()
      • setupStatusItem()
      • PanelController()
      • registerHotkeyFromSettings()
      • Task { await AuthService.shared.checkSession() }
        ├─ signed in + onboardingCompleted → PanelController.setup()
        └─ else → OnboardingManager.shared.showIfNeeded { panelController.setup() }
```

**Panel toggle (hotkey or status-item click)**

```
GlobalHotKey / NSStatusItem.button.action
  → AppDelegate → PanelController.togglePanel()
  → KeyablePanel.orderFront / orderOut
  → NSHostingView.rootView rebuild (debounced)
```

**Quick record (⌘⇧R) — panel stays hidden**

```
GlobalHotKey 'QPRK' callback
  ├─ ts.isRecording  → TranscriptionService.stopRecording()
  └─ not recording:
      ├─ !AuthService.shared.isSignedIn → PanelController.showPanel() (auth gate)
      └─ signed in → TranscriptionService.startRecording()
                      → floating pill appears (TranscriptionFloatingWidget)
```

**OAuth callback**

```
System browser → quickpanel://auth/callback?code=...
  ├─ AppDelegate.application(_:open:)           (app already running, foreground)
  └─ NSAppleEventManager handleURL handler       (app launched by the URL)
      → AuthService.handleOAuthCallback(url:)
        • exchanges PKCE code
        • fetches Supabase user
        • upserts app user row
        • isSignedIn = true (SwiftUI refreshes)
```

**Transcription pipeline**

```
TranscriptionService.startRecording
  → AVAudioRecorder → .m4a file on disk
  → duration / level timers drive pill UI
  → stopRecording → processRecording
  → POST {transcriptionBaseURL}/audio/transcriptions   (Whisper; model per key prefix)
  → short-vs-long branch (lastRecordingWasShort):
      ├─ short (< 5 min):
      │   POST {inferenceBaseURL}/chat/completions   (chatModelForShortClean — fast)
      │   → NotesStorage.addNote(origin: .transcription)
      │   → onNoteCreated callback: show list with new note pinned at top
      └─ long:
          POST {inferenceBaseURL}/chat/completions   (chatModel — full meeting notes)
          → NotesStorage.addNote(origin: .transcription)
          → onNoteCreated callback: auto-open the editor
```

**File drop + Quick Look**

```
FileDropContainerView receives NSDraggingInfo
  → FileDropStorage.addFiles(urls:)              (copies to Application Support)
  → @Published array updates → grid rebuilds
  → spacebar on focused file
      → FileQuickLookController.togglePreview
      → QLPreviewPanel shared instance data-source = controller
```

---

## 7. Secrets and config

- **`SupabaseConfig.swift`** — `supabaseURL`, `supabaseAnonKey`. Anon key is public by design; committed.
- **`APIKeys.swift`** — resolution chain for three keys (inference, transcription, OAuth client):
  1. Environment variable (debug / CI)
  2. Bundled `Secrets.plist` (gitignored in-repo copy for local dev)
  3. `~/Library/Application Support/Stash/Secrets.plist` (shipped-app override)
- **`Secrets.example.plist`** — documents the expected key names; copy to `Secrets.plist` and fill in.
- **Never hardcode real keys.** Real `Secrets.plist` is gitignored.
- **Sparkle signing key** — private key lives only in macOS Keychain (`Private key for signing Sparkle updates`). Public key is in `Info.plist` as `SUPublicEDKey`. Sign DMGs with the `sign_update` helper from the Sparkle SPM artifacts bundle.

---

## 8. Non-Swift files worth knowing

- **`CLAUDE.md`** — Session rules for LLMs: restate task, list files, use `/write-plan`, conventions, landmines, things not to touch. Read first.
- **`LAUNCH_BACKLOG.md`** — Pre-launch todo list.
- **`appcast.xml`** — Sparkle feed. `SUFeedURL` in `Info.plist` points here.
- **`Scripts/`** — One-off Swift scripts for generating app-icon and clipboard-icon PDFs. Not part of the built app target.
- **`docs/auth/success.html`** — The page the OAuth flow lands on in the browser before redirecting to `quickpanel://`.
- **`docs/superpowers/plans/`** — Implementation plans written for `/write-plan` / `/execute-plan` sessions. Historical and in-flight.
- **`Assets.xcassets`** — Icons (menu-bar template image, app icon) and any asset catalogs.

---

## 9. Notes for LLMs touching this code

- Read **`CLAUDE.md`** first for session rules and the full list of landmines.
- Feature branches only — never commit to `main`.
- **`PanelController.swift`** and **`FileDropZoneView.swift`** are the two largest files (~1,200 lines each). Scope your changes narrowly; do not refactor on the side.
- **`NSHostingView.rootView` must be updated in `updateNSView`** or SwiftUI bindings go stale.
- **`.onOpenURL` is unreliable for `LSUIElement` apps** — OAuth uses `AppDelegate.application(_:open:)` + `NSAppleEventManager`. Do not switch to `.onOpenURL`.
- **`FileDropZoneView` overlays use `isHidden`, not `alphaValue`** — for hit-testing reasons. Do not swap.
- **`onNoteCreated`** is owned by `PanelController.setup()`. Do not override from view-level `onAppear`.
- **Do not modify without explicit approval:** `GlobalHotKey.swift` registration logic, `APIKeys.swift` resolution chain, `appcast.xml` / `SUFeedURL`, panel open/close animation timing, bundle ID / `CFBundleURLSchemes`, `Info.plist`, entitlements, Signing & Capabilities, or SPM dependencies.
