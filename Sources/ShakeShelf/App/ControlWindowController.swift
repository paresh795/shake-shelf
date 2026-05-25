import AppKit

@MainActor
final class ControlWindowController: NSViewController {
    private let monitor: DragShakeMonitor
    private let onShowShelf: () -> Void

    private let statusLabel = NSTextField(labelWithString: "Drag-shake monitor starting")
    private let detailLabel = NSTextField(labelWithString: "Pick up a Finder file, shake left-right while holding it, then drop onto the shelf.")

    init(monitor: DragShakeMonitor, onShowShelf: @escaping () -> Void) {
        self.monitor = monitor
        self.onShowShelf = onShowShelf
        super.init(nibName: nil, bundle: nil)

        monitor.onStatusChange = { [weak self] status in
            self?.statusLabel.stringValue = status
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        let titleLabel = NSTextField(labelWithString: "Shake Shelf")
        titleLabel.font = .systemFont(ofSize: 34, weight: .bold)

        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        statusLabel.textColor = .secondaryLabelColor

        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 2

        let testButton = NSButton(title: "Show Test Shelf", target: self, action: #selector(showShelf))
        testButton.bezelStyle = .rounded

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded

        let stack = NSStackView(views: [titleLabel, statusLabel, detailLabel, buttonRow(testButton, quitButton)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func buttonRow(_ buttons: NSButton...) -> NSStackView {
        let stack = NSStackView(views: buttons)
        stack.orientation = .horizontal
        stack.spacing = 10
        return stack
    }

    @objc private func showShelf() {
        onShowShelf()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
