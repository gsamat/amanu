import AppKit

/// The small window behind **About amanu**: whose program this is, where its
/// source is, and how to ask for one like it.
///
/// Every Mac application has this window and it is always in the same place,
/// which is the whole reason for it — somebody wondering who wrote a thing
/// that has been recording their meetings for a month looks under About
/// before anywhere else. amanu had nowhere to answer: it runs as
/// `.accessory`, so its application menu is only on screen while one of its
/// windows is in front, and neither the status window nor Settings is a place
/// for a name.
///
/// It says four things and does nothing. A window with an action in it is a
/// window that has to know what the recorder is doing; this one can be opened
/// at any moment of a recording and cost nothing.
@MainActor
final class AboutWindow: NSObject {
    private let panel: NSWindow
    private var linkButtons: [NSButton] = []

    override init() {
        panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            // No resize and no minimise: there is nothing in here that a
            // bigger window would show more of.
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.title = localised("About amanu", "О программе amanu")
        panel.isReleasedWhenClosed = false

        let icon = NSImageView()
        // The same feather as the Dock icon, drawn as a template so it is
        // black on a light Mac and white on a dark one without this window
        // having to know which it is.
        icon.image = FeatherIcon.image(size: 72, color: nil)

        let name = NSTextField(labelWithString: "amanu")
        name.font = .systemFont(ofSize: 22, weight: .semibold)

        let version = NSTextField(labelWithString: Self.versionLine ?? "")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        // A bare `swift run` has no bundle and therefore no version; an empty
        // line would leave a gap where a sentence looks like it went missing.
        version.isHidden = Self.versionLine == nil

        let tagline = NSTextField(labelWithString: localised(
            "Records your meetings and keeps them on this Mac.",
            "Записывает встречи и держит их на этом Маке."))
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .secondaryLabelColor
        tagline.alignment = .center
        tagline.lineBreakMode = .byWordWrapping
        tagline.maximumNumberOfLines = 0
        tagline.preferredMaxLayoutWidth = 260

        linkButtons = [
            // A name is usually left exactly as it is; a name is also how a
            // person is called, and in Russian this one is called this.
            link(localised("Samat Galimov", "Самат Галимов"), Self.authorPage),
            link(localised("Source code on GitHub", "Исходный код на GitHub"),
                 Self.sourceRepository),
            link(localised("Order custom development", "Заказать разработку"),
                 Self.developmentStudio),
        ]
        let links = NSStackView(views: linkButtons)
        links.orientation = .vertical
        links.alignment = .centerX
        links.spacing = 4

        let stack = NSStackView(views: [icon, name, version, tagline, links])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        // The links are a group of their own, and the gap above them is what
        // says so.
        stack.setCustomSpacing(18, after: tagline)
        stack.setCustomSpacing(4, after: name)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
        ])
        panel.contentView = content
        // The height is whatever the words come to. Russian runs a fifth
        // longer than English and the version line is missing from a bare
        // build, so a number written here would be the right one for one of
        // the four windows this can be.
        content.layoutSubtreeIfNeeded()
        panel.setContentSize(NSSize(width: Self.width, height: content.fittingSize.height))
        panel.center()
    }

    func show() {
        panel.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { panel.isVisible }

    /// What the window says, for the walk that reads every window in both
    /// languages. The title is in here because it is a sentence like the
    /// others, and it is the one that is not inside the content view.
    var view: NSView? { panel.contentView }
    var title: String { panel.title }

    /// The three links, as they read and where they go. The window is
    /// nothing but these, so this is how anything outside checks them.
    var offeredLinks: [(title: String, url: String)] {
        linkButtons.map { ($0.title, $0.identifier?.rawValue ?? "") }
    }

    /// Wide enough for the longest of the three links with room around it,
    /// and no wider: nothing in here is a paragraph.
    private static let width: CGFloat = 340

    static let authorPage = "https://samat.me"
    static let sourceRepository = "https://github.com/gsamat/amanu"

    /// The studio's site exists in each of amanu's two languages, and the one
    /// to open is the one the person reading this window can read. Which is
    /// why an address goes through `localised` here, where addresses usually
    /// stay as they are: these two are one page written twice, not a name.
    static var developmentStudio: String {
        localised("https://fans.dev", "https://fansdev.ru")
    }

    /// The version, as the bundle knows it. Nil for a bare build, which has
    /// no `Info.plist` to have been stamped by `make app`.
    static var versionLine: String? {
        guard let info = Runtime.appBundle?.infoDictionary,
              let short = info["CFBundleShortVersionString"] as? String
        else { return nil }
        let build = info["CFBundleVersion"] as? String
        let number = build.map { "\(short) (\($0))" } ?? short
        return localised("Version \(number)", "Версия \(number)")
    }

    private func link(_ title: String, _ url: String) -> NSButton {
        SetupLayout.link(title, url, target: self, action: #selector(linkClicked(_:)))
    }

    @objc private func linkClicked(_ sender: NSButton) {
        guard let url = sender.identifier.flatMap({ URL(string: $0.rawValue) }) else { return }
        NSWorkspace.shared.open(url)
    }
}
