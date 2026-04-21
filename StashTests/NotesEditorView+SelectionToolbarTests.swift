import Testing
@testable import Stash

/// Manual-verification checklist for the notes selection toolbar — kept as a
/// disabled suite so the structure (and test names) exists for later automation.
/// Unblock one test at a time by removing the `.disabled(...)` trait and
/// filling in the assertions.
///
/// NOTE: there is no `StashTests` Xcode target at the time of writing. This
/// file sits in a plain directory under the repo and does NOT compile until a
/// test target is added. The scaffold is here so the test names exist as a
/// to-do list for whoever wires up the target.
@Suite(.disabled("Manual-only verification for v1 — see the PR description for the checklist."))
struct NotesEditorSelectionToolbarTests {

    @Test func selectionAppearsAboveSelectionWithin16pt() throws {
        // Place caret, extend selection, compute glyph bounding rect, assert
        // controller's panel origin sits at rect.maxY + 8 (or flips to
        // rect.minY - 8 - panel.height if offscreen-top).
    }

    @Test func scrollTracksToolbarUntilSelectionLeavesViewport() throws {
        // Scroll the enclosing NSScrollView while selection is held; assert the
        // panel's screen origin updates within one runloop tick. When the
        // selection scrolls entirely out of the visible rect by more than the
        // toolbar height, the panel hides; it re-shows on scroll back.
    }

    @Test func boldClickKeepsEditorFirstResponder() throws {
        // Simulate toolbar Bold click; assert textView.window?.firstResponder === textView.
    }

    @Test func selectAllPositionsToolbarWithinScreenBounds() throws {
        // ⌘A; assert the resolved panel origin lies inside screen.visibleFrame.
    }

    @Test func escapeDismissesToolbarWithoutCollapsingSelection() throws {
        // Simulate Escape; assert panel.isVisible == false AND selectedRange.length > 0.
    }

    @Test func emptySelectionHidesToolbar() throws {
        // Collapse selection; assert panel.isVisible == false.
    }

    @Test func headingDropdownConvertsLineInPlace() throws {
        // applyHeading(.h1); assert the paragraph's font changed to h1NSFont,
        // caret stayed on the same line, and background color / foreground
        // color were stripped (no stale inline-code chrome).
    }

    @Test func linkPopoverPersistsURLAfterApply() throws {
        // Apply URL; assert attributedString has .link at the selection range.
        // Cmd-click opens the URL in the default browser via NSTextView's
        // built-in link handling.
    }

    @Test func windowResizeKeepsToolbarAttached() throws {
        // Resize the window while toolbar is visible; assert panel origin
        // updates within one runloop tick via the didResizeNotification sink.
    }
}
