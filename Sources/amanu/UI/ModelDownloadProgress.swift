import AppKit

/// Progress and cancellation inside the card for one downloadable model.
@MainActor
final class ModelDownloadProgress: NSStackView {
    private let status = SetupLayout.status()
    private let bar = NSProgressIndicator()
    private let cancel: NSButton

    init(model: String, identifier: String, target: AnyObject, action: Selector) {
        cancel = NSButton(title: "", target: target, action: action)
        super.init(frame: .zero)

        orientation = .vertical
        alignment = .leading
        spacing = 7

        bar.style = .bar
        bar.controlSize = .small
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.setAccessibilityLabel(localised(
            "Download progress for \(model)", "Ход загрузки \(model)"))

        cancel.identifier = NSUserInterfaceItemIdentifier(identifier)
        cancel.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        cancel.imagePosition = .imageOnly
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        let cancelName = localised("Cancel \(model) download", "Отменить загрузку \(model)")
        cancel.toolTip = cancelName
        cancel.setAccessibilityLabel(cancelName)
        cancel.widthAnchor.constraint(equalToConstant: 24).isActive = true
        cancel.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let controls = NSStackView(views: [bar, cancel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        addArrangedSubview(status)
        addArrangedSubview(controls)
        status.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        controls.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        bar.widthAnchor.constraint(equalTo: controls.widthAnchor, constant: -32).isActive = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func begin() {
        cancel.isEnabled = true
        isHidden = false
        update(0)
    }

    func update(_ fraction: Double?) {
        guard let fraction, fraction.isFinite else {
            status.stringValue = localised("Downloading…", "Загрузка…")
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            return
        }
        let value = min(1, max(0, fraction))
        bar.stopAnimation(nil)
        bar.isIndeterminate = false
        bar.doubleValue = value
        status.stringValue = localised("Downloading · ", "Загрузка · ")
            + "\(Int(value * 100))%"
    }

    func cancelling() {
        cancel.isEnabled = false
        status.stringValue = localised("Stopping…", "Останавливаем…")
    }

    func end() {
        bar.stopAnimation(nil)
        isHidden = true
    }
}
