#!/usr/bin/env swift
import AppKit

/// Renders a macOS App Icon placeholder: rounded rect, gradient, bold white "Q" (SF Pro Display when available).
func renderAppIcon(pixelSize: Int) -> NSImage {
    let side = CGFloat(pixelSize)
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { dst in
        let rect = NSRect(origin: .zero, size: dst.size)
        let corner = min(rect.width, rect.height) * 0.2237
        let rounded = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
        rounded.addClip()

        let g = NSGradient(colors: [
            NSColor(calibratedRed: 0.22, green: 0.42, blue: 0.98, alpha: 1),
            NSColor(calibratedRed: 0.58, green: 0.28, blue: 0.92, alpha: 1)
        ])!
        g.draw(in: rect, angle: 128)

        let fontSize = side * 0.52
        // Use system SF (bold); PostScript names like SFProDisplay-Bold are unreliable outside app bundles.
        let font = NSFont.systemFont(ofSize: fontSize, weight: .bold)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let str = NSAttributedString(string: "Q", attributes: attrs)
        let textHeight = str.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin]).height
        let textRect = NSRect(
            x: 0,
            y: (rect.height - textHeight) / 2 - side * 0.04,
            width: rect.width,
            height: textHeight + side * 0.1
        )
        str.draw(with: textRect, options: [.usesLineFragmentOrigin])
        return true
    }
    return img
}

func pngData(from image: NSImage, pixelWidth: Int, pixelHeight: Int) -> Data? {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    else { return nil }

    rep.size = NSSize(width: pixelWidth, height: pixelHeight)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight).fill()
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [.compressionFactor: 1.0])
}

struct Slot: CustomStringConvertible {
    let filename: String
    let pixels: Int
    var description: String { "\(filename) (\(pixels)px)" }
}

let slots: [Slot] = [
    .init(filename: "icon_16x16.png", pixels: 16),
    .init(filename: "icon_16x16@2x.png", pixels: 32),
    .init(filename: "icon_32x32.png", pixels: 32),
    .init(filename: "icon_32x32@2x.png", pixels: 64),
    .init(filename: "icon_128x128.png", pixels: 128),
    .init(filename: "icon_128x128@2x.png", pixels: 256),
    .init(filename: "icon_256x256.png", pixels: 256),
    .init(filename: "icon_256x256@2x.png", pixels: 512),
    .init(filename: "icon_512x512.png", pixels: 512),
    .init(filename: "icon_512x512@2x.png", pixels: 1024)
]

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: GenerateAppIcon <path-to-AppIcon.appiconset>\n", stderr)
    exit(1)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let fm = FileManager.default

for slot in slots {
    let img = renderAppIcon(pixelSize: slot.pixels)
    guard let data = pngData(from: img, pixelWidth: slot.pixels, pixelHeight: slot.pixels) else {
        fputs("Failed to encode \(slot.filename)\n", stderr)
        exit(1)
    }
    let url = outDir.appendingPathComponent(slot.filename)
    do {
        try data.write(to: url)
        print("Wrote \(slot)")
    } catch {
        fputs("Write error \(url.path): \(error)\n", stderr)
        exit(1)
    }
}

print("Done. \(slots.count) PNGs → \(outDir.path)")
