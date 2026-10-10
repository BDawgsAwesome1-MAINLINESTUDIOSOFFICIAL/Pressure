import AppKit
import Combine
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
    private var alertHold = false
    private var alertToken = 0
    private var showsNowPlaying = false
    private var showsTimer = false
    private var showsStopwatch = false
    private var layoutKey = ""
    private var cancellables: Set<AnyCancellable> = []

    init(model: PressureAppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HubLayout.collapsedWidth, height: HubLayout.collapsedHeight(nowPlaying: false, timer: false, stopwatch: false)),
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
        panel.title = "Pressure"
        panel.identifier = NSUserInterfaceItemIdentifier("PressureHub")

        let host = NSHostingController(rootView: HubView(model: model, hub: self))
        host.view.autoresizingMask = [.width, .height]
        panel.contentView = host.view

        model.island.onAlert = { [weak self] in
            self?.presentAlert()
        }
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
        observeContent()
        guard !previewLocked else { return }

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.trackPointer()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }


    private func observeContent() {
        let island = model.island
        island.$media
            .combineLatest(island.$countdown, island.$stopwatch, island.$alertMessage)
            .sink { [weak self] media, countdown, stopwatch, alert in
                self?.noteContent(
                    nowPlaying: media?.isPlaying == true,
                    timer: countdown.phase == .running || alert != nil,
                    stopwatch: stopwatch.phase == .running
                )
            }
            .store(in: &cancellables)
    }

    private func noteContent(nowPlaying: Bool, timer: Bool, stopwatch: Bool) {
        let key = "\(nowPlaying)-\(timer)-\(stopwatch)"
        guard key != layoutKey else { return }
        layoutKey = key
        showsNowPlaying = nowPlaying
        showsTimer = timer
        showsStopwatch = stopwatch
        let screen = anchoredScreen ?? NSScreen.main ?? NSScreen.screens.first
        place(expanded: isExpanded, on: screen, animated: panel.isVisible)
    }

    func collapse() {
        guard !previewLocked else { return }
        alertHold = false
        place(expanded: false, on: anchoredScreen ?? NSScreen.main, animated: true)
    }

    private func presentAlert() {
        guard !previewLocked else { return }
        alertHold = true
        cancelCollapse()
        let screen = anchoredScreen ?? NSScreen.main ?? NSScreen.screens.first
        place(expanded: true, on: screen, animated: true)
        alertToken += 1
        let token = alertToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.2))
            guard token == self.alertToken else { return }
            self.alertHold = false
            self.trackPointer()
        }
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
            visibleHeight: Double(home.visibleFrame.height),
            nowPlaying: showsNowPlaying,
            timer: showsTimer,
            stopwatch: showsStopwatch
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
            if !alertHold {
                scheduleCollapse()
            }
        } else if anchoredScreen != screen {
            anchoredScreen = screen
            place(expanded: false, on: screen, animated: false)
        }
    }

    private func scheduleCollapse() {
        guard !collapsePending, !alertHold else { return }
        collapsePending = true
        collapseGeneration += 1
        let generation = collapseGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(420))
            guard generation == self.collapseGeneration else { return }
            self.collapsePending = false
            guard !self.previewLocked, !self.alertHold else { return }
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
            visibleHeight: Double(screen.visibleFrame.height),
            nowPlaying: showsNowPlaying,
            timer: showsTimer,
            stopwatch: showsStopwatch
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
    @ObservedObject var island: IslandModel
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var hub: HubController
    var showSettings: () -> Void

    init(model: PressureAppModel, hub: HubController) {
        island = model.island
        monitor = model.monitor
        configStore = model.configStore
        self.hub = hub
        showSettings = { model.showSettings() }
    }

    var body: some View {
        Group {
            if hub.isExpanded {
                expandedCard
            } else {
                compactPill
            }
        }
        .padding(.horizontal, hub.isExpanded ? CGFloat(HubLayout.contentMargin) : CGFloat(HubLayout.collapsedPadH))
        .padding(.vertical, hub.isExpanded ? 10 : CGFloat(HubLayout.collapsedPadV))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
        }
        .animation(.spring(response: 0.48, dampingFraction: 0.76), value: hub.isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pressure, a Dynamic Island for Mac")
        .accessibilityIdentifier("PressureIsland")
    }

    private var cornerRadius: CGFloat {
        CGFloat(hub.isExpanded ? HubLayout.expandedCornerRadius : HubLayout.collapsedCornerRadius)
    }

    private var compactPill: some View {
        VStack(spacing: CGFloat(HubLayout.rowGap)) {
            compactBattery
            if island.media?.isPlaying == true {
                compactNowPlaying
            }
            if island.countdown.phase == .running || island.alertMessage != nil {
                Text(island.alertMessage ?? IslandTimeFormat.countdown(island.countdown.remaining))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(height: CGFloat(HubLayout.timeRow))
            }
            if island.stopwatch.phase == .running {
                Text(IslandTimeFormat.stopwatch(island.stopwatch.elapsed))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(nsColor: .systemYellow))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .frame(height: CGFloat(HubLayout.timeRow))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var compactBattery: some View {
        HStack(spacing: 2) {
            if island.power.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 8, weight: .bold))
            } else if island.power.mode == .ac {
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(island.power.mode == .ac ? "AC" : island.power.compactText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .foregroundStyle(powerColor)
        .frame(height: CGFloat(HubLayout.batteryRow))
    }

    private var compactNowPlaying: some View {
        HStack(spacing: 4) {
            coverArt(side: 22)
            Button(action: island.playPause) {
                Image(systemName: island.media?.isPlaying == true ? "pause.fill" : "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(Color.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(island.media?.isPlaying == true ? "Pause" : "Play")
        }
        .frame(height: CGFloat(HubLayout.mediaRow))
    }

    private var expandedCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header
                nowPlayingRow
                timerRow
                stopwatchRow
                powerRow
                if island.nextEvent != nil {
                    eventRow
                }
                memoryRow
                Button(action: {
                    hub.collapse()
                    showSettings()
                }) {
                    Text("Settings")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
    }

    private var header: some View {
        Button(action: openHeader) {
            VStack(alignment: .leading, spacing: 2) {
                Text(island.headerTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Text(island.headerValue)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if island.compactKind == .nowPlaying, let artist = island.media?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private var nowPlayingRow: some View {
        row {
            VStack(alignment: .leading, spacing: 8) {
                Button(action: island.openNowPlaying) {
                    HStack(spacing: 8) {
                        coverArt(side: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(nowPlayingTitle)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(nowPlayingSubtitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                    }
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    transport("backward.fill", action: island.previousTrack)
                    transport(island.media?.isPlaying == true ? "pause.fill" : "play.fill", action: island.playPause)
                    transport("forward.fill", action: island.nextTrack)
                }
            }
        }
    }

    private var timerRow: some View {
        row {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Timer", systemImage: "timer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text(island.alertMessage ?? IslandTimeFormat.countdown(island.displayedRemaining))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    preset("1", minutes: 1)
                    preset("5", minutes: 5)
                    preset("15", minutes: 15)
                    preset("25", minutes: 25)
                }
                HStack(spacing: 6) {
                    actionChip("Start", enabled: island.countdown.phase != .running, action: island.startTimer)
                    actionChip("Pause", enabled: island.countdown.phase == .running, action: island.pauseTimer)
                    actionChip("Cancel", enabled: island.countdown.phase != .idle, action: island.cancelTimer)
                }
            }
        }
    }

    private var stopwatchRow: some View {
        row {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Stopwatch", systemImage: "stopwatch")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text(IslandTimeFormat.stopwatch(island.stopwatch.elapsed))
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(nsColor: .systemYellow))
                        .monospacedDigit()
                }
                if let lap = island.stopwatch.lastLap {
                    Text("Last lap \(IslandTimeFormat.stopwatch(lap))")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .monospacedDigit()
                }
                HStack(spacing: 6) {
                    actionChip(island.stopwatch.phase == .running ? "Stop" : "Start", enabled: true, action: island.toggleStopwatch)
                    actionChip("Lap", enabled: island.stopwatch.phase == .running, action: island.lap)
                    actionChip("Reset", enabled: island.stopwatch.phase != .idle || island.stopwatch.elapsed > 0, action: island.resetStopwatch)
                }
            }
        }
    }

    private var powerRow: some View {
        Button(action: island.openPowerSettings) {
            row {
                HStack(spacing: 10) {
                    Image(systemName: island.power.symbolName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(powerColor)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(island.power.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(island.power.detail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer(minLength: 8)
                    Text(island.power.mode == .ac ? "AC" : island.power.compactText)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(powerColor)
                        .monospacedDigit()
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var eventRow: some View {
        Button(action: island.openCalendar) {
            row {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemBlue))
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(island.nextEvent?.title ?? "Calendar")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let event = island.nextEvent {
                            Text(island.eventTime(event))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    Spacer(minLength: 4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var memoryRow: some View {
        row {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(memoryColor)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Memory \(island.memoryPercent)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(island.memoryFree)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer(minLength: 6)
                Button(action: {
                    configStore.update { $0.autoCloseEnabled.toggle() }
                }) {
                    Text(configStore.config.autoCloseEnabled ? "Auto-close on" : "Auto-close off")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            configStore.config.autoCloseEnabled ? memoryColor.opacity(0.9) : Color.white.opacity(0.14),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }


    private func coverArt(side: CGFloat) -> some View {
        Group {
            if let image = island.artwork {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color(nsColor: .systemPink)
                    Text(coverMark)
                        .font(.system(size: side * 0.38, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }

    private var coverMark: String {
        let title = island.media?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let words = title.split(whereSeparator: { $0.isWhitespace })
        let letters = words.prefix(2).compactMap(\.first)
        if letters.isEmpty { return "♪" }
        return String(letters).uppercased()
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.white.opacity(0.08),
                in: RoundedRectangle(cornerRadius: CGFloat(HubLayout.innerCornerRadius), style: .continuous)
            )
    }

    private func preset(_ title: String, minutes: Int) -> some View {
        let selected = Int(island.countdown.presetSeconds / 60) == minutes
        return Button(action: { island.startPreset(minutes: minutes) }) {
            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(selected ? Color(nsColor: .systemOrange) : Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) minute timer")
    }

    private func actionChip(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(enabled ? .white : .white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.white.opacity(enabled ? 0.14 : 0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func transport(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var nowPlayingTitle: String {
        let title = island.media?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Not playing" : title
    }

    private var nowPlayingSubtitle: String {
        guard let media = island.media else { return "Music or Spotify" }
        let artist = media.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = media.isPlaying ? "Playing" : "Paused"
        if artist.isEmpty { return "\(media.source.appName) · \(state)" }
        return "\(artist) · \(media.source.appName)"
    }

    private func openHeader() {
        switch island.compactKind {
        case .nowPlaying:
            island.openNowPlaying()
        case .calendar:
            island.openCalendar()
        case .battery:
            island.openPowerSettings()
        case .timer, .stopwatch, .memory:
            break
        }
    }

    private var accent: Color {
        switch island.compactKind {
        case .timer:
            return Color(nsColor: .systemOrange)
        case .stopwatch:
            return Color(nsColor: .systemYellow)
        case .nowPlaying:
            return Color(nsColor: .systemPink)
        case .battery:
            return powerColor
        case .calendar:
            return Color(nsColor: .systemBlue)
        case .memory:
            return memoryColor
        }
    }

    private var powerColor: Color {
        if island.power.isLow { return Color(nsColor: .systemRed) }
        if island.power.isCharging { return Color(nsColor: .systemGreen) }
        if island.power.mode == .ac { return Color(nsColor: .systemYellow) }
        return Color(nsColor: .systemGreen)
    }

    private var memoryColor: Color {
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
}
