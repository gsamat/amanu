#!/usr/bin/env swift
//
// make-icon.swift — build Resources/Amanu.icns from the same feather the app
// draws at runtime.
//
//   swift scripts/make-icon.swift Resources/Amanu.icns
//
// The feather path is copied from Sources/amanu/UI/FeatherIcon.swift rather
// than imported: this runs as a standalone script, before and independently of
// the amanu target, so it cannot link against it. The two are only three SVG
// path strings apart, and those come from Lucide and do not change.
//
// The Dock icon is not the menu bar icon. In the menu bar the feather is a
// template image the system inverts to match the bar, so a bare stroke on
// transparency is exactly right. On the Dock a bare stroke would sit directly
// on the wallpaper — a dark feather over a dark desktop is invisible, the same
// failure FeatherIcon's comment describes for the recording colour. So the app
// icon gets the macOS treatment: a squircle plate at 80% of the canvas, and
// the feather in warm off-white on top. The plate is deliberately neutral
// slate; red and orange stay meaningful because they only ever appear while
// something is actually being recorded.

import AppKit
import Foundation

// MARK: - Drawing

/// Lucide feather, with three knobs the menu bar version does not need, all of
/// them there because an outline drawn at 16 or 32 pixels stops being a
/// drawing and becomes a grey smudge:
///
/// - `barb`, the short line across the vane, lands on top of the quill at
///   small sizes and is dropped there;
/// - `filled` paints the vane solid instead of outlining it, so the feather
///   survives as a silhouette when its outline is a single pixel wide;
/// - `strokeWidth` goes up as the size comes down.
private func featherSVG(strokeWidth: CGFloat, color: String, barb: Bool, filled: Bool) -> String {
    let vaneFill = filled ? color : "none"
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"
    viewBox="0 0 24 24" fill="none" stroke="\(color)" stroke-width="\(strokeWidth)"
    stroke-linecap="round" stroke-linejoin="round">
    <path fill="\(vaneFill)" d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>
    <path d="M16 8 2 22"/>
    \(barb ? #"<path d="M17.5 15H9"/>"# : "")
    </svg>
    """
}

private let plateTop = NSColor(srgbRed: 0.294, green: 0.353, blue: 0.435, alpha: 1)    // #4B5A6F
private let plateBottom = NSColor(srgbRed: 0.129, green: 0.161, blue: 0.212, alpha: 1) // #212936
private let featherInk = "#F3EFE5"

/// A superellipse — |x|⁵ + |y|⁵ = 1 — which is what the rounded square of a
/// macOS icon actually is. A plain rounded rectangle has circular corners and
/// reads subtly wrong next to the system's own icons.
private func squircle(in rect: NSRect, exponent n: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = rect.midX + a * copysign(pow(abs(c), 2 / n), c)
        let y = rect.midY + b * copysign(pow(abs(s), 2 / n), s)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

/// The icon at `pixels` × `pixels`, as a bitmap.
private func renderIcon(pixels: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)

    let n = CGFloat(pixels)
    // Apple's grid: an 824pt shape on a 1024pt canvas, sitting a touch high so
    // its baked-in shadow has room underneath.
    let side = n * 0.824
    let plate = NSRect(x: (n - side) / 2, y: (n - side) / 2 + n * 0.012,
                       width: side, height: side)
    // Below ~32px the feather's own strokes are barely a pixel wide, so it is
    // drawn larger and heavier there; the alternative is a grey smudge.
    let small = pixels <= 32
    let glyphSide = side * (small ? 0.76 : 0.68)
    let stroke: CGFloat = small ? 2.6 : 1.9

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let shape = squircle(in: plate)

    // Contact shadow. Subtle: the Dock adds its own reflection, and a heavy
    // one here makes the icon look like it is floating.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.30)
    shadow.shadowBlurRadius = n * 0.022
    shadow.shadowOffset = NSSize(width: 0, height: -n * 0.012)
    shadow.set()
    plateBottom.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [plateBottom, plateTop])?.draw(in: shape, angle: 90)

    // A hairline of light along the edge keeps the plate from dissolving into
    // a light wallpaper, which the gradient alone does not prevent at the top.
    NSGraphicsContext.saveGraphicsState()
    shape.setClip()
    let rim = squircle(in: plate.insetBy(dx: n * 0.004, dy: n * 0.004))
    rim.lineWidth = n * 0.008
    NSColor.white.withAlphaComponent(0.14).setStroke()
    rim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    let svg = featherSVG(strokeWidth: stroke, color: featherInk,
                         barb: !small, filled: pixels <= 16)
    guard let feather = NSImage(data: Data(svg.utf8)) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    feather.size = NSSize(width: glyphSide, height: glyphSide)
    let origin = NSPoint(x: plate.midX - glyphSide / 2, y: plate.midY - glyphSide / 2)
    feather.draw(at: origin, from: NSRect(origin: .zero, size: feather.size),
                 operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Iconset

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

private func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("PNG encoding failed for \(url.lastPathComponent)")
    }
    try data.write(to: url)
}

let args = CommandLine.arguments
guard args.count == 2 else {
    fail("usage: swift scripts/make-icon.swift <output.icns>")
}
let output = URL(fileURLWithPath: args[1]).standardizedFileURL

let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("amanu-icon-\(UUID().uuidString)")
let iconset = work.appendingPathComponent("Amanu.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

// The full macOS set. Each nominal point size appears at both scales, so the
// pixel sizes run 16 through 1024 and iconutil has an exact match for every
// place the system draws an icon.
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

for variant in variants {
    let pixels = variant.points * variant.scale
    guard let rep = renderIcon(pixels: pixels) else { fail("could not render \(pixels)px") }
    let suffix = variant.scale == 1 ? "" : "@\(variant.scale)x"
    try writePNG(rep, to: iconset.appendingPathComponent(
        "icon_\(variant.points)x\(variant.points)\(suffix).png"))
}

try? fm.createDirectory(at: output.deletingLastPathComponent(),
                        withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fail("iconutil failed") }

print("wrote \(output.path)")
