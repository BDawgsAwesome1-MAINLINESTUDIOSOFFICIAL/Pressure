import AppKit
import SwiftUI

@MainActor
final class SettingsSelection: ObservableObject {
    @Published var priorityID: String?
    @Published var protectedID: String?
}

@MainActor
final class SettingsWindowController {
    private let window: NSWindow
    private let selection = SettingsSelection()

    init(model: PressureAppModel) {
        let host = NSHostingController(rootView: SettingsView(model: model, selection: selection))
        window = NSWindow(contentViewController: host)
        window.title = "Pressure Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 680))
        window.minSize = NSSize(width: 480, height: 560)
        window.isReleasedWhenClosed = false
    }

    func show() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var log: ActionLog
    @ObservedObject var selection: SettingsSelection
    var loginStatus: () -> String
    var setLaunchAtLogin: (Bool) -> Void

    init(model: PressureAppModel, selection: SettingsSelection) {
        monitor = model.monitor
        configStore = model.configStore
        log = model.log
        self.selection = selection
        loginStatus = { model.loginItemStatus }
        setLaunchAtLogin = { model.setLaunchAtLogin($0) }
    }

    var body: some View {
        Form {
            memorySection
            thresholdSection
            prioritySection
            protectedSection
            generalSection
            logSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var memorySection: some View {
        Section("Right Now") {
            if let snapshot = monitor.snapshot {
                let score = snapshot.displayScore(config: configStore.config)
                LabeledContent("Pressure", value: PercentFormat.string(score))
                LabeledContent("Available", value: ByteFormat.string(snapshot.availableBytes))
                LabeledContent("Wired", value: ByteFormat.string(snapshot.wiredBytes))
                LabeledContent("Compressed", value: ByteFormat.string(snapshot.compressedBytes))
                LabeledContent(
                    "Swap",
                    value: "\(ByteFormat.string(snapshot.swapUsedBytes)) of \(ByteFormat.string(snapshot.swapTotalBytes))"
                )
            } else {
                Text("Reading memory…")
            }
        }
    }

    private var thresholdSection: some View {
        Section("Thresholds") {
            thresholdSlider(
                title: "Warning",
                value: configStore.config.warningThreshold,
                range: 50...min(90, configStore.config.criticalThreshold - 1)
            ) { newValue in
                configStore.update { $0.warningThreshold = newValue }
            }
            thresholdSlider(
                title: "Critical",
                value: configStore.config.criticalThreshold,
                range: (configStore.config.warningThreshold + 1)...min(95, configStore.config.autoCloseThreshold - 1)
            ) { newValue in
                configStore.update { $0.criticalThreshold = newValue }
            }
            thresholdSlider(
                title: "Auto-close",
                value: configStore.config.autoCloseThreshold,
                range: (configStore.config.criticalThreshold + 1)...99
            ) { newValue in
                configStore.update { $0.autoCloseThreshold = newValue }
            }
            Text("The icon turns yellow at Warning and red at Critical. Auto-close starts at the last slider and keeps going until pressure drops below Critical.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var prioritySection: some View {
        Section("Close These First") {
            Text("Add apps Pressure is allowed to quit. The bottom of the list is closed first. The app you are using is never closed automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if configStore.config.priority.isEmpty {
                Text("No apps yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(selection: $selection.priorityID) {
                    ForEach(Array(configStore.config.priority.enumerated()), id: \.element.id) { index, entry in
                        HStack {
                            Text("\(index + 1)")
                                .foregroundStyle(.secondary)
                                .frame(width: 20, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.displayName)
                                Text(entry.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .tag(entry.id)
                    }
                    .onMove(perform: movePriority)
                }
                .frame(minHeight: 140)
            }
            HStack {
                addMenu(title: "Add App", excluding: Set(configStore.config.priority.map(\.bundleIdentifier))) { bundleID, name in
                    configStore.update { config in
                        guard !config.priority.contains(where: { $0.bundleIdentifier == bundleID }) else { return }
                        config.priority.append(AppPriorityEntry(bundleIdentifier: bundleID, displayName: name))
                    }
                }
                Button("Remove") { removeSelectedPriority() }
                    .disabled(selection.priorityID == nil)
                Button("Up") { nudgePriority(direction: -1) }
                    .disabled(!canNudgePriority(-1))
                Button("Down") { nudgePriority(direction: 1) }
                    .disabled(!canNudgePriority(1))
            }
        }
    }

    private var protectedSection: some View {
        Section("Never Close") {
            Text("Finder, Dock, and the rest of the menu bar session are always protected.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(AppPriority.sessionCriticalNames, id: \.bundleIdentifier) { item in
                Text(item.name)
            }
            if !configStore.config.protectedBundleIDs.isEmpty {
                List(selection: $selection.protectedID) {
                    ForEach(configStore.config.protectedBundleIDs, id: \.self) { bundleID in
                        Text(displayName(for: bundleID))
                            .tag(bundleID)
                    }
                }
                .frame(minHeight: 80)
            }
            HStack {
                addMenu(
                    title: "Protect App",
                    excluding: Set(configStore.config.protectedBundleIDs).union(AppPriority.sessionCriticalBundleIDs)
                ) { bundleID, _ in
                    configStore.update { config in
                        guard !config.protectedBundleIDs.contains(bundleID) else { return }
                        config.protectedBundleIDs.append(bundleID)
                    }
                }
                Button("Remove") { removeSelectedProtected() }
                    .disabled(selection.protectedID == nil)
            }
        }
    }

    private var generalSection: some View {
        Section("General") {
            Toggle("Automatically close apps", isOn: binding(\.autoCloseEnabled))
            Toggle("Notify on warning", isOn: binding(\.notifyOnWarning))
            Toggle("Notify before auto-closing", isOn: binding(\.notifyBeforeAutoClose))
            Toggle("Launch at login", isOn: Binding(
                get: { configStore.config.launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            let status = loginStatus()
            if !status.isEmpty {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var logSection: some View {
        Section("Recent Actions") {
            if log.events.isEmpty {
                Text("Nothing yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(log.events) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.message)
                        Text(event.date.formatted(date: .abbreviated, time: .standard))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func thresholdSlider(
        title: String,
        value: Double,
        range: ClosedRange<Double>,
        set: @escaping (Double) -> Void
    ) -> some View {
        let lower = range.lowerBound
        let upper = max(range.upperBound, lower + 1)
        return LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { value }, set: set), in: lower...upper, step: 1)
                Text(PercentFormat.string(value))
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AppConfig, Bool>) -> Binding<Bool> {
        Binding(
            get: { configStore.config[keyPath: keyPath] },
            set: { newValue in
                configStore.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func addMenu(title: String, excluding: Set<String>, add: @escaping (String, String) -> Void) -> some View {
        let apps = addableApps(excluding: excluding)
        return Menu(title) {
            if apps.isEmpty {
                Text("No other running apps")
            } else {
                ForEach(apps) { app in
                    Button(app.name) {
                        if let bundleID = app.bundleIdentifier {
                            add(bundleID, app.name)
                        }
                    }
                }
            }
        }
    }

    private func addableApps(excluding: Set<String>) -> [AppFootprint] {
        var seen = Set<String>()
        return monitor.footprints
            .filter { app in
                guard let bundleID = app.bundleIdentifier, app.isUserApp else { return false }
                guard !excluding.contains(bundleID) else { return false }
                guard bundleID != Bundle.main.bundleIdentifier else { return false }
                return seen.insert(bundleID).inserted
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func displayName(for bundleID: String) -> String {
        if let match = monitor.footprints.first(where: { $0.bundleIdentifier == bundleID }) {
            return "\(match.name)  ·  \(bundleID)"
        }
        if let match = configStore.config.priority.first(where: { $0.bundleIdentifier == bundleID }) {
            return "\(match.displayName)  ·  \(bundleID)"
        }
        return bundleID
    }

    private func movePriority(from offsets: IndexSet, to offset: Int) {
        configStore.update { $0.priority.move(fromOffsets: offsets, toOffset: offset) }
    }

    private func removeSelectedPriority() {
        guard let selectedPriority = selection.priorityID else { return }
        configStore.update { config in
            config.priority.removeAll { $0.bundleIdentifier == selectedPriority }
        }
        selection.priorityID = nil
    }

    private func removeSelectedProtected() {
        guard let selectedProtected = selection.protectedID else { return }
        configStore.update { config in
            config.protectedBundleIDs.removeAll { $0 == selectedProtected }
        }
        selection.protectedID = nil
    }

    private func canNudgePriority(_ direction: Int) -> Bool {
        guard let selectedPriority = selection.priorityID,
              let index = configStore.config.priority.firstIndex(where: { $0.bundleIdentifier == selectedPriority })
        else { return false }
        let next = index + direction
        return configStore.config.priority.indices.contains(next)
    }

    private func nudgePriority(direction: Int) {
        guard let selectedPriority = selection.priorityID,
              let index = configStore.config.priority.firstIndex(where: { $0.bundleIdentifier == selectedPriority })
        else { return }
        let next = index + direction
        guard configStore.config.priority.indices.contains(next) else { return }
        configStore.update { config in
            config.priority.swapAt(index, next)
        }
    }
}
