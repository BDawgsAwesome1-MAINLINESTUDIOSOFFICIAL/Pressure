import Foundation

struct IncomingMessage: Equatable, Identifiable {
    var id: Int64
    var sender: String
    var body: String
    var chatID: String
    var appleDate: Int64
}

struct MessageSnapshot: Equatable {
    var unseen: [IncomingMessage] = []
    var note: String?
    var sentAt: Date?
    var showSentCheck = false
    /// The running app was denied Messages, so it needs a fresh start after access is allowed.
    var needsAccess = false
    static let sentWindow: TimeInterval = 4

    var latest: IncomingMessage? { unseen.first }
    var showsOnPill: Bool { !unseen.isEmpty || showSentCheck }

    var pillText: String {
        if unseen.count > 1 { return "\(unseen.count)" }
        return ""
    }
}

enum MessageParser {
    /// Rows are JSON objects from `sqlite3 -json`, with ids and dates as strings.
    static func unseen(from data: Data, baseline: Int64?) -> (messages: [IncomingMessage], baseline: Int64) {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ([], baseline ?? 0)
        }
        let parsed: [IncomingMessage] = rows.compactMap { row in
            let id = int64(row["id"])
            let appleDate = int64(row["appleDate"])
            let body = string(row["text"])
            let chatID = string(row["chat"])
            guard id > 0, appleDate > 0, !body.isEmpty, !chatID.isEmpty else { return nil }
            if int64(row["fromMe"]) != 0 { return nil }
            let title = string(row["title"])
            let handle = string(row["handle"])
            let sender = title.isEmpty ? (handle.isEmpty ? "Message" : handle) : title
            return IncomingMessage(id: id, sender: sender, body: body, chatID: chatID, appleDate: appleDate)
        }.sorted { $0.appleDate > $1.appleDate }

        let newest = parsed.map(\.appleDate).max() ?? baseline ?? 0
        guard let baseline else {
            return ([], newest)
        }
        let fresh = parsed.filter { $0.appleDate > baseline }
        return (Array(fresh.prefix(5)), baseline)
    }

    private static func string(_ value: Any?) -> String {
        if let value = value as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let value = value as? String { return Int64(value) ?? 0 }
        if let value = value as? NSNumber { return value.int64Value }
        return 0
    }
}

enum MessageInbox {
    static let baselineKey = "messageInbox.baselineAppleDate"
    private static let databasePath = NSString(string: "~").expandingTildeInPath + "/Library/Messages/chat.db"
    private static let query = """
    SELECT CAST(m.ROWID AS TEXT) AS id,
           IFNULL(m.text, '') AS text,
           CAST(m.is_from_me AS TEXT) AS fromMe,
           CAST(m.date AS TEXT) AS appleDate,
           IFNULL(h.id, '') AS handle,
           c.guid AS chat,
           IFNULL(c.display_name, '') AS title
    FROM message m
    JOIN chat_message_join cm ON cm.message_id = m.ROWID
    JOIN chat c ON c.ROWID = cm.chat_id
    LEFT JOIN handle h ON h.ROWID = m.handle_id
    WHERE m.is_from_me = 0 AND m.text IS NOT NULL AND m.text != ''
    ORDER BY m.date DESC
    LIMIT 20;
    """

    static func poll(defaults: UserDefaults = .standard, sentAt: Date? = nil, now: Date = Date()) -> MessageSnapshot {
        let stored = defaults.object(forKey: baselineKey) as? NSNumber
        let baseline = stored?.int64Value
        let showSent = sentAt.map { now.timeIntervalSince($0) <= MessageSnapshot.sentWindow } ?? false
        switch readDatabase() {
        case .denied:
            return MessageSnapshot(
                note: "Turn on Full Disk Access for Pressure, then reset it.",
                sentAt: sentAt,
                showSentCheck: showSent,
                needsAccess: true
            )
        case .failed:
            return MessageSnapshot(note: "Messages could not be read.", sentAt: sentAt, showSentCheck: showSent)
        case .rows(let data):
            let result = MessageParser.unseen(from: data, baseline: baseline)
            if baseline == nil {
                defaults.set(NSNumber(value: result.baseline), forKey: baselineKey)
            }
            return MessageSnapshot(unseen: result.messages, sentAt: sentAt, showSentCheck: showSent)
        }
    }

    static func acknowledge(_ appleDate: Int64, defaults: UserDefaults = .standard) {
        let stored = (defaults.object(forKey: baselineKey) as? NSNumber)?.int64Value ?? 0
        if appleDate > stored {
            defaults.set(NSNumber(value: appleDate), forKey: baselineKey)
        }
    }

    /// Sends through Messages. Returns a short error, or nil when Messages accepted it.
    static func send(_ text: String, chatID: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !chatID.isEmpty else { return "Nothing to send" }
        let script = """
        tell application "Messages"
          send "\(escape(trimmed))" to chat id "\(escape(chatID))"
        end tell
        """
        let result = AppleScriptRunner.run(script)
        if result.errorNumber == nil { return nil }
        if result.errorNumber == -1743 { return "Allow Messages in Automation" }
        let message = result.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return message.isEmpty ? "Could not send" : message
    }

    private enum ReadResult {
        case rows(Data)
        case denied
        case failed
    }

    private static func readDatabase() -> ReadResult {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sqlite3") else { return .failed }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        task.arguments = ["-json", databasePath, query]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return .failed
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if task.terminationStatus == 0 { return .rows(data) }
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        if text.contains("authorization") || text.contains("operation not permitted") {
            return .denied
        }
        return .failed
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
