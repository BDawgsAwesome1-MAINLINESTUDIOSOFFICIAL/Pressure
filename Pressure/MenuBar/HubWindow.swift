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
    private var showsCursor = false
    private var showsMessages = false
    private var showsActions = false
    private var layoutKey = ""
    private var cancellables: Set<AnyCancellable> = []

    init(model: PressureAppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HubLayout.collapsedWidth, height: HubLayout.collapsedHeight(nowPlaying: false, timer: false, stopwatch: false, cursor: false)),
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

    /// Puts the side island back in front after the Dock app is closed.
    func keepVisible() {
        panel.orderFrontRegardless()
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
                    stopwatch: stopwatch.phase == .running,
                    cursor: self?.showsCursor ?? false,
                    messages: self?.showsMessages ?? false,
                    actions: self?.showsActions ?? false
                )
            }
            .store(in: &cancellables)
        island.$cursor
            .sink { [weak self] cursor in
                guard let self else { return }
                self.noteContent(
                    nowPlaying: self.showsNowPlaying,
                    timer: self.showsTimer,
                    stopwatch: self.showsStopwatch,
                    cursor: cursor.showsOnPill,
                    messages: self.showsMessages,
                    actions: self.showsActions
                )
            }
            .store(in: &cancellables)
        island.$messages
            .sink { [weak self] messages in
                guard let self else { return }
                self.noteContent(
                    nowPlaying: self.showsNowPlaying,
                    timer: self.showsTimer,
                    stopwatch: self.showsStopwatch,
                    cursor: self.showsCursor,
                    messages: messages.showsOnPill,
                    actions: self.showsActions
                )
            }
            .store(in: &cancellables)
        island.$actions
            .sink { [weak self] actions in
                guard let self else { return }
                self.noteContent(
                    nowPlaying: self.showsNowPlaying,
                    timer: self.showsTimer,
                    stopwatch: self.showsStopwatch,
                    cursor: self.showsCursor,
                    messages: self.showsMessages,
                    actions: actions.showsOnPill
                )
            }
            .store(in: &cancellables)
    }

    private func noteContent(
        nowPlaying: Bool,
        timer: Bool,
        stopwatch: Bool,
        cursor: Bool,
        messages: Bool,
        actions: Bool
    ) {
        let key = "\(nowPlaying)-\(timer)-\(stopwatch)-\(cursor)-\(messages)-\(actions)"
        guard key != layoutKey else { return }
        layoutKey = key
        showsNowPlaying = nowPlaying
        showsTimer = timer
        showsStopwatch = stopwatch
        showsCursor = cursor
        showsMessages = messages
        showsActions = actions
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
            stopwatch: showsStopwatch,
            cursor: showsCursor,
            messages: showsMessages,
            actions: showsActions
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
            stopwatch: showsStopwatch,
            cursor: showsCursor,
            messages: showsMessages,
            actions: showsActions
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

private struct CheckStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.26, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.44, y: rect.minY + rect.height * 0.70))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.34))
        return path
    }
}

/// Circle, then check, each drawn with a stroke trim the way Apple Pay finishes a payment.
private struct DrawnCheck: View {
    var startedAt: Date
    var side: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { context in
            let elapsed = context.date.timeIntervalSince(startedAt)
            let circle = min(1, max(0, elapsed / 0.42))
            let check = min(1, max(0, (elapsed - 0.28) / 0.36))
            let width = max(1.6, side * 0.12)
            ZStack {
                Circle()
                    .trim(from: 0, to: circle)
                    .stroke(
                        Color(nsColor: .systemGreen),
                        style: StrokeStyle(lineWidth: width, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                CheckStroke()
                    .trim(from: 0, to: check)
                    .stroke(
                        Color(nsColor: .systemGreen),
                        style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
                    )
            }
        }
        .frame(width: side, height: side)
        .accessibilityLabel("Finished")
    }
}

private struct SpinningStar: View {
    var spinning: Bool
    var size: CGFloat

    var body: some View {
        let symbol = Image(systemName: "sparkle")
            .font(.system(size: size, weight: .bold))
        if spinning, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                symbol.rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 240))
            }
        } else {
            symbol
        }
    }
}

struct HubView: View {
    @ObservedObject var island: IslandModel
    @ObservedObject var monitor: MemoryMonitor
    @ObservedObject var configStore: ConfigStore
    @ObservedObject var hub: HubController
    var showSettings: () -> Void
    var resetPressure: () -> Void

    init(model: PressureAppModel, hub: HubController) {
        island = model.island
        monitor = model.monitor
        configStore = model.configStore
        self.hub = hub
        showSettings = { model.showSettings() }
        resetPressure = { model.resetPressure() }
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
            if island.messages.showsOnPill {
                compactMessages
            }
            if island.actions.showsOnPill {
                compactActions
            }
            if island.cursor.showsOnPill {
                compactCursor
            }
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

    private var compactMessages: some View {
        HStack(spacing: 2) {
            if island.messages.showSentCheck, let started = island.messages.sentAt {
                DrawnCheck(startedAt: started, side: 14)
            } else {
                Image(systemName: "message.fill")
                    .font(.system(size: 9, weight: .bold))
                if !island.messages.pillText.isEmpty {
                    Text(island.messages.pillText)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
        .foregroundStyle(Color(nsColor: .systemGreen))
        .frame(height: CGFloat(HubLayout.cursorRow))
        .accessibilityLabel("New iMessage")
    }

    private var compactActions: some View {
        HStack(spacing: 2) {
            if island.actions.showCheck, let started = island.actions.finishedAt {
                DrawnCheck(startedAt: started, side: 14)
            } else if island.actions.showFailure {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: .systemRed))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 240))
                }
                if !island.actions.pillText.isEmpty {
                    Text(island.actions.pillText)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                }
            }
        }
        .foregroundStyle(Color(nsColor: .systemPurple))
        .frame(height: CGFloat(HubLayout.cursorRow))
        .accessibilityLabel(island.actions.headline.isEmpty ? "GitHub Actions" : island.actions.headline)
    }

    private var compactCursor: some View {
        Group {
            if island.cursor.isWorking {
                HStack(spacing: 2) {
                    SpinningStar(spinning: true, size: 8)
                    Text(island.cursor.pillText)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .foregroundStyle(Color(nsColor: .systemTeal))
            } else if let started = island.cursor.finishedAt {
                DrawnCheck(startedAt: started, side: 14)
            }
        }
        .frame(height: CGFloat(HubLayout.cursorRow))
        .accessibilityLabel(island.cursor.isWorking ? (island.cursor.headline.isEmpty ? "Cursor" : island.cursor.headline) : "Finished")
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
                if island.messages.showsOnPill || island.messages.note != nil {
                    messagesSection
                }
                if island.actions.showsOnPill || island.actions.note != nil {
                    actionsSection
                }
                if island.cursor.isActive {
                    cursorSection
                }
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

    private var messagesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("iMessage")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemGreen))
                Spacer()
                if !island.messages.unseen.isEmpty {
                    Button("Seen") { island.markMessagesSeen() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
            if let note = island.messages.note {
                Text(note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if island.messages.needsAccess {
                Button("Reset Pressure", action: resetPressure)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.14), in: Capsule())
            }
            ForEach(island.messages.unseen.prefix(3)) { message in
                VStack(alignment: .leading, spacing: 1) {
                    Text(message.sender)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(message.body)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }
            if island.messages.latest != nil {
                HStack(spacing: 6) {
                    TextField(
                        "Reply",
                        text: Binding(
                            get: { island.messageDraft },
                            set: { island.messageDraft = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onSubmit { island.sendMessageReply() }
                    Button(action: island.sendMessageReply) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(Color(nsColor: .systemGreen))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send reply")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if island.actions.showCheck, let started = island.actions.finishedAt {
                    DrawnCheck(startedAt: started, side: 16)
                } else if !island.actions.running.isEmpty {
                    TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .bold))
                            .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 240))
                    }
                }
                Text(island.actions.running.isEmpty ? "GitHub Actions" : "GitHub Actions · \(island.actions.running.count)")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(island.actions.showFailure ? Color(nsColor: .systemRed) : Color(nsColor: .systemPurple))
            if let note = island.actions.note {
                Text(note)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let current = island.actions.running.first {
                Text(current.headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(current.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            } else if island.actions.showCheck {
                Text("Passed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            } else if island.actions.showFailure {
                Text("Failed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemRed))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if island.cursor.isWorking {
                    SpinningStar(spinning: true, size: 11)
                        .foregroundStyle(Color(nsColor: .systemTeal))
                } else if let started = island.cursor.finishedAt {
                    DrawnCheck(startedAt: started, side: 16)
                }
                Text(island.cursor.runningCount > 0 ? "Cursor · \(island.cursor.runningCount)" : "Cursor")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemTeal))
                Spacer()
                if !island.cursor.requestCost.isEmpty {
                    Text(island.cursor.requestCost)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .accessibilityLabel("Estimated request cost \(island.cursor.requestCost)")
                }
            }
            ForEach(island.cursor.lines) { line in
                VStack(alignment: .leading, spacing: 1) {
                    Text(line.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(line.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
                            if let note = island.playbackNote, !note.isEmpty {
                                Text(note)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(Color(nsColor: .systemOrange))
                                    .lineLimit(2)
                            }
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
