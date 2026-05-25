import AppKit
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
    private var isExpanded = false
    private var pendingDragURLs: [URL] = []
    private var windowDragState: WindowDragState?
    private var previewCache: [String: FilePreview] = [:]

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 270, height: 230))
        wantsLayer = true
        registerForDraggedTypes([.fileURL, filenamesPasteboardType])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        drawBackground()

        if urls.isEmpty {
            drawEmptyState()
        } else if isExpanded {
            drawExpandedList()
        } else {
            drawStack()
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        readFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .generic
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        readFileURLs(from: sender.draggingPasteboard).isEmpty ? [] : .generic
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = readFileURLs(from: sender.draggingPasteboard)
        add(dropped)
        return !dropped.isEmpty
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pendingDragURLs = []

        if toggleRect.contains(point), urls.count > 1 {
            isExpanded.toggle()
            needsDisplay = true
            return
        }

        if closeRect.contains(point) {
            window?.orderOut(nil)
            return
        }

        if headerDragRect.contains(point), let window {
            windowDragState = WindowDragState(mouseStart: NSEvent.mouseLocation, windowStart: window.frame.origin)
            return
        }

        if isExpanded, let url = rowHit(at: point) {
            pendingDragURLs = [url]
        } else if stackRect.contains(point), !urls.isEmpty {
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

    private func drawHeader(subtitle: String) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .bold),
            .foregroundColor: NSColor.labelColor
        ]
        "Shake Shelf".draw(at: CGPoint(x: 18, y: 14), withAttributes: titleAttributes)

        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        subtitle.draw(at: CGPoint(x: 116, y: 18), withAttributes: detailAttributes)

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
        drawCentered("Drag stack for all files", detail: "Use the list button for one file.", in: NSRect(x: 16, y: bounds.maxY - 52, width: bounds.width - 32, height: 36))
    }

    private func drawExpandedList() {
        drawHeader(subtitle: "Drag one row")

        for (url, rect) in rowRects() {
            let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
            NSColor.controlBackgroundColor.withAlphaComponent(0.75).setFill()
            path.fill()

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
