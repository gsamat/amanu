import AppKit
import Foundation
import Testing

@testable import amanu

@Suite(.serialized, .freshHome(config: #"{"transcription":{"engine":"compatible"}}"#))
@MainActor
struct ServerFormatLayoutTests {
    @Test("Server API format is above the URL and shares its label and value columns",
          .speaking(.russian))
    func formatRowMatchesInputGrid() throws {
        let form = SetupForm()
        defer { form.stop() }

        let fields = form.view.allDescendants.compactMap { $0 as? NSTextField }
        let format = try #require(fields.first { $0.identifier?.rawValue == "transcription.compatible.format" })
        let url = try #require(fields.first { $0.identifier?.rawValue == "transcription.compatible.base-url" })
        let formatRow = try #require(format.superview as? NSStackView)
        let urlRow = try #require(url.superview as? NSStackView)
        let options = try #require(formatRow.superview as? NSStackView)
        let heading = try #require(formatRow.arrangedSubviews.first as? NSTextField)
        let urlHeading = try #require(urlRow.arrangedSubviews.first as? NSTextField)

        #expect(format.stringValue == "MLX Audio")
        #expect(heading.stringValue == "Формат API")
        #expect(heading.textColor == .secondaryLabelColor)
        #expect(format.accessibilityLabel() == "Формат API")
        #expect(options.arrangedSubviews.firstIndex(of: formatRow)! < options.arrangedSubviews.firstIndex(of: urlRow)!)
        #expect(heading.constraints.contains { $0.firstAttribute == .width && $0.constant == 76 })
        #expect(urlHeading.constraints.contains { $0.firstAttribute == .width && $0.constant == 76 })
        #expect(formatRow.spacing == urlRow.spacing)
    }

    @Test("Long server errors wrap beside the test button at the narrow window width",
          .speaking(.russian))
    func longServerResultFitsNarrowWindow() throws {
        _ = NSApplication.shared
        let settings = SettingsWindow()
        defer { withExtendedLifetime(settings) {} }
        let panel = try #require(NSApp.windows.last { $0.title == "Настройки amanu" })
        let content = try #require(panel.contentView)
        let button = try #require(content.allDescendants.compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "transcription.compatible.check-recognition"
        })
        let status = try #require(content.allDescendants.compactMap { $0 as? NSTextField }.first {
            $0.identifier?.rawValue == "transcription.compatible.status"
        })
        let row = try #require(button.superview as? NSStackView)
        #expect(status.superview === row)
        status.stringValue = String(repeating: "Сервер не ответил. Проверьте адрес, модель и сетевое подключение. ", count: 4)
        let options = try #require(row.superview as? NSStackView)
        let rowIndex = try #require(options.arrangedSubviews.firstIndex(of: row))
        let note = try #require(options.arrangedSubviews[rowIndex + 1] as? NSTextField)
        #expect(note.stringValue.contains("короткая тестовая фраза"))

        // Test the actual row in the space available in a 640-point window,
        // independent of the settings window's other minimum-width content.
        options.removeArrangedSubview(row)
        row.removeFromSuperview()
        let narrow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let host = try #require(narrow.contentView)
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            row.topAnchor.constraint(equalTo: host.topAnchor, constant: 32),
        ])
        host.layoutSubtreeIfNeeded()

        let buttonFrame = button.convert(button.bounds, to: row)
        let statusFrame = status.convert(status.bounds, to: row)
        #expect(row.bounds.width <= 401, "the test must exercise a constrained row")
        #expect(row.frame.maxY <= host.bounds.maxY + 0.5 && row.frame.minY >= host.bounds.minY - 0.5,
                "the row must be fully visible inside the test container")
        #expect(buttonFrame.maxX <= statusFrame.minX + 0.5, "status overlaps the button")
        #expect(statusFrame.maxX <= row.bounds.maxX + 0.5, "status extends beyond the row")
        #expect(buttonFrame.minY >= row.bounds.minY - 0.5 && buttonFrame.maxY <= row.bounds.maxY + 0.5,
                "the button must fit vertically inside the row")
        #expect(statusFrame.minY >= row.bounds.minY - 0.5 && statusFrame.maxY <= row.bounds.maxY + 0.5,
                "the status must fit vertically inside the row")
        #expect(statusFrame.width > 30)
        let textBounds = (status.stringValue as NSString).boundingRect(
            with: NSSize(width: statusFrame.width, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: try #require(status.font)])
        #expect(statusFrame.height + 2 >= textBounds.height, "long server output is vertically clipped")

        let longResult = status.stringValue
        narrow.setContentSize(NSSize(width: 600, height: 300))
        status.stringValue = "Проверяю сгенерированную тестовую фразу…"
        host.layoutSubtreeIfNeeded()
        #expect(status.frame.width > 400, "the status should use available space")
        #expect(status.frame.height < 20, "a short status should fit on one line")

        narrow.setContentSize(NSSize(width: 400, height: 300))
        status.stringValue = longResult
        host.layoutSubtreeIfNeeded()

        if let path = ProcessInfo.processInfo.environment["AMANU_STATUS_SHOT"] {
            let ground = StatusShotBackground(frame: host.bounds)
            ground.autoresizingMask = [.width, .height]
            host.addSubview(ground, positioned: .below, relativeTo: nil)
            defer { ground.removeFromSuperview() }
            host.displayIfNeeded()
            let shot = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: shot)
            let png = try #require(shot.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}

private final class StatusShotBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
