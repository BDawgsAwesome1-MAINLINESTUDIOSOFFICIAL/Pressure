import AppKit
import EventKit
import Foundation

struct AgendaEvent: Equatable {
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool

    var isHappening: Bool {
        let now = Date()
        return start <= now && end > now
    }
}

@MainActor
final class CalendarAgenda {
    var onEvent: ((AgendaEvent?) -> Void)?

    private let store = EKEventStore()
    private var granted = false
    private var timer: Timer?

    func start() {
        requestAccess()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func openCalendar() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    private func requestAccess() {
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents { [weak self] granted, _ in
                Task { @MainActor in
                    self?.applyAccess(granted)
                }
            }
        } else {
            store.requestAccess(to: .event) { [weak self] granted, _ in
                Task { @MainActor in
                    self?.applyAccess(granted)
                }
            }
        }
    }

    private func applyAccess(_ granted: Bool) {
        self.granted = granted
        refresh()
    }

    private func refresh() {
        guard granted else {
            onEvent?(nil)
            return
        }
        onEvent?(Self.nextEvent(in: store))
    }

    static func nextEvent(in store: EKEventStore, now: Date = Date()) -> AgendaEvent? {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return nil }
        let predicate = store.predicateForEvents(withStart: startOfDay, end: startOfTomorrow, calendars: nil)
        let events = store.events(matching: predicate).filter { event in
            event.status != .canceled && event.endDate > now
        }
        let timed = events.filter { !$0.isAllDay }.sorted { $0.startDate < $1.startDate }
        let happening = timed.first { $0.startDate <= now && $0.endDate > now }
        let chosen = happening ?? timed.first ?? events.sorted { $0.startDate < $1.startDate }.first
        guard let chosen else { return nil }
        let title = chosen.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgendaEvent(
            title: (title?.isEmpty == false ? title! : "Event"),
            start: chosen.startDate,
            end: chosen.endDate,
            isAllDay: chosen.isAllDay
        )
    }
}
