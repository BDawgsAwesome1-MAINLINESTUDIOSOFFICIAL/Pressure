import AppKit
import Combine
import Darwin
import Foundation

struct AppFootprint: Identifiable, Equatable {
    var pid: Int32
    var name: String
    var bundleIdentifier: String?
    var residentBytes: UInt64
    var isFrontmost: Bool
    var isUserApp: Bool

    var id: String { bundleIdentifier ?? "pid-\(pid)" }

    func ranked() -> RankedApp? {
        guard let bundleIdentifier else { return nil }
        return RankedApp(
            bundleIdentifier: bundleIdentifier,
            displayName: name,
            pid: pid,
            residentBytes: residentBytes,
            isFrontmost: isFrontmost,
            isUserApp: isUserApp
        )
    }
}

@MainActor
final class MemoryMonitor: ObservableObject {
    @Published private(set) var snapshot: MemorySnapshot?
    @Published private(set) var footprints: [AppFootprint] = []

    private var timer: Timer?

    func start() {
        poll()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        snapshot = MemoryReader.read()
        footprints = ProcessMemory.footprints()
    }

    var topFootprints: [AppFootprint] {
        Array(footprints.prefix(5))
    }
}

enum ProcessMemory {
    static func footprints() -> [AppFootprint] {
        let usage = residentUsageByPID()
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps = NSWorkspace.shared.runningApplications
        var footprints: [AppFootprint] = []
        footprints.reserveCapacity(apps.count)

        for app in apps {
            let policy = app.activationPolicy
            let isUserApp = policy == .regular || policy == .accessory
            guard isUserApp || app.bundleIdentifier != nil else { continue }
            let pid = app.processIdentifier
            let bytes = usage.total(for: pid)
            guard bytes > 0 else { continue }
            footprints.append(
                AppFootprint(
                    pid: pid,
                    name: app.localizedName ?? app.bundleIdentifier ?? "App",
                    bundleIdentifier: app.bundleIdentifier,
                    residentBytes: bytes,
                    isFrontmost: pid == frontmost,
                    isUserApp: isUserApp
                )
            )
        }

        footprints.sort { $0.residentBytes > $1.residentBytes }
        return footprints
    }

    private static func residentUsageByPID() -> ResidentUsage {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return ResidentUsage(rss: [:], children: [:]) }

        var pids = [pid_t](repeating: 0, count: Int(needed) + 8)
        let bufferBytes = Int32(pids.count * MemoryLayout<pid_t>.size)
        let got = proc_listallpids(&pids, bufferBytes)
        guard got > 0 else { return ResidentUsage(rss: [:], children: [:]) }

        var rss: [pid_t: UInt64] = [:]
        var children: [pid_t: [pid_t]] = [:]
        rss.reserveCapacity(Int(got))

        for pid in pids.prefix(Int(got)) where pid > 0 {
            var info = proc_bsdshortinfo()
            let infoSize = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            let infoRead = proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, infoSize)
            guard infoRead == infoSize else { continue }

            var task = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let taskRead = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize)
            let resident = taskRead == taskSize ? task.pti_resident_size : 0
            rss[pid] = resident
            let parent = pid_t(info.pbsi_ppid)
            if parent > 0 {
                children[parent, default: []].append(pid)
            }
        }

        return ResidentUsage(rss: rss, children: children)
    }
}

private struct ResidentUsage {
    var rss: [pid_t: UInt64]
    var children: [pid_t: [pid_t]]

    func total(for root: pid_t) -> UInt64 {
        var sum: UInt64 = 0
        var stack = [root]
        var seen = Set<pid_t>()
        while let pid = stack.popLast() {
            guard seen.insert(pid).inserted else { continue }
            sum += rss[pid] ?? 0
            if let kids = children[pid] {
                stack.append(contentsOf: kids)
            }
        }
        return sum
    }
}
