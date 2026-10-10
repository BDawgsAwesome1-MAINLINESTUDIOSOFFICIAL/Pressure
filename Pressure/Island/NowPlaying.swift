import AppKit

enum AppleScriptRunner {
    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error, error[NSAppleScript.errorNumber] != nil {
            return nil
        }
        return result.stringValue ?? ""
    }
}

enum MediaPoll {
    case failed
    case update(MediaSample?)
}

enum MediaScripts {
    /// One line, no double quotes, so it can sit inside an AppleScript string.
    /// Fields are separated with character 31. A playing element wins over a paused one.
    static let safariProbe = "(function(){function clean(v){return String(v||'').split(String.fromCharCode(9)).join(' ').split(String.fromCharCode(10)).join(' ').split(String.fromCharCode(13)).join(' ').trim();}function walk(doc,list){if(!doc||!list){return;}var nodes=doc.querySelectorAll('audio,video');for(var i=0;i<nodes.length;i++){list.push(nodes[i]);}var frames=doc.querySelectorAll('iframe');for(var j=0;j<frames.length;j++){try{walk(frames[j].contentDocument,list);}catch(e){}}}var list=[];walk(document,list);var playing=null;for(var k=0;k<list.length;k++){var el=list[k];if(!el.paused&&!el.ended&&(el.currentSrc||el.src)){playing=el;break;}}if(!playing){return '';}var meta=null;try{meta=navigator.mediaSession&&navigator.mediaSession.metadata;}catch(e){}var title=clean(playing.getAttribute('title')||(meta&&meta.title)||document.title||'');var artist=clean((meta&&meta.artist)||'');var art='';if(playing.poster){art=playing.poster;}try{if(!art&&meta&&meta.artwork&&meta.artwork.length){art=meta.artwork[0].src||'';}}catch(e){}art=clean(art);if(art.indexOf('blob:')===0){art='';}return ['playing',title,artist,art].join(String.fromCharCode(31));})()"

    static let safariToggle = "(function(){function walk(doc,list){if(!doc||!list){return;}var nodes=doc.querySelectorAll('audio,video');for(var i=0;i<nodes.length;i++){list.push(nodes[i]);}var frames=doc.querySelectorAll('iframe');for(var j=0;j<frames.length;j++){try{walk(frames[j].contentDocument,list);}catch(e){}}}var list=[];walk(document,list);var el=null;for(var k=0;k<list.length;k++){if(!list[k].paused&&!list[k].ended){el=list[k];break;}}if(!el){return 'missing';}if(el.paused){var pending=el.play();if(pending&&pending.catch){pending.catch(function(){});}return 'playing';}el.pause();return 'paused';})()"

    static let poll = """
    on describe(appName)
      tell application appName
        if player state is playing then
          set ps to "playing"
        else if player state is paused then
          set ps to "paused"
        else
          set ps to "stopped"
        end if
        if ps is "stopped" then
          return ps & tab & "" & tab & "" & tab & ""
        end if
        set trackName to ""
        set artistName to ""
        set art to ""
        try
          set trackName to name of current track
        end try
        try
          set artistName to artist of current track
        end try
        if appName is "Spotify" then
          try
            set art to artwork url of current track
          end try
        else if appName is "Music" then
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
        end if
        return ps & tab & trackName & tab & artistName & tab & art
      end tell
    end describe

    set output to ""
    if application "Music" is running then
      try
        set output to output & "music" & tab & describe("Music") & linefeed
      end try
    end if
    if application "Spotify" is running then
      try
        set output to output & "spotify" & tab & describe("Spotify") & linefeed
      end try
    end if
    return output
    """

    static var safariPoll: String {
        """
        if application "Safari" is not running then return ""
        set jsResult to ""
        try
          tell application "Safari"
            set jsResult to do JavaScript "\(safariProbe)" in front document
          end tell
        on error
          return ""
        end try
        if jsResult is missing value or jsResult is "" then return ""
        set AppleScript's text item delimiters to (character id 31)
        set bits to text items of (jsResult as text)
        set AppleScript's text item delimiters to tab
        set joined to bits as text
        set AppleScript's text item delimiters to ""
        return "safari" & tab & joined
        """
    }

    static var safariPlayPause: String {
        """
        if application "Safari" is not running then return ""
        try
          tell application "Safari"
            do JavaScript "\(safariToggle)" in front document
          end tell
        end try
        return ""
        """
    }

    static func transport(_ command: String, appName: String) -> String {
        "tell application \"\(appName)\" to \(command)"
    }
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
        if let raw = AppleScriptRunner.run(MediaScripts.poll) {
            sawScript = true
            chunks.append(raw)
        }
        if isRunning(.safari), let raw = AppleScriptRunner.run(MediaScripts.safariPoll) {
            sawScript = true
            chunks.append(raw)
        }
        guard sawScript else { return .failed }
        return .update(NowPlayingParser.choose(from: chunks.joined(separator: "\n")))
    }

    static func playPause(current: MediaSample?) {
        if current?.source == .safari {
            _ = AppleScriptRunner.run(MediaScripts.safariPlayPause)
            return
        }
        if let current {
            _ = AppleScriptRunner.run(MediaScripts.transport("playpause", appName: current.source.appName))
            return
        }
        if isRunning(.music) {
            _ = AppleScriptRunner.run(MediaScripts.transport("play", appName: MediaSource.music.appName))
        } else if isRunning(.spotify) {
            _ = AppleScriptRunner.run(MediaScripts.transport("play", appName: MediaSource.spotify.appName))
        } else if isRunning(.safari) {
            _ = AppleScriptRunner.run(MediaScripts.safariPlayPause)
        } else {
            open(.music)
        }
    }

    static func next(current: MediaSample?) {
        guard let current, current.source != .safari else { return }
        _ = AppleScriptRunner.run(MediaScripts.transport("next track", appName: current.source.appName))
    }

    static func previous(current: MediaSample?) {
        guard let current, current.source != .safari else { return }
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
}
