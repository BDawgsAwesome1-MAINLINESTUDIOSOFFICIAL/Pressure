import Foundation

struct CursorLine: Equatable, Identifiable {
    var id: String
    var title: String
    var detail: String
    var status: String
}

struct CursorSnapshot: Equatable {
    var lines: [CursorLine] = []
    var runningCount = 0
    var headline = ""
    var isActive = false
    /// True only while a session or subagent is still working.
    var isWorking = false
    /// Green check on the pill for a few seconds after work finishes.
    var showCheck = false
    var finishedAt: Date?

    var showsOnPill: Bool { isWorking || showCheck }
    /// One estimated dollar cost for the latest request. Empty until Cursor reports tokens.
    var requestCost = ""

    var pillText: String {
        if runningCount > 1 { return "\(runningCount)" }
        if runningCount == 1 { return "1" }
        return "•"
    }
}

enum CursorActivityReader {
    static let finishedWindow: TimeInterval = 25
    static let staleRunning: TimeInterval = 180
    static let checkWindow: TimeInterval = 4

    static func load(from path: String = CursorBridge.statusPath, now: Date = Date()) -> CursorSnapshot {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return CursorSnapshot()
        }
        return snapshot(from: data, now: now)
    }

    static func snapshot(from data: Data, now: Date = Date()) -> CursorSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CursorSnapshot()
        }
        let sessions = root["sessions"] as? [String: Any] ?? [:]
        let agents = root["agents"] as? [String: Any] ?? [:]
        var lines: [CursorLine] = []
        var running = 0
        var latestFinish: TimeInterval = 0

        let sessionRows: [(String, [String: Any])] = sessions.compactMap { key, value in
            guard let row = value as? [String: Any] else { return nil }
            return (key, row)
        }.sorted { updated($0.1) > updated($1.1) }

        for (sid, row) in sessionRows {
            let phase = string(row["phase"])
            let age = now.timeIntervalSince1970 - updated(row)
            let working = phase == "working" && age <= staleRunning
            let recentlyIdle = phase != "working" && age <= finishedWindow && !string(row["step"]).isEmpty
            guard working || recentlyIdle else { continue }
            let title = string(row["title"]).isEmpty ? "Cursor" : string(row["title"])
            var detail = string(row["step"])
            if let percent = row["contextPercent"] as? Int, percent > 0 {
                detail = detail.isEmpty ? "Context \(percent)%" : "\(detail) · \(percent)%"
            } else if let percent = row["contextPercent"] as? Double, percent > 0 {
                detail = detail.isEmpty ? "Context \(Int(percent))%" : "\(detail) · \(Int(percent))%"
            }
            let tools = int(row["toolCount"])
            if tools > 0 {
                detail = detail.isEmpty ? "\(tools) steps" : "\(detail) · \(tools) steps"
            }
            lines.append(CursorLine(
                id: "session-\(sid)",
                title: title,
                detail: detail.isEmpty ? (working ? "Working" : "Done") : detail,
                status: working ? "working" : "done"
            ))
            if !working {
                latestFinish = max(latestFinish, finishStamp(row))
            }
        }

        let agentRows: [(String, [String: Any])] = agents.compactMap { key, value in
            guard let row = value as? [String: Any] else { return nil }
            return (key, row)
        }.sorted { updated($0.1) > updated($1.1) }

        for (agentID, row) in agentRows {
            let status = string(row["status"])
            let age = now.timeIntervalSince1970 - updated(row)
            let live = status == "running" && age <= staleRunning
            let recent = !live && age <= finishedWindow
            guard live || recent else { continue }
            if live { running += 1 }
            let name = string(row["name"]).isEmpty ? "Subagent" : string(row["name"])
            var detail = string(row["step"])
            let tools = int(row["toolCount"])
            if tools > 0 {
                detail = detail.isEmpty ? "\(tools) steps" : "\(detail) · \(tools)"
            }
            lines.append(CursorLine(
                id: "agent-\(agentID)",
                title: name,
                detail: detail.isEmpty ? statusLabel(status) : detail,
                status: live ? "running" : status
            ))
            if !live {
                latestFinish = max(latestFinish, finishStamp(row))
            }
        }

        let active = lines.contains { $0.status == "working" || $0.status == "running" } || running > 0
        let headline: String
        if running > 1 {
            headline = "\(running) agents"
        } else if let agent = lines.first(where: { $0.status == "running" }) {
            headline = agent.detail
        } else if let session = lines.first(where: { $0.status == "working" }) {
            headline = session.detail
        } else if let latest = lines.first {
            headline = latest.detail
        } else {
            headline = ""
        }
        let visible = lines.filter { item in
            if active { return item.status == "working" || item.status == "running" || item.status == "completed" || item.status == "error" || item.status == "aborted" || item.status == "done" }
            return true
        }
        let finishedDate = latestFinish > 0 ? Date(timeIntervalSince1970: latestFinish) : nil
        let sinceFinish = finishedDate.map { now.timeIntervalSince($0) } ?? 999
        let showCheck = !active && sinceFinish >= 0 && sinceFinish <= checkWindow
        let requestCost: String = {
            guard let latest = sessionRows.first(where: { pair in
                let phase = string(pair.1["phase"])
                let age = now.timeIntervalSince1970 - updated(pair.1)
                let working = phase == "working" && age <= staleRunning
                let recentlyIdle = phase != "working" && age <= finishedWindow && !string(pair.1["step"]).isEmpty
                return working || recentlyIdle
            }) else { return "" }
            return CursorCost.label(from: latest.1["usage"])
        }()
        return CursorSnapshot(
            lines: Array(visible.prefix(6)),
            runningCount: running,
            headline: headline,
            isActive: active || !lines.isEmpty,
            isWorking: active,
            showCheck: showCheck,
            finishedAt: showCheck ? finishedDate : nil,
            requestCost: requestCost
        )
    }

    private static func finishStamp(_ row: [String: Any]) -> TimeInterval {
        let stamped = updatedValue(row["finishedAt"])
        if stamped > 0 { return stamped }
        return updated(row)
    }

    private static func updatedValue(_ value: Any?) -> TimeInterval {
        if let value = value as? TimeInterval { return value }
        if let value = value as? Int { return TimeInterval(value) }
        if let value = value as? Double { return value }
        return 0
    }

    private static func updated(_ row: [String: Any]) -> TimeInterval {
        if let value = row["updatedAt"] as? TimeInterval { return value }
        if let value = row["updatedAt"] as? Int { return TimeInterval(value) }
        return 0
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func int(_ value: Any?) -> Int {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        return 0
    }

    private static func statusLabel(_ status: String) -> String {
        switch status {
        case "running": return "Working"
        case "completed": return "Done"
        case "error": return "Error"
        case "aborted": return "Stopped"
        default: return status.isEmpty ? "Working" : status
        }
    }
}

enum CursorCost {
    /// List prices from Cursor's model pricing, per million tokens.
    /// Cache-write cells published as "-" are billed at the input rate.
    private struct Price {
        var input: Double
        var cacheRead: Double
        var output: Double
        var cacheWrite: Double? = nil
        var fastInput: Double? = nil
        var fastCacheRead: Double? = nil
        var fastOutput: Double? = nil
        var fastCacheWrite: Double? = nil
        var longAt: Int? = nil
        var longMultiplier = 2.0
        var longMultiplierWhenFast = 2.0
        var longScalesOutput = false
    }

    static func estimate(model: String, fast: Bool, input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> Double? {
        guard input >= 0, output >= 0, cacheRead >= 0, cacheWrite >= 0 else { return nil }
        guard let price = price(for: model) else { return nil }
        let useFast = fast || model.lowercased().contains("fast")
        var inputPrice = useFast ? (price.fastInput ?? price.input * 2) : price.input
        var readPrice = useFast ? (price.fastCacheRead ?? price.cacheRead * 2) : price.cacheRead
        var outputPrice = useFast ? (price.fastOutput ?? price.output * 2) : price.output
        let baseWrite = price.cacheWrite ?? price.input
        var writePrice = useFast ? (price.fastCacheWrite ?? price.fastInput ?? baseWrite * 2) : baseWrite
        if let cutoff = price.longAt, input > cutoff {
            let scale = useFast ? price.longMultiplierWhenFast : price.longMultiplier
            inputPrice *= scale
            readPrice *= scale
            writePrice *= scale
            if price.longScalesOutput { outputPrice *= scale }
        }
        let uncached = max(0, input - cacheRead - cacheWrite)
        let million = 1_000_000.0
        return (Double(uncached) * inputPrice
            + Double(cacheRead) * readPrice
            + Double(cacheWrite) * writePrice
            + Double(output) * outputPrice) / million
    }

    static func format(_ dollars: Double) -> String {
        let pattern = dollars < 0.01 ? "%.3f" : "%.2f"
        let text = String(format: pattern, locale: Locale(identifier: "en_US_POSIX"), dollars)
        return "Est. $\(text)"
    }

    static func label(from usage: Any?) -> String {
        guard let usage = usage as? [String: Any] else { return "" }
        guard let input = optionalInt(usage["input"]), let output = optionalInt(usage["output"]) else { return "" }
        let dollars = estimate(
            model: string(usage["model"]),
            fast: bool(usage["fast"]),
            input: input,
            output: output,
            cacheRead: optionalInt(usage["cacheRead"]) ?? 0,
            cacheWrite: optionalInt(usage["cacheWrite"]) ?? 0
        )
        guard let dollars else { return "" }
        return format(dollars)
    }

    private static func price(for model: String) -> Price? {
        let name = model.lowercased().replacingOccurrences(of: "_", with: "-")
        if name.contains("composer") { return Price(input: 0.5, cacheRead: 0.2, output: 2.5, fastInput: 3, fastCacheRead: 0.5, fastOutput: 15) }
        if name.contains("grok") && (name.contains("4.7") || name.contains("4-7")) {
            return Price(input: 2, cacheRead: 0.5, output: 6, fastInput: 4, fastCacheRead: 1, fastOutput: 12, longAt: 256_000, longMultiplierWhenFast: 1.5, longScalesOutput: true)
        }
        if name.contains("grok") && (name.contains("4.6") || name.contains("4-6")) {
            return Price(input: 2, cacheRead: 0.5, output: 6, fastInput: 4, fastCacheRead: 1, fastOutput: 12)
        }
        if name.contains("grok") && (name.contains("4.5") || name.contains("4-5")) {
            return Price(input: 2, cacheRead: 0.5, output: 6, fastInput: 4, fastCacheRead: 1, fastOutput: 18)
        }
        if name.contains("fable") && (name.contains("5.1") || name.contains("5-1")) {
            return Price(input: 10, cacheRead: 0.25, output: 50, cacheWrite: 12.5)
        }
        if name.contains("fable") { return Price(input: 10, cacheRead: 1, output: 50, cacheWrite: 12.5) }
        if name.contains("haiku") && (name.contains("5.5") || name.contains("5-5")) {
            return Price(input: 0.1, cacheRead: 0.01, output: 0.5, cacheWrite: 0.125, longAt: 100_000, longMultiplier: 5, longMultiplierWhenFast: 5, longScalesOutput: true)
        }
        if name.contains("haiku") { return Price(input: 1, cacheRead: 0.1, output: 5, cacheWrite: 1.25) }
        if name.contains("opus") && (name.contains("5.5") || name.contains("5-5")) {
            return Price(input: 4, cacheRead: 0.2, output: 20, cacheWrite: 5)
        }
        if name.contains("opus") && (name.contains("4.7") || name.contains("4-7")) && name.contains("fast") {
            return Price(input: 30, cacheRead: 3, output: 150, cacheWrite: 37.5, fastInput: 30, fastCacheRead: 3, fastOutput: 150, fastCacheWrite: 37.5)
        }
        if name.contains("opus") { return Price(input: 5, cacheRead: 0.5, output: 25, cacheWrite: 6.25) }
        if name.contains("sonnet") && (name.contains("5.5") || name.contains("5-5")) {
            return Price(input: 2, cacheRead: 0.1, output: 10, cacheWrite: 2.5)
        }
        if name.contains("sonnet") && name.contains("5") && !name.contains("4") {
            return Price(input: 2, cacheRead: 0.2, output: 10, cacheWrite: 2.5)
        }
        if name.contains("sonnet") && name.contains("1m") {
            return Price(input: 6, cacheRead: 0.6, output: 22.5, cacheWrite: 7.5)
        }
        if name.contains("sonnet") { return Price(input: 3, cacheRead: 0.3, output: 15, cacheWrite: 3.75) }
        if name.contains("gpt") && name.contains("5.6") && name.contains("luna") {
            return Price(input: 0.2, cacheRead: 0.02, output: 1.2, cacheWrite: 0.25, longAt: 272_000)
        }
        if name.contains("gpt") && name.contains("5.6") && name.contains("terra") {
            return Price(input: 2, cacheRead: 0.2, output: 12, cacheWrite: 2.5, longAt: 272_000)
        }
        if name.contains("gpt") && name.contains("5.6") && name.contains("sol") {
            return Price(input: 4, cacheRead: 0.4, output: 20, cacheWrite: 5, longAt: 272_000)
        }
        if name.contains("gpt") && name.contains("5.5") { return Price(input: 5, cacheRead: 0.5, output: 30) }
        if name.contains("gpt") && name.contains("5.4") && name.contains("nano") { return Price(input: 0.2, cacheRead: 0.02, output: 1.25) }
        if name.contains("gpt") && name.contains("5.4") && name.contains("mini") { return Price(input: 0.75, cacheRead: 0.075, output: 4.5) }
        if name.contains("gpt") && name.contains("5.4") { return Price(input: 2.5, cacheRead: 0.25, output: 15) }
        if name.contains("gemini") && name.contains("3.8") { return Price(input: 0.75, cacheRead: 0.075, output: 3.5) }
        if name.contains("gemini") && name.contains("3.1") { return Price(input: 2, cacheRead: 0.2, output: 12) }
        if name.contains("gemini") && name.contains("3") && name.contains("pro") { return Price(input: 2, cacheRead: 0.2, output: 12) }
        if name.contains("muse") || name.contains("spark") { return Price(input: 1.25, cacheRead: 0.15, output: 4.25) }
        return nil
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        if value == nil { return nil }
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "true" || value == "1" }
        return false
    }

    private static func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

enum CursorBridge {
    static var supportDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Library/Application Support/Pressure")
    }

    static var statusPath: String {
        (supportDirectory as NSString).appendingPathComponent("cursor-activity.json")
    }

    static let hookCommand = "/usr/bin/python3 ./hooks/pressure-cursor.py"
    static let hookEvents = [
        "sessionStart",
        "sessionEnd",
        "beforeSubmitPrompt",
        "preToolUse",
        "postToolUse",
        "postToolUseFailure",
        "subagentStart",
        "subagentStop",
        "stop",
        "afterAgentResponse",
        "afterAgentThought",
        "preCompact",
    ]

    /// Copies the hook into ~/.cursor and adds it beside any hooks already there.
    static func install() {
        let fileManager = FileManager.default
        guard let script = bundledScript() else { return }
        let cursorRoot = (fileManager.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".cursor")
        let hooksDirectory = (cursorRoot as NSString).appendingPathComponent("hooks")
        let destination = (hooksDirectory as NSString).appendingPathComponent("pressure-cursor.py")
        do {
            try fileManager.createDirectory(atPath: supportDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(atPath: hooksDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination) {
                try fileManager.removeItem(atPath: destination)
            }
            try fileManager.copyItem(atPath: script, toPath: destination)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination)
            try mergeHooks(at: (cursorRoot as NSString).appendingPathComponent("hooks.json"))
        } catch {
            return
        }
    }

    private static func bundledScript() -> String? {
        if let bundled = Bundle.main.path(forResource: "cursor-hook", ofType: "py") {
            return bundled
        }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/cursor-hook.py")
            .path
        if FileManager.default.fileExists(atPath: source) {
            return source
        }
        return nil
    }

    private static func mergeHooks(at path: String) throws {
        var root: [String: Any] = ["version": 1, "hooks": [String: Any]()]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = existing
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in hookEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            let already = entries.contains { entry in
                String(describing: entry["command"] ?? "").contains("pressure-cursor.py")
            }
            if !already {
                entries.append(["command": hookCommand])
            }
            hooks[event] = entries
        }
        root["version"] = root["version"] ?? 1
        root["hooks"] = hooks
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
