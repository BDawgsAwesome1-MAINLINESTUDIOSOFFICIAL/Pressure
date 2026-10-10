import Foundation

/// Compact-pill priority, highest first. Memory is the fallback so the pill
/// can still draw when every other activity is hidden.
enum IslandActivityKind: String, Equatable {
    case timer
    case stopwatch
    case nowPlaying
    case battery
    case calendar
    case memory
}

struct IslandCandidates: Equatable {
    var timerRunning = false
    var timerAlert = false
    var stopwatchRunning = false
    var nowPlaying = false
    var hasPower = false
    var hasCalendarEvent = false
}

enum IslandPriority {
    static func compact(_ candidates: IslandCandidates) -> IslandActivityKind {
        if candidates.timerRunning || candidates.timerAlert { return .timer }
        if candidates.stopwatchRunning { return .stopwatch }
        if candidates.nowPlaying { return .nowPlaying }
        if candidates.hasPower { return .battery }
        if candidates.hasCalendarEvent { return .calendar }
        return .memory
    }
}

enum IslandTimeFormat {
    static func countdown(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    static func stopwatch(_ seconds: TimeInterval) -> String {
        let scaled = max(0, Int((seconds * 10).rounded()))
        let whole = scaled / 10
        let tenths = scaled % 10
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d.%d", minutes, secs, tenths)
    }
}

enum MediaSource: String, Equatable {
    case music
    case spotify
    case brave
    case safari

    var appName: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        case .brave: return "Brave Browser"
        case .safari: return "Safari"
        }
    }

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        case .brave: return "com.brave.Browser"
        case .safari: return "com.apple.Safari"
        }
    }
}

struct MediaSample: Equatable {
    var source: MediaSource
    var state: String
    var title: String
    var artist: String
    var artworkURL: String = ""

    var isPlaying: Bool { state == "playing" }
}

enum NowPlayingParser {
    /// Lines look like `music<tab>playing<tab>title<tab>artist`.
    static func samples(from raw: String) -> [MediaSample] {
        raw.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = String(line).components(separatedBy: "\t")
            guard parts.count >= 4, let source = MediaSource(rawValue: parts[0]) else { return nil }
            let state = parts[1]
            guard state == "playing" || state == "paused" || state == "stopped" else { return nil }
            let title = parts[2]
            let artist: String
            let artwork: String
            if parts.count >= 5 {
                artwork = parts[parts.count - 1]
                artist = parts[3..<(parts.count - 1)].joined(separator: "\t")
            } else {
                artwork = ""
                artist = parts.dropFirst(3).joined(separator: "\t")
            }
            return MediaSample(source: source, state: state, title: title, artist: artist, artworkURL: artwork)
        }
    }

    /// Playing wins over paused. Music, then Spotify, then a browser.
    /// Stopped players are hidden. A `denied` line is not a track.
    static func choose(from raw: String?) -> MediaSample? {
        guard let raw else { return nil }
        let active = samples(from: raw).filter { $0.state == "playing" || $0.state == "paused" }
        let order: [MediaSource] = [.music, .spotify, .brave, .safari]
        for source in order {
            if let playing = active.first(where: { $0.source == source && $0.isPlaying }) {
                return playing
            }
        }
        for source in order {
            if let paused = active.first(where: { $0.source == source && $0.state == "paused" }) {
                return paused
            }
        }
        return nil
    }

    /// One short line when Music or Spotify refused the Apple Event (-1743).
    static func denialNote(from raw: String) -> String? {
        var names: [String] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let parts = String(line).components(separatedBy: "\t")
            guard parts.count >= 2, parts[1] == "denied" else { continue }
            if parts[0] == MediaSource.music.rawValue, !names.contains("Music") {
                names.append("Music")
            } else if parts[0] == MediaSource.spotify.rawValue, !names.contains("Spotify") {
                names.append("Spotify")
            }
        }
        guard !names.isEmpty else { return nil }
        return "Allow \(names.joined(separator: " and ")) in Automation"
    }
}
