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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shelfController = ShelfPanelController()
    private let shakeMonitor = DragShakeMonitor()
    private var controlWindow: NSWindow?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        shakeMonitor.onShake = { [weak self] location in
            self?.shelfController.showShelf(near: location, ephemeral: true)
        }

        configureStatusItem()
        shakeMonitor.start()

        if ProcessInfo.processInfo.environment["SHAKE_SHELF_SHOW_CONTROL"] == "1" {
            showControlWindow()
            NSApp.activate(ignoringOtherApps: true)
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

        let quit = NSMenuItem(title: "Quit Shake Shelf", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
    }

    @objc private func showShelfFromMenu() {
        shelfController.showShelf(near: NSEvent.mouseLocation, ephemeral: false)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showControlWindow() {
        NSApp.setActivationPolicy(.regular)

        let controller = ControlWindowController(
            monitor: shakeMonitor,
            onShowShelf: { [weak self] in
                self?.shelfController.showShelf(near: NSEvent.mouseLocation, ephemeral: false)
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
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        controlWindow = window
    }
}
