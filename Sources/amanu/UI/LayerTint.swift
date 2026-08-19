import AppKit

/// A view that paints part of itself into its own layer, and therefore has to
/// be told when the Mac changes appearance.
///
/// The reason is that a `CGColor` is a number and an `NSColor` is a rule. Read
/// `NSColor.separatorColor.cgColor` and you get whatever that rule evaluated
/// to at that instant — a pale line under a dark appearance, a dark one under
/// a light appearance — and the layer keeps that number for the rest of its
/// life. Nothing in AppKit re-evaluates it, because by then there is nothing
/// left to re-evaluate. So the borders and hairlines of the setup window
/// disappeared the moment someone switched their Mac between light and dark
/// with the window already built: the colours were still the other theme's.
///
/// Conforming views name their layer colours in `tintLayer()` and call
/// `retint()` whenever those colours could have changed.
@MainActor
protocol LayerTinted: NSView {
    /// Read every layer colour this view uses, from `NSColor`, now.
    func tintLayer()
}

extension LayerTinted {
    /// Drawing the colours as the view's own appearance is the part that is
    /// easy to leave out and hard to notice missing. Outside of drawing,
    /// `NSColor.cgColor` resolves against the *thread's* appearance rather
    /// than the view's, and for a view being built before it has a window
    /// that is plain Aqua whatever the Mac is set to — which is how a window
    /// comes out with light-mode hairlines on a dark background without
    /// anyone having switched anything.
    func retint() {
        effectiveAppearance.performAsCurrentDrawingAppearance { tintLayer() }
    }
}
