import AppKit
import ServiceManagement

@MainActor
final class PressureAppModel {
    let monitor = MemoryMonitor()
    let configStore = ConfigStore()
    let log = ActionLog()
    let engine: PressureEngine
    let island: IslandModel
    private(set) var loginItemStatus = ""
    private var settings: SettingsWindowController?
    private var fullQuit = false

    init() {
        engine = PressureEngine(monitor: monitor, configStore: configStore, log: log)
        island = IslandModel(monitor: monitor, configStore: configStore)
        island.onPlaybackNote = { [log] note in
            log.record(note)
        }
    }

    func start() {
        refreshLoginItemStatus()
        engine.start()
        monitor.start()
        island.start()
    }

    func showSettings() {
        applyDockVisibility()
        if settings == nil {
            settings = SettingsWindowController(model: self)
        }
        settings?.show()
    }

    /// Dock Quit and Command-Q close the Dock app only. The island keeps running.
    func dismissDockApp() {
        settings?.close()
        NSApp.setActivationPolicy(.accessory)
    }

    /// Menu-bar Quit stops the island as well.
    func quitCompletely() {
        fullQuit = true
        NSApp.terminate(nil)
    }

    /// Starts Pressure again so a new Full Disk Access grant is picked up.
    func resetPressure() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        let current = ProcessInfo.processInfo.processIdentifier
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, error in
            let launched = app?.processIdentifier
            DispatchQueue.main.async {
                guard error == nil, let launched, launched != current else { return }
                self.fullQuit = true
                NSApp.terminate(nil)
            }
        }
    }

    func consumeFullQuit() -> Bool {
        let quitting = fullQuit
        fullQuit = false
        return quitting
    }

    /// The Dock icon stays while the Dock app is open.
    func applyDockVisibility() {
        configStore.update { $0.showInDock = true }
        NSApp.setActivationPolicy(.regular)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemStatus = ""
            configStore.setLaunchAtLoginFlag(SMAppService.mainApp.status == .enabled || enabled)
            refreshLoginItemStatus()
        } catch {
            loginItemStatus = error.localizedDescription
            refreshLoginItemStatus()
        }
    }

    private func refreshLoginItemStatus() {
        switch SMAppService.mainApp.status {
        case .enabled:
            loginItemStatus = ""
            configStore.setLaunchAtLoginFlag(true)
        case .requiresApproval:
            loginItemStatus = "Approve Pressure in System Settings → General → Login Items."
            configStore.setLaunchAtLoginFlag(true)
        case .notRegistered:
            loginItemStatus = ""
            configStore.setLaunchAtLoginFlag(false)
        case .notFound:
            loginItemStatus = "Launch at login needs a signed copy of Pressure, usually one installed in Applications."
            configStore.setLaunchAtLoginFlag(false)
        default:
            break
        }
    }
}

@main
final class PressureAppDelegate: NSObject, NSApplicationDelegate {
    private var model: PressureAppModel?
    private var statusItem: StatusItemController?
    private var hub: HubController?

    static func main() {
        let app = NSApplication.shared
        let delegate = PressureAppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = PressureAppModel()
        self.model = model
        statusItem = StatusItemController(model: model)
        let hub = HubController(model: model)
        self.hub = hub
        model.applyDockVisibility()
        model.start()
        hub.start()
        NSApp.deactivate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model?.showSettings()
        hub?.keepVisible()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.consumeFullQuit() {
            return .terminateNow
        }
        model.dismissDockApp()
        hub?.keepVisible()
        DispatchQueue.main.async { [weak hub] in
            hub?.keepVisible()
        }
        return .terminateCancel
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
