import AppKit
import ImageIO
import QuickLookThumbnailing
import Quartz
import ShakeShelfCore
import UniformTypeIdentifiers

@MainActor
final class ShelfView: NSView, NSDraggingSource, NSMenuDelegate {
    private struct FilePreview {
        let image: NSImage
        let isThumbnail: Bool
    }

    private struct WindowDragState {
        let mouseStart: CGPoint
        let windowStart: CGPoint
    }

    private enum HeaderControl: Equatable {
        case close
        case toggle
        case history
    }

    static let compactSize = NSSize(width: 270, height: 230)
    static let cornerRadius: CGFloat = 22

    var urls: [URL] {
        items.urls
    }

    var onPreferredSizeChange: ((NSSize) -> Void)?
    var onRequestClose: (() -> Void)?
    var onRequestCloseQuickLook: (() -> Void)?
    var onContentsChanged: (([URL]) -> Void)?
    var onContentsWillClear: (([URL]) -> Void)?
    var historyMenuItems: (() -> [(id: UUID, title: String)])?
    var onRestoreHistoryEntry: ((UUID) -> Void)?
    var onClearHistory: (() -> Void)?
    var isBallPresentation = false
    var onBallDragged: ((CGPoint) -> Void)?
    var onBallClicked: (() -> Void)?
    var onRequestCollapse: (() -> Void)?
    var onBallPressDown: (() -> Void)?
    var onBallResetHome: (() -> Void)?
    var onBallMenuWillPresent: (() -> Void)?
    var onBallMenuDidDismiss: (() -> Void)?
    var onBallMenuQuit: (() -> Void)?

    var preferredSize: NSSize {
        isStackOverview ? overviewSize(forItemCount: urls.count) : Self.compactSize
    }

    private let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private let listRowHeight: CGFloat = 35
    private let listRowSpacing: CGFloat = 4
    private let previewCacheLimit = 200
    private lazy var externalFileStore = ShelfFileStore(
        baseDirectory: (try? ShelfFileStore.defaultIncomingDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Shake Shelf/Incoming", isDirectory: true)
    )
    private lazy var itemPersistence = ShelfItemPersistence(
        fileURL: (try? ShelfItemPersistence.defaultFileURL())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Shake Shelf/Items.plist")
    )
    private var items = ShelfItems()
    private var isExpanded = false
    private var isStackOverview = false
    private var listScrollOffset: CGFloat = 0
    private var pendingDragURLs: [URL] = []
    private var pendingExternalDrops = 0
    private var windowDragState: WindowDragState?
    private var selectedURL: URL?
    private var hoveredURL: URL?
    private var hoveredHeaderControl: HeaderControl?
    private var trackingArea: NSTrackingArea?
    private var copyStatus: String?
    private var copyStatusToken: UUID?
    private var receiveGeneration = UUID()
    private var previewGeneration = UUID()
    private var previewCache: [String: FilePreview] = [:]
    private var previewCacheKeys: [String] = []
    private var pendingQuickLookKeys: Set<String> = []
    private var failedQuickLookKeys: Set<String> = []
    private var persistenceSaveWorkItem: DispatchWorkItem?
    private var stepsForSampling: [String] = []
    private let quickLookSource = QuickLookPreviewSource()
    private var ballDwellGlowActive = false
    private var presentedBallMenu: NSMenu?

    var isReceivingExternalDrop: Bool {
        pendingExternalDrops > 0
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.compactSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let promisedFileTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL, filenamesPasteboardType, .png, .tiff] + promisedFileTypes)

        if ShakeShelfSettings.load().persistItemsAcrossRelaunch {
            let persisted = itemPersistence.load()
            if !persisted.isEmpty {
                items.add(persisted)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        if isBallPresentation {
            drawBall()
            return
        }

        drawBackground()

        if urls.isEmpty, isReceivingExternalDrop {
            drawReceivingState()
        } else if urls.isEmpty {
            drawEmptyState()
        } else if isExpanded {
            drawExpandedList()
        } else if isStackOverview {
            drawStackOverview()
        } else {
            drawStack()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canReadDrop(from: sender.draggingPasteboard) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard

        let dropped = readFileURLs(from: pasteboard)
        if !dropped.isEmpty {
            add(dropped)
            return true
        }

        let imageURLs = storeRawImages(from: pasteboard)
        if !imageURLs.isEmpty {
            add(imageURLs)
            return true
        }

        let promisedFiles = readFilePromises(from: pasteboard)
        if !promisedFiles.isEmpty {
            return receivePromisedFiles(promisedFiles)
        }

        logUnsupportedDrop(from: pasteboard)
        return false
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        if isBallPresentation {
            animateBallPressScale(0.96, duration: 0.08)
            onBallPressDown?()
            if let window {
                windowDragState = WindowDragState(
                    mouseStart: NSEvent.mouseLocation,
                    windowStart: window.frame.origin
                )
                NSCursor.closedHand.set()
            }
            return
        }

        let point = convert(event.locationInWindow, from: nil)
        pendingDragURLs = []

        if let url = removeButtonHit(at: point) {
            _ = removeFromShelf(url)
            return
        }

        if toggleRect.contains(point), urls.count > 1 {
            isExpanded.toggle()
            isStackOverview = false
            listScrollOffset = 0
            selectedURL = nil
            hoveredURL = nil
            hoveredHeaderControl = nil
            requestPreferredSizeUpdate()
            invalidateInteractionState()
            return
        }

        if historyRect.contains(point) {
            presentHistoryMenu()
            return
        }

        if closeRect.contains(point) {
            clearShelfContents()
            onRequestClose?()
            return
        }

        if headerDragRect.contains(point), let window {
            selectedURL = nil
            windowDragState = WindowDragState(mouseStart: NSEvent.mouseLocation, windowStart: window.frame.origin)
            NSCursor.closedHand.set()
            return
        }

        if isExpanded, let url = rowHit(at: point) {
            selectedURL = url
            if event.clickCount >= 2 {
                _ = quickLookCurrentSelectionToPanel()
                pendingDragURLs = []
                needsDisplay = true
                return
            }

            pendingDragURLs = ShelfDragResolver.urlsToDrag(
                allURLs: existing(urls),
                selectedURL: url,
                surface: .list
            )
            needsDisplay = true
        } else if isStackOverview, let url = overviewItemHit(at: point) {
            selectedURL = url
            if event.clickCount >= 2 {
                _ = quickLook([url])
                pendingDragURLs = []
                needsDisplay = true
                return
            }

            pendingDragURLs = ShelfDragResolver.urlsToDrag(
                allURLs: existing(urls),
                selectedURL: url,
                surface: .overview
            )
            needsDisplay = true
        } else if !isStackOverview, stackInteractionRect.contains(point), !urls.isEmpty {
            selectedURL = nil
            if event.clickCount >= 2 {
                toggleStackOverview()
                pendingDragURLs = []
                return
            }

            pendingDragURLs = ShelfDragResolver.urlsToDrag(
                allURLs: existing(urls),
                selectedURL: nil,
                surface: .compactStack
            )
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let trackingArea {
            removeTrackingArea(trackingArea)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHoveredURL(nil)
        setHoveredHeaderControl(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        if let windowDragState, let window {
            let location = NSEvent.mouseLocation
            window.setFrameOrigin(CGPoint(
                x: windowDragState.windowStart.x + location.x - windowDragState.mouseStart.x,
                y: windowDragState.windowStart.y + location.y - windowDragState.mouseStart.y
            ))
            return
        }

        guard !pendingDragURLs.isEmpty else { return }
        beginDragging(urls: pendingDragURLs, event: event)
        pendingDragURLs = []
    }

    override func mouseUp(with event: NSEvent) {
        if isBallPresentation {
            if let state = windowDragState {
                windowDragState = nil
                let end = NSEvent.mouseLocation

                if ShelfBallBehavior.isDragMovement(from: state.mouseStart, to: end), let window {
                    animateBallRelease()
                    onBallDragged?(CGPoint(x: window.frame.midX, y: window.frame.midY))
                } else {
                    animateBallRelease()
                    onBallClicked?()
                }
            }
            NSCursor.arrow.set()
            window?.invalidateCursorRects(for: self)
            return
        }

        windowDragState = nil
        pendingDragURLs = []
        if window?.isKeyWindow == true {
            NSCursor.arrow.set()
        }
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        if isBallPresentation {
            addCursorRect(bounds, cursor: .openHand)
            return
        }

        if urls.count > 1 {
            addCursorRect(toggleRect, cursor: .pointingHand)
        }
        if !(historyMenuItems?().isEmpty ?? true) {
            addCursorRect(historyRect, cursor: .pointingHand)
        }
        addCursorRect(closeRect, cursor: .pointingHand)

        if isExpanded {
            addCursorRect(headerDragRect, cursor: .openHand)
            for (url, rect) in rowRects() where rect.intersects(listViewportRect) {
                addCursorRect(rect, cursor: .pointingHand)
                if shouldShowRemoveButton(for: url) {
                    addCursorRect(listRemoveButtonRect(for: rect), cursor: .pointingHand)
                }
            }
        } else if isStackOverview {
            addCursorRect(headerDragRect, cursor: .openHand)
            for (_, rect) in overviewItemRects() {
                addCursorRect(rect, cursor: .pointingHand)
            }
        } else {
            addCursorRect(headerDragRect, cursor: .openHand)
            if !urls.isEmpty {
                addCursorRect(stackInteractionRect, cursor: .openHand)
            }
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isExpanded, maxListScrollOffset() > 0 else {
            super.scrollWheel(with: event)
            return
        }

        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 8
        let previousOffset = listScrollOffset
        listScrollOffset = clampedListScrollOffset(for: listScrollOffset + delta)

        if listScrollOffset != previousOffset {
            needsDisplay = true
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.isVisible == true, window?.isKeyWindow == true else {
            return super.performKeyEquivalent(with: event)
        }

        if isBallPresentation {
            return super.performKeyEquivalent(with: event)
        }

        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCopy = modifierFlags == .command && event.charactersIgnoringModifiers?.lowercased() == "c"
        let isSpace = modifierFlags.isEmpty && event.charactersIgnoringModifiers == " "
        let isEscape = modifierFlags.isEmpty && event.charactersIgnoringModifiers == "\u{1B}"
        let isRemove = modifierFlags.isEmpty
            && (event.charactersIgnoringModifiers == "\u{7F}" || event.charactersIgnoringModifiers == "\u{8}")

        if isCopy, copyCurrentSelectionToPasteboard() {
            return true
        }

        if isRemove, removeCurrentSelectionFromShelf() {
            return true
        }

        if isSpace {
            guard let window, window.frame.contains(NSEvent.mouseLocation) else {
                return super.performKeyEquivalent(with: event)
            }

            if isExpanded {
                return quickLookCurrentSelectionToPanel()
            }

            if !urls.isEmpty {
                toggleStackOverview()
                return true
            }
        }

        if isEscape, isStackOverview {
            setStackOverview(false)
            return true
        }

        if isEscape {
            onRequestCollapse?()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        if isBallPresentation {
            return ballPresentationMenu()
        }
        guard !existing(urls).isEmpty else { return nil }

        let menu = NSMenu()
        let point = convert(event.locationInWindow, from: nil)

        if isExpanded, let rowURL = rowHit(at: point) {
            selectedURL = rowURL
            needsDisplay = true

            let quickLookSelectedItem = NSMenuItem(title: "Quick Look This File", action: #selector(quickLookCurrentSelection(_:)), keyEquivalent: "")
            quickLookSelectedItem.target = self
            menu.addItem(quickLookSelectedItem)

            let copySelectedItem = NSMenuItem(title: "Copy This File", action: #selector(copyCurrentSelection(_:)), keyEquivalent: "")
            copySelectedItem.target = self
            menu.addItem(copySelectedItem)

            let removeSelectedItem = NSMenuItem(title: "Remove This File from Shelf", action: #selector(removeCurrentSelection(_:)), keyEquivalent: "")
            removeSelectedItem.target = self
            menu.addItem(removeSelectedItem)

            menu.addItem(.separator())

            let quickLookAllItem = NSMenuItem(title: "Quick Look All Files", action: #selector(quickLookAllFiles(_:)), keyEquivalent: "")
            quickLookAllItem.target = self
            menu.addItem(quickLookAllItem)

            let copyAllItem = NSMenuItem(title: "Copy All Files", action: #selector(copyAllFiles(_:)), keyEquivalent: "")
            copyAllItem.target = self
            menu.addItem(copyAllItem)
        } else if isStackOverview, let itemURL = overviewItemHit(at: point) {
            selectedURL = itemURL
            hoveredURL = itemURL
            needsDisplay = true

            let quickLookSelectedItem = NSMenuItem(title: "Quick Look This File", action: #selector(quickLookCurrentSelection(_:)), keyEquivalent: "")
            quickLookSelectedItem.target = self
            menu.addItem(quickLookSelectedItem)

            let removeSelectedItem = NSMenuItem(title: "Remove This File from Shelf", action: #selector(removeCurrentSelection(_:)), keyEquivalent: "")
            removeSelectedItem.target = self
            menu.addItem(removeSelectedItem)

            menu.addItem(.separator())

            let copyAllItem = NSMenuItem(title: "Copy All Files", action: #selector(copyAllFiles(_:)), keyEquivalent: "")
            copyAllItem.target = self
            menu.addItem(copyAllItem)
        } else {
            let overviewTitle = isStackOverview ? "Collapse Overview" : "Show Overview"
            let overviewItem = NSMenuItem(title: overviewTitle, action: #selector(toggleStackOverviewFromMenu(_:)), keyEquivalent: "")
            overviewItem.target = self
            menu.addItem(overviewItem)

            let copyItem = NSMenuItem(title: "Copy All Files", action: #selector(copyAllFiles(_:)), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
        }

        menu.addItem(.separator())

        if let entries = historyMenuItems?(), !entries.isEmpty {
            let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
            let historyMenu = NSMenu()
            for entry in entries.prefix(12) {
                let item = NSMenuItem(title: entry.title, action: #selector(restoreHistoryEntry(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.id
                historyMenu.addItem(item)
            }
            historyItem.submenu = historyMenu
            menu.addItem(historyItem)
        }

        let clearItem = NSMenuItem(title: "Clear Shelf", action: #selector(clearShelfFromMenu(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        return menu
    }

    @objc private func restoreHistoryEntry(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.representedObject as? UUID else { return }
        onRestoreHistoryEntry?(id)
    }

    // MARK: - Ball presentation menu

    private func ballPresentationMenu() -> NSMenu {
        let menu = NSMenu()

        let count = urls.count
        let statusTitle = count == 0
            ? "Shake Shelf"
            : "Shake Shelf — \(count) item\(count == 1 ? "" : "s") on shelf"
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open Shelf", action: #selector(openShelfFromBallMenu(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let reset = NSMenuItem(title: "Reset Ball to Corner", action: #selector(resetBallHomeFromMenu(_:)), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Shake Shelf", action: #selector(quitFromBallMenu(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        presentedBallMenu = menu
        menu.delegate = self
        onBallMenuWillPresent?()
        return menu
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === presentedBallMenu else { return }
        presentedBallMenu = nil
        onBallMenuDidDismiss?()
    }

    @objc private func openShelfFromBallMenu(_ sender: Any?) {
        onBallClicked?()
    }

    @objc private func resetBallHomeFromMenu(_ sender: Any?) {
        onBallResetHome?()
    }

    @objc private func quitFromBallMenu(_ sender: Any?) {
        onBallMenuQuit?()
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    private func geometryDescription() -> String {
        let shelfSize = frame.size
        let backdropSize = superview?.bounds.size ?? .zero
        let windowSize = window?.frame.size ?? .zero
        let contentSize = window?.contentView?.bounds.size ?? .zero
        return "shelf=\(Int(shelfSize.width))x\(Int(shelfSize.height)) backdrop=\(Int(backdropSize.width))x\(Int(backdropSize.height)) window=\(Int(windowSize.width))x\(Int(windowSize.height)) content=\(Int(contentSize.width))x\(Int(contentSize.height))"
    }

    private func renderedDarkPixelCount() -> Int {
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return 0 }
        cacheDisplay(in: bounds, to: bitmap)
        var darkSamples = 0
        let width = bitmap.pixelsWide
        let height = bitmap.pixelsHigh

        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let luminance = 0.299 * color.redComponent + 0.587 * color.greenComponent + 0.114 * color.blueComponent
                if luminance < 0.35 {
                    darkSamples += 1
                }
            }
        }

        return darkSamples
    }

    // MARK: - Smoke test

    func runSmokeTest(completion: @escaping (Bool, [String]) -> Void) {
        var steps: [String] = []
        var allPassed = true

        func step(_ name: String, _ condition: Bool) {
            allPassed = allPassed && condition
            steps.append("\(condition ? "PASS" : "FAIL"): \(name)")
        }

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShakeShelfSmoke-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let fileURLs = (0..<8).map { index in
            let url = tempDirectory.appendingPathComponent("smoke-\(index).txt")
            try? Data("content-\(index)".utf8).write(to: url)
            return url
        }

        let materialIsBehindContent = !subviews.contains(where: { $0 is NSVisualEffectView })
            && superview != nil
        step("shelf content renders above material", materialIsBehindContent)

        let emptyStateDarkPixels = renderedDarkPixelCount()
        steps.append("INFO: empty state dark pixel samples: \(emptyStateDarkPixels)")

        add(fileURLs)
        step("add 8 items", urls.count == 8)
        add(fileURLs)
        step("dedupe on re-add", urls.count == 8)

        display()
        steps.append("INFO: stack mode dark pixel samples: \(renderedDarkPixelCount())")
        toggleStackOverview()
        step("overview opens", isStackOverview == true)
        steps.append("INFO: after overview expand sync: \(geometryDescription())")
        display()
        steps.append("INFO: overview dark pixel samples: \(renderedDarkPixelCount())")
        setStackOverview(false)
        step("overview collapses", isStackOverview == false)
        steps.append("INFO: after overview collapse sync: \(geometryDescription())")
        for delay in [0.1, 0.2, 0.3, 0.5] {
            let d = delay
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in
                guard let self else { return }
                self.stepsForSampling.append("INFO: collapse t=\(d): \(self.geometryDescription())")
            }
        }

        isExpanded = true
        requestPreferredSizeUpdate()
        step("list mode opens", isExpanded == true)
        display()

        let removed = removeFromShelf(fileURLs[0])
        step("remove single item", removed == true && urls.count == 7)

        let copied = copyAllFilesToPasteboard()
        step("copy all to pasteboard", copied == true)

        let quickLookOpened = quickLookAllFilesToPanel()
        step("quick look opens", quickLookOpened == true)
        onRequestCloseQuickLook?()

        setStackOverview(false)
        isExpanded = false
        requestPreferredSizeUpdate()
        display()

        let hadPersistence = UserDefaults.standard.bool(forKey: "persistItemsAcrossRelaunch")
        UserDefaults.standard.set(true, forKey: "persistItemsAcrossRelaunch")
        schedulePersist()

        let expectedPersisted = Set(fileURLs.dropFirst().map(\.lastPathComponent))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let geometry = self.geometryDescription()
            steps.append("INFO: geometry after collapse: \(geometry)")

            let backdropSize = self.superview?.bounds.size ?? .zero
            let shelfSize = self.frame.size
            step("shelf view fills backdrop after collapse", shelfSize == backdropSize)

            let windowSize = self.window?.frame.size ?? .zero
            let contentSize = self.window?.contentView?.bounds.size ?? .zero
            step("backdrop fills window after collapse", contentSize == windowSize)

            let persisted = Set(self.itemPersistence.load().map(\.lastPathComponent))
            step("persist round trip", persisted == expectedPersisted)

            if !hadPersistence {
                UserDefaults.standard.set(false, forKey: "persistItemsAcrossRelaunch")
            }

            self.clearShelfContents()
            step("clear shelf", self.urls.isEmpty)

            try? FileManager.default.removeItem(at: tempDirectory)
            completion(allPassed, steps + self.stepsForSampling)
        }
    }

    // MARK: - Ball interaction animation

    func setBallDwellActive(_ active: Bool) {
        guard ballDwellGlowActive != active else { return }
        ballDwellGlowActive = active
        guard let layer = layer else { return }

        layer.removeAnimation(forKey: "ballPulse")
        layer.removeAnimation(forKey: "ballPress")
        layer.removeAnimation(forKey: "ballDwellGlow")

        if active {
            let glow = CABasicAnimation(keyPath: "transform.scale")
            glow.fromValue = 1.0
            glow.toValue = 1.09
            glow.duration = 0.12
            glow.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glow.fillMode = .forwards
            glow.isRemovedOnCompletion = false
            layer.add(glow, forKey: "ballDwellGlow")
        } else {
            let settleBack = CABasicAnimation(keyPath: "transform.scale")
            settleBack.fromValue = (layer.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue ?? 1.0
            settleBack.toValue = 1.0
            settleBack.duration = 0.18
            settleBack.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(settleBack, forKey: "ballDwellGlow")
        }
    }

    private func animateBallPressScale(_ scale: CGFloat, duration: TimeInterval) {
        guard let layer = layer else { return }
        layer.removeAnimation(forKey: "ballPulse")
        layer.removeAnimation(forKey: "ballDwellGlow")
        ballDwellGlowActive = false

        let press = CABasicAnimation(keyPath: "transform.scale")
        press.fromValue = (layer.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue ?? 1.0
        press.toValue = scale
        press.duration = duration
        press.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(press, forKey: "ballPress")
    }

    private func animateBallRelease() {
        guard let layer = layer else { return }
        layer.removeAnimation(forKey: "ballPress")
        layer.removeAnimation(forKey: "ballPulse")

        let release = CABasicAnimation(keyPath: "transform.scale")
        release.fromValue = (layer.presentation()?.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue ?? 0.96
        release.toValue = 1.0
        release.duration = 0.22
        release.timingFunction = CAMediaTimingFunction(controlPoints: 0.34, 1.56, 0.64, 1.0)
        layer.add(release, forKey: "ballPress")
    }

    // MARK: - Item management

    private func add(_ newURLs: [URL]) {
        let accepted = items.add(newURLs)
        guard !accepted.isEmpty else { return }
        isExpanded = false
        isStackOverview = false
        listScrollOffset = 0
        selectedURL = nil
        hoveredURL = nil
        hoveredHeaderControl = nil
        requestPreferredSizeUpdate()
        invalidateInteractionState()
        schedulePersist()
        onContentsChanged?(urls)
    }

    func replaceContents(with newURLs: [URL]) {
        clearShelfContents()
        add(newURLs)
    }

    func appendContents(with newURLs: [URL]) {
        add(newURLs)
    }

    private func clearShelfContents() {
        onContentsWillClear?(urls)

        items.clear()
        isExpanded = false
        isStackOverview = false
        listScrollOffset = 0
        pendingDragURLs = []
        pendingExternalDrops = 0
        windowDragState = nil
        selectedURL = nil
        hoveredURL = nil
        hoveredHeaderControl = nil
        copyStatus = nil
        copyStatusToken = nil
        receiveGeneration = UUID()
        previewGeneration = UUID()
        previewCache.removeAll()
        previewCacheKeys.removeAll()
        pendingQuickLookKeys.removeAll()
        failedQuickLookKeys.removeAll()
        quickLookSource.update(with: [])
        onRequestCloseQuickLook?()
        requestPreferredSizeUpdate()
        invalidateInteractionState()
        schedulePersist()
        onContentsChanged?(urls)
    }

    @discardableResult
    private func removeFromShelf(_ url: URL) -> Bool {
        guard items.remove(url) else { return false }

        pendingDragURLs.removeAll { sameFileURL($0, url) }
        if sameFileURL(selectedURL, url) {
            selectedURL = nil
        }
        if sameFileURL(hoveredURL, url) {
            hoveredURL = nil
        }

        quickLookSource.update(with: existing(urls))

        if urls.isEmpty {
            isExpanded = false
            isStackOverview = false
            listScrollOffset = 0
        } else if isStackOverview, urls.count == 1 {
            isStackOverview = false
        }

        requestPreferredSizeUpdate()
        invalidateInteractionState()
        schedulePersist()
        onContentsChanged?(urls)
        return true
    }

    private func existing(_ urls: [URL]) -> [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func schedulePersist() {
        persistenceSaveWorkItem?.cancel()

        guard ShakeShelfSettings.load().persistItemsAcrossRelaunch else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            do {
                try self.itemPersistence.save(self.urls)
            } catch {
                NSLog("Shake Shelf failed to persist items: \(error.localizedDescription)")
            }
        }
        persistenceSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: workItem)
    }

    private func invalidateInteractionState() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Layout geometry

    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - 40, y: 12, width: 24, height: 24)
    }

    private var historyRect: NSRect {
        NSRect(x: bounds.maxX - 108, y: 12, width: 24, height: 24)
    }

    private var toggleRect: NSRect {
        NSRect(x: bounds.maxX - 74, y: 12, width: 24, height: 24)
    }

    private var headerDragRect: NSRect {
        NSRect(x: 12, y: 6, width: bounds.width - 128, height: 38)
    }

    private var stackRect: NSRect {
        NSRect(x: bounds.midX - 76, y: 70, width: 152, height: 100)
    }

    private var stackInteractionRect: NSRect {
        if isStackOverview {
            return overviewGridRect.insetBy(dx: -12, dy: -12)
        }

        return NSRect(x: 40, y: 42, width: bounds.width - 80, height: 132)
    }

    private var listViewportRect: NSRect {
        NSRect(x: 16, y: 48, width: bounds.width - 32, height: max(0, bounds.height - 62))
    }

    private var overviewGridRect: NSRect {
        NSRect(x: 22, y: 54, width: bounds.width - 44, height: max(0, bounds.height - 102))
    }

    private func rowRects() -> [(URL, NSRect)] {
        let viewport = listViewportRect
        let scrollOffset = clampedListScrollOffset()

        return urls.enumerated().map { index, url in
            let y = ShelfListScroll.rowY(
                index: index,
                startY: Double(viewport.minY),
                scrollOffset: Double(scrollOffset),
                rowHeight: Double(listRowHeight),
                rowSpacing: Double(listRowSpacing)
            )
            let rect = NSRect(
                x: viewport.minX,
                y: CGFloat(y),
                width: viewport.width,
                height: listRowHeight
            )
            return (url, rect)
        }
    }

    private func rowHit(at point: CGPoint) -> URL? {
        guard listViewportRect.contains(point) else { return nil }
        return rowRects().first { $0.1.contains(point) }?.0
    }

    private func overviewItemRects() -> [(URL, NSRect)] {
        let columns = ShelfOverviewGrid.columns(forItemCount: urls.count)
        let rows = ShelfOverviewGrid.rows(forItemCount: urls.count, columns: columns)
        guard columns > 0, rows > 0 else { return [] }

        let spacing: CGFloat = 12
        let gridRect = overviewGridRect
        let availableCardWidth = (gridRect.width - (CGFloat(columns - 1) * spacing)) / CGFloat(columns)
        let availableCardHeight = (gridRect.height - (CGFloat(rows - 1) * spacing)) / CGFloat(rows)
        let cardSize = max(34, min(82, availableCardWidth, availableCardHeight))
        let totalWidth = (CGFloat(columns) * cardSize) + (CGFloat(columns - 1) * spacing)
        let totalHeight = (CGFloat(rows) * cardSize) + (CGFloat(rows - 1) * spacing)
        let startX = gridRect.midX - (totalWidth / 2)
        let startY = gridRect.midY - (totalHeight / 2)

        return urls.enumerated().map { index, url in
            let column = index % columns
            let row = index / columns
            let rect = NSRect(
                x: startX + CGFloat(column) * (cardSize + spacing),
                y: startY + CGFloat(row) * (cardSize + spacing),
                width: cardSize,
                height: cardSize
            )

            return (url, rect)
        }
    }

    private func overviewItemHit(at point: CGPoint) -> URL? {
        guard overviewGridRect.insetBy(dx: -12, dy: -12).contains(point) else { return nil }
        return overviewItemRects().first { $0.1.contains(point) }?.0
    }

    private func listRemoveButtonRect(for rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - 27, y: rect.midY - 9, width: 18, height: 18)
    }

    private func overviewRemoveButtonRect(for rect: NSRect) -> NSRect {
        NSRect(x: rect.maxX - 13, y: rect.minY - 5, width: 20, height: 20)
    }

    private func removeButtonHit(at point: CGPoint) -> URL? {
        if isExpanded {
            for (url, rect) in rowRects() where rect.intersects(listViewportRect) && shouldShowRemoveButton(for: url) {
                if listRemoveButtonRect(for: rect).contains(point) {
                    return url
                }
            }
        } else if isStackOverview {
            for (url, rect) in overviewItemRects() where shouldShowRemoveButton(for: url) {
                if overviewRemoveButtonRect(for: rect).contains(point) {
                    return url
                }
            }
        }

        return nil
    }

    // MARK: - Hover tracking

    private func updateHover(at point: CGPoint) {
        if isExpanded {
            setHoveredURL(rowHit(at: point))
        } else if isStackOverview {
            setHoveredURL(overviewItemHit(at: point))
        } else {
            setHoveredURL(nil)
        }

        let newControl: HeaderControl?
        if closeRect.contains(point) {
            newControl = .close
        } else if toggleRect.contains(point), urls.count > 1 {
            newControl = .toggle
        } else if historyRect.contains(point) {
            newControl = .history
        } else {
            newControl = nil
        }
        setHoveredHeaderControl(newControl)
    }

    private func setHoveredURL(_ url: URL?) {
        guard !sameFileURL(hoveredURL, url) else { return }
        hoveredURL = url
        needsDisplay = true
    }

    private func setHoveredHeaderControl(_ control: HeaderControl?) {
        guard hoveredHeaderControl != control else { return }
        hoveredHeaderControl = control
        needsDisplay = true
    }

    private func shouldShowRemoveButton(for url: URL) -> Bool {
        sameFileURL(selectedURL, url) || sameFileURL(hoveredURL, url)
    }

    private func sameFileURL(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs else {
            return lhs == nil && rhs == nil
        }

        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    // MARK: - List scrolling

    private func maxListScrollOffset() -> CGFloat {
        CGFloat(ShelfListScroll.maxOffset(
            itemCount: urls.count,
            viewportHeight: Double(listViewportRect.height),
            rowHeight: Double(listRowHeight),
            rowSpacing: Double(listRowSpacing)
        ))
    }

    private func clampedListScrollOffset(for offset: CGFloat? = nil) -> CGFloat {
        CGFloat(ShelfListScroll.clampedOffset(
            Double(offset ?? listScrollOffset),
            itemCount: urls.count,
            viewportHeight: Double(listViewportRect.height),
            rowHeight: Double(listRowHeight),
            rowSpacing: Double(listRowSpacing)
        ))
    }

    private func clampListScrollOffset() {
        listScrollOffset = clampedListScrollOffset()
    }

    // MARK: - Overview toggling

    private func toggleStackOverview() {
        setStackOverview(!isStackOverview)
    }

    private func setStackOverview(_ isActive: Bool) {
        guard isStackOverview != isActive else { return }
        isStackOverview = isActive
        isExpanded = false
        selectedURL = nil
        hoveredURL = nil
        listScrollOffset = 0
        requestPreferredSizeUpdate()
        invalidateInteractionState()
    }

    private func requestPreferredSizeUpdate() {
        onPreferredSizeChange?(preferredSize)
    }

    private func overviewSize(forItemCount itemCount: Int) -> NSSize {
        let columns = CGFloat(ShelfOverviewGrid.columns(forItemCount: itemCount))
        let rows = CGFloat(ShelfOverviewGrid.rows(forItemCount: itemCount, columns: Int(columns)))
        let cardSize: CGFloat

        switch itemCount {
        case ...8:
            cardSize = 74
        case 9...15:
            cardSize = 64
        default:
            cardSize = 54
        }

        let spacing: CGFloat = 12
        let width = 44 + (columns * cardSize) + (max(0, columns - 1) * spacing)
        let height = 54 + (rows * cardSize) + (max(0, rows - 1) * spacing) + 52

        return NSSize(
            width: min(620, max(Self.compactSize.width, width)),
            height: min(520, max(270, height))
        )
    }

    // MARK: - Drawing

    private func drawBackground() {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.45).setFill()
        path.fill()

        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawBall() {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        guard rect.width > 6, rect.height > 6 else { return }
        let circle = NSBezierPath(ovalIn: rect)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = rect.width / 2

        let metal = NSGradient(colors: [
            NSColor(calibratedWhite: 0.99, alpha: 0.97),
            NSColor(calibratedWhite: 0.86, alpha: 0.95),
            NSColor(calibratedWhite: 0.62, alpha: 0.93)
        ])
        metal?.draw(in: circle, relativeCenterPosition: NSPoint(x: -0.42, y: 0.48))

        NSGraphicsContext.saveGraphicsState()
        circle.addClip()

        func hubPoint(angle: CGFloat, factor: CGFloat) -> NSPoint {
            NSPoint(
                x: center.x + cos(angle) * radius * factor,
                y: center.y + sin(angle) * radius * factor
            )
        }

        // embossed blade seams: dark ridge + light ridge per flap
        let darkSeams = NSBezierPath()
        let lightSeams = NSBezierPath()
        darkSeams.lineWidth = 0.8
        lightSeams.lineWidth = 0.7

        for index in 0..<8 {
            let angle = (CGFloat(index) * .pi / 4) + .pi / 8

            darkSeams.move(to: hubPoint(angle: angle - 0.035, factor: 0.30))
            darkSeams.line(to: hubPoint(angle: angle - 0.035, factor: 0.96))

            lightSeams.move(to: hubPoint(angle: angle + 0.035, factor: 0.30))
            lightSeams.line(to: hubPoint(angle: angle + 0.035, factor: 0.96))
        }

        NSColor.black.withAlphaComponent(0.15).setStroke()
        darkSeams.stroke()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        lightSeams.stroke()

        // inner depth ring near the rim
        let depthRing = NSBezierPath(ovalIn: NSRect(
            x: center.x - radius * 0.80,
            y: center.y - radius * 0.80,
            width: radius * 1.60,
            height: radius * 1.60
        ))
        depthRing.lineWidth = 1.4
        NSColor.black.withAlphaComponent(0.12).setStroke()
        depthRing.stroke()

        // iris hub
        let hubRect = NSRect(
            x: center.x - radius * 0.30,
            y: center.y - radius * 0.30,
            width: radius * 0.60,
            height: radius * 0.60
        )
        let hub = NSBezierPath(ovalIn: hubRect)
        NSColor.black.withAlphaComponent(0.10).setFill()
        hub.fill()
        hub.lineWidth = 0.7
        NSColor.white.withAlphaComponent(0.25).setStroke()
        hub.stroke()

        // soft specular arc (upper left)
        let softSpecRect = NSRect(
            x: rect.minX + rect.width * 0.14,
            y: rect.minY + rect.height * 0.50,
            width: rect.width * 0.72,
            height: rect.height * 0.38
        )
        let softSpec = NSBezierPath(ovalIn: softSpecRect)
        softSpec.lineWidth = 1.6
        NSColor.white.withAlphaComponent(0.42).setStroke()
        softSpec.stroke()

        // bright specular crescent (smaller, sharper)
        let brightSpecRect = NSRect(
            x: rect.minX + rect.width * 0.26,
            y: rect.minY + rect.height * 0.62,
            width: rect.width * 0.46,
            height: rect.height * 0.20
        )
        let brightSpec = NSBezierPath(ovalIn: brightSpecRect)
        brightSpec.lineWidth = 1.0
        NSColor.white.withAlphaComponent(0.65).setStroke()
        brightSpec.stroke()

        NSGraphicsContext.restoreGraphicsState()

        // outer rim: soft dark edge then light separator
        circle.lineWidth = 1.4
        NSColor.black.withAlphaComponent(0.25).setStroke()
        circle.stroke()

        let rim = NSBezierPath(ovalIn: rect.insetBy(dx: 0.7, dy: 0.7))
        rim.lineWidth = 0.7
        NSColor.separatorColor.withAlphaComponent(0.75).setStroke()
        rim.stroke()

        if !urls.isEmpty {
            drawBallCountBadge(urls.count)
        }
    }

    private func drawBallCountBadge(_ count: Int) {
        let diameter: CGFloat = 15
        let rect = NSRect(
            x: bounds.maxX - diameter - 1.5,
            y: bounds.minY + 1.5,
            width: diameter,
            height: diameter
        )

        let halo = NSBezierPath(ovalIn: rect.insetBy(dx: -1.2, dy: -1.2))
        NSColor.white.withAlphaComponent(0.92).setFill()
        halo.fill()

        let path = NSBezierPath(ovalIn: rect)
        NSColor.controlAccentColor.withAlphaComponent(0.96).setFill()
        path.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let text = count > 99 ? "99+" : "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: text.count > 2 ? 7.5 : 9, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        text.draw(
            in: NSRect(x: rect.minX, y: rect.minY + 3.5, width: rect.width, height: rect.height - 6),
            withAttributes: attributes
        )
    }

    private func drawEmptyState() {
        drawHeader(subtitle: "Empty")

        let dropRect = bounds.insetBy(dx: 18, dy: 58)
        let path = NSBezierPath(roundedRect: dropRect, xRadius: 16, yRadius: 16)
        NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1.2
        path.setLineDash([6, 5], count: 2, phase: 0)
        path.stroke()

        tintedSymbol(named: "tray.and.arrow.down", color: NSColor.secondaryLabelColor, size: NSSize(width: 30, height: 30))?
            .draw(in: NSRect(x: dropRect.midX - 15, y: dropRect.midY - 44, width: 30, height: 30))

        drawCentered("Drop files here", detail: "Shake a dragged file to summon", in: dropRect)
    }

    private func drawReceivingState() {
        drawHeader(subtitle: "Receiving...")

        let dropRect = bounds.insetBy(dx: 18, dy: 58)
        let path = NSBezierPath(roundedRect: dropRect, xRadius: 16, yRadius: 16)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        path.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1.2
        path.stroke()

        drawCentered("Receiving file", detail: "Keep this shelf open for a moment.", in: dropRect)
    }

    private func drawHeader(subtitle: String) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]
        "Shake Shelf".draw(at: CGPoint(x: 16, y: 17), withAttributes: titleAttributes)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let subtitleRect = NSRect(
            x: 94,
            y: 18,
            width: max(0, historyRect.minX - 112),
            height: 16
        )
        subtitle.draw(in: subtitleRect, withAttributes: detailAttributes)

        let hasHistory = !(historyMenuItems?().isEmpty ?? true)
        drawIconButton(rect: historyRect, title: "clock.arrow.circlepath", isHovered: hoveredHeaderControl == .history, isEnabled: hasHistory)

        drawIconButton(rect: closeRect, title: "xmark", isDanger: hoveredHeaderControl == .close)

        if urls.count > 1 {
            drawIconButton(rect: toggleRect, title: isExpanded ? "square.stack.3d.up" : "list.bullet", isProminent: true, isHovered: hoveredHeaderControl == .toggle)
        }
    }

    private func presentHistoryMenu() {
        let entries = historyMenuItems?() ?? []
        let menu = NSMenu()

        if let first = entries.first {
            let restoreLast = NSMenuItem(title: "Restore Last Session", action: #selector(restoreHistoryEntry(_:)), keyEquivalent: "")
            restoreLast.target = self
            restoreLast.representedObject = first.id
            menu.addItem(restoreLast)
            menu.addItem(.separator())
        }

        for entry in entries.prefix(12) {
            let item = NSMenuItem(title: entry.title, action: #selector(restoreHistoryEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            menu.addItem(item)
        }

        if !entries.isEmpty {
            menu.addItem(.separator())
        }

        let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistoryFromShelf), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        guard menu.items.count > (entries.isEmpty ? 1 : 0) else { return }

        let contentView = window?.contentView ?? self
        let point = convert(historyRect.origin, to: contentView)
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: point.x, y: point.y - historyRect.height / 2),
            in: contentView
        )
    }

    @objc private func clearHistoryFromShelf() {
        onClearHistory?()
    }

    private func drawStack() {
        drawHeader(subtitle: "\(urls.count) item\(urls.count == 1 ? "" : "s")")

        drawCompactStack()

        drawBadge("\(urls.count)", at: CGPoint(x: stackRect.maxX - 18, y: stackRect.minY - 8))
        drawCentered(
            copyStatus ?? "Drag the stack to move all files",
            detail: copyStatus == nil ? "Space overview · List · Cmd-C copies" : "Paste in Finder with Cmd-V.",
            in: NSRect(x: 16, y: bounds.maxY - 52, width: bounds.width - 32, height: 36)
        )
    }

    private func drawStackOverview() {
        drawHeader(subtitle: "Overview")
        drawOverviewGrid()

        drawCentered(
            "Space to collapse",
            detail: "Drag a tile for one file · List keeps Quick Look",
            in: NSRect(x: 16, y: bounds.maxY - 48, width: bounds.width - 32, height: 32)
        )
    }

    private func drawCompactStack() {
        for (index, url) in Array(urls.prefix(5)).enumerated().reversed() {
            let offset = CGFloat(index) * 6
            let rect = stackRect.offsetBy(dx: offset, dy: -offset).insetBy(dx: 10, dy: 8)

            if index == 0 {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
                shadow.shadowBlurRadius = 10
                shadow.shadowOffset = NSSize(width: 0, height: -2)
                shadow.set()
                drawStackCard(for: url, in: rect, previewInset: NSSize(width: 14, height: 12))
                NSGraphicsContext.restoreGraphicsState()
            } else {
                drawStackCard(for: url, in: rect, previewInset: NSSize(width: 14, height: 12))
            }
        }
    }

    private func drawStackCard(for url: URL, in rect: NSRect, previewInset: NSSize) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSColor.windowBackgroundColor.withAlphaComponent(0.55).setFill()
        path.fill()

        let highlight = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 13.5, yRadius: 13.5)
        NSColor.white.withAlphaComponent(0.10).setStroke()
        highlight.lineWidth = 0.75
        highlight.stroke()

        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()

        drawPreview(for: url, in: rect.insetBy(dx: previewInset.width, dy: previewInset.height), cornerRadius: 10)
    }

    private func drawOverviewGrid() {
        for (url, rect) in overviewItemRects() {
            if sameFileURL(hoveredURL, url), !sameFileURL(selectedURL, url) {
                drawStackCard(for: url, in: rect.insetBy(dx: -3, dy: -3), previewInset: NSSize(width: 7, height: 7))

                let hoverRing = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 17, yRadius: 17)
                NSColor.controlAccentColor.withAlphaComponent(0.35).setStroke()
                hoverRing.lineWidth = 1.2
                hoverRing.stroke()
            } else {
                drawStackCard(for: url, in: rect, previewInset: NSSize(width: 6, height: 6))
            }

            if shouldShowRemoveButton(for: url) {
                let selectionPath = NSBezierPath(roundedRect: rect.insetBy(dx: -2, dy: -2), xRadius: 16, yRadius: 16)
                NSColor.controlAccentColor.withAlphaComponent(0.74).setStroke()
                selectionPath.lineWidth = 1.2
                selectionPath.stroke()

                drawRemoveButton(
                    in: overviewRemoveButtonRect(for: rect),
                    isHighlighted: sameFileURL(hoveredURL, url)
                )
            }
        }
    }

    private func drawExpandedList() {
        drawHeader(subtitle: "List")
        clampListScrollOffset()

        let viewport = listViewportRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: viewport).addClip()

        for (url, rect) in rowRects() where rect.intersects(viewport) {
            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)

            if selectedURL == url {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            } else if sameFileURL(hoveredURL, url) {
                NSColor.windowBackgroundColor.withAlphaComponent(0.72).setFill()
            } else {
                NSColor.windowBackgroundColor.withAlphaComponent(0.35).setFill()
            }
            path.fill()

            if selectedURL == url {
                NSColor.controlAccentColor.withAlphaComponent(0.70).setStroke()
                path.lineWidth = 1
                path.stroke()
            }

            drawPreview(for: url, in: NSRect(x: rect.minX + 8, y: rect.minY + 6, width: 22, height: 22), cornerRadius: 4)

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingMiddle

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
            url.lastPathComponent.draw(
                in: NSRect(x: rect.minX + 38, y: rect.minY + 9, width: rect.width - 74, height: 18),
                withAttributes: attributes
            )

            if shouldShowRemoveButton(for: url) {
                drawRemoveButton(
                    in: listRemoveButtonRect(for: rect),
                    isHighlighted: sameFileURL(hoveredURL, url)
                )
            }
        }

        NSGraphicsContext.restoreGraphicsState()
        drawListScrollIndicator(in: viewport)
    }

    private func drawListScrollIndicator(in viewport: NSRect) {
        let maxOffset = maxListScrollOffset()
        guard maxOffset > 0 else { return }

        let track = NSRect(x: viewport.maxX - 4, y: viewport.minY + 3, width: 2, height: viewport.height - 6)
        let thumbHeight = max(22, track.height * (viewport.height / (viewport.height + maxOffset)))
        let travel = max(0, track.height - thumbHeight)
        let thumbY = track.minY + (listScrollOffset / maxOffset) * travel
        let thumb = NSRect(x: track.minX, y: thumbY, width: track.width, height: thumbHeight)

        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()

        NSColor.secondaryLabelColor.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: 1, yRadius: 1).fill()
    }

    private func drawIconButton(rect: NSRect, title: String, isProminent: Bool = false, isHovered: Bool = false, isDanger: Bool = false, isEnabled: Bool = true) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)

        if isDanger {
            NSColor.systemRed.withAlphaComponent(0.14).setFill()
        } else if isProminent {
            NSColor.controlAccentColor.withAlphaComponent(isHovered ? 0.34 : 0.22).setFill()
        } else {
            NSColor.windowBackgroundColor.withAlphaComponent(isHovered ? 0.90 : 0.72).setFill()
        }
        path.fill()

        let strokeColor: NSColor
        if isDanger {
            strokeColor = NSColor.systemRed.withAlphaComponent(0.85)
        } else if isProminent {
            strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.85)
        } else {
            strokeColor = NSColor.separatorColor.withAlphaComponent(0.45)
        }
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let symbolColor: NSColor
        if isDanger {
            symbolColor = NSColor.systemRed
        } else if isProminent {
            symbolColor = NSColor.controlAccentColor
        } else if isEnabled {
            symbolColor = NSColor.labelColor
        } else {
            symbolColor = NSColor.secondaryLabelColor.withAlphaComponent(0.5)
        }
        tintedSymbol(named: title, color: symbolColor, size: NSSize(width: 13, height: 13))?
            .draw(in: rect.insetBy(dx: 5.5, dy: 5.5))
    }

    private func drawRemoveButton(in rect: NSRect, isHighlighted: Bool) {
        let path = NSBezierPath(ovalIn: rect)
        let fillColor = isHighlighted
            ? NSColor.systemRed.withAlphaComponent(0.90)
            : NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        fillColor.setFill()
        path.fill()

        let strokeColor = isHighlighted
            ? NSColor.systemRed.withAlphaComponent(0.96)
            : NSColor.systemRed.withAlphaComponent(0.62)
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let symbolColor = isHighlighted ? NSColor.white : NSColor.systemRed
        tintedSymbol(named: "xmark", color: symbolColor, size: NSSize(width: 8, height: 8))?
            .draw(in: rect.insetBy(dx: 5, dy: 5))
    }

    private func tintedSymbol(named name: String, color: NSColor, size: NSSize) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }

        symbol.size = size

        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        symbol.draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .destinationIn,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }

    private func drawBadge(_ text: String, at point: CGPoint) {
        let rect = NSRect(x: point.x, y: point.y, width: 34, height: 22)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.controlAccentColor.setFill()
        path.fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        text.draw(in: rect.insetBy(dx: 4, dy: 3), withAttributes: attributes)
    }

    private func drawCentered(_ title: String, detail: String, in rect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]

        title.draw(in: NSRect(x: rect.minX + 8, y: rect.midY - 18, width: rect.width - 16, height: 18), withAttributes: titleAttributes)
        detail.draw(in: NSRect(x: rect.minX + 8, y: rect.midY + 2, width: rect.width - 16, height: 16), withAttributes: detailAttributes)
    }

    // MARK: - Previews

    private func drawPreview(for url: URL, in rect: NSRect, cornerRadius: CGFloat) {
        let preview = preview(for: url)
        let drawRect = aspectFitRect(for: preview.image.size, in: rect)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .high

        if preview.isThumbnail {
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
            NSColor.black.withAlphaComponent(0.08).setFill()
            NSBezierPath(rect: rect).fill()
        }

        preview.image.draw(
            in: drawRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )

        NSGraphicsContext.restoreGraphicsState()
    }

    private func preview(for url: URL) -> FilePreview {
        let key = previewCacheKey(for: url)
        if let cached = previewCache[key] {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let preview = FilePreview(image: icon, isThumbnail: false)
        cachePreview(key, preview)

        if isImageFile(url) {
            requestImageThumbnail(for: url, cacheKey: key)
        } else {
            requestQuickLookThumbnail(for: url, cacheKey: key)
        }

        return preview
    }

    private func requestImageThumbnail(for url: URL, cacheKey: String) {
        guard !pendingQuickLookKeys.contains(cacheKey), !failedQuickLookKeys.contains(cacheKey) else {
            return
        }

        pendingQuickLookKeys.insert(cacheKey)
        let generation = previewGeneration

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = ImageThumbnailResult(image: Self.downsampledImage(for: url, maxPixelSize: 512))

            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.previewGeneration else { return }
                self.pendingQuickLookKeys.remove(cacheKey)

                guard let image = result.image else {
                    self.failedQuickLookKeys.insert(cacheKey)
                    return
                }

                self.cachePreview(cacheKey, FilePreview(image: image, isThumbnail: true))
                self.needsDisplay = true
            }
        }
    }

    private func cachePreview(_ key: String, _ preview: FilePreview) {
        if let index = previewCacheKeys.firstIndex(of: key) {
            previewCacheKeys.remove(at: index)
        }
        previewCacheKeys.append(key)
        previewCache[key] = preview

        if previewCacheKeys.count > previewCacheLimit {
            let overflow = previewCacheKeys.count - previewCacheLimit
            for staleKey in previewCacheKeys.prefix(overflow) {
                previewCache.removeValue(forKey: staleKey)
            }
            previewCacheKeys.removeFirst(overflow)
        }
    }

    private func requestQuickLookThumbnail(for url: URL, cacheKey: String) {
        guard !pendingQuickLookKeys.contains(cacheKey), !failedQuickLookKeys.contains(cacheKey) else {
            return
        }

        pendingQuickLookKeys.insert(cacheKey)
        let generation = previewGeneration

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: NSSize(width: 240, height: 180),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, error in
            let result = QuickLookThumbnailResult(image: representation?.nsImage, failed: error != nil)

            DispatchQueue.main.async { [weak self] in
                guard let self, generation == self.previewGeneration else { return }
                self.pendingQuickLookKeys.remove(cacheKey)

                guard !result.failed, let image = result.image else {
                    self.failedQuickLookKeys.insert(cacheKey)
                    return
                }

                self.cachePreview(cacheKey, FilePreview(image: image, isThumbnail: true))
                self.needsDisplay = true
            }
        }
    }

    private func previewCacheKey(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modifiedAt = values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
        let fileSize = values?.fileSize ?? 0
        return "\(url.standardizedFileURL.path)#\(modifiedAt)#\(fileSize)"
    }

    private func isImageFile(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }

        switch url.pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp":
            return true
        default:
            return false
        }
    }

    nonisolated private static func downsampledImage(for url: URL, maxPixelSize: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    private func aspectFitRect(for imageSize: NSSize, in rect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }

        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Drop handling

    private func readFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let modern = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [NSURL] ?? []).map { $0 as URL }

        let legacy = (pasteboard.propertyList(forType: filenamesPasteboardType) as? [String] ?? [])
            .map(URL.init(fileURLWithPath:))

        var seen: Set<String> = []
        return (modern + legacy).filter { url in
            guard url.isFileURL else { return false }
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private func canReadDrop(from pasteboard: NSPasteboard) -> Bool {
        !readFilePromises(from: pasteboard).isEmpty
            || !readFileURLs(from: pasteboard).isEmpty
            || !rawImagePayloads(from: pasteboard).isEmpty
    }

    private func readFilePromises(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    private func receivePromisedFiles(_ promises: [NSFilePromiseReceiver]) -> Bool {
        do {
            let destination = try externalFileStore.ensureBaseDirectory()
            let generation = receiveGeneration
            pendingExternalDrops += promises.count
            needsDisplay = true

            for promise in promises {
                promise.receivePromisedFiles(
                    atDestination: destination,
                    options: [:],
                    operationQueue: .main
                ) { [weak self] url, error in
                    if let error {
                        NSLog("Shake Shelf failed to receive promised file: \(error.localizedDescription)")
                    }

                    let receivedURL = error == nil ? url.standardizedFileURL : nil
                    self?.finishReceivingPromisedFile(receivedURL, generation: generation)
                }
            }

            return true
        } catch {
            NSLog("Shake Shelf failed to create promised-file destination: \(error.localizedDescription)")
            return false
        }
    }

    private func finishReceivingPromisedFile(_ url: URL?, generation: UUID) {
        guard generation == receiveGeneration else { return }
        pendingExternalDrops = max(0, pendingExternalDrops - 1)

        if let url {
            add([url])
        } else {
            needsDisplay = true
        }
    }

    private func storeRawImages(from pasteboard: NSPasteboard) -> [URL] {
        rawImagePayloads(from: pasteboard).compactMap { payload in
            do {
                return try externalFileStore.store(
                    data: payload.data,
                    preferredExtension: payload.pathExtension,
                    suggestedName: "Dropped Image"
                )
            } catch {
                NSLog("Shake Shelf failed to store raw image drop: \(error.localizedDescription)")
                return nil
            }
        }
    }

    private func rawImagePayloads(from pasteboard: NSPasteboard) -> [(data: Data, pathExtension: String)] {
        let acceptedTypes: [(type: NSPasteboard.PasteboardType, pathExtension: String)] = [
            (.png, "png"),
            (.tiff, "tiff")
        ]

        return pasteboard.pasteboardItems?.compactMap { item in
            for acceptedType in acceptedTypes {
                guard let type = item.availableType(from: [acceptedType.type]),
                      let data = item.data(forType: type),
                      !data.isEmpty else {
                    continue
                }

                return (data, acceptedType.pathExtension)
            }

            return nil
        } ?? []
    }

    private func logUnsupportedDrop(from pasteboard: NSPasteboard) {
        let types = pasteboard.types?.map(\.rawValue).joined(separator: ", ") ?? "none"
        let itemTypes = pasteboard.pasteboardItems?
            .map { item in item.types.map(\.rawValue).joined(separator: "|") }
            .joined(separator: ", ") ?? "none"
        NSLog("Shake Shelf unsupported drop. Pasteboard types: \(types). Item types: \(itemTypes)")
    }

    // MARK: - Copy / Quick Look / Remove

    @discardableResult
    private func copyCurrentSelectionToPasteboard() -> Bool {
        let existingURLs = existing(urls)
        let existingSelectedURL = selectedURL.flatMap { selected in
            existingURLs.contains(selected) ? selected : nil
        }
        let fileURLs = ShelfCopyResolver.urlsToCopy(
            allURLs: existingURLs,
            selectedURL: existingSelectedURL,
            isExpanded: isExpanded
        )

        return copyToPasteboard(fileURLs)
    }

    private func copyAllFilesToPasteboard() -> Bool {
        copyToPasteboard(existing(urls))
    }

    private func copyToPasteboard(_ fileURLs: [URL]) -> Bool {
        guard !fileURLs.isEmpty else { return false }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        guard pasteboard.writeObjects(fileURLs.map { $0 as NSURL }) else {
            return false
        }

        showCopyConfirmation(fileCount: fileURLs.count)
        return true
    }

    @discardableResult
    private func quickLookCurrentSelectionToPanel() -> Bool {
        let existingURLs = existing(urls)
        let existingSelectedURL = selectedURL.flatMap { selected in
            existingURLs.contains(selected) ? selected : nil
        }
        let previewURLs = ShelfQuickLookResolver.urlsToPreview(
            allURLs: existingURLs,
            selectedURL: existingSelectedURL,
            isExpanded: isExpanded
        )

        return quickLook(previewURLs)
    }

    private func quickLookAllFilesToPanel() -> Bool {
        quickLook(existing(urls))
    }

    @discardableResult
    private func removeCurrentSelectionFromShelf() -> Bool {
        guard let selectedURL else { return false }
        return removeFromShelf(selectedURL)
    }

    private func quickLook(_ fileURLs: [URL]) -> Bool {
        guard !fileURLs.isEmpty, let panel = QLPreviewPanel.shared() else {
            return false
        }

        quickLookSource.onClose = { [weak self] in
            self?.teardownQuickLookPanel()
        }
        quickLookSource.update(with: fileURLs)
        panel.dataSource = quickLookSource
        panel.delegate = quickLookSource
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    private func teardownQuickLookPanel() {
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.delegate = nil
        panel.dataSource = nil
        quickLookSource.update(with: [])
    }

    @objc private func quickLookCurrentSelection(_ sender: Any?) {
        _ = quickLookCurrentSelectionToPanel()
    }

    @objc private func quickLookAllFiles(_ sender: Any?) {
        _ = quickLookAllFilesToPanel()
    }

    @objc private func toggleStackOverviewFromMenu(_ sender: Any?) {
        toggleStackOverview()
    }

    @objc private func copyCurrentSelection(_ sender: Any?) {
        _ = copyCurrentSelectionToPasteboard()
    }

    @objc private func copyAllFiles(_ sender: Any?) {
        _ = copyAllFilesToPasteboard()
    }

    @objc private func removeCurrentSelection(_ sender: Any?) {
        _ = removeCurrentSelectionFromShelf()
    }

    @objc private func clearShelfFromMenu(_ sender: Any?) {
        clearShelfContents()
    }

    private func showCopyConfirmation(fileCount: Int) {
        let token = UUID()
        copyStatusToken = token
        copyStatus = "Copied \(fileCount) file\(fileCount == 1 ? "" : "s")"
        needsDisplay = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.copyStatusToken == token else { return }
            self.copyStatus = nil
            self.copyStatusToken = nil
            self.needsDisplay = true
        }
    }

    private func beginDragging(urls: [URL], event: NSEvent) {
        let items = urls.enumerated().map { index, url in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let previewImage = preview(for: url).image
            let dragImage = (previewImage.copy() as? NSImage) ?? previewImage
            dragImage.size = NSSize(width: 44, height: 44)
            let offset = CGFloat(index) * 4
            item.setDraggingFrame(
                NSRect(x: 26 + offset, y: 80 - offset, width: 52, height: 52),
                contents: dragImage
            )
            return item
        }

        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .stack
    }
}

private struct QuickLookThumbnailResult: @unchecked Sendable {
    let image: NSImage?
    let failed: Bool
}

private struct ImageThumbnailResult: @unchecked Sendable {
    let image: NSImage?
}

private final class QuickLookPreviewSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private var urls: [NSURL] = []
    var onClose: (() -> Void)?

    func update(with fileURLs: [URL]) {
        urls = fileURLs.map { $0 as NSURL }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index]
    }

    func previewPanelDidClose(_ panel: QLPreviewPanel!) {
        onClose?()
    }
}
