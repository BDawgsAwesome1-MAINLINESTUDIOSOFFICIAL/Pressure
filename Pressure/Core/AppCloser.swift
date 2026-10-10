import AppKit
import Combine
import Foundation

struct ActionEvent: Codable, Equatable, Identifiable {
    var id: UUID
    var date: Date
    var message: String
}

enum CloseOutcome: Equatable {
    case graceful(String)
    case forced(String)
    case failed(String)
    case refused(String)
    case alreadyGone

    var message: String {
        switch self {
        case .graceful(let name):
            return "Closed \(name)."
        case .forced(let name):
            return "Force quit \(name) after it ignored the quit request."
        case .failed(let name):
            return "Could not close \(name)."
        case .refused(let name):
            return "Refused to close \(name)."
        case .alreadyGone:
            return "That app was already gone."
        }
    }
}

@MainActor
final class ActionLog: ObservableObject {
    @Published private(set) var events: [ActionEvent] = []

    private let defaults: UserDefaults
    private let storageKey = "actionLog"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ActionEvent].self, from: data) {
            events = Array(decoded.prefix(EventBuffer.limit))
        }
    }

    func record(_ message: String) {
        let event = ActionEvent(id: UUID(), date: Date(), message: message)
        events = EventBuffer.prepend(event, to: events)
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

@MainActor
final class AppCloser {
    func close(pid: pid_t) async -> CloseOutcome {
        if pid <= 1 || pid == ProcessInfo.processInfo.processIdentifier {
            return .refused("system process")
        }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            return .alreadyGone
        }
        let name = app.localizedName ?? app.bundleIdentifier ?? "App"
        if let bundleID = app.bundleIdentifier, AppPriority.isSessionCritical(bundleID) {
            return .refused(name)
        }

        let accepted = app.terminate()
        if !accepted {
            return force(app, name: name)
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if app.isTerminated {
                return .graceful(name)
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return force(app, name: name)
    }

    private func force(_ app: NSRunningApplication, name: String) -> CloseOutcome {
        if let bundleID = app.bundleIdentifier, AppPriority.isSessionCritical(bundleID) {
            return .refused(name)
        }
        app.forceTerminate()
        return app.isTerminated ? .forced(name) : .failed(name)
    }
}
