import AppKit

extension NSFont {
    /// The same font, asked for its tabular figures — the numerals redrawn on
    /// one shared advance, everything else untouched.
    ///
    /// Anywhere a clock ticks, the ordinary figures are wrong: every digit has
    /// its own width, so 1:19 becoming 1:20 changes the length of the line and
    /// shifts what is drawn beside it, once a second, for the length of the
    /// meeting. Asking for the feature rather than swapping in a monospaced
    /// face keeps the words either side of the clock in the font they were
    /// designed in.
    ///
    /// A face without the feature comes back unchanged, which is the right
    /// answer: proportional digits beat none.
    var tabularFigures: NSFont {
        let descriptor = fontDescriptor.addingAttributes([
            .featureSettings: [
                [
                    NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                    NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                ]
            ]
        ])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
