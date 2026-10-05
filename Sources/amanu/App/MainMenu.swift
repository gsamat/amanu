import AppKit

extension Run {
    /// A .regular app owns the menu bar while it's focused, and without a main
    /// menu that bar is empty — no ⌘Q, no window menu. This is the minimum
    /// that makes the app behave like an app.
    @MainActor
    static func mainMenu(settingsTarget: AppDelegate) -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // First in the menu, where every Mac puts it.
        let about = NSMenuItem(
            title: localised("About Amanu", "О программе amanu"),
            action: #selector(AppDelegate.showAboutClicked(_:)),
            keyEquivalent: ""
        )
        about.target = settingsTarget
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        // ⌘, is where every Mac user looks for settings, and it only works
        // from the main menu — the status item's copy of it is live just
        // while that menu is open.
        let settings = NSMenuItem(
            title: localised("Settings…", "Настройки…"),
            action: #selector(AppDelegate.showSettingsClicked(_:)),
            keyEquivalent: ","
        )
        settings.target = settingsTarget
        appMenu.addItem(settings)
        // Present only while there is a first run to finish; the delegate
        // keeps it so it can be taken away again. See `setupAvailable`.
        let setup = NSMenuItem(
            title: localised("Setup…", "Первая настройка…"),
            action: #selector(AppDelegate.showSetupClicked(_:)),
            keyEquivalent: ""
        )
        setup.target = settingsTarget
        settingsTarget.setupItem = setup
        // Answered here as well as by the controller, because the menu is
        // built after the controller has already asked once: an item that is
        // born visible on a machine that finished setup last month is visible
        // until something else happens to change it.
        setup.isHidden = !SetupState.isPending
        appMenu.addItem(setup)
        let updates = NSMenuItem(
            title: localised("Check for updates…", "Проверить обновления…"),
            action: #selector(AppDelegate.checkForUpdatesClicked(_:)),
            keyEquivalent: ""
        )
        updates.target = settingsTarget
        appMenu.addItem(updates)
        appMenu.addItem(.separator())
        // Quit routes through terminate so the delegate is asked first — it
        // stops to ask when a meeting is being recorded — and so
        // applicationWillTerminate closes a live recording properly rather
        // than truncating it.
        appMenu.addItem(withTitle: localised("Quit Amanu", "Завершить amanu"),
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: localised("File", "Файл"))
        let importItem = NSMenuItem(
            title: localised("Import…", "Импортировать…"),
            action: #selector(AppDelegate.importClicked(_:)),
            keyEquivalent: "i"
        )
        importItem.target = settingsTarget
        fileMenu.addItem(importItem)
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        // AppKit routes Command-key editing shortcuts through the main menu,
        // including when an NSSecureTextField has the focus in Settings.
        // Nil targets let the focused field editor handle each action.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: localised("Edit", "Правка"))
        editMenu.addItem(withTitle: localised("Cut", "Вырезать"),
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: localised("Copy", "Копировать"),
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: localised("Paste", "Вставить"),
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: localised("Select All", "Выделить всё"),
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: localised("Window", "Окно"))
        windowMenu.addItem(withTitle: localised("Close", "Закрыть"),
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: localised("Minimise", "Убрать в Dock"),
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }
}
