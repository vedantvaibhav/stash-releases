# Stash (Mark 1) — Claude Code Instructions

_Last updated: 20 Apr 2026_

## Project

- macOS menu-bar app: clipboard history, notes, meeting transcription, file shelf
- Swift + SwiftUI + AppKit hybrid
- SPM: Sparkle only
- Supabase auth (Google OAuth PKCE)
- OpenAI Whisper + GPT-4o for transcription

## Session rules

- Always restate the task and list files to be touched BEFORE planning or writing.
- Use `/write-plan` for anything touching >1 file. Push plan score to 8.5+ before `/execute-plan`.
- One dense context dump in the first message beats five thin ones.
- Don't ask to add SPM deps, modify Info.plist, entitlements, or Signing & Capabilities without explicit approval.
- Never force push, rebase shared branches, or rewrite history.
- Work on feature branches — not `main`.

## Swift / macOS conventions

- Deployment target: macOS 13+
- Prefer `@Observable` over `ObservableObject` for new view models.
- Prefer Swift Testing over XCTest.
- Prefer `async/await` over completion handlers.
- No force unwraps (`!`), force casts (`as!`), or `try!` in new code. Exceptions: `Bundle.main`, known-safe IBOutlets.
- No sprinkled `@MainActor` — explain isolation choice when adding it.
- Prefer SwiftUI over UIKit/AppKit bridging unless there is no SwiftUI native option.
- Run `xcodebuild -scheme Stash -configuration Debug` after changes. Run `swiftformat` + `swiftlint` before declaring done.

## File layout rules

- Secrets live only in `Secrets.plist` (gitignored) or `~/Library/Application Support/Stash/Secrets.plist`. Never hardcode keys.
- `SupabaseConfig.swift` anon key is public by design — safe to commit.
- Design tokens live in `DesignTokens.swift`. No hardcoded colors/sizes in components.
- Reusable icon CTA: `HeaderIconButton`. Do not duplicate.

## Things NOT to touch unless explicitly asked

- `GlobalHotKey.swift` registration logic
- `APIKeys.swift` resolution chain
- Sparkle appcast.xml or `SUFeedURL`
- Panel open/close animation timing
- Bundle ID or `CFBundleURLSchemes`

## Known landmines

- `FileDropZoneView` overlays use `isHidden` not `alphaValue` for hit-testing reasons. Do not swap.
- `NSHostingView.rootView` must be updated in `updateNSView` or SwiftUI bindings go stale.
- `onNoteCreated` callback is owned by `PanelController.setup()`. Do not override it from view-level `onAppear`.
- OAuth callback uses `AppDelegate.application(_:open:)` + `NSAppleEventManager`. Do not use `.onOpenURL` — unreliable for `LSUIElement` apps.

## Workflow

1. Restate task → list files → confirm scope
2. `/write-plan` for multi-file work
3. Sub-agent scores plan → push to 8.5+
4. `/execute-plan`
5. Run build, tests, format, lint
6. `/simplify` before PR
7. Conventional Commits format
8. Branch — never direct to main

## When stuck

- 5th attempt at a fix failing = stop. Explain root cause before writing more code.
- Confused session → check `git status` for stale changes
- Long session sluggish → `/compact` early
- Really stuck → restart clean
