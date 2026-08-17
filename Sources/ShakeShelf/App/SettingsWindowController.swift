import AppKit
import ServiceManagement
import ShakeShelfCore

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onSettingsChanged: ((ShakeShelfSettings) -> Void)?

    private let settings: ShakeShelfSettings
    private let sensitivityControl = NSSegmentedControl(
        labels: ShakeSensitivity.allCases.map(\.displayName),
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let launchAtLoginButton = NSButton(checkboxWithTitle: "Launch Shake Shelf at login", target: nil, action: nil)
    private let persistButton = NSButton(checkboxWithTitle: "Keep items on the shelf after quitting", target: nil, action: nil)
    private let ballButton = NSButton(checkboxWithTitle: "Collapse into a floating ball when idle", target: nil, action: nil)

    init(settings: ShakeShelfSettings) {
        self.settings = settings

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Shake Shelf Settings"
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self

        buildContent()
        loadSettings()

        sensitivityControl.target = self
        sensitivityControl.action = #selector(controlChanged)
        launchAtLoginButton.target = self
        launchAtLoginButton.action = #selector(launchAtLoginToggled)
        persistButton.target = self
        persistButton.action = #selector(controlChanged)
        ballButton.target = self
        ballButton.action = #selector(controlChanged)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let titleLabel = NSTextField(labelWithString: "Shake Shelf")
        titleLabel.font = .systemFont(ofSize: 17, weight: .bold)

        let sensitivityLabel = NSTextField(labelWithString: "Shake sensitivity")
        sensitivityLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        let sensitivityDetail = NSTextField(wrappingLabelWithString: "How much left-right motion while dragging a file summons the shelf.")
        sensitivityDetail.font = .systemFont(ofSize: 11)
        sensitivityDetail.textColor = .secondaryLabelColor

        let sensitivityStack = NSStackView(views: [sensitivityLabel, sensitivityDetail, sensitivityControl])
        sensitivityStack.orientation = .vertical
        sensitivityStack.alignment = .leading
        sensitivityStack.spacing = 6
        sensitivityControl.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let loginDetail = NSTextField(wrappingLabelWithString: "Restarts automatically when you sign in to this Mac.")
        loginDetail.font = .systemFont(ofSize: 11)
        loginDetail.textColor = .secondaryLabelColor

        let loginStack = NSStackView(views: [launchAtLoginButton, loginDetail])
        loginStack.orientation = .vertical
        loginStack.alignment = .leading
        loginStack.spacing = 4

        let persistDetail = NSTextField(wrappingLabelWithString: "Files stay on the shelf across app restarts. Items whose files were moved or deleted are dropped automatically.")
        persistDetail.font = .systemFont(ofSize: 11)
        persistDetail.textColor = .secondaryLabelColor

        let persistStack = NSStackView(views: [persistButton, persistDetail])
        persistStack.orientation = .vertical
        persistStack.alignment = .leading
        persistStack.spacing = 4

        let ballDetail = NSTextField(wrappingLabelWithString: "The shelf shrinks into a small translucent orb when you're not using it. Hover the orb to reopen the shelf, or drag it to move it out of the way.")
        ballDetail.font = .systemFont(ofSize: 11)
        ballDetail.textColor = .secondaryLabelColor

        let ballStack = NSStackView(views: [ballButton, ballDetail])
        ballStack.orientation = .vertical
        ballStack.alignment = .leading
        ballStack.spacing = 4

        let doneButton = NSButton(title: "Done", target: self, action: #selector(done))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [titleLabel, separator, sensitivityStack, loginStack, persistStack, ballStack, doneButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20)
        ])

        doneButton.alignment = .right
        stack.setCustomSpacing(4, after: titleLabel)
    }

    private func loadSettings() {
        sensitivityControl.selectedSegment = max(0, ShakeSensitivity.allCases.firstIndex(of: settings.sensitivity) ?? 1)
        launchAtLoginButton.state = settings.launchAtLogin ? .on : .off
        persistButton.state = settings.persistItemsAcrossRelaunch ? .on : .off
        ballButton.state = settings.collapseToBallEnabled ? .on : .off
    }

    private func currentSettings() -> ShakeShelfSettings {
        var updated = ShakeShelfSettings.load()
        let segment = max(0, sensitivityControl.selectedSegment)
        updated.sensitivity = ShakeSensitivity.allCases[min(segment, ShakeSensitivity.allCases.count - 1)]
        updated.persistItemsAcrossRelaunch = persistButton.state == .on
        updated.collapseToBallEnabled = ballButton.state == .on
        return updated
    }

    @objc private func controlChanged() {
        let updated = currentSettings()
        updated.save()
        onSettingsChanged?(updated)
    }

    @objc private func launchAtLoginToggled() {
        let shouldLaunch = launchAtLoginButton.state == .on

        do {
            if shouldLaunch {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }

            var updated = settings
            updated.launchAtLogin = shouldLaunch
            updated.save()
            onSettingsChanged?(updated)
        } catch {
            launchAtLoginButton.state = shouldLaunch ? .off : .on
            let alert = NSAlert()
            alert.messageText = "Could Not Update Login Item"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func done() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window?.orderOut(nil)
    }
}
