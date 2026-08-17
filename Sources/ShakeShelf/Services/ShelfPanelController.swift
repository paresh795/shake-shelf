import AppKit
import Quartz
import QuartzCore
import ShakeShelfCore

@MainActor
final class ShelfPanelController {
    private var panel: NSPanel?
    private var shelfView: ShelfView?
    private var releaseMonitor: Any?
    private var hoverMonitor: Any?
    private var expandedPointerMonitor: Any?
    private var pendingEmptyShelf = false
    private var releaseRearmCount = 0
    private var focusReturnTarget: NSRunningApplication?
    private var collapseTimerToken: UUID?
    private var hoverDwellToken: UUID?
    private var hoverArmed = false
    private var ballMenuPresenting = false
    private var lastHoverPoint: CGPoint?

    private(set) var isCollapsed = false

    var currentShelfView: ShelfView? {
        shelfView
    }

    var currentURLs: [URL] {
        shelfView?.urls ?? []
    }

    var onShelfContentsChanged: (([URL]) -> Void)?
    var onShelfContentsWillClear: (([URL]) -> Void)?
    var onConfigureShelfView: ((ShelfView) -> Void)?
    var fallbackFocusReturnTarget: NSRunningApplication?

    var ballModeEnabled = ShakeShelfSettings.load().collapseToBallEnabled {
        didSet {
            guard ballModeEnabled != oldValue else { return }

            if ballModeEnabled {
                if isCollapsed || panel?.isVisible != true {
                    showBallIfEnabled()
                } else {
                    armExpandedPointerMonitor()
                    scheduleCollapseTimerIfNeeded()
                }
            } else if isCollapsed {
                dismissShelf(reason: "ball-mode-off", restoreFocus: false)
            } else {
                disarmExpandedPointerMonitor()
                cancelCollapseTimer()
            }
        }
    }

    private lazy var ballCenter: CGPoint? = {
        guard UserDefaults.standard.object(forKey: "ballCenterX") != nil,
              UserDefaults.standard.object(forKey: "ballCenterY") != nil else {
            return nil
        }

        return CGPoint(
            x: UserDefaults.standard.double(forKey: "ballCenterX"),
            y: UserDefaults.standard.double(forKey: "ballCenterY")
        )
    }() {
        didSet {
            if let ballCenter {
                UserDefaults.standard.set(ballCenter.x, forKey: "ballCenterX")
                UserDefaults.standard.set(ballCenter.y, forKey: "ballCenterY")
            } else {
                UserDefaults.standard.removeObject(forKey: "ballCenterX")
                UserDefaults.standard.removeObject(forKey: "ballCenterY")
            }
        }
    }

    func showShelf(near point: CGPoint, ephemeral: Bool) {
        if isCollapsed {
            expandFromBall(near: point, ephemeral: ephemeral, makeKey: true, reason: ephemeral ? "shake" : "menu")
            return
        }

        let shelfView = shelfView ?? ShelfView()
        self.shelfView = shelfView
        pendingEmptyShelf = ephemeral && shelfView.urls.isEmpty
        releaseRearmCount = 0

        if ephemeral {
            captureFocusReturnTarget()
        }

        Diagnostics.log("SHELF SHOW ephemeral=\(ephemeral) items=\(shelfView.urls.count)")

        let panel = panel ?? makePanel(shelfView: shelfView)
        self.panel = panel

        resize(panel, to: shelfView.preferredSize, animate: false)
        position(panel, near: point)

        let wasHidden = !panel.isVisible
        panel.orderFrontRegardless()
        if wasHidden {
            animateAppear(panel)
        }

        panel.makeKey()
        panel.makeFirstResponder(shelfView)

        if ephemeral {
            armReleaseWatcher()
        }

        if ballModeEnabled {
            armExpandedPointerMonitor()
            scheduleCollapseTimerIfNeeded()
        }
    }

    func showBallIfEnabled() {
        guard ballModeEnabled, !isCollapsed, panel?.isVisible != true else { return }

        let shelfView = shelfView ?? ShelfView()
        self.shelfView = shelfView
        let panel = panel ?? makePanel(shelfView: shelfView)
        self.panel = panel

        isCollapsed = true
        hoverArmed = true
        shelfView.isBallPresentation = true

        let ballRect = ShelfBallBehavior.ballRect(centeredAt: ballHomePosition())
        panel.contentView?.setFrameSize(ballRect.size)
        panel.setFrame(ballRect, display: true, animate: false)
        panel.orderFrontRegardless()

        armHoverMonitor()
        startBallSettle()
        Diagnostics.log("BALL SHOW at=\(Int(ballRect.midX)),\(Int(ballRect.midY))")
    }

    func hideShelf() {
        if ballModeEnabled {
            collapseToBall(reason: "close")
        } else {
            dismissShelf(reason: "close")
        }
    }

    func dismissShelf(reason: String = "dismiss", restoreFocus: Bool = true) {
        disarmReleaseWatcher()
        disarmHoverMonitor()
        disarmExpandedPointerMonitor()
        cancelCollapseTimer()
        cancelHoverDwell()
        pendingEmptyShelf = false
        releaseRearmCount = 0
        isCollapsed = false
        hoverArmed = false
        ballMenuPresenting = false
        shelfView?.isBallPresentation = false
        shelfView?.layer?.removeAllAnimations()
        panel?.orderOut(nil)
        closeQuickLookPanel()
        Diagnostics.log("SHELF HIDE reason=\(reason)")

        if restoreFocus {
            restoreFocusToPreviousApp()
        }
    }

    func closeQuickLookPanel() {
        QLPreviewPanel.shared()?.close()
    }

    // MARK: - Ball collapse / expand

    private func expandFromBall(near point: CGPoint, ephemeral: Bool, makeKey: Bool, reason: String, anchoredToBall: Bool = false) {
        guard isCollapsed else { return }
        disarmHoverMonitor()
        cancelCollapseTimer()
        cancelHoverDwell()
        isCollapsed = false

        guard let panel, let shelfView else { return }

        shelfView.layer?.removeAllAnimations()

        pendingEmptyShelf = ephemeral && shelfView.urls.isEmpty
        releaseRearmCount = 0
        if ephemeral {
            captureFocusReturnTarget()
        }

        let targetSize = shelfView.preferredSize
        panel.contentView?.setFrameSize(targetSize)
        shelfView.isBallPresentation = false

        let targetFrame = anchoredToBall
            ? ShelfBallBehavior.shelfFrame(nearBall: point, size: targetSize, in: visibleFrame(containing: point))
            : frame(near: point, size: targetSize)

        fadeShelfContent(to: 0, duration: 0)
        panel.orderFrontRegardless()
        animateFrame(to: targetFrame, duration: 0.28, overshoot: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.bloomShelfContent()

            if makeKey {
                panel.makeKey()
                panel.makeFirstResponder(shelfView)
            }

            if ephemeral {
                self.armReleaseWatcher()
            }

            if self.ballModeEnabled {
                self.armExpandedPointerMonitor()
                self.scheduleCollapseTimerIfNeeded()
            }
        }

        Diagnostics.log("SHELF EXPAND reason=\(reason) items=\(shelfView.urls.count)")
    }

    private func collapseToBall(reason: String) {
        guard !isCollapsed else { return }

        disarmReleaseWatcher()
        cancelCollapseTimer()
        disarmExpandedPointerMonitor()
        cancelHoverDwell()
        pendingEmptyShelf = false
        releaseRearmCount = 0
        closeQuickLookPanel()

        guard let panel, let shelfView else { return }

        isCollapsed = true
        hoverArmed = false
        lastHoverPoint = nil

        let ballRect = ShelfBallBehavior.ballRect(centeredAt: ballHomePosition())

        fadeShelfContent(to: 0, duration: 0.1)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, self.isCollapsed else { return }
            shelfView.isBallPresentation = true
            panel.contentView?.setFrameSize(ballRect.size)
            self.animateFrame(to: ballRect, duration: 0.28, overshoot: true)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.isCollapsed else { return }
                self.fadeShelfContent(to: 1, duration: 0.12)
                self.armHoverMonitor()
                self.startBallSettle()
            }
        }

        Diagnostics.log("SHELF COLLAPSE reason=\(reason)")
    }

    private func handleBallDragged(to center: CGPoint) {
        cancelHoverDwell()
        hoverArmed = false
        lastHoverPoint = nil
        let visible = visibleFrame(containing: center)
        ballCenter = ShelfBallBehavior.clampedPosition(center, in: visible)
        Diagnostics.log("BALL DRAG to=\(Int(ballCenter?.x ?? 0)),\(Int(ballCenter?.y ?? 0))")
    }

    private func handleBallClicked() {
        guard isCollapsed else { return }
        cancelHoverDwell()
        expandFromBall(near: ballHomePosition(), ephemeral: false, makeKey: true, reason: "click", anchoredToBall: true)
    }

    private func handleBallResetHome() {
        guard isCollapsed else { return }
        cancelHoverDwell()
        hoverArmed = false
        ballCenter = nil

        let home = ballHomePosition()
        let ballRect = ShelfBallBehavior.ballRect(centeredAt: home)
        animateFrame(to: ballRect, duration: 0.3, overshoot: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            self?.startBallSettle()
        }

        Diagnostics.log("BALL RESET to=\(Int(home.x)),\(Int(home.y))")
    }

    // MARK: - Hover / idle monitoring

    private func armHoverMonitor() {
        disarmHoverMonitor()
        disarmExpandedPointerMonitor()

        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in
                self?.handleCollapsedPointerMove()
            }
        }
    }

    private func disarmHoverMonitor() {
        if let hoverMonitor {
            NSEvent.removeMonitor(hoverMonitor)
        }
        hoverMonitor = nil
    }

    private func handleCollapsedPointerMove() {
        guard isCollapsed, let frame = panel?.frame else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        guard !ballMenuPresenting else { return }

        let halo = frame.insetBy(
            dx: -ShelfBallBehavior.hoverHaloInset,
            dy: -ShelfBallBehavior.hoverHaloInset
        )
        let mouse = NSEvent.mouseLocation

        if halo.contains(mouse) {
            guard hoverArmed else { return }

            if let last = lastHoverPoint,
               !ShelfBallBehavior.isRestMovement(from: last, to: mouse) {
                // pointer is still moving — restart the dwell clock, keep glowing
                startHoverDwellIfNeeded(restart: true)
            } else {
                startHoverDwellIfNeeded()
            }
            lastHoverPoint = mouse
        } else {
            hoverArmed = true
            lastHoverPoint = nil
            cancelHoverDwell()
        }
    }

    private func startHoverDwellIfNeeded(restart: Bool = false) {
        if !restart, hoverDwellToken != nil { return }

        let token = UUID()
        hoverDwellToken = token

        if !restart {
            shelfView?.setBallDwellActive(true)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + ShelfBallBehavior.hoverOpenDwell) { [weak self] in
            guard let self, self.hoverDwellToken == token else { return }
            self.hoverDwellToken = nil

            guard self.isCollapsed, NSEvent.pressedMouseButtons == 0, !self.ballMenuPresenting else { return }

            let halo = (self.panel?.frame ?? .zero).insetBy(
                dx: -ShelfBallBehavior.hoverHaloInset,
                dy: -ShelfBallBehavior.hoverHaloInset
            )
            guard halo.contains(NSEvent.mouseLocation) else {
                self.hoverArmed = true
                return
            }

            self.shelfView?.setBallDwellActive(false)
            self.expandFromBall(
                near: self.ballHomePosition(),
                ephemeral: false,
                makeKey: false,
                reason: "hover",
                anchoredToBall: true
            )
        }
    }

    private func cancelHoverDwell() {
        guard hoverDwellToken != nil else { return }
        hoverDwellToken = nil
        shelfView?.setBallDwellActive(false)
    }

    private func armExpandedPointerMonitor() {
        disarmExpandedPointerMonitor()
        disarmHoverMonitor()

        expandedPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in
                self?.handleExpandedPointerMove()
            }
        }
    }

    private func disarmExpandedPointerMonitor() {
        if let expandedPointerMonitor {
            NSEvent.removeMonitor(expandedPointerMonitor)
        }
        expandedPointerMonitor = nil
    }

    private func handleExpandedPointerMove() {
        guard !isCollapsed, ballModeEnabled, let frame = panel?.frame else { return }

        let area = frame.insetBy(
            dx: -ShelfBallBehavior.shelfHoverMargin,
            dy: -ShelfBallBehavior.shelfHoverMargin
        )

        if area.contains(NSEvent.mouseLocation) {
            cancelCollapseTimer()
        } else {
            scheduleCollapseTimerIfNeeded()
        }
    }

    private func scheduleCollapseTimerIfNeeded() {
        guard collapseTimerToken == nil else { return }

        let token = UUID()
        collapseTimerToken = token

        DispatchQueue.main.asyncAfter(deadline: .now() + ShelfBallBehavior.autoCollapseDelay) { [weak self] in
            guard let self, self.collapseTimerToken == token else { return }
            self.collapseTimerToken = nil

            let area = (self.panel?.frame ?? .zero).insetBy(
                dx: -ShelfBallBehavior.shelfHoverMargin,
                dy: -ShelfBallBehavior.shelfHoverMargin
            )

            if ShelfBallBehavior.shouldCollapse(
                pointerInShelfArea: area.contains(NSEvent.mouseLocation),
                mouseButtonPressed: NSEvent.pressedMouseButtons > 0,
                quickLookVisible: QLPreviewPanel.shared()?.isVisible == true,
                receivingExternalDrop: self.shelfView?.isReceivingExternalDrop == true,
                appIsActive: NSApp.isActive
            ) {
                self.collapseToBall(reason: "idle")
            } else {
                self.scheduleCollapseTimerIfNeeded()
            }
        }
    }

    private func cancelCollapseTimer() {
        collapseTimerToken = nil
    }

    // MARK: - Ball placement

    private func ballHomePosition() -> CGPoint {
        let reference = ballCenter ?? NSEvent.mouseLocation
        let visible = visibleFrame(containing: reference)

        if let saved = ballCenter {
            return ShelfBallBehavior.clampedPosition(saved, in: visible)
        }

        return ShelfBallBehavior.defaultHomePosition(in: visible)
    }

    private func visibleFrame(containing point: CGPoint) -> NSRect {
        NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    // MARK: - Panel construction and layout

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

        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = ShelfView.cornerRadius
        backdrop.layer?.masksToBounds = true
        backdrop.frame = NSRect(origin: .zero, size: shelfView.preferredSize)

        shelfView.autoresizingMask = [.width, .height]
        shelfView.frame = backdrop.bounds
        backdrop.addSubview(shelfView)
        panel.contentView = backdrop

        shelfView.onPreferredSizeChange = { [weak self, weak panel] size in
            guard let self, let panel else { return }
            self.resize(panel, to: size, animate: true)
        }
        shelfView.onRequestClose = { [weak self] in
            self?.hideShelf()
        }
        shelfView.onRequestCloseQuickLook = { [weak self] in
            self?.closeQuickLookPanel()
        }
        shelfView.onRequestCollapse = { [weak self] in
            guard let self else { return }
            if self.ballModeEnabled {
                self.collapseToBall(reason: "escape")
            }
        }
        shelfView.onBallDragged = { [weak self] center in
            self?.handleBallDragged(to: center)
        }
        shelfView.onBallClicked = { [weak self] in
            self?.handleBallClicked()
        }
        shelfView.onBallPressDown = { [weak self] in
            self?.cancelHoverDwell()
        }
        shelfView.onBallResetHome = { [weak self] in
            self?.handleBallResetHome()
        }
        shelfView.onBallMenuWillPresent = { [weak self] in
            self?.cancelHoverDwell()
            self?.hoverArmed = false
            self?.ballMenuPresenting = true
        }
        shelfView.onBallMenuDidDismiss = { [weak self] in
            self?.ballMenuPresenting = false
        }
        shelfView.onBallMenuQuit = { [weak self] in
            self?.dismissShelf(reason: "quit", restoreFocus: false)
            NSApp.terminate(nil)
        }
        shelfView.onContentsChanged = { [weak self] urls in
            self?.onShelfContentsChanged?(urls)
        }
        shelfView.onContentsWillClear = { [weak self] urls in
            self?.onShelfContentsWillClear?(urls)
        }

        onConfigureShelfView?(shelfView)

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

        if animate {
            DispatchQueue.main.async { [weak panel] in
                panel?.setFrame(nextFrame, display: true, animate: true)
            }
        } else {
            panel.setFrame(nextFrame, display: true, animate: false)
        }
    }

    private func position(_ panel: NSPanel, near point: CGPoint) {
        panel.setFrameOrigin(frame(near: point, size: panel.frame.size).origin)
    }

    private func frame(near point: CGPoint, size: NSSize) -> NSRect {
        let visibleFrame = visibleFrame(containing: point)

        var origin = CGPoint(x: point.x - (size.width / 2), y: point.y + 30)

        if origin.y + size.height > visibleFrame.maxY - 10 {
            origin.y = point.y - size.height - 30
        }

        origin.x = max(visibleFrame.minX + 10, min(origin.x, visibleFrame.maxX - size.width - 10))
        origin.y = max(visibleFrame.minY + 10, min(origin.y, visibleFrame.maxY - size.height - 10))

        return NSRect(origin: origin, size: size)
    }

    private func animateAppear(_ panel: NSPanel) {
        guard let layer = panel.contentView?.layer else { return }

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.92
        scale.toValue = 1.0
        scale.duration = 0.16
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(scale, forKey: "shelfAppearScale")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0
        fade.duration = 0.12
        layer.add(fade, forKey: "shelfAppearFade")
    }

    private func animateFrame(to frame: NSRect, duration: TimeInterval, overshoot: Bool = false) {
        NSAnimationContext.runAnimationGroup { [weak panel] context in
            context.duration = duration
            context.timingFunction = overshoot
                ? CAMediaTimingFunction(controlPoints: 0.34, 1.2, 0.64, 1.0)
                : CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            panel?.animator().setFrame(frame, display: true)
        }
    }

    private func bloomShelfContent() {
        guard let layer = shelfView?.layer else { return }

        let group = CAAnimationGroup()
        group.duration = 0.3
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.2, 0.64, 1.0)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.0
        fade.toValue = 1.0

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.94
        scale.toValue = 1.0

        group.animations = [fade, scale]
        layer.add(group, forKey: "shelfBloom")
        layer.opacity = 1.0
    }

    private func fadeShelfContent(to alpha: CGFloat, duration: TimeInterval) {
        guard let layer = shelfView?.layer else { return }

        if duration <= 0 {
            layer.opacity = Float(alpha)
            return
        }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
        fade.toValue = Float(alpha)
        fade.duration = duration
        layer.add(fade, forKey: "shelfContentFade")
        layer.opacity = Float(alpha)
    }

    private func startBallSettle() {
        guard let layer = shelfView?.layer else { return }
        layer.removeAllAnimations()

        let settle = CAKeyframeAnimation(keyPath: "transform.scale")
        settle.values = [1.0, 1.07, 1.02, 1.0]
        settle.keyTimes = [0, 0.35, 0.7, 1.0]
        settle.duration = 1.1
        settle.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeIn)
        ]
        layer.add(settle, forKey: "ballPulse")
    }

    // MARK: - Focus management

    private func captureFocusReturnTarget() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            focusReturnTarget = frontmost
        } else {
            focusReturnTarget = nil
        }
    }

    private func restoreFocusToPreviousApp() {
        if let target = focusReturnTarget {
            focusReturnTarget = nil
            target.activate()
        } else if let target = fallbackFocusReturnTarget {
            fallbackFocusReturnTarget = nil
            target.activate()
        }
    }

    // MARK: - Drag release watching

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

        DispatchQueue.main.async { [weak self] in
            self?.restoreFocusToPreviousApp()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }

            if self.pendingEmptyShelf, self.shelfView?.urls.isEmpty == true {
                if self.shelfView?.isReceivingExternalDrop == true, self.releaseRearmCount < 3 {
                    self.releaseRearmCount += 1
                    self.handleDragRelease()
                    return
                }

                if self.ballModeEnabled {
                    self.collapseToBall(reason: "auto-empty")
                } else {
                    self.panel?.orderOut(nil)
                    Diagnostics.log("SHELF HIDE reason=auto-empty")
                }
            }

            self.pendingEmptyShelf = false
            self.releaseRearmCount = 0
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
