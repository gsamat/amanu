import AppKit

/// Foundation parses Markdown; AppKit needs explicit fonts and paragraph
/// breaks to display its block and inline presentation intents in NSTextView.
@MainActor
enum MarkdownPreview {
    static func render(_ markdown: String) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: 13)
        guard let parsed = try? AttributedString(markdown: markdown) else {
            return NSAttributedString(string: markdown, attributes: [
                .font: baseFont, .foregroundColor: NSColor.labelColor,
            ])
        }
        let result = NSMutableAttributedString(string: "")
        var previousBlock: Int?
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let block = components.first?.identity
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 8
            paragraph.lineSpacing = 2
            var font = baseFont
            var prefix = ""
            var isCode = false
            // Components run from the innermost block outwards, so the first
            // list item is the one this text belongs to and the component
            // after it is the list that numbers it. Taking the last instead
            // gave every item of a nested list its parent's number.
            let depth = components.filter {
                if case .listItem = $0.kind { return true }
                return false
            }.count
            var listed = false
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .header(let level):
                    font = .systemFont(ofSize: max(14, 24 - CGFloat(level) * 2), weight: .semibold)
                    paragraph.paragraphSpacingBefore = 8
                case .listItem(let ordinal):
                    guard !listed else { break }
                    listed = true
                    let ordered = components.indices.contains(index + 1)
                        && components[index + 1].kind == .orderedList
                    prefix = ordered ? "\(ordinal). " : "• "
                    let indent = CGFloat(depth - 1) * 20
                    paragraph.firstLineHeadIndent = indent
                    paragraph.headIndent = indent + 20
                    paragraph.paragraphSpacing = 4
                case .blockQuote:
                    paragraph.firstLineHeadIndent = 16
                    paragraph.headIndent = 16
                case .codeBlock:
                    isCode = true
                default:
                    break
                }
            }
            let inline = run.inlinePresentationIntent ?? []
            if isCode || inline.contains(.code) {
                font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            }
            if inline.contains(.stronglyEmphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if inline.contains(.emphasized) {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
            ]
            if let link = run.link { attributes[.link] = link }
            if inline.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if block != previousBlock {
                if result.length > 0 { result.append(NSAttributedString(string: "\n", attributes: attributes)) }
                if !prefix.isEmpty { result.append(NSAttributedString(string: prefix, attributes: attributes)) }
                previousBlock = block
            }
            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }
}
