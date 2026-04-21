import AppKit
import SwiftUI

/// Small URL entry popover. `.onSubmit` handles Enter; Escape dismissal is
/// wired via a local `NSEvent` key-down monitor installed by the controller
/// when the popover shows (see `presentLinkPopover`) — attempting to handle
/// Escape inside the SwiftUI hierarchy fails because `NSTextField` holds
/// first responder inside the popover window, so the child NSView never sees
/// the key event.
struct NotesLinkPopover: View {
    @State private var url: String = ""
    let initialURL: String?
    let onApply: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .foregroundStyle(DesignTokens.Icon.tintMuted)
            TextField("https://example.com", text: $url)
                .textFieldStyle(.plain)
                .font(DesignTokens.Typography.bodyFont)
                .frame(width: 260)
                .onSubmit { submit() }
        }
        .padding(10)
        .onAppear {
            url = initialURL ?? ""
        }
    }

    private func submit() {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onApply(trimmed)
    }
}
