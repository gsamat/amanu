#!/usr/bin/env swift
// Renders Amanu.icns from the same feather the menu bar and Dock tile draw.
//
// The app icon is not the menu-bar icon at a larger size. A bare feather on
// transparency disappears into a dark wallpaper, and macOS expects an app to
// occupy a rounded square with the right margins around it — so the feather is
// drawn on a squircle, in ink over paper, and the shape is what someone
// recognises in the Dock before they can see the drawing.
//
//   swift scripts/make-icon.swift Resources/Amanu.icns [preview.png]

import AppKit
import Foundation

let feather = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"
viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"
stroke-linecap="round" stroke-linejoin="round">
<path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>
<path d="M16 8 2 22"/>
<path d="M17.5 15H9"/>
</svg>
"""

/// Paper and ink. Warm off-white rather than pure white so the tile reads as
/// paper next to the aluminium and glass of everything else in the Dock, and
/// near-black rather than black so the strokes don't vibrate against it.
let paperTop = NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.94, alpha: 1)
let paperBottom = NSColor(calibratedRed: 0.90, green: 0.88, blue: 0.83, alpha: 1)
let ink = NSColor(calibratedRed: 0.13, green: 0.12, blue: 0.11, alpha: 1)

func icon(side: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    defer { image.unlockFocus() }

    // Apple's grid leaves the icon shape at about 80% of the canvas.
    let inset = side * 0.10
    let tile = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let squircle = NSBezierPath(
        roundedRect: tile,
        xRadius: tile.width * 0.2237,
        yRadius: tile.height * 0.2237)

    NSGradient(starting: paperTop, ending: paperBottom)?.draw(in: squircle, angle: -90)

    // A hairline edge, so the tile keeps its shape on a white background.
    ink.withAlphaComponent(0.12).setStroke()
    squircle.lineWidth = max(1, side / 256)
    squircle.stroke()

    if let drawn = NSImage(data: Data(feather.utf8))?.copy() as? NSImage {
        let featherSide = tile.width * 0.62
        drawn.size = NSSize(width: featherSide, height: featherSide)

        // Paint the feather on its own canvas first. `sourceAtop` colours
        // everything already drawn in the context it runs in — done here, it
        // would swallow the paper as well as the feather.
        let painted = NSImage(size: drawn.size)
        painted.lockFocus()
        drawn.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        ink.set()
        NSRect(origin: .zero, size: drawn.size).fill(using: .sourceAtop)
        painted.unlockFocus()

        painted.draw(
            in: NSRect(
                x: tile.midX - featherSide / 2,
                y: tile.midY - featherSide / 2,
                width: featherSide,
                height: featherSide),
            from: .zero, operation: .sourceOver, fraction: 1)
    }
    return image
}

func png(_ image: NSImage, pixels: Int) -> Data? {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    representation.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()

    return representation.representation(using: .png, properties: [:])
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data(
        "usage: make-icon.swift <output.icns> [preview.png]\n".utf8))
    exit(64)
}
let output = URL(fileURLWithPath: arguments[1])
let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("Amanu-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        guard let data = png(icon(side: CGFloat(pixels)), pixels: pixels) else { continue }
        let suffix = scale == 1 ? "" : "@2x"
        try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

try? fm.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

if arguments.count >= 3, let preview = png(icon(side: 512), pixels: 512) {
    try preview.write(to: URL(fileURLWithPath: arguments[2]))
}
print("wrote \(output.path)")
