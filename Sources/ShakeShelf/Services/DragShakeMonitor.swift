import AppKit
import ShakeShelfCore
import QuartzCore

@MainActor
final class DragShakeMonitor {
    var onShake: ((CGPoint) -> Void)?
    var onStatusChange: ((String) -> Void)?

    private var recognizer = DragShakeRecognizer()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastStatusUpdate: CFTimeInterval = 0

    func start() {
        stop()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
            return event
        }

        onStatusChange?("Ready: drag a file and shake left-right")
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }

        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }

        globalMonitor = nil
        localMonitor = nil
        recognizer.reset()
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseUp:
            recognizer.reset()
            onStatusChange?("Ready: drag a file and shake left-right")
        case .leftMouseDragged:
            let now = CACurrentMediaTime()
            let x = Double(NSEvent.mouseLocation.x)

            if now - lastStatusUpdate > 0.35 {
                lastStatusUpdate = now
                onStatusChange?("Drag detected")
            }

            if recognizer.ingest(DragShakeSample(time: now, x: x)) {
                onStatusChange?("Shake recognized")
                onShake?(NSEvent.mouseLocation)
            }
        default:
            break
        }
    }
}
