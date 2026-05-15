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

    @State private var isPopoverShown = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // Left: active filter title + count
            HStack(spacing: 8) {
                Text(activeFilter.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Typography.sectionColor)
                Text("\(counts[activeFilter, default: 0])")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignTokens.Typography.itemColor)
            }

            Spacer(minLength: 0)

            // Right: filter icon + F badge
            HStack(spacing: 6) {
                filterIconButton
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

                FKeyBadge()
                    .onTapGesture { isPopoverShown.toggle() }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // No background — the bar reads as part of the column, not a separate UI element.
    }

    private var filterIconButton: some View {
        HeaderIconButton(
            icon: .system(activeFilter == .all
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill"),
            iconColor: DesignTokens.Icon.tintMuted,
            size: 26
        ) {
            isPopoverShown.toggle()
        }
    }

    /// Public toggle entry point for the keyboard-shortcut follow-up task.
    func toggleFromShortcut() {
        isPopoverShown.toggle()
    }
}

// MARK: - F key badge

private struct FKeyBadge: View {
    var body: some View {
        Text("F")
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(DesignTokens.Icon.tintMuted)
            .frame(width: 16, height: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(DesignTokens.Icon.tintMuted.opacity(0.55), lineWidth: 1)
            )
            .contentShape(Rectangle())
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

                Text(filter.displayName)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.primary)

                Spacer(minLength: 8)

                Text("\(count)")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(DesignTokens.Typography.itemColor.opacity(0.6))
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
