import Combine
import Foundation
import UserNotifications

@MainActor
final class PressureEngine {
    private let monitor: MemoryMonitor
    private let configStore: ConfigStore
    private let log: ActionLog
    private let closer = AppCloser()
    private let notifications = PressureNotifications()

    private var episodeActive = false
    private var closesThisEpisode = 0
    private var isClosing = false
    private var warnedThisEpisode = false
    private var reportedEmptyList = false
    private var reportedCap = false
    private var attemptedBundleIDs = Set<String>()
    private var cancellable: AnyCancellable?

    init(monitor: MemoryMonitor, configStore: ConfigStore, log: ActionLog) {
        self.monitor = monitor
        self.configStore = configStore
        self.log = log
    }

    func start() {
        notifications.prepare()
        cancellable = monitor.$snapshot.sink { [weak self] snapshot in
            guard let self, let snapshot else { return }
            self.consume(snapshot)
        }
    }

    func purge() {
        let script = "do shell script \"/usr/sbin/purge\" with administrator privileges"
        var errorInfo: NSDictionary?
        let result = NSAppleScript(source: script)?.executeAndReturnError(&errorInfo)
        guard result != nil else {
            let message = errorInfo?[NSAppleScript.errorMessage] as? String ?? "Purge was cancelled."
            log.record(message)
            return
        }
        log.record("Purged inactive memory.")
        monitor.poll()
    }

    func closeManually(_ app: RankedApp) async {
        guard !isClosing else { return }
        isClosing = true
        defer { isClosing = false }
        let outcome = await closer.close(pid: app.pid)
        log.record(outcome.message)
        monitor.poll()
    }

    private func consume(_ snapshot: MemorySnapshot) {
        let config = configStore.config
        let score = snapshot.displayScore(config: config)
        let decision = PressurePolicy.step(
            score: score,
            config: config,
            episodeActive: episodeActive,
            closesThisEpisode: closesThisEpisode,
            isClosing: isClosing
        )

        if !decision.episodeActive {
            warnedThisEpisode = false
            reportedEmptyList = false
            reportedCap = false
            attemptedBundleIDs.removeAll()
        }
        episodeActive = decision.episodeActive
        closesThisEpisode = decision.closesThisEpisode

        let level = PressureLevel.resolve(score: score, config: config)
        if level != .ok && !warnedThisEpisode && config.notifyOnWarning {
            warnedThisEpisode = true
            notifications.post(
                "Memory pressure is \(PercentFormat.string(score)). Available memory is \(ByteFormat.string(snapshot.availableBytes))."
            )
        }

        guard decision.wantsClose else {
            if decision.episodeActive && closesThisEpisode >= PressurePolicy.maxClosesPerEpisode && !reportedCap {
                reportedCap = true
                log.record("Paused auto-close after \(PressurePolicy.maxClosesPerEpisode) apps. Pressure is still high.")
            }
            return
        }

        let ranked = monitor.footprints.compactMap { $0.ranked() }
        guard let target = AppPriority.autoCloseTarget(
            apps: ranked,
            config: config,
            selfBundleID: Bundle.main.bundleIdentifier,
            excluding: attemptedBundleIDs
        ) else {
            if !reportedEmptyList {
                reportedEmptyList = true
                log.record("Auto-close is ready, but no running app in the close list can be quit.")
            }
            return
        }

        isClosing = true
        attemptedBundleIDs.insert(target.bundleIdentifier)
        if config.notifyBeforeAutoClose {
            notifications.post("Closing \(target.displayName) to free memory.")
        }

        Task {
            let outcome = await closer.close(pid: target.pid)
            log.record(outcome.message)
            closesThisEpisode += 1
            try? await Task.sleep(for: .seconds(3))
            isClosing = false
            monitor.poll()
        }
    }
}

@MainActor
final class PressureNotifications: NSObject, UNUserNotificationCenterDelegate {
    private var prepared = false

    func prepare() {
        guard !prepared else { return }
        prepared = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pressure"
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
