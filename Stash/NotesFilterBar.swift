import AppKit
import SwiftUI

/// Sticky filter bar that sits above the notes list in the Notes tab.
///
/// Layout (LTR):
///   "<displayName>  <count>" ............ <filterIcon> <F-badge>
///
/// The filter icon swaps to its `.fill` SF Symbol variant when a non-`.all`
/// filter is active — this is the active-state visual indicator. Tapping
/// the icon or the F-badge opens the popover; pressing the `F` key is wired
/// in a follow-up task.
struct NotesFilterBar: View {
    @Binding var activeFilter: NotesFilter
    /// Map of every filter case → matching-note count. Caller computes
    /// this from `notesStorage.notes` and passes it in so we don't
    /// re-iterate the array per filter row.
    let counts: [NotesFilter: Int]
    let pendingCount: Int
    let onRetryAllTap: () -> Void

    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                // Left: active filter title + count — both in the shared 14pt
                // tab-label font so the filter bar matches the tab row typography.
                HStack(spacing: 4) {
                    Text(activeFilter.displayName)
                        .font(DesignTokens.Typography.tabLabelFont)
                        .foregroundStyle(DesignTokens.Typography.sectionColor)
                        .lineLimit(1)
                    Text("(\(counts[activeFilter, default: 0]))")
                        .font(DesignTokens.Typography.tabLabelFont)
                        .foregroundStyle(DesignTokens.Typography.itemColor.opacity(0.55))
                        .lineLimit(1)
                        .layoutPriority(0)

                    // Inline "Waiting" shimmer replaces the old separate
                    // "N waiting" badge. Tap reruns userRequestedDrain.
                    if pendingCount > 0 {
                        Text("Waiting")
                            .font(DesignTokens.Typography.tabLabelFont)
                            .foregroundStyle(DesignTokens.Typography.itemColor.opacity(0.55))
                            .lineLimit(1)
                            .shimmer()
                            .padding(.leading, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { onRetryAllTap() }
                            .help("Tap to retry pending uploads")
                    }
                }
                .layoutPriority(1)
                .animation(.easeInOut(duration: 0.08), value: activeFilter)

                Spacer(minLength: 8)

                // Native macOS dropdown. An inline Picker inside a Menu
                // renders the filter options as standard menu items with an
                // automatic checkmark on the active one. Clicking the pill
                // opens it; the F key (NSEvent monitor below) still cycles.
                Menu {
                    Picker("Filter", selection: $activeFilter) {
                        ForEach(NotesFilter.allCases) { filter in
                            Text("\(filter.displayName) (\(counts[filter, default: 0]))")
                                .tag(filter)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    FilterPill(isActive: activeFilter != .all)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 9) // bar content height ≈ 40pt with 22pt content
            .frame(minHeight: 40)

            // Edge-to-edge hairline divider. Lives outside the padded HStack so its
            // width tracks the parent column, not the HStack's content inset.
            Rectangle()
                .fill(DesignTokens.Icon.tintMuted.opacity(0.18))
                .frame(maxWidth: .infinity)
                .frame(height: 1)
                // Bleed past the panel's 20pt outer padding so the divider
                // spans the full panel width edge-to-edge.
                .padding(.horizontal, -20)
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private func installKeyMonitor() {
        // Idempotent — `.onAppear` can fire after a re-entry.
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard self.shouldHandleFKey(event: event) else { return event }
            // F cycles the filter directly — does NOT open the popover.
            // Click the pill (separate gesture handler) to open the popover.
            self.activeFilter = self.activeFilter.next()
            return nil   // swallow the keystroke
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Returns true ONLY if this `keyDown` is a bare `F` press (no modifiers)
    /// AND no text field is first responder. Layout-independent — uses
    /// `charactersIgnoringModifiers` rather than `keyCode`.
    private func shouldHandleFKey(event: NSEvent) -> Bool {
        let disallowed: NSEvent.ModifierFlags = [.command, .option, .control]
        if !event.modifierFlags.intersection(disallowed).isEmpty {
            return false
        }
        guard event.charactersIgnoringModifiers?.lowercased() == "f" else {
            return false
        }
        if let responder = NSApp.keyWindow?.firstResponder, responder is NSText {
            return false
        }
        return true
    }
}

// MARK: - Combined filter pill (icon + "F" letter)

/// Rounded-rect chip containing the filter icon and the "F" key letter, side
/// by side. Used as the label of the parent's `Menu`, so the click-to-open
/// behaviour is owned by SwiftUI's native menu — this view is pure visual.
/// Pressing F cycles the filter (wired by the parent's NSEvent monitor).
/// Background tints when `isActive` is true so the bar reads as "filter
/// applied" at a glance.
private struct FilterPill: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foregroundColor)

            Text("F")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundFill)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .animation(.easeInOut(duration: 0.12), value: isActive)
    }

    private var foregroundColor: Color {
        if isActive { return DesignTokens.FilterPill.activeForeground }
        return DesignTokens.Icon.tintMuted.opacity(0.85)
    }

    private var backgroundFill: Color {
        // Rest fill matches the pinned-card gray (PanelCardChromeStyle.bgDefault,
        // #262626) so the pill reads as a solid chip. Hover is handled by the
        // enclosing Menu's native highlight.
        isActive ? DesignTokens.FilterPill.activeBackground : PanelCardChromeStyle.bgDefault
    }
}
