import AppKit

/// The feather, drawn from an inlined SVG so the executable still needs no
/// resource bundle next to it. Shared by the menu bar, the status window and
/// the Dock tile so all three show the same state in the same colour.
enum FeatherIcon {
    // Lucide feather.
    private static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24"
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5"
    stroke-linecap="round" stroke-linejoin="round">
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>
    <path d="M16 8 2 22"/>
    <path d="M17.5 15H9"/>
    </svg>
    """

    private static let source: NSImage? = NSImage(data: Data(svg.utf8))

    /// The feather at `size`. With a colour it is painted in that colour and
    /// marked non-template; without one it is a template image the system
    /// renders to match its surroundings.
    ///
    /// Painting rather than tinting is deliberate: `contentTintColor` doesn't
    /// reliably override template rendering, and over a dark wallpaper the
    /// "red" recording icon came out near-black on near-black — invisible in
    /// the one state that must never be (upstream issue #15).
    static func image(size: CGFloat, color: NSColor?) -> NSImage? {
        guard let source = source?.copy() as? NSImage else { return nil }
        source.size = NSSize(width: size, height: size)

        guard let color else {
            source.isTemplate = true
            return source
        }
        let rect = NSRect(origin: .zero, size: source.size)
        let painted = NSImage(size: source.size)
        painted.lockFocus()
        source.draw(at: .zero, from: rect, operation: .sourceOver, fraction: 1)
        color.set()
        rect.fill(using: .sourceAtop)
        painted.unlockFocus()
        painted.isTemplate = false
        return painted
    }

    /// Colour for a recording state, or nil for idle (template rendering).
    static func color(recording: Bool, paused: Bool) -> NSColor? {
        if paused { return .systemOrange }
        if recording { return .systemRed }
        return nil
    }
}
