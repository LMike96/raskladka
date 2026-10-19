import Cocoa
import ServiceManagement
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let settings = Settings.shared
    private let layouts = LayoutManager.shared
    private let engine = TypingEngine.shared
    private var permissionTimer: Timer?
    private var lastExternalApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let myID = Bundle.main.bundleIdentifier ?? ""
        if NSRunningApplication.runningApplications(withBundleIdentifier: myID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        layouts.onChange = { [weak self] in self?.updateTitle() }
        layouts.onExternalChange = { [weak self] in self?.engine.resetAll() }
        engine.onStateChange = { [weak self] in self?.updateTitle() }
        layouts.reload()

        engine.detector = Detector()

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != myID {
            lastExternalApp = front
            engine.setFrontApp(front.bundleIdentifier)
        }

        updateTitle()
        startWhenPermitted(prompt: true)
    }

    // MARK: - Разрешения

    private func startWhenPermitted(prompt: Bool) {
        if AXIsProcessTrusted() && engine.start() {
            permissionTimer?.invalidate()
            permissionTimer = nil
            updateTitle()
            return
        }
        if prompt {
            if !AXIsProcessTrusted() {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            } else {
                _ = CGRequestListenEventAccess()
            }
        }
        if permissionTimer == nil {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if AXIsProcessTrusted() && self.engine.start() {
                    self.permissionTimer?.invalidate()
                    self.permissionTimer = nil
                    self.updateTitle()
                }
            }
        }
        updateTitle()
    }

    @objc private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Иконка в строке меню

    private func updateTitle() {
        guard let button = statusItem?.button else { return }
        let text: String
        var color = NSColor.labelColor
        if !engine.isRunning {
            text = "⚠︎"
        } else if let lang = layouts.currentLang {
            text = lang == .ru ? "RU" : "EN"
        } else {
            text = "··"
        }
        if !settings.enabled || engine.isAppExcluded || !engine.isRunning {
            color = .tertiaryLabelColor
        }
        button.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color
        ])
        button.toolTip = "Раскладка — автопереключение RU/EN"
    }

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        lastExternalApp = app
        engine.setFrontApp(app.bundleIdentifier)
        updateTitle()
    }

    // MARK: - Меню

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Статус
        let status: String
        if !engine.isRunning {
            status = "⚠︎ Нужен доступ «Универсальный доступ»"
        } else if !layouts.hasBothLayouts {
            status = "⚠︎ Добавьте русскую и английскую раскладки"
        } else if !settings.enabled {
            status = "Приостановлено"
        } else if engine.isAppExcluded {
            status = "Отключено в этом приложении"
        } else {
            status = "Работает"
        }
        addInfo(menu, status)
        if let en = layouts.layout(for: .en), let ru = layouts.layout(for: .ru) {
            addInfo(menu, "\(en.name) ⇄ \(ru.name)")
        }
        if !engine.isRunning {
            addAction(menu, "Открыть настройки доступа…", #selector(openAccessibilitySettings))
        }
        menu.addItem(.separator())

        addToggle(menu, "Включено", Settings.Key.enabled)
        addToggle(menu, "Автоисправление раскладки", Settings.Key.autoSwitch)
        menu.addItem(.separator())

        addToggle(menu, "Shift — отменить / исправить последнее слово", Settings.Key.shiftTap)
        addToggle(menu, "Shift Shift — исправить выделенный текст", Settings.Key.doubleShift)
        addToggle(menu, "Исправлять ДВе ЗАглавные", Settings.Key.fixTwoCaps)
        addToggle(menu, "Заменять -- на длинное тире —", Settings.Key.dash)
        addToggle(menu, "Звук при переключении", Settings.Key.sound)
        addToggle(menu, "Запоминать мои исправления", Settings.Key.learning)
        menu.addItem(.separator())

        // Текущее приложение
        if let app = lastExternalApp, let id = app.bundleIdentifier {
            let name = app.localizedName ?? id
            let byPattern = settings.isExcluded(id) && !settings.excludedApps.contains(id)
            let item = NSMenuItem(title: "Не работать в «\(name)»", action: #selector(toggleCurrentApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = settings.isExcluded(id) ? .on : .off
            item.isEnabled = !byPattern
            menu.addItem(item)
        }

        // Исключения
        let exMenu = NSMenu()
        exMenu.autoenablesItems = false
        for id in settings.excludedApps {
            let item = NSMenuItem(title: appName(id), action: #selector(removeException(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = .on
            item.toolTip = "Нажмите, чтобы убрать из исключений"
            exMenu.addItem(item)
        }
        exMenu.addItem(.separator())
        addAction(exMenu, "Восстановить стандартный список", #selector(resetExceptions))
        let exItem = NSMenuItem(title: "Исключения (\(settings.excludedApps.count))", action: nil, keyEquivalent: "")
        exItem.submenu = exMenu
        menu.addItem(exItem)

        // Обучение
        let learnMenu = NSMenu()
        learnMenu.autoenablesItems = false
        addInfo(learnMenu, "Выучено слов: \(engine.detector?.learned.count ?? 0)")
        addAction(learnMenu, "Показать файлы словаря в Finder", #selector(showLearnedFiles))
        addAction(learnMenu, "Забыть выученные слова…", #selector(resetLearned))
        let learnItem = NSMenuItem(title: "Мой словарь", action: nil, keyEquivalent: "")
        learnItem.submenu = learnMenu
        menu.addItem(learnItem)
        menu.addItem(.separator())

        if #available(macOS 13.0, *) {
            let item = NSMenuItem(title: "Запускать при входе в систему", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
            item.target = self
            item.state = SMAppService.mainApp.status == .enabled ? .on : .off
            menu.addItem(item)
        }
        addAction(menu, "О программе", #selector(showAbout))
        let quit = NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func addInfo(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func addToggle(_ menu: NSMenu, _ title: String, _ key: String) {
        let item = NSMenuItem(title: title, action: #selector(toggleSetting(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = key
        item.state = settings.bool(key) ? .on : .off
        menu.addItem(item)
    }

    private func appName(_ id: String) -> String {
        if id == "com.jetbrains.*" { return "Все IDE JetBrains" }
        if id.hasSuffix("*") { return id }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            let name = FileManager.default.displayName(atPath: url.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return id
    }

    // MARK: - Действия меню

    @objc private func toggleSetting(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        settings.toggle(key)
        engine.resetAll()
        updateTitle()
    }

    @objc private func toggleCurrentApp(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.setExcluded(id, !settings.excludedApps.contains(id))
        engine.refreshExclusion()
        updateTitle()
    }

    @objc private func removeException(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.setExcluded(id, false)
        engine.refreshExclusion()
        updateTitle()
    }

    @objc private func resetExceptions() {
        settings.resetExclusions()
        engine.refreshExclusion()
        updateTitle()
    }

    @objc private func showLearnedFiles() {
        guard let dir = engine.detector?.learned.directory else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    @objc private func resetLearned() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Забыть выученные слова?"
        alert.informativeText = "Все слова, которые программа запомнила по вашим исправлениям Shift'ом, будут удалены."
        alert.addButton(withTitle: "Забыть")
        alert.addButton(withTitle: "Отмена")
        if alert.runModal() == .alertFirstButtonReturn {
            engine.detector?.learned.reset()
        }
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Не удалось изменить автозапуск"
            alert.informativeText = "Убедитесь, что приложение лежит в папке «Программы». \(error.localizedDescription)"
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Раскладка 1.0"
        alert.informativeText = """
        Автоматическое исправление раскладки RU ⇄ EN для macOS.

        • Слово, набранное не в той раскладке, исправляется после пробела.
        • Shift (коротко) — отменить исправление или исправить последнее слово вручную; если исправлять нечего — переключить раскладку.
        • Shift Shift — исправить выделенный текст в любом приложении.
        • Программа запоминает ваши исправления и больше не ошибается на этих словах.
        • В терминалах, IDE и менеджерах паролей отключена.
        """
        alert.runModal()
    }
}
