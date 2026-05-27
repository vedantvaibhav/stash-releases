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

    @State private var isPopoverShown = false
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
                }
                .layoutPriority(1)
                .animation(.easeInOut(duration: 0.08), value: activeFilter)

                if pendingCount > 0 {
                    Button(action: onRetryAllTap) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .medium))
                            Text("\(pendingCount) waiting")
                                .font(.system(size: 12, weight: .regular))
                        }
                        .foregroundStyle(DesignTokens.Icon.tintMuted.opacity(0.75))
                        .padding(.leading, 6)
                    }
                    .buttonStyle(.plain)
                    .help("Tap to retry pending uploads")
                }

                Spacer(minLength: 8)

                FilterPill(isActive: activeFilter != .all)
                    .onTapGesture { isPopoverShown.toggle() }
                    .popover(isPresented: $isPopoverShown, arrowEdge: .top) {
                        NotesFilterPopoverContent(
                            activeFilter: $activeFilter,
                            counts: counts,
                            onPick: { picked in
                                activeFilter = picked
                                isPopoverShown = false
                            }
                        )
                    }
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

// MARK: - Popover content

private struct NotesFilterPopoverContent: View {
    @Binding var activeFilter: NotesFilter
    let counts: [NotesFilter: Int]
    let onPick: (NotesFilter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(NotesFilter.allCases) { filter in
                row(for: filter)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 220)
    }

    @ViewBuilder
    private func row(for filter: NotesFilter) -> some View {
        FilterRow(
            filter: filter,
            isActive: filter == activeFilter,
            count: counts[filter, default: 0],
            onTap: { onPick(filter) }
        )
    }
}

private struct FilterRow: View {
    let filter: NotesFilter
    let isActive: Bool
    let count: Int
    let onTap: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                ZStack {
                    if isActive {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(width: 14)

                Text("\(filter.displayName) (\(count))")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? PanelListRowHoverStyle.hoverFill : Color.clear)
                    .padding(.horizontal, 6)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(PanelListRowHoverStyle.animation, value: isHovering)
    }
}

// MARK: - Combined filter pill (icon + "F" letter)

/// Rounded-rect chip containing the filter icon and the "F" key letter, side
/// by side. Click opens the popover (wired by the parent); pressing F cycles
/// the filter (wired by the parent's NSEvent monitor). Background tints when
/// `isActive` is true so the bar reads as "filter applied" at a glance.
///
/// The parent uses `.onTapGesture` to open the popover. We attach a separate
/// `simultaneousGesture(TapGesture())` here purely to drive the scale press
/// feedback — without a `simultaneousGesture` the parent's tap would steal the
/// event before this view can observe it. The pill never owns the popover
/// state; it only renders.
private struct FilterPill: View {
    let isActive: Bool

    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.horizontal.3")
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
        .scaleEffect(isPressed ? 0.96 : 1.0)
        .onHover { isHovering = $0 }
        .simultaneousGesture(
            TapGesture().onEnded {
                // Tap feedback: scale down briefly then restore. Independent of
                // the parent's tap handler that opens the popover.
                withAnimation(.easeInOut(duration: 0.05)) { isPressed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeInOut(duration: 0.05)) { isPressed = false }
                }
            }
        )
        .animation(.easeInOut(duration: 0.12), value: isHovering)
        .animation(.easeInOut(duration: 0.12), value: isActive)
    }

    private var foregroundColor: Color {
        if isActive { return DesignTokens.FilterPill.activeForeground }
        return DesignTokens.Icon.tintMuted.opacity(0.85)
    }

    private var backgroundFill: Color {
        if isActive { return DesignTokens.FilterPill.activeBackground }
        if isHovering { return DesignTokens.Icon.backgroundHover }
        return DesignTokens.Icon.backgroundRest
    }
}
