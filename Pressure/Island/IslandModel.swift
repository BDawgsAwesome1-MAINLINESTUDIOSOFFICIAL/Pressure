import AppKit
import Combine

enum CountdownPhase: Equatable {
    case idle
    case running
    case paused
}

struct CountdownState: Equatable {
    var phase: CountdownPhase = .idle
    var remaining: TimeInterval = 5 * 60
    var presetSeconds: TimeInterval = 5 * 60
}

enum StopwatchPhase: Equatable {
    case idle
    case running
    case stopped
}

struct StopwatchState: Equatable {
    var phase: StopwatchPhase = .idle
    var elapsed: TimeInterval = 0
    var lastLap: TimeInterval?
    var lapAnchor: TimeInterval = 0
}

@MainActor
final class IslandModel: ObservableObject {
    let monitor: MemoryMonitor
    let configStore: ConfigStore

    @Published private(set) var media: MediaSample?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var power: PowerReading
    @Published private(set) var nextEvent: AgendaEvent?
    @Published private(set) var countdown = CountdownState()
    @Published private(set) var stopwatch = StopwatchState()
    @Published private(set) var alertMessage: String?
    @Published private(set) var playbackNote: String?
    @Published private(set) var cursor = CursorSnapshot()
    @Published private(set) var messages = MessageSnapshot()
    @Published private(set) var actions = ActionSnapshot()
    @Published var messageDraft = ""

    var onAlert: (() -> Void)?
    var onPlaybackNote: ((String) -> Void)?

    private let agenda = CalendarAgenda()
    private var clock: Timer?
    private var mediaTimer: Timer?
    private var powerTimer: Timer?
    private var cursorTimer: Timer?
    private var messageTimer: Timer?
    private var actionTimer: Timer?
    private var actionMemory = ActionMemory()
    private var latestRuns: [ActionRun] = []
    private var messageSentAt: Date?
    private var countdownEndsAt: Date?
    private var stopwatchStartedAt: Date?
    private var accumulatedStopwatch: TimeInterval = 0
    private var countdownFinished = false
    private var artworkURL = ""
    private var lastPlaybackNote: String?
    private let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    init(monitor: MemoryMonitor, configStore: ConfigStore) {
        self.monitor = monitor
        self.configStore = configStore
        power = PowerReader.read()
        agenda.onEvent = { [weak self] event in
            self?.nextEvent = event
        }
    }

    func start() {
        agenda.start()
        refreshPower()
        CursorBridge.install()
        refreshCursor()
        refreshMessages()
        refreshActions()
        Task { @MainActor in
            self.pollMedia()
        }

        let clock = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickClock()
            }
        }
        let mediaTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollMedia()
            }
        }
        let powerTimer = Timer(timeInterval: 8, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPower()
            }
        }
        let cursorTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshCursor()
            }
        }
        let messageTimer = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshMessages()
            }
        }
        let actionTimer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshActions()
            }
        }
        RunLoop.main.add(clock, forMode: .common)
        RunLoop.main.add(mediaTimer, forMode: .common)
        RunLoop.main.add(powerTimer, forMode: .common)
        RunLoop.main.add(cursorTimer, forMode: .common)
        RunLoop.main.add(messageTimer, forMode: .common)
        RunLoop.main.add(actionTimer, forMode: .common)
        self.clock = clock
        self.mediaTimer = mediaTimer
        self.powerTimer = powerTimer
        self.cursorTimer = cursorTimer
        self.messageTimer = messageTimer
        self.actionTimer = actionTimer
    }

    var candidates: IslandCandidates {
        IslandCandidates(
            timerRunning: countdown.phase == .running,
            timerAlert: alertMessage != nil,
            stopwatchRunning: stopwatch.phase == .running,
            nowPlaying: media?.isPlaying == true,
            hasPower: true,
            hasCalendarEvent: nextEvent != nil
        )
    }

    var compactKind: IslandActivityKind {
        IslandPriority.compact(candidates)
    }

    var compactSymbol: String {
        switch compactKind {
        case .timer:
            return "timer"
        case .stopwatch:
            return "stopwatch"
        case .nowPlaying:
            return "music.note"
        case .battery:
            return power.symbolName
        case .calendar:
            return "calendar"
        case .memory:
            return "gauge.with.dots.needle.33percent"
        }
    }

    var compactText: String {
        switch compactKind {
        case .timer:
            if alertMessage != nil { return "Done" }
            return IslandTimeFormat.countdown(displayedRemaining)
        case .stopwatch:
            return IslandTimeFormat.stopwatch(stopwatch.elapsed)
        case .nowPlaying:
            let title = media?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? (media?.source.appName ?? "Music") : title
        case .battery:
            return power.compactText
        case .calendar:
            guard let nextEvent else { return "Today" }
            if nextEvent.isAllDay { return "Today" }
            return clockFormatter.string(from: nextEvent.start)
        case .memory:
            return memoryPercent
        }
    }

    var headerTitle: String {
        switch compactKind {
        case .timer: return "Timer"
        case .stopwatch: return "Stopwatch"
        case .nowPlaying: return "Now Playing"
        case .battery: return power.title
        case .calendar: return "Calendar"
        case .memory: return "Memory"
        }
    }

    var headerValue: String {
        switch compactKind {
        case .timer:
            return alertMessage ?? IslandTimeFormat.countdown(displayedRemaining)
        case .stopwatch:
            return IslandTimeFormat.stopwatch(stopwatch.elapsed)
        case .nowPlaying:
            let title = media?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return title.isEmpty ? "Not playing" : title
        case .battery:
            return power.mode == .ac ? "AC" : power.compactText
        case .calendar:
            return nextEvent?.title ?? "Nothing today"
        case .memory:
            return memoryPercent
        }
    }

    var displayedRemaining: TimeInterval {
        if countdown.phase == .idle { return countdown.presetSeconds }
        return max(0, countdown.remaining)
    }

    var memoryPercent: String {
        guard let snapshot = monitor.snapshot else { return "—" }
        return PercentFormat.string(snapshot.displayScore(config: configStore.config))
    }

    var memoryFree: String {
        guard let snapshot = monitor.snapshot else { return "Reading memory" }
        return "\(ByteFormat.string(snapshot.availableBytes)) free"
    }

    func eventTime(_ event: AgendaEvent) -> String {
        if event.isAllDay { return "All day" }
        if event.isHappening { return "Now · \(clockFormatter.string(from: event.start))" }
        return clockFormatter.string(from: event.start)
    }

    func startPreset(minutes: Int) {
        let seconds = TimeInterval(minutes * 60)
        countdownFinished = false
        alertMessage = nil
        countdown.presetSeconds = seconds
        countdown.remaining = seconds
        countdown.phase = .running
        countdownEndsAt = Date().addingTimeInterval(seconds)
    }

    func startTimer() {
        guard countdown.phase != .running else { return }
        countdownFinished = false
        alertMessage = nil
        let seconds = countdown.phase == .paused ? countdown.remaining : countdown.presetSeconds
        countdown.remaining = seconds
        countdown.phase = .running
        countdownEndsAt = Date().addingTimeInterval(seconds)
    }

    func pauseTimer() {
        guard countdown.phase == .running else { return }
        countdown.remaining = max(0, countdownEndsAt?.timeIntervalSinceNow ?? countdown.remaining)
        countdownEndsAt = nil
        countdown.phase = .paused
    }

    func cancelTimer() {
        countdownEndsAt = nil
        countdownFinished = false
        alertMessage = nil
        countdown.phase = .idle
        countdown.remaining = countdown.presetSeconds
    }

    func toggleStopwatch() {
        if stopwatch.phase == .running {
            accumulatedStopwatch = stopwatch.elapsed
            stopwatchStartedAt = nil
            stopwatch.phase = .stopped
            return
        }
        stopwatchStartedAt = Date()
        stopwatch.phase = .running
    }

    func lap() {
        guard stopwatch.phase == .running else { return }
        let lapTime = max(0, stopwatch.elapsed - stopwatch.lapAnchor)
        stopwatch.lastLap = lapTime
        stopwatch.lapAnchor = stopwatch.elapsed
    }

    func resetStopwatch() {
        stopwatchStartedAt = nil
        accumulatedStopwatch = 0
        stopwatch = StopwatchState()
    }

    func playPause() {
        MediaController.playPause(current: media)
        refreshMediaSoon()
    }

    func nextTrack() {
        MediaController.next(current: media)
        refreshMediaSoon()
    }

    func previousTrack() {
        MediaController.previous(current: media)
        refreshMediaSoon()
    }

    func openNowPlaying() {
        MediaController.open(media?.source ?? .music)
    }

    func openPowerSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.Battery.extension",
            "x-apple.systempreferences:com.apple.Battery-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.battery"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func openCalendar() {
        agenda.openCalendar()
    }

    private func tickClock() {
        if countdown.phase == .running, let ends = countdownEndsAt {
            let left = ends.timeIntervalSinceNow
            if left <= 0 {
                finishTimer()
            } else if abs(left - countdown.remaining) >= 0.05 {
                countdown.remaining = left
            }
        }

        if stopwatch.phase == .running, let started = stopwatchStartedAt {
            let elapsed = accumulatedStopwatch + Date().timeIntervalSince(started)
            if abs(elapsed - stopwatch.elapsed) >= 0.05 {
                stopwatch.elapsed = elapsed
            }
        }
    }

    private func finishTimer() {
        countdownEndsAt = nil
        countdown.phase = .idle
        countdown.remaining = countdown.presetSeconds
        guard !countdownFinished else { return }
        countdownFinished = true
        alertMessage = "Done"
        NSSound(named: NSSound.Name("Glass"))?.play()
        onAlert?()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4.2))
            if self.alertMessage == "Done" {
                self.alertMessage = nil
            }
        }
    }

    private func pollMedia() {
        switch MediaController.poll() {
        case .failed:
            break
        case .update(let sample, let note):
            media = sample
            syncArtwork(with: sample)
            guard note != playbackNote else { return }
            playbackNote = note
            if let note, note != lastPlaybackNote {
                lastPlaybackNote = note
                onPlaybackNote?(note)
            } else if note == nil {
                lastPlaybackNote = nil
            }
        }
    }

    private func syncArtwork(with sample: MediaSample?) {
        let next = sample?.artworkURL.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fileBacked = next.hasPrefix("/") || next.hasPrefix("file:")
        if next == artworkURL && !fileBacked { return }
        artworkURL = next
        guard !next.isEmpty else {
            artwork = nil
            return
        }
        let token = next
        ArtworkLoader.load(next) { image in
            Task { @MainActor in
                guard self.artworkURL == token else { return }
                if let image {
                    self.artwork = image
                } else if !fileBacked {
                    self.artwork = nil
                }
            }
        }
    }

    private func refreshMediaSoon() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            self.pollMedia()
        }
    }

    func sendMessageReply() {
        guard let message = messages.latest else { return }
        let text = messageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let error = MessageInbox.send(text, chatID: message.chatID) {
            messages.note = error
            return
        }
        messageDraft = ""
        MessageInbox.acknowledge(message.appleDate)
        messageSentAt = Date()
        refreshMessages()
    }

    func markMessagesSeen() {
        guard let newest = messages.unseen.map(\.appleDate).max() else { return }
        MessageInbox.acknowledge(newest)
        messageSentAt = nil
        refreshMessages()
    }

    private func refreshMessages() {
        let next = MessageInbox.poll(sentAt: messageSentAt)
        if next != messages {
            messages = next
        }
    }

    private func refreshActions() {
        let result = GitHubActions.poll(memory: actionMemory)
        actionMemory = result.0
        latestRuns = result.1.running
        if result.1 != actions {
            actions = result.1
        }
    }

    private func refreshCursor() {
        let next = CursorActivityReader.load()
        if next != cursor {
            cursor = next
        }
        if messages.showSentCheck {
            refreshMessages()
        }
        if actions.showCheck || actions.showFailure {
            let result = ActionBoard.reduce(previous: actionMemory, runs: latestRuns, now: Date())
            actionMemory = result.0
            if result.1 != actions {
                actions = result.1
            }
        }
    }

    private func refreshPower() {
        let reading = PowerReader.read()
        if reading != power {
            power = reading
        }
    }
}
