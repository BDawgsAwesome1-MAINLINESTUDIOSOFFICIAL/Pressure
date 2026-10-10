import Foundation

struct ActionRun: Equatable, Identifiable {
    var id: Int
    var name: String
    var title: String
    var status: String
    var conclusion: String
    var updatedAt: Date

    var isRunning: Bool { status == "in_progress" || status == "queued" || status == "waiting" || status == "pending" }
    var headline: String { title.isEmpty ? name : title }
}

struct ActionMemory: Equatable {
    var seeded = false
    var completed: Set<Int> = []
    var successAt: [Int: Date] = [:]
    var failureAt: [Int: Date] = [:]
}

struct ActionSnapshot: Equatable {
    var running: [ActionRun] = []
    var showCheck = false
    var showFailure = false
    var finishedAt: Date?
    var headline = ""
    var note: String?
    static let resultWindow: TimeInterval = 4

    var showsOnPill: Bool { !running.isEmpty || showCheck || showFailure }
    var pillText: String {
        if running.count > 1 { return "\(running.count)" }
        return ""
    }
}

enum ActionBoard {
    static func reduce(previous: ActionMemory, runs: [ActionRun], now: Date) -> (ActionMemory, ActionSnapshot) {
        var memory = previous
        if !memory.seeded {
            memory.seeded = true
            memory.completed = Set(runs.filter { !$0.isRunning }.map(\.id))
        }
        for run in runs where !run.isRunning && !memory.completed.contains(run.id) {
            memory.completed.insert(run.id)
            if run.conclusion == "success" {
                memory.successAt[run.id] = now
            } else if run.conclusion == "failure" || run.conclusion == "timed_out" || run.conclusion == "startup_failure" {
                memory.failureAt[run.id] = now
            }
        }
        memory.successAt = memory.successAt.filter { now.timeIntervalSince($0.value) <= ActionSnapshot.resultWindow }
        memory.failureAt = memory.failureAt.filter { now.timeIntervalSince($0.value) <= ActionSnapshot.resultWindow }
        let running = runs.filter(\.isRunning)
        let showCheck = !memory.successAt.isEmpty && running.isEmpty
        let showFailure = !memory.failureAt.isEmpty && running.isEmpty && !showCheck
        let finishedAt = (memory.successAt.values.max()).flatMap { showCheck ? $0 : nil }
            ?? (memory.failureAt.values.max()).flatMap { showFailure ? $0 : nil }
        let headline: String
        if let current = running.first {
            headline = current.headline
        } else if showCheck {
            headline = "Passed"
        } else if showFailure {
            headline = "Failed"
        } else {
            headline = ""
        }
        let snapshot = ActionSnapshot(
            running: running,
            showCheck: showCheck,
            showFailure: showFailure,
            finishedAt: finishedAt,
            headline: headline
        )
        return (memory, snapshot)
    }

    static func runs(from data: Data) -> [ActionRun] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let id = int(row["databaseId"])
            guard id > 0 else { return nil }
            let name = string(row["name"])
            let title = string(row["displayTitle"])
            let status = string(row["status"])
            let conclusion = string(row["conclusion"])
            let updated = date(string(row["updatedAt"])) ?? .distantPast
            return ActionRun(id: id, name: name, title: title, status: status, conclusion: conclusion, updatedAt: updated)
        }
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ""
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) ?? 0 }
        return 0
    }

    private static func date(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

enum GitHubActions {
    private static let repoKey = "githubActions.repoPath"

    static func poll(memory: ActionMemory, now: Date = Date()) -> (ActionMemory, ActionSnapshot) {
        guard let gh = executable else {
            return (memory, ActionSnapshot(note: "Install GitHub CLI to see Actions."))
        }
        let directory = repoDirectory()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: gh)
        if let directory {
            task.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        }
        task.arguments = [
            "run", "list", "--limit", "8",
            "--json", "databaseId,name,displayTitle,status,conclusion,updatedAt",
        ]
        let pipe = Pipe()
        let errors = Pipe()
        task.standardOutput = pipe
        task.standardError = errors
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return (memory, ActionSnapshot(note: "GitHub CLI could not start."))
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if task.terminationStatus != 0 {
            if errorText.localizedCaseInsensitiveContains("not a git repository") {
                return (memory, ActionSnapshot(note: "Open Pressure from a git repo once so Actions knows which one to watch."))
            }
            return (memory, ActionSnapshot(note: "GitHub CLI is not logged in."))
        }
        if let directory {
            UserDefaults.standard.set(directory, forKey: repoKey)
        }
        return ActionBoard.reduce(previous: memory, runs: ActionBoard.runs(from: data), now: now)
    }

    private static func repoDirectory() -> String? {
        if let saved = UserDefaults.standard.string(forKey: repoKey), gitRoot(saved) != nil {
            return saved
        }
        return gitRoot(FileManager.default.currentDirectoryPath)
    }

    private static func gitRoot(_ path: String) -> String? {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        guard let git = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: git)
        task.arguments = ["-C", path, "rev-parse", "--show-toplevel"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private static var executable: String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
