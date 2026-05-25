import AppKit

@MainActor
final class ShelfPanelController {
    private var panel: NSPanel?
    private var shelfView: ShelfView?
    private var releaseMonitor: Any?
    private var pendingEmptyShelf = false

    func showShelf(near point: CGPoint, ephemeral: Bool) {
        let shelfView = shelfView ?? ShelfView()
        self.shelfView = shelfView
        pendingEmptyShelf = ephemeral && shelfView.urls.isEmpty

        let panel = panel ?? makePanel(shelfView: shelfView)
        self.panel = panel

        resize(panel, to: shelfView.preferredSize, animate: false)
        position(panel, near: point)
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.makeFirstResponder(shelfView)

        if ephemeral {
            armReleaseWatcher()
        }
    }

    private func makePanel(shelfView: ShelfView) -> NSPanel {
        let panel = ShelfPanel(
            contentRect: NSRect(origin: .zero, size: ShelfView.compactSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = shelfView
        shelfView.onPreferredSizeChange = { [weak self, weak panel] size in
            guard let self, let panel else { return }
            self.resize(panel, to: size, animate: true)
        }

        return panel
    }

    private func resize(_ panel: NSPanel, to size: NSSize, animate: Bool) {
        let currentFrame = panel.frame
        let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        var nextFrame = NSRect(
            x: center.x - (size.width / 2),
            y: center.y - (size.height / 2),
            width: size.width,
            height: size.height
        )

        let visibleFrame = NSScreen.screens.first { $0.frame.intersects(currentFrame) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        nextFrame.origin.x = max(visibleFrame.minX + 10, min(nextFrame.origin.x, visibleFrame.maxX - size.width - 10))
        nextFrame.origin.y = max(visibleFrame.minY + 10, min(nextFrame.origin.y, visibleFrame.maxY - size.height - 10))

        panel.contentView?.setFrameSize(size)
        panel.setFrame(nextFrame, display: true, animate: animate)
    }

    private func position(_ panel: NSPanel, near point: CGPoint) {
        let size = panel.frame.size
        let visibleFrame = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var origin = CGPoint(x: point.x - (size.width / 2), y: point.y + 30)

        if origin.y + size.height > visibleFrame.maxY - 10 {
            origin.y = point.y - size.height - 30
        }

        origin.x = max(visibleFrame.minX + 10, min(origin.x, visibleFrame.maxX - size.width - 10))
        origin.y = max(visibleFrame.minY + 10, min(origin.y, visibleFrame.maxY - size.height - 10))

        panel.setFrameOrigin(origin)
    }

    private func armReleaseWatcher() {
        disarmReleaseWatcher()
        releaseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in
                self?.handleDragRelease()
            }
        }
    }

    private func disarmReleaseWatcher() {
        if let releaseMonitor {
            NSEvent.removeMonitor(releaseMonitor)
        }
        releaseMonitor = nil
    }

    private func handleDragRelease() {
        disarmReleaseWatcher()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }

            if self.pendingEmptyShelf, self.shelfView?.urls.isEmpty == true {
                if self.shelfView?.isReceivingExternalDrop == true {
                    self.handleDragRelease()
                    return
                }

                self.panel?.orderOut(nil)
            }

            self.pendingEmptyShelf = false
        }
    }
}

private final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}
