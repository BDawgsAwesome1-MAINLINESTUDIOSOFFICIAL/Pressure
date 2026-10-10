import AppKit
import SwiftUI

@MainActor
final class HubController: ObservableObject {
    @Published private(set) var isExpanded = false

    private let model: PressureAppModel
    private let panel: NSPanel
    private var pollTimer: Timer?
    private var anchoredScreen: NSScreen?
    private var collapseGeneration = 0
    private var collapsePending = false
    private var previewLocked = false

    init(model: PressureAppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HubLayout.collapsedWidth, height: HubLayout.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.isMovable = false
        panel.title = "Pressure Hub"
        panel.identifier = NSUserInterfaceItemIdentifier("PressureHub")

        let host = NSHostingController(rootView: HubView(model: model, hub: self))
        host.view.autoresizingMask = [.width, .height]
        panel.contentView = host.view
    }

    func start() {
        let preview = ProcessInfo.processInfo.environment["PRESSURE_HUB_PREVIEW"]
        previewLocked = preview == "expanded" || preview == "collapsed"
        let screen = NSScreen.main ?? NSScreen.screens.first
        anchoredScreen = screen
        if let screen {
            place(expanded: preview == "expanded", on: screen, animated: false)
        }
        panel.orderFrontRegardless()
        guard !previewLocked else { return }

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trackPointer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func collapse() {
        guard !previewLocked else { return }
        place(expanded: false, on: anchoredScreen ?? NSScreen.main, animated: true)
    }

    private func trackPointer() {
        let mouse = NSEvent.mouseLocation
        let mouseX = Double(mouse.x)
        let mouseY = Double(mouse.y)
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? anchoredScreen ?? NSScreen.main
        guard let screen else { return }

        if !isExpanded {
            anchoredScreen = screen
        }
        let home = anchoredScreen ?? screen
        let panelBox = HubLayout.panel(
            expanded: isExpanded,
            visibleMinX: Double(home.visibleFrame.minX),
            visibleMidY: Double(home.visibleFrame.midY),
            visibleHeight: Double(home.visibleFrame.height)
        )
        let hot = HubLayout.hotZone(
            screenMinX: Double(screen.frame.minX),
            visibleMinX: Double(screen.visibleFrame.minX),
            visibleMidY: Double(screen.visibleFrame.midY)
        )
        let pointingAtHub = panelBox.insetBy(dx: 16, dy: 24).contains(x: mouseX, y: mouseY) || hot.contains(x: mouseX, y: mouseY)

        if pointingAtHub {
            cancelCollapse()
            if !isExpanded || anchoredScreen != screen {
                anchoredScreen = screen
                place(expanded: true, on: screen, animated: true)
            }
        } else if isExpanded {
            scheduleCollapse()
        } else if anchoredScreen != screen {
            anchoredScreen = screen
            place(expanded: false, on: screen, animated: false)
        }
    }

    private func scheduleCollapse() {
        guard !collapsePending else { return }
        collapsePending = true
        collapseGeneration += 1
        let generation = collapseGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard generation == self.collapseGeneration else { return }
            self.collapsePending = false
            guard !self.previewLocked else { return }
            self.place(expanded: false, on: self.anchoredScreen ?? NSScreen.main, animated: true)
        }
    }

    private func cancelCollapse() {
        collapseGeneration += 1
        collapsePending = false
    }

    private func place(expanded: Bool, on screen: NSScreen?, animated: Bool) {
        guard let screen else { return }
        let box = HubLayout.panel(
            expanded: expanded,
            visibleMinX: Double(screen.visibleFrame.minX),
            visibleMidY: Double(screen.visibleFrame.midY),
            visibleHeight: Double(screen.visibleFrame.height)
        )
        let rect = NSRect(x: box.x, y: box.y, width: box.width, height: box.height)
        isExpanded = expanded
        guard animated else {
            panel.setFrame(rect, display: true)
            panel.orderFrontRegardless()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.52
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 1.22, 0.36, 1)
            panel.animator().setFrame(rect, display: true)
        }
        panel.orderFrontRegardless()
    }
}

struct HubView: View {
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var hub: HubController
    var showSettings: () -> Void
    var setLaunchAtLogin: (Bool) -> Void
    var loginStatus: () -> String

    init(model: PressureAppModel, hub: HubController) {
        monitor = model.monitor
        configStore = model.configStore
        self.hub = hub
        showSettings = { model.showSettings() }
        setLaunchAtLogin = { model.setLaunchAtLogin($0) }
        loginStatus = { model.loginItemStatus }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            if hub.isExpanded {
                Capsule()
                    .fill(pressureColor)
                    .frame(width: 6)
                    .padding(.vertical, 22)
                    .padding(.trailing, 14)
                controls
                    .transition(.opacity)
            } else {
                liveColumn
            }
        }
        .padding(.horizontal, hub.isExpanded ? CGFloat(HubLayout.contentMargin) : 6)
        .padding(.vertical, hub.isExpanded ? 18 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.76), value: hub.isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pressure Hub")
    }

    private var cornerRadius: CGFloat {
        CGFloat(hub.isExpanded ? HubLayout.expandedCornerRadius : HubLayout.collapsedCornerRadius)
    }

    private var liveColumn: some View {
        VStack(spacing: hub.isExpanded ? 10 : 8) {
            Circle()
                .fill(pressureColor)
                .frame(width: hub.isExpanded ? 12 : 10, height: hub.isExpanded ? 12 : 10)
                .shadow(color: pressureColor.opacity(0.85), radius: 8)
            Text(scoreText)
                .font(.system(size: hub.isExpanded ? 22 : 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(width: hub.isExpanded ? 64 : nil)
        .frame(maxHeight: .infinity)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Hub")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 8)
                    Text(scoreText)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(pressureColor)
                        .monospacedDigit()
                }
                Text(availableText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            VStack(spacing: 0) {
                hubToggle("Auto-close", systemImage: "arrow.down.app", keyPath: \.autoCloseEnabled)
                hairline
                hubToggle("Warning alerts", systemImage: "bell", keyPath: \.notifyOnWarning)
                hairline
                hubToggle("Before quit", systemImage: "bell.badge", keyPath: \.notifyBeforeAutoClose)
                hairline
                launchRow
            }
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: CGFloat(HubLayout.innerCornerRadius), style: .continuous))

            if let status = loginMessage {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !topApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Using the most")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                    ForEach(topApps) { app in
                        HStack {
                            Text(app.name)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(ByteFormat.string(app.residentBytes))
                                .monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                    }
                }
            }

            Button(action: {
                hub.collapse()
                showSettings()
            }) {
                Text("All Settings")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, 46)
    }

    private var launchRow: some View {
        hubToggleButton(
            title: "Launch at login",
            systemImage: "power",
            isOn: configStore.config.launchAtLogin,
            set: setLaunchAtLogin
        )
    }

    private func hubToggle(
        _ title: String,
        systemImage: String,
        keyPath: WritableKeyPath<AppConfig, Bool>
    ) -> some View {
        hubToggleButton(
            title: title,
            systemImage: systemImage,
            isOn: configStore.config[keyPath: keyPath],
            set: { newValue in
                configStore.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    private func hubToggleButton(
        title: String,
        systemImage: String,
        isOn: Bool,
        set: @escaping (Bool) -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? pressureColor : Color.white.opacity(0.9))
                .frame(width: 28, height: 28)
                .background(
                    Color.white.opacity(isOn ? 0.16 : 0.08),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            Toggle(title, isOn: Binding(get: { isOn }, set: set))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(pressureColor)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var topApps: [AppFootprint] {
        Array(monitor.topFootprints.prefix(3))
    }

    private var scoreText: String {
        guard let snapshot = monitor.snapshot else { return "—" }
        return PercentFormat.string(snapshot.displayScore(config: configStore.config))
    }

    private var availableText: String {
        guard let snapshot = monitor.snapshot else { return "Reading memory" }
        return "\(ByteFormat.string(snapshot.availableBytes)) free"
    }

    private var pressureColor: Color {
        let level = monitor.snapshot?.level(config: configStore.config) ?? .ok
        switch level {
        case .ok:
            return Color(nsColor: .systemGreen)
        case .warning:
            return Color(nsColor: .systemYellow)
        case .critical:
            return Color(nsColor: .systemRed)
        }
    }

    private var loginMessage: String? {
        let status = loginStatus()
        return status.isEmpty ? nil : status
    }
}
