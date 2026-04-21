# Stash — Launch Backlog

_Last updated: 20 Apr 2026_

## Deferred

- [ ] **Buy `getstash.app` domain (~$15/yr, namecheap)** — swap OAuth redirect from GitHub Pages to custom domain. One-line change in `AuthService.swift` + Supabase dashboard redirect URL.
- [ ] **UI polish — auth gate (sign-in screen)** — needs better visual treatment. Current is functional but bare. Design pass + Figma.
- [ ] **UI polish — OAuth success landing page** — `docs/auth/success.html` is minimal text. Add logo, polish typography, better "return to Stash" copy.
- [ ] **Custom domain landing page** — Framer site with hero, features, download DMG, waitlist capture.
- [x] ~~**Notes tab row tap-while-hover bug**~~ — resolved
- [ ] **Onboarding flow simplification** — remove unnecessary steps. Needs walk-through of current flow.
- [x] ~~**Files Quick Look (spacebar preview)**~~ — resolved
- [ ] **Panel open/close animations** — currently instant. Add subtle spring/fade.
- [ ] **Settings UI modernization** — needs Figma or design pass.
- [ ] **Floating transcription widget pill redesign** — three states (Recording / Processing / Copied). Figma: https://www.figma.com/design/ZPMewp00IZp9xGYeUjupbi/M1?node-id=280-981&m=dev
- [ ] **Row component unification** — Clipboard / Pinned / Notes share one row. In flight.
- [ ] **Notes detail view redesign** — inside-a-note reading/writing experience.
- [ ] **Meeting note tabs UI polish** — Overview / Transcript tab picker styling, tab transitions, selected-state visual, spacing. Currently functional but basic.
- [ ] **In-app activation tips** — Day 1/3/7 nudges after first use.
- [ ] **Email sequence** — 8 emails drafted, need Loops.so or Resend setup.
- [ ] **Trial + paywall** — Day 30 gate via RevenueCat + Stripe.
- [ ] **Referral link per user**.
- [ ] **macOS notifications** — 2 types agreed: copy milestone + meeting-soon prompt.
- [ ] **Crash reporter (Sentry free tier)**.

## Must-do before launch

- [ ] Apple Developer account ($99) + notarization
- [ ] Final app icon (1024x1024) + all sizes
- [ ] Sparkle appcast live on GitHub Pages + `SUFeedURL` wired + `SUPublicEDKey` committed
- [ ] Bundle ID consistent across Info.plist, entitlements, Supabase redirect URLs
- [ ] LinkedIn posts 1–4 scheduled
- [ ] 60-second demo video recorded
- [ ] Feedback form live on Tally.so
