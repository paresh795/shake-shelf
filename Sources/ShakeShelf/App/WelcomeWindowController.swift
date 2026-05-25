import AppKit

@MainActor
final class WelcomeWindowController: NSViewController {
    private let onShowShelf: () -> Void
    private let onDone: () -> Void

    init(onShowShelf: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.onShowShelf = onShowShelf
        self.onDone = onDone
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        let titleLabel = NSTextField(labelWithString: "Shake Shelf is running")
        titleLabel.font = .systemFont(ofSize: 26, weight: .bold)
        titleLabel.textColor = .labelColor

        let detailLabel = NSTextField(wrappingLabelWithString: "Drag a file, shake left-right, and drop it onto the shelf. Shake Shelf stays in the menu bar after this window closes.")
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3

        let testButton = NSButton(title: "Show Test Shelf", target: self, action: #selector(showShelf))
        testButton.bezelStyle = .rounded

        let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [testButton, doneButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let stack = NSStackView(views: [titleLabel, detailLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    @objc private func showShelf() {
        onShowShelf()
    }

    @objc private func done() {
        onDone()
    }
}
