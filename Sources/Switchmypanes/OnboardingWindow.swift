import AppKit

/// Plain-language permission checklist with live status (refreshes every second).
@MainActor
final class OnboardingWindowController: NSWindowController {
    @MainActor private struct Row {
        let title: String, why: String, pane: PermissionManager.Pane
        let request: () -> Void
        let isGranted: (PermissionManager.Status) -> Bool
        let status = NSTextField(labelWithString: "")
        let button = NSButton()
    }

    private var rows: [Row] = []
    private let summary = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private let keyboardActive: () -> Bool

    init(keyboardActive: @escaping () -> Bool) {
        self.keyboardActive = keyboardActive
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Switchmypanes: permissions"
        w.isReleasedWhenClosed = false
        super.init(window: w)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        rows = [
            Row(title: "Accessibility", why: "Lets Switchmypanes move, resize and bring forward other apps' windows, and read their titles. Required.",
                pane: .accessibility, request: PermissionManager.requestAccessibility, isGranted: { $0.accessibility }),
            Row(title: "Input Monitoring", why: "Lets Switchmypanes notice its own shortcuts (Option+Tab and the snap keys). It only checks whether a key is one of those; it never reads, stores or sends what you type. Required.",
                pane: .inputMonitoring, request: PermissionManager.requestInputMonitoring, isGranted: { $0.inputMonitoring }),
            Row(title: "Screen Recording", why: "Only used to draw the small window previews in the Option+Tab overlay. Optional: without it you still get app icons and titles. Nothing is saved or sent anywhere.",
                pane: .screenRecording, request: PermissionManager.requestScreenRecording, isGranted: { $0.screenRecording }),
        ]

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        let head = NSTextField(wrappingLabelWithString: "Switchmypanes needs your permission for a few things. Click each button, switch Switchmypanes on in the System Settings page that opens, then come back here. The status updates by itself.")
        head.preferredMaxLayoutWidth = 510
        stack.addArrangedSubview(head)

        for (i, row) in rows.enumerated() {
            let title = NSTextField(labelWithString: row.title)
            title.font = .boldSystemFont(ofSize: 14)
            let why = NSTextField(wrappingLabelWithString: row.why)
            why.preferredMaxLayoutWidth = 510
            why.textColor = .secondaryLabelColor
            row.button.title = "Open System Settings…"
            row.button.bezelStyle = .rounded
            row.button.tag = i
            row.button.target = self
            row.button.action = #selector(grantTapped(_:))
            let line = NSStackView(views: [row.status, row.button])
            line.spacing = 12
            let block = NSStackView(views: [title, why, line])
            block.orientation = .vertical
            block.alignment = .leading
            block.spacing = 4
            stack.addArrangedSubview(block)
        }

        summary.preferredMaxLayoutWidth = 510
        stack.addArrangedSubview(summary)

        let relaunch = NSButton(title: "Relaunch Switchmypanes", target: self, action: #selector(relaunch))
        let done = NSButton(title: "Done", target: self, action: #selector(closeTapped))
        done.keyEquivalent = "\r"
        let buttons = NSStackView(views: [relaunch, done])
        buttons.spacing = 12
        stack.addArrangedSubview(buttons)

        window?.contentView = stack
        window?.setContentSize(stack.fittingSize)
        refresh()
    }

    func show() {
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        showWindow(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        let s = PermissionManager.current()
        for row in rows {
            let ok = row.isGranted(s)
            row.status.stringValue = ok ? "✓ Granted" : "✗ Not granted"
            row.status.textColor = ok ? .systemGreen : .systemRed
        }
        if keyboardActive() {
            summary.stringValue = "Keyboard shortcuts: active. Try Option+Tab."
            summary.textColor = .systemGreen
        } else if s.shortcutsReady {
            summary.stringValue = "Permissions look right, but the keyboard shortcuts are not active yet. Click “Relaunch Switchmypanes”: macOS only applies some permissions to apps that start afterwards."
            summary.textColor = .systemOrange
        } else {
            summary.stringValue = "Keyboard shortcuts: not active yet. Grant Accessibility and Input Monitoring above."
            summary.textColor = .systemOrange
        }
    }

    @objc private func grantTapped(_ sender: NSButton) {
        let row = rows[sender.tag]
        row.request()                                  // shows the system prompt the first time
        PermissionManager.openSettings(row.pane)       // and always opens the right page
    }

    @objc private func relaunch() {
        let url = Bundle.main.bundleURL
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }

    @objc private func closeTapped() { window?.close() }

    override func close() { timer?.invalidate(); timer = nil; super.close() }
}
