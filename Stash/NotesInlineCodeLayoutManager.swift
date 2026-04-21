import AppKit

/// Draws rounded-rect backgrounds (radius 4) for runs that carry both a
/// monospaced font AND a background color — our inline-code signature.
///
/// RTF-safe: Apple's RTF serializer preserves both `.font` (including
/// monospaced trait) and `.backgroundColor`, so the rounded rendering survives
/// save/close/reopen. A custom attribute key (`.notesInlineCode`) would have
/// been cleaner semantically but gets silently dropped on round-trip.
final class NotesInlineCodeLayoutManager: NSLayoutManager {

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>,
                                          count rectCount: Int,
                                          forCharacterRange charRange: NSRange,
                                          color: NSColor) {
        // Only round when the run at this range uses a monospaced font.
        guard let textStorage,
              charRange.location < textStorage.length,
              let font = textStorage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont,
              font.fontDescriptor.symbolicTraits.contains(.monoSpace)
        else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }

        color.setFill()
        for i in 0..<rectCount {
            let rect = rectArray[i].insetBy(dx: 0, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            path.fill()
        }
    }
}
