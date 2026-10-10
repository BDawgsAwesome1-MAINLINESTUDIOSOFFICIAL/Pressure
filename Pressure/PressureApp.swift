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

    init() {
        engine = PressureEngine(monitor: monitor, configStore: configStore, log: log)
        island = IslandModel(monitor: monitor, configStore: configStore)
    }

    func start() {
        refreshLoginItemStatus()
        engine.start()
        monitor.start()
        island.start()
    }

    func showSettings() {
        if settings == nil {
            settings = SettingsWindowController(model: self)
        }
        settings?.show()
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
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = PressureAppModel()
        self.model = model
        statusItem = StatusItemController(model: model)
        let hub = HubController(model: model)
        self.hub = hub
        model.start()
        hub.start()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
