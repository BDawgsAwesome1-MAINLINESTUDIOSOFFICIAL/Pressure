import AppKit
import Combine

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let model: PressureAppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    private var isPurging = false

    init(model: PressureAppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("Pressure")
        }
        model.monitor.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshIcon()
        }.store(in: &cancellables)
        model.configStore.$config.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.refreshIcon()
        }.store(in: &cancellables)
        refreshIcon()
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.monitor.poll()
        rebuild(menu)
    }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let config = model.configStore.config
        let level = model.monitor.snapshot?.level(config: config) ?? .ok
        let score = model.monitor.snapshot?.displayScore(config: config)
        button.image = PressureIcon.image(for: level)
        button.title = score.map { " \(PercentFormat.string($0))" } ?? " …"
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = model.configStore.config
        let snapshot = model.monitor.snapshot

        menu.addItem(header("A Dynamic Island for Mac"))
        if let snapshot {
            let score = snapshot.displayScore(config: config)
            menu.addItem(header("Memory  \(PercentFormat.string(score))"))
            menu.addItem(header("Available  \(ByteFormat.string(snapshot.availableBytes))"))
            menu.addItem(header("Wired  \(ByteFormat.string(snapshot.wiredBytes))"))
            menu.addItem(header("Compressed  \(ByteFormat.string(snapshot.compressedBytes))"))
            menu.addItem(header("Swap  \(ByteFormat.string(snapshot.swapUsedBytes)) of \(ByteFormat.string(snapshot.swapTotalBytes))"))
        } else {
            menu.addItem(header("Reading memory…"))
        }

        menu.addItem(.separator())
        menu.addItem(header("Top Memory"))
        let top = model.monitor.topFootprints
        if top.isEmpty {
            menu.addItem(header("No user apps yet"))
        } else {
            for app in top {
                menu.addItem(header("\(app.name)  \(ByteFormat.string(app.residentBytes))"))
            }
        }

        menu.addItem(.separator())
        let ranked = model.monitor.footprints.compactMap { $0.ranked() }
        if let target = AppPriority.manualCloseTarget(
            apps: ranked,
            config: config,
            selfBundleID: Bundle.main.bundleIdentifier
        ) {
            let item = NSMenuItem(
                title: "Close \(target.displayName)  \(ByteFormat.string(target.residentBytes))",
                action: #selector(closeTopApp(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = CloseRequest(bundleIdentifier: target.bundleIdentifier, pid: target.pid)
            menu.addItem(item)
        } else {
            let item = NSMenuItem(title: "Close Top App", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let purge = NSMenuItem(title: "Purge Inactive Memory…", action: #selector(purgeMemory(_:)), keyEquivalent: "")
        purge.target = self
        purge.isEnabled = !isPurging
        menu.addItem(purge)

        let pause = NSMenuItem(
            title: "Auto-Close Apps",
            action: #selector(toggleAutoClose(_:)),
            keyEquivalent: ""
        )
        pause.target = self
        pause.state = config.autoCloseEnabled ? .on : .off
        menu.addItem(pause)

        if !model.log.events.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Recent"))
            for event in model.log.events.prefix(3) {
                menu.addItem(header(event.message))
            }
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Pressure", action: #selector(quit(_:)), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func closeTopApp(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? CloseRequest else { return }
        let ranked = model.monitor.footprints.compactMap { $0.ranked() }
        guard let target = ranked.first(where: { $0.pid == request.pid && $0.bundleIdentifier == request.bundleIdentifier })
            ?? AppPriority.manualCloseTarget(
                apps: ranked,
                config: model.configStore.config,
                selfBundleID: Bundle.main.bundleIdentifier
            )
        else { return }

        let alert = NSAlert()
        alert.messageText = "Close \(target.displayName)?"
        alert.informativeText = "\(target.displayName) is using \(ByteFormat.string(target.residentBytes)). Pressure will ask it to quit, then force quit if it is still open after 5 seconds."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            await model.engine.closeManually(target)
        }
    }

    @objc private func purgeMemory(_ sender: NSMenuItem) {
        guard !isPurging else { return }
        isPurging = true
        model.engine.purge()
        isPurging = false
    }

    @objc private func toggleAutoClose(_ sender: NSMenuItem) {
        model.configStore.update { $0.autoCloseEnabled.toggle() }
    }

    @objc private func openSettings(_ sender: NSMenuItem) {
        model.showSettings()
    }

    @objc private func quit(_ sender: NSMenuItem) {
        model.quitCompletely()
    }

    private func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private final class CloseRequest: NSObject {
    let bundleIdentifier: String
    let pid: Int32

    init(bundleIdentifier: String, pid: Int32) {
        self.bundleIdentifier = bundleIdentifier
        self.pid = pid
    }
}

enum PressureIcon {
    static func image(for level: PressureLevel) -> NSImage {
        let symbol: String
        let color: NSColor
        switch level {
        case .ok:
            symbol = "gauge.with.dots.needle.33percent"
            color = .systemGreen
        case .warning:
            symbol = "gauge.with.dots.needle.67percent"
            color = .systemYellow
        case .critical:
            symbol = "gauge.with.dots.needle.100percent"
            color = .systemRed
        }

        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Memory pressure")?
            .withSymbolConfiguration(configuration) {
            image.isTemplate = false
            return image
        }
        return fallbackCircle(color: color)
    }

    private static func fallbackCircle(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
