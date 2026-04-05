import AppKit
import SwiftUI

@MainActor
func renderPDF<V: View>(size: CGSize, @ViewBuilder view: () -> V) -> Data? {
    let root = view().frame(width: size.width, height: size.height)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = CGRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
    hosting.cacheDisplay(in: hosting.bounds, to: image)
    guard let cg = image.cgImage else { return nil }
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
    var mediaBox = CGRect(origin: .zero, size: size)
    guard let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
    pdf.beginPDFPage(nil)
    pdf.draw(cg, in: mediaBox)
    pdf.endPDFPage()
    pdf.closePDF()
    return data as Data
}

@MainActor
enum IconGen {
    static func pinIcon() -> some View {
        Image("clipboard-pin-icon-svg")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: 14, height: 14)
    }

    static func copyIcon() -> some View {
        Image("clipboard-copy-icon-svg")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .frame(width: 14, height: 14)
    }
}
