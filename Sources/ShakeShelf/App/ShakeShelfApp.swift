import AppKit
import ShakeShelfCore

@main
enum ShakeShelfApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()

        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let didShowWelcomeKey = "didShowWelcome"
    private let shelfController = ShelfPanelController()
    private let shakeMonitor = DragShakeMonitor()
    private lazy var historyRecorder = ShelfHistoryRecorder(
        store: ShelfHistoryStore(fileURL: historyStoreURL)
    )
    private var welcomeWindow: NSWindow?
    private var markWelcomeOnClose = false
    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private var historyMenu: NSMenu?
    private var restoreLastSessionItem: NSMenuItem?
    private let mainThreadWatchdog = MainThreadWatchdog()

    private var historyStoreURL: URL {
        (try? ShelfHistoryStore.defaultFileURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Shake Shelf/History.plist")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.setup()

        let isSmokeTest = ProcessInfo.processInfo.environment["SHAKE_SHELF_SMOKE_TEST"] == "1"
        if isSmokeTest {
            shelfController.ballModeEnabled = false
        }

        shakeMonitor.onShake = { [weak self] location in
            self?.shelfController.showShelf(near: location, ephemeral: true)
        }

        configureHistoryRecorder()
        configureStatusItem()
        shakeMonitor.start()
        mainThreadWatchdog.start()

        if !isSmokeTest {
            shelfController.showBallIfEnabled()
        }

        if ProcessInfo.processInfo.environment["SHAKE_SHELF_SHOW_WELCOME"] == "1"
            || !UserDefaults.standard.bool(forKey: didShowWelcomeKey) {
            showWelcomeWindow(markAsShownOnClose: true)
        }

        if isSmokeTest {
            runSmokeTest()
        }
    }

    private func configureHistoryRecorder() {
        shelfController.onShelfContentsChanged = { [weak self] urls in
            self?.historyRecorder.contentsChanged(to: urls)
        }
        shelfController.onShelfContentsWillClear = { [weak self] urls in
            self?.historyRecorder.contentsWillClear(current: urls)
        }
        shelfController.onConfigureShelfView = { [weak self] shelfView in
            shelfView.historyMenuItems = { [weak self] in
                self?.historyMenuEntries() ?? []
            }
            shelfView.onRestoreHistoryEntry = { [weak self] id in
                self?.restoreSession(id: id)
            }
            shelfView.onClearHistory = { [weak self] in
                self?.clearHistoryFromMenu()
            }
        }
    }

    private func historyMenuEntries() -> [(id: UUID, title: String)] {
        historyRecorder.sessionList.prefix(12).map { session in
            (id: session.id, title: ShelfHistoryFormatter.title(for: session))
        }
    }

    private func runSmokeTest() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let point = NSScreen.main.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? .zero
            self.shelfController.showShelf(near: point, ephemeral: false)

            guard let shelfView = self.shelfController.currentShelfView else {
                Diagnostics.log("SMOKE FAIL: no shelf view")
                NSApp.terminate(nil)
                return
            }

            shelfView.runSmokeTest { passed, steps in
                for step in steps {
                    Diagnostics.log("SMOKE \(step)")
                }
                Diagnostics.log(passed ? "SMOKE TEST PASSED" : "SMOKE TEST FAILED")
                self.runHistorySmokeTest(shelfView: shelfView)
            }
        }
    }

    private func runHistorySmokeTest(shelfView: ShelfView) {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShakeShelfHistorySmoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let fileURLs = (0..<3).map { index in
            let url = tempDirectory.appendingPathComponent("history-\(index).txt")
            try? Data("history-\(index)".utf8).write(to: url)
            return url
        }

        historyRecorder.clearHistory()
        historyRecorder.contentsChanged(to: fileURLs)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            let sessions = self.historyRecorder.sessionList
            let recorded = sessions.count == 1 && sessions[0].urls.count == 3
            Diagnostics.log("SMOKE \(recorded ? "PASS" : "FAIL"): history records shelf state")
            Diagnostics.log("SMOKE INFO: session title: \(sessions.first.map { ShelfHistoryFormatter.title(for: $0) } ?? "none")")

            guard let session = sessions.first else {
                Diagnostics.log("SMOKE FAIL: history restore (no session)")
                self.historyRecorder.clearHistory()
                try? FileManager.default.removeItem(at: tempDirectory)
                self.shelfController.hideShelf()
                NSApp.terminate(nil)
                return
            }

            let (restoredURLs, missing) = self.historyRecorder.restoreState(from: session)
            Diagnostics.log("SMOKE \(restoredURLs.count == 3 && missing == 0 ? "PASS" : "FAIL"): history restore resolves files")

            shelfView.replaceContents(with: restoredURLs)
            Diagnostics.log("SMOKE \(shelfView.urls.count == 3 ? "PASS" : "FAIL"): history restore replaces shelf contents")

            let clearedSession = self.historyRecorder.sessionList.first
            Diagnostics.log("SMOKE \(clearedSession != nil ? "PASS" : "FAIL"): pre-restore state recorded")

            self.historyRecorder.clearHistory()
            self.historyRecorder.contentsChanged(to: [])
            try? FileManager.default.removeItem(at: tempDirectory)
            self.shelfController.hideShelf()
            Diagnostics.log("SMOKE TEST PASSED")
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        historyRecorder.recordAtTermination()
        shakeMonitor.stop()
        Diagnostics.noteTermination()
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            shelfController.fallbackFocusReturnTarget = frontmost
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        shelfController.closeQuickLookPanel()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = item.button {
            let image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: "Shake Shelf")
            image?.isTemplate = true
            button.image = image
            button.title = image == nil ? "S" : ""
            button.toolTip = "Shake Shelf"
        }

        let menu = NSMenu()
        let status = NSMenuItem(title: "Shake Shelf is running", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let showShelf = NSMenuItem(title: "Show Shelf", action: #selector(showShelfFromMenu), keyEquivalent: "s")
        showShelf.target = self
        menu.addItem(showShelf)

        let restoreLastSession = NSMenuItem(title: "Restore Last Session", action: #selector(restoreLastSession), keyEquivalent: "r")
        restoreLastSession.keyEquivalentModifierMask = [.control, .option]
        restoreLastSession.target = self
        menu.addItem(restoreLastSession)
        restoreLastSessionItem = restoreLastSession

        let historyMenu = NSMenu()
        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)
        self.historyMenu = historyMenu
        menu.delegate = self

        let showWelcome = NSMenuItem(title: "Show Welcome", action: #selector(showWelcomeFromMenu), keyEquivalent: "")
        showWelcome.target = self
        menu.addItem(showWelcome)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Shake Shelf", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func restoreLastSession() {
        guard let session = historyRecorder.sessionList.first else { return }
        restore(session: session)
    }

    private func restoreSession(id: UUID) {
        guard let session = historyRecorder.sessionList.first(where: { $0.id == id }) else { return }
        restore(session: session)
    }

    private func restore(session: ShelfSession) {
        let (urls, missing) = historyRecorder.restoreState(from: session)
        let current = shelfController.currentURLs
        let mode: RestoreMode

        if current.isEmpty {
            mode = .replace
        } else {
            let alert = NSAlert()
            alert.messageText = "Restore Session?"
            alert.informativeText = restoreAlertMessage(
                currentCount: current.count,
                sessionCount: urls.count,
                missing: missing
            )
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Append")
            alert.addButton(withTitle: "Cancel")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                mode = .replace
            case .alertSecondButtonReturn:
                mode = .append
            default:
                return
            }
        }

        if shelfController.currentShelfView == nil {
            shelfController.showShelf(near: NSEvent.mouseLocation, ephemeral: false)
        }

        guard let shelfView = shelfController.currentShelfView else { return }

        switch mode {
        case .replace:
            shelfView.replaceContents(with: urls)
        case .append:
            shelfView.appendContents(with: urls)
        }
    }

    private func restoreAlertMessage(currentCount: Int, sessionCount: Int, missing: Int) -> String {
        var message = "Replace the current shelf (\(currentCount) file\(currentCount == 1 ? "" : "s")) with this session (\(sessionCount) file\(sessionCount == 1 ? "" : "s"))?"
        if missing > 0 {
            message += " \(missing) file\(missing == 1 ? " was" : "s were") moved or deleted."
        }
        return message
    }

    private enum RestoreMode {
        case replace
        case append
    }

    @objc private func openSettings() {
        if let settingsWindowController {
            settingsWindowController.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = SettingsWindowController(settings: ShakeShelfSettings.load())
        controller.onSettingsChanged = { [weak self] updated in
            self?.shakeMonitor.applySensitivity(updated.sensitivity)
            self?.shelfController.ballModeEnabled = updated.collapseToBallEnabled
        }
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showShelfFromMenu() {
        shelfController.showShelf(near: NSEvent.mouseLocation, ephemeral: false)
    }

    @objc private func showWelcomeFromMenu() {
        showWelcomeWindow(markAsShownOnClose: false)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showWelcomeWindow(markAsShownOnClose: Bool) {
        if let welcomeWindow {
            welcomeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        NSApp.setActivationPolicy(.regular)

        let controller = WelcomeWindowController(
            onShowShelf: { [weak self] in
                self?.shelfController.showShelf(near: NSEvent.mouseLocation, ephemeral: false)
            },
            onDone: { [weak self] in
                self?.closeWelcomeWindow(markAsShown: markAsShownOnClose)
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shake Shelf"
        window.center()
        window.contentViewController = controller
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        window.isReleasedWhenClosed = false
        welcomeWindow = window
        markWelcomeOnClose = markAsShownOnClose
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeWelcomeWindow(markAsShown: Bool) {
        if markAsShown {
            UserDefaults.standard.set(true, forKey: didShowWelcomeKey)
        }

        markWelcomeOnClose = false
        welcomeWindow?.close()
        welcomeWindow = nil
        NSApp.setActivationPolicy(.accessory)
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === welcomeWindow else { return }

        if markWelcomeOnClose {
            UserDefaults.standard.set(true, forKey: didShowWelcomeKey)
        }

        welcomeWindow = nil
        markWelcomeOnClose = false
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - History menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === historyMenu else { return }

        historyMenu?.removeAllItems()
        let sessions = historyRecorder.sessionList
        restoreLastSessionItem?.isEnabled = !sessions.isEmpty

        guard !sessions.isEmpty else {
            let empty = NSMenuItem(title: "No sessions yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            historyMenu?.addItem(empty)
            return
        }

        for session in sessions.prefix(12) {
            let item = NSMenuItem(
                title: ShelfHistoryFormatter.title(for: session),
                action: #selector(restoreSessionFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = session.id
            historyMenu?.addItem(item)
        }

        historyMenu?.addItem(.separator())

        let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistoryFromMenu), keyEquivalent: "")
        clear.target = self
        historyMenu?.addItem(clear)
    }

    @objc private func restoreSessionFromMenu(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        restoreSession(id: id)
    }

    @objc private func clearHistoryFromMenu() {
        let alert = NSAlert()
        alert.messageText = "Clear History?"
        alert.informativeText = "All saved shelf sessions will be removed. This cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        historyRecorder.clearHistory()
    }
}
