import AppKit
import ShakeShelfCore
import UniformTypeIdentifiers

@MainActor
final class ShelfView: NSView, NSDraggingSource {
    private struct FilePreview {
        let image: NSImage
        let isThumbnail: Bool
    }

    private struct WindowDragState {
        let mouseStart: CGPoint
        let windowStart: CGPoint
    }

    private(set) var urls: [URL] = []

    private let filenamesPasteboardType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    private let cornerRadius: CGFloat = 22
    private lazy var externalFileStore = ShelfFileStore(
        baseDirectory: (try? ShelfFileStore.defaultIncomingDirectory())
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("Shake Shelf/Incoming", isDirectory: true)
    )
    private var isExpanded = false
    private var pendingDragURLs: [URL] = []
    private var pendingExternalDrops = 0
    private var windowDragState: WindowDragState?
    private var selectedURL: URL?
    private var copyStatus: String?
    private var copyStatusToken: UUID?
    private var previewCache: [String: FilePreview] = [:]

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
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 230))
        wantsLayer = true
        let promisedFileTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        registerForDraggedTypes([.fileURL, filenamesPasteboardType, .png, .tiff] + promisedFileTypes)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBackground()

        if urls.isEmpty, isReceivingExternalDrop {
            drawReceivingState()
        } else if urls.isEmpty {
            drawEmptyState()
        } else if isExpanded {
            drawExpandedList()
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

        let point = convert(event.locationInWindow, from: nil)
        pendingDragURLs = []

        if toggleRect.contains(point), urls.count > 1 {
            isExpanded.toggle()
            selectedURL = nil
            needsDisplay = true
            return
        }

        if closeRect.contains(point) {
            window?.orderOut(nil)
            return
        }

        if headerDragRect.contains(point), let window {
            selectedURL = nil
            windowDragState = WindowDragState(mouseStart: NSEvent.mouseLocation, windowStart: window.frame.origin)
            return
        }

        if isExpanded, let url = rowHit(at: point) {
            selectedURL = url
            pendingDragURLs = [url]
            needsDisplay = true
        } else if stackRect.contains(point), !urls.isEmpty {
            selectedURL = nil
            pendingDragURLs = existing(urls)
        }
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
        windowDragState = nil
        pendingDragURLs = []
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isCopy = modifierFlags == .command && event.charactersIgnoringModifiers?.lowercased() == "c"

        if isCopy, copyCurrentSelectionToPasteboard() {
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !existing(urls).isEmpty else { return nil }

        let menu = NSMenu()
        let point = convert(event.locationInWindow, from: nil)

        if isExpanded, let rowURL = rowHit(at: point) {
            selectedURL = rowURL
            needsDisplay = true

            let copySelectedItem = NSMenuItem(title: "Copy This File", action: #selector(copyCurrentSelection(_:)), keyEquivalent: "")
            copySelectedItem.target = self
            menu.addItem(copySelectedItem)

            let copyAllItem = NSMenuItem(title: "Copy All Files", action: #selector(copyAllFiles(_:)), keyEquivalent: "")
            copyAllItem.target = self
            menu.addItem(copyAllItem)
        } else {
            let copyItem = NSMenuItem(title: "Copy All Files", action: #selector(copyAllFiles(_:)), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
        }

        return menu
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    private func add(_ newURLs: [URL]) {
        var seen = Set(urls.map { $0.standardizedFileURL.path })
        var accepted: [URL] = []

        for url in newURLs.map(\.standardizedFileURL) where url.isFileURL {
            let path = url.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            accepted.append(url)
        }

        guard !accepted.isEmpty else { return }
        urls.append(contentsOf: accepted)
        isExpanded = false
        selectedURL = nil
        needsDisplay = true
    }

    private func existing(_ urls: [URL]) -> [URL] {
        urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - 44, y: 10, width: 28, height: 28)
    }

    private var toggleRect: NSRect {
        NSRect(x: bounds.maxX - 84, y: 10, width: 28, height: 28)
    }

    private var headerDragRect: NSRect {
        NSRect(x: 12, y: 6, width: bounds.width - 108, height: 40)
    }

    private var stackRect: NSRect {
        NSRect(x: bounds.midX - 76, y: 56, width: 152, height: 112)
    }

    private func rowRects() -> [(URL, NSRect)] {
        var y: CGFloat = 48
        return urls.map { url in
            let rect = NSRect(x: 16, y: y, width: bounds.width - 32, height: 35)
            y += 39
            return (url, rect)
        }
    }

    private func rowHit(at point: CGPoint) -> URL? {
        rowRects().first { $0.1.contains(point) }?.0
    }

    private func drawBackground() {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill()
        path.fill()

        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawEmptyState() {
        drawHeader(subtitle: "Drop here")

        let dropRect = bounds.insetBy(dx: 18, dy: 58)
        let path = NSBezierPath(roundedRect: dropRect, xRadius: 16, yRadius: 16)
        NSColor.separatorColor.withAlphaComponent(0.45).setStroke()
        path.lineWidth = 1.2
        path.setLineDash([6, 5], count: 2, phase: 0)
        path.stroke()

        drawCentered("Release files", detail: "This shelf will stay if something lands here.", in: dropRect)
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
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]
        "Shake Shelf".draw(at: CGPoint(x: 18, y: 14), withAttributes: titleAttributes)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]
        let subtitleRect = NSRect(
            x: 116,
            y: 18,
            width: max(0, toggleRect.minX - 124),
            height: 16
        )
        subtitle.draw(in: subtitleRect, withAttributes: detailAttributes)

        drawIconButton(rect: closeRect, title: "xmark")

        if urls.count > 1 {
            drawIconButton(rect: toggleRect, title: isExpanded ? "square.stack.3d.up" : "list.bullet", isProminent: true)
        }
    }

    private func drawStack() {
        drawHeader(subtitle: "\(urls.count) item\(urls.count == 1 ? "" : "s")")

        for (index, url) in Array(urls.prefix(5)).enumerated().reversed() {
            let offset = CGFloat(index) * 7
            let rect = stackRect.offsetBy(dx: offset, dy: -offset).insetBy(dx: 10, dy: 8)
            let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
            path.stroke()

            drawPreview(for: url, in: rect.insetBy(dx: 14, dy: 12), cornerRadius: 10)
        }

        drawBadge("\(urls.count)", at: CGPoint(x: stackRect.maxX - 18, y: stackRect.minY - 2))
        drawCentered(
            copyStatus ?? "Drag stack for all files",
            detail: copyStatus == nil ? "Use list for one file. Cmd-C copies all." : "Paste in Finder with Cmd-V.",
            in: NSRect(x: 16, y: bounds.maxY - 52, width: bounds.width - 32, height: 36)
        )
    }

    private func drawExpandedList() {
        drawHeader(subtitle: "List")

        for (url, rect) in rowRects() {
            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            if selectedURL == url {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
            } else {
                NSColor.controlBackgroundColor.withAlphaComponent(0.75).setFill()
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
            url.lastPathComponent.draw(in: NSRect(x: rect.minX + 38, y: rect.minY + 9, width: rect.width - 46, height: 18), withAttributes: attributes)
        }
    }

    private func drawIconButton(rect: NSRect, title: String, isProminent: Bool = false) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        let fillColor = isProminent
            ? NSColor.controlAccentColor.withAlphaComponent(0.22)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.72)
        fillColor.setFill()
        path.fill()

        let strokeColor = isProminent
            ? NSColor.controlAccentColor.withAlphaComponent(0.85)
            : NSColor.separatorColor.withAlphaComponent(0.45)
        strokeColor.setStroke()
        path.lineWidth = 1
        path.stroke()

        let symbolColor = isProminent ? NSColor.controlAccentColor : NSColor.labelColor
        tintedSymbol(named: title, color: symbolColor, size: NSSize(width: 15, height: 15))?
            .draw(in: rect.insetBy(dx: 6.5, dy: 6.5))
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
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ]

        title.draw(in: NSRect(x: rect.minX + 8, y: rect.midY - 18, width: rect.width - 16, height: 18), withAttributes: titleAttributes)
        detail.draw(in: NSRect(x: rect.minX + 8, y: rect.midY + 2, width: rect.width - 16, height: 16), withAttributes: detailAttributes)
    }

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

        let preview: FilePreview
        if isImageFile(url), let image = NSImage(contentsOf: url) {
            preview = FilePreview(image: image, isThumbnail: true)
        } else {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            preview = FilePreview(image: icon, isThumbnail: false)
        }

        previewCache[key] = preview
        return preview
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
                    self?.finishReceivingPromisedFile(receivedURL)
                }
            }

            return true
        } catch {
            NSLog("Shake Shelf failed to create promised-file destination: \(error.localizedDescription)")
            return false
        }
    }

    private func finishReceivingPromisedFile(_ url: URL?) {
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

    @objc private func copyCurrentSelection(_ sender: Any?) {
        _ = copyCurrentSelectionToPasteboard()
    }

    @objc private func copyAllFiles(_ sender: Any?) {
        _ = copyAllFilesToPasteboard()
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
