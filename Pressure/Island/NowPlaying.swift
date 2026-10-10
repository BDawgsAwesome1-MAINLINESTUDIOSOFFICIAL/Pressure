import AppKit

struct ScriptResult {
    var text: String
    var errorNumber: Int?
    var errorMessage: String?
}

enum AppleScriptRunner {
    static func run(_ source: String) -> ScriptResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return ScriptResult(text: "", errorNumber: -2741, errorMessage: "The script could not be created.")
        }
        let result = script.executeAndReturnError(&error)
        if let error, let number = (error[NSAppleScript.errorNumber] as? NSNumber)?.intValue {
            let message = error[NSAppleScript.errorMessage] as? String ?? ""
            return ScriptResult(text: result.stringValue ?? "", errorNumber: number, errorMessage: message)
        }
        return ScriptResult(text: result.stringValue ?? "", errorNumber: nil, errorMessage: nil)
    }
}

enum MediaPoll {
    case failed
    case update(MediaSample?, note: String?)
}

enum MediaScripts {
    /// One line, no double quotes, so it can sit inside an AppleScript string.
    /// Fields are separated with character 31. A playing element wins over a paused one.
    static let mediaProbe = "(function(){function clean(v){return String(v||'').split(String.fromCharCode(9)).join(' ').split(String.fromCharCode(10)).join(' ').split(String.fromCharCode(13)).join(' ').trim();}function walk(doc,list){if(!doc||!list){return;}var nodes=doc.querySelectorAll('audio,video');for(var i=0;i<nodes.length;i++){list.push(nodes[i]);}var frames=doc.querySelectorAll('iframe');for(var j=0;j<frames.length;j++){try{walk(frames[j].contentDocument,list);}catch(e){}}}var list=[];walk(document,list);var playing=null;for(var k=0;k<list.length;k++){var el=list[k];if(!el.paused&&!el.ended&&(el.currentSrc||el.src)){playing=el;break;}}if(!playing){return '';}var meta=null;try{meta=navigator.mediaSession&&navigator.mediaSession.metadata;}catch(e){}var title=clean(playing.getAttribute('title')||(meta&&meta.title)||document.title||'');var artist=clean((meta&&meta.artist)||'');var art='';if(playing.poster){art=playing.poster;}try{if(!art&&meta&&meta.artwork&&meta.artwork.length){art=meta.artwork[0].src||'';}}catch(e){}art=clean(art);if(art.indexOf('blob:')===0){art='';}return ['playing',title,artist,art].join(String.fromCharCode(31));})()"

    static let mediaToggle = "(function(){function walk(doc,list){if(!doc||!list){return;}var nodes=doc.querySelectorAll('audio,video');for(var i=0;i<nodes.length;i++){list.push(nodes[i]);}var frames=doc.querySelectorAll('iframe');for(var j=0;j<frames.length;j++){try{walk(frames[j].contentDocument,list);}catch(e){}}}var list=[];walk(document,list);var playing=null;var paused=null;for(var k=0;k<list.length;k++){var el=list[k];if(el.ended){continue;}if(!el.paused&&(el.currentSrc||el.src)){playing=el;break;}if(!paused&&el.paused&&(el.currentSrc||el.src)){paused=el;}}var target=playing||paused;if(!target){return 'missing';}if(target.paused){var pending=target.play();if(pending&&pending.catch){pending.catch(function(){});}return 'playing';}target.pause();return 'paused';})()"

    /// Literal application names. `tell application appName` does not load
    /// Music's dictionary, so `playing` fails to compile and the track is dropped.
    /// Spotify is a separate script: compiling `tell application "Spotify"`
    /// when Spotify is not installed fails the whole script, including Music.
    static let musicPoll = """
    set output to ""
    try
      if application "Music" is running then
        tell application "Music"
          set ps to player state as string
          if ps is "stopped" then
            set output to output & "music" & tab & "stopped" & tab & "" & tab & "" & tab & "" & linefeed
          else
            set trackName to ""
            set artistName to ""
            set art to ""
            try
              set trackName to name of current track
            end try
            try
              set artistName to artist of current track
            end try
            try
              if (count of artworks of current track) is greater than 0 then
                set artData to raw data of artwork 1 of current track
                set art to (POSIX path of (path to temporary items from user domain)) & "PressureMusicArt.jpg"
                set fileRef to open for access (POSIX file art) with write permission
                set eof fileRef to 0
                write artData to fileRef
                close access fileRef
              end if
            end try
            set output to output & "music" & tab & ps & tab & trackName & tab & artistName & tab & art & linefeed
          end if
        end tell
      end if
    on error errMsg number errNum
      if errNum is -1743 then
        set output to output & "music" & tab & "denied" & linefeed
      end if
    end try
    return output
    """

    static let spotifyPoll = """
    set output to ""
    try
      if application "Spotify" is running then
        tell application "Spotify"
          set ps to player state as string
          if ps is "stopped" then
            set output to output & "spotify" & tab & "stopped" & tab & "" & tab & "" & tab & "" & linefeed
          else
            set trackName to ""
            set artistName to ""
            set art to ""
            try
              set trackName to name of current track
            end try
            try
              set artistName to artist of current track
            end try
            try
              set art to artwork url of current track
            end try
            set output to output & "spotify" & tab & ps & tab & trackName & tab & artistName & tab & art & linefeed
          end if
        end tell
      end if
    on error errMsg number errNum
      if errNum is -1743 then
        set output to output & "spotify" & tab & "denied" & linefeed
      end if
    end try
    return output
    """

    static var safariPoll: String { browserPoll(kind: .safari, javascript: mediaProbe) }
    static var bravePoll: String { browserPoll(kind: .brave, javascript: mediaProbe) }
    static var safariPlayPause: String { browserPoll(kind: .safari, javascript: mediaToggle, toggle: true) }
    static var bravePlayPause: String { browserPoll(kind: .brave, javascript: mediaToggle, toggle: true) }

    static func transport(_ command: String, appName: String) -> String {
        "tell application \"\(appName)\" to \(command)"
    }

    private enum BrowserKind {
        case safari
        case brave

        var appName: String {
            switch self {
            case .safari: return "Safari"
            case .brave: return "Brave Browser"
            }
        }

        var sourceKey: String {
            switch self {
            case .safari: return "safari"
            case .brave: return "brave"
            }
        }
    }

    /// Front window first, then the browser's other tabs, so playback does not
    /// have to be the frontmost app. JavaScript permission errors return empty.
    private static func browserPoll(kind: BrowserKind, javascript: String, toggle: Bool = false) -> String {
        let appName = kind.appName
        let sourceKey = kind.sourceKey
        let command = kind == .safari ? "do JavaScript" : "execute javascript"
        let targetList = kind == .safari ? safariTargets : braveTargets
        let success = toggle
            ? """
              if jsResult is "playing" or jsResult is "paused" then return ""
              """
            : """
              if jsResult is not missing value and (jsResult as text) is not "" then
                set AppleScript's text item delimiters to (character id 31)
                set bits to text items of (jsResult as text)
                set AppleScript's text item delimiters to tab
                set joined to bits as text
                set AppleScript's text item delimiters to ""
                return "\(sourceKey)" & tab & joined
              end if
              """
        return """
        if application "\(appName)" is not running then return ""
        set js to "\(javascript)"
        try
          tell application "\(appName)"
            \(targetList)
            repeat with mediaTarget in mediaTargets
              try
                set pageURL to ""
                try
                  set pageURL to URL of mediaTarget as text
                end try
                if pageURL starts with "brave:" or pageURL starts with "chrome:" or pageURL starts with "chrome-extension:" or pageURL starts with "about:" or pageURL starts with "safari-resource:" then
                  -- internal page, no page JavaScript
                else
                  set jsResult to \(command) js in mediaTarget
                  \(success)
                end if
              on error errMsg number errNum
                if errNum is -1723 or errNum is -1743 then
                  return ""
                end if
              end try
            end repeat
          end tell
        on error
          return ""
        end try
        return ""
        """
    }

    private static let safariTargets = """
    if (count of documents) is 0 then return ""
    set mediaTargets to {front document}
    repeat with oneDocument in documents
      set end of mediaTargets to oneDocument
    end repeat
    """

    private static let braveTargets = """
    if (count of windows) is 0 then return ""
    set mediaTargets to {}
    try
      set end of mediaTargets to active tab of front window
    end try
    repeat with oneWindow in windows
      try
        set end of mediaTargets to active tab of oneWindow
        repeat with oneTab in tabs of oneWindow
          set end of mediaTargets to oneTab
        end repeat
      end try
    end repeat
    """
}

enum ArtworkLoader {
    static func load(_ raw: String, completion: @escaping (NSImage?) -> Void) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(nil)
            return
        }
        if trimmed.hasPrefix("data:image") {
            completion(image(fromDataURL: trimmed))
            return
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            guard let url = URL(string: trimmed) else {
                completion(nil)
                return
            }
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let image = data.flatMap { NSImage(data: $0) }
                completion(image)
            }.resume()
            return
        }
        let path: String
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            path = url.path
        } else {
            path = trimmed
        }
        let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        completion(data.flatMap { NSImage(data: $0) })
    }

    private static func image(fromDataURL raw: String) -> NSImage? {
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        let payload = String(raw[raw.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }
}

enum MediaController {
    static func poll() -> MediaPoll {
        var chunks: [String] = []
        var sawScript = false
        var note: String?
        let players = AppleScriptRunner.run(MediaScripts.musicPoll)
        if players.errorNumber == nil {
            sawScript = true
            chunks.append(players.text)
            note = NowPlayingParser.denialNote(from: players.text)
        } else if players.errorNumber == -1743 {
            sawScript = true
            note = "Allow Music in Automation"
        }
        if spotifyInstalled {
            let spotify = AppleScriptRunner.run(MediaScripts.spotifyPoll)
            if spotify.errorNumber == nil {
                sawScript = true
                chunks.append(spotify.text)
                if note == nil {
                    note = NowPlayingParser.denialNote(from: spotify.text)
                }
            } else if spotify.errorNumber == -1743 {
                sawScript = true
                note = note ?? "Allow Spotify in Automation"
            }
        }
        if isRunning(.brave) {
            let brave = AppleScriptRunner.run(MediaScripts.bravePoll)
            if brave.errorNumber == nil {
                sawScript = true
                if !brave.text.isEmpty { chunks.append(brave.text) }
            }
        }
        if isRunning(.safari) {
            let safari = AppleScriptRunner.run(MediaScripts.safariPoll)
            if safari.errorNumber == nil {
                sawScript = true
                if !safari.text.isEmpty { chunks.append(safari.text) }
            }
        }
        guard sawScript else { return .failed }
        let sample = NowPlayingParser.choose(from: chunks.joined(separator: "\n"))
        if sample?.source == .music || sample?.source == .spotify {
            note = nil
        }
        return .update(sample, note: note)
    }

    static func playPause(current: MediaSample?) {
        switch current?.source {
        case .safari:
            _ = AppleScriptRunner.run(MediaScripts.safariPlayPause)
        case .brave:
            _ = AppleScriptRunner.run(MediaScripts.bravePlayPause)
        case .music, .spotify:
            if let current {
                _ = AppleScriptRunner.run(MediaScripts.transport("playpause", appName: current.source.appName))
            }
        case nil:
            if isRunning(.music) {
                _ = AppleScriptRunner.run(MediaScripts.transport("play", appName: MediaSource.music.appName))
            } else if isRunning(.spotify) {
                _ = AppleScriptRunner.run(MediaScripts.transport("play", appName: MediaSource.spotify.appName))
            } else if isRunning(.brave) {
                _ = AppleScriptRunner.run(MediaScripts.bravePlayPause)
            } else if isRunning(.safari) {
                _ = AppleScriptRunner.run(MediaScripts.safariPlayPause)
            } else {
                open(.music)
            }
        }
    }

    static func next(current: MediaSample?) {
        guard let current, (current.source == .music || current.source == .spotify) else { return }
        _ = AppleScriptRunner.run(MediaScripts.transport("next track", appName: current.source.appName))
    }

    static func previous(current: MediaSample?) {
        guard let current, (current.source == .music || current.source == .spotify) else { return }
        _ = AppleScriptRunner.run(MediaScripts.transport("previous track", appName: current.source.appName))
    }

    static func open(_ source: MediaSource) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static func isRunning(_ source: MediaSource) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID).isEmpty
    }

    private static var spotifyInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: MediaSource.spotify.bundleID) != nil
    }
}
