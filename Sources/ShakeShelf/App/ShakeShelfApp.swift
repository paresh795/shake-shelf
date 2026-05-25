import AppKit

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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let didShowWelcomeKey = "didShowWelcome"
    private let shelfController = ShelfPanelController()
    private let shakeMonitor = DragShakeMonitor()
    private var welcomeWindow: NSWindow?
    private var markWelcomeOnClose = false
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        shakeMonitor.onShake = { [weak self] location in
            self?.shelfController.showShelf(near: location, ephemeral: true)
        }

        configureStatusItem()
        shakeMonitor.start()

        if ProcessInfo.processInfo.environment["SHAKE_SHELF_SHOW_WELCOME"] == "1"
            || !UserDefaults.standard.bool(forKey: didShowWelcomeKey) {
            showWelcomeWindow(markAsShownOnClose: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        shakeMonitor.stop()
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

        let showWelcome = NSMenuItem(title: "Show Welcome", action: #selector(showWelcomeFromMenu), keyEquivalent: "")
        showWelcome.target = self
        menu.addItem(showWelcome)

        let quit = NSMenuItem(title: "Quit Shake Shelf", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
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
}
