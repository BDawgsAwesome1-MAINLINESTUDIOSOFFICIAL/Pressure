import Foundation

@main
struct PressureTests {
    static func main() {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition {
                failures.append(message)
            }
        }

        check(MemoryReader.pressureScore(availablePercent: 54) == 46, "available 54% is pressure 46")
        check(MemoryReader.pressureScore(availablePercent: -4) == 100, "negative available clamps to full pressure")
        check(MemoryReader.pressureScore(availablePercent: 140) == 0, "available above 100 clamps to zero pressure")

        var config = AppConfig()
        config.warningThreshold = 95
        config.criticalThreshold = 60
        config.autoCloseThreshold = 40
        config.normalizeThresholds()
        check(config.warningThreshold < config.criticalThreshold, "warning stays below critical")
        check(config.criticalThreshold < config.autoCloseThreshold, "critical stays below auto-close")

        let base = AppConfig()
        check(
            PressurePolicy.effectiveScore(40, kernel: .critical, config: base) == base.autoCloseThreshold,
            "kernel critical floors the score at auto-close"
        )
        check(
            PressurePolicy.effectiveScore(10, kernel: .warning, config: base) == base.warningThreshold,
            "kernel warning floors the score at warning"
        )
        check(
            PressurePolicy.effectiveScore(96, kernel: .normal, config: base) == 96,
            "normal kernel pressure leaves the percentage alone"
        )

        let idle = PressurePolicy.step(score: 40, config: base, episodeActive: false, closesThisEpisode: 0, isClosing: false)
        check(!idle.wantsClose && !idle.episodeActive, "low pressure does not close anything")

        let armed = PressurePolicy.step(score: 91, config: base, episodeActive: false, closesThisEpisode: 0, isClosing: false)
        check(armed.episodeActive && armed.wantsClose, "crossing auto-close starts an episode")

        let holding = PressurePolicy.step(score: 86, config: base, episodeActive: true, closesThisEpisode: 1, isClosing: false)
        check(holding.wantsClose && holding.closesThisEpisode == 1, "episode continues between critical and auto-close")

        let cooled = PressurePolicy.step(score: 84, config: base, episodeActive: true, closesThisEpisode: 2, isClosing: false)
        check(!cooled.episodeActive && cooled.closesThisEpisode == 0, "dropping under critical ends the episode")

        let capped = PressurePolicy.step(
            score: 95,
            config: base,
            episodeActive: true,
            closesThisEpisode: PressurePolicy.maxClosesPerEpisode,
            isClosing: false
        )
        check(!capped.wantsClose, "episode stops after the close cap")

        var paused = base
        paused.autoCloseEnabled = false
        let disabled = PressurePolicy.step(score: 99, config: paused, episodeActive: false, closesThisEpisode: 0, isClosing: false)
        check(disabled.episodeActive && !disabled.wantsClose, "pause keeps the episode but does not close")

        let apps = [
            RankedApp(bundleIdentifier: "com.apple.finder", displayName: "Finder", pid: 1, residentBytes: 500, isFrontmost: false, isUserApp: true),
            RankedApp(bundleIdentifier: "com.example.xcode", displayName: "Xcode", pid: 2, residentBytes: 4_000, isFrontmost: true, isUserApp: true),
            RankedApp(bundleIdentifier: "com.example.slack", displayName: "Slack", pid: 3, residentBytes: 2_000, isFrontmost: false, isUserApp: true),
            RankedApp(bundleIdentifier: "com.example.spotify", displayName: "Spotify", pid: 4, residentBytes: 1_000, isFrontmost: false, isUserApp: true),
            RankedApp(bundleIdentifier: "com.example.chrome", displayName: "Chrome", pid: 5, residentBytes: 8_000, isFrontmost: false, isUserApp: true),
            RankedApp(bundleIdentifier: "com.example.agent", displayName: "Agent", pid: 6, residentBytes: 400, isFrontmost: false, isUserApp: false)
        ]
        var listed = AppConfig()
        listed.priority = [
            AppPriorityEntry(bundleIdentifier: "com.example.xcode", displayName: "Xcode"),
            AppPriorityEntry(bundleIdentifier: "com.example.slack", displayName: "Slack"),
            AppPriorityEntry(bundleIdentifier: "com.example.spotify", displayName: "Spotify")
        ]
        let target = AppPriority.autoCloseTarget(apps: apps, config: listed, selfBundleID: "com.mainlinestudios.Pressure")
        check(target?.bundleIdentifier == "com.example.spotify", "lowest listed app is closed first, got \(target?.displayName ?? "nil")")

        let withoutSpotify = apps.filter { $0.bundleIdentifier != "com.example.spotify" }
        let next = AppPriority.autoCloseTarget(apps: withoutSpotify, config: listed, selfBundleID: "com.mainlinestudios.Pressure")
        check(next?.bundleIdentifier == "com.example.slack", "frontmost Xcode is skipped, so Slack is next")

        var protected = listed
        protected.protectedBundleIDs = ["com.example.spotify"]
        let skipped = AppPriority.autoCloseTarget(apps: apps, config: protected, selfBundleID: "com.mainlinestudios.Pressure")
        check(skipped?.bundleIdentifier == "com.example.slack", "protected apps are skipped")

        let retry = AppPriority.autoCloseTarget(
            apps: apps,
            config: listed,
            selfBundleID: "com.mainlinestudios.Pressure",
            excluding: ["com.example.spotify"]
        )
        check(retry?.bundleIdentifier == "com.example.slack", "already attempted apps are skipped")

        let manual = AppPriority.manualCloseTarget(apps: apps, config: listed, selfBundleID: "com.mainlinestudios.Pressure")
        check(manual?.bundleIdentifier == "com.example.chrome", "manual close picks the largest unprotected app, even if unlisted")

        let finder = AppPriority.manualCloseTarget(
            apps: [apps[0]],
            config: listed,
            selfBundleID: "com.mainlinestudios.Pressure"
        )
        check(finder == nil, "Finder is never a close target")

        var events: [Int] = []
        for value in 1...25 {
            events = EventBuffer.prepend(value, to: events)
        }
        check(events.count == EventBuffer.limit, "action log stays at \(EventBuffer.limit)")
        check(events.first == 25 && events.last == 6, "action log keeps the newest events")

        let collapsed = HubLayout.panel(expanded: false, visibleMinX: 0, visibleMidY: 800)
        check(collapsed.width == HubLayout.collapsedWidth, "compact hub keeps the pill width")
        check(abs((collapsed.y + collapsed.height / 2) - 800) < 0.01, "compact hub stays vertically centered")
        check(collapsed.x == 0 - HubLayout.edgeTuck, "compact hub sits on the left edge")

        let expanded = HubLayout.panel(expanded: true, visibleMinX: 80, visibleMidY: 800)
        check(expanded.x == 80, "expanded hub sits just inside the visible edge")
        check(abs((expanded.y + expanded.height / 2) - 800) < 0.01, "expanded hub grows from the same center")

        let hot = HubLayout.hotZone(screenMinX: 0, visibleMinX: 0, visibleMidY: 800)
        check(hot.contains(x: 4, y: 800), "left middle of the screen opens the hub")
        check(!hot.contains(x: 4, y: 200), "the top of the left edge does not open the hub")
        check(!hot.contains(x: 400, y: 800), "the middle of the screen does not open the hub")
        check(HubLayout.innerCornerRadius == HubLayout.expandedCornerRadius - HubLayout.contentMargin, "inner corners stay concentric with the island")
        check((44...52).contains(HubLayout.collapsedWidth), "compact pill stays about 44 to 52 points wide")
        check(HubLayout.expandedWidth >= 280 && HubLayout.expandedWidth <= 320, "expanded card stays about 280 to 320 points wide")
        check(HubLayout.expandedHeight >= 360 && HubLayout.expandedHeight <= 400, "expanded card stays under a 400 point cap")
        let batteryOnly = HubLayout.collapsedHeight(nowPlaying: false, timer: false, stopwatch: false)
        let withMedia = HubLayout.collapsedHeight(nowPlaying: true, timer: true, stopwatch: true)
        check(batteryOnly < 56, "battery-only pill is short, got \(batteryOnly)")
        check(withMedia > batteryOnly && withMedia < 140, "live rows add height without a tall panel, got \(withMedia)")
        check(collapsed.height == batteryOnly, "the resting pill is only as tall as the battery row")

        let timerFirst = IslandPriority.compact(IslandCandidates(
            timerRunning: true,
            stopwatchRunning: true,
            nowPlaying: true,
            hasPower: true,
            hasCalendarEvent: true
        ))
        check(timerFirst == .timer, "a running timer wins the compact pill")

        let stopwatchNext = IslandPriority.compact(IslandCandidates(
            stopwatchRunning: true,
            nowPlaying: true,
            hasPower: true,
            hasCalendarEvent: true
        ))
        check(stopwatchNext == .stopwatch, "a running stopwatch beats now playing")

        let playingNext = IslandPriority.compact(IslandCandidates(
            nowPlaying: true,
            hasPower: true,
            hasCalendarEvent: true
        ))
        check(playingNext == .nowPlaying, "now playing beats battery")

        let batteryNext = IslandPriority.compact(IslandCandidates(hasPower: true, hasCalendarEvent: true))
        check(batteryNext == .battery, "battery beats the next event")

        let eventNext = IslandPriority.compact(IslandCandidates(hasCalendarEvent: true))
        check(eventNext == .calendar, "calendar shows when power is unavailable")

        let memoryFallback = IslandPriority.compact(IslandCandidates())
        check(memoryFallback == .memory, "memory is the fallback activity")

        let alertFace = IslandPriority.compact(IslandCandidates(timerAlert: true, hasPower: true))
        check(alertFace == .timer, "a finished timer keeps the pill until the alert ends")

        check(IslandTimeFormat.countdown(65) == "1:05", "countdown formats minutes")
        check(IslandTimeFormat.countdown(3600) == "1:00:00", "countdown formats hours")
        check(IslandTimeFormat.stopwatch(65.1) == "1:05.1", "stopwatch keeps a tenth")

        let sample = "music\tplaying\tIsland\tMainline\nspotify\tpaused\tOther\tBand\n"
        let chosen = NowPlayingParser.choose(from: sample)
        check(chosen?.source == .music && chosen?.title == "Island" && chosen?.isPlaying == true, "playing Music wins over paused Spotify")
        check(NowPlayingParser.choose(from: "music\tstopped\t\t\n") == nil, "a stopped player is hidden")
        let pausedTrack = NowPlayingParser.choose(from: "spotify\tpaused\tTide\tPool\n")
        check(pausedTrack?.isPlaying == false && pausedTrack?.artist == "Pool", "paused playback stays available for the expanded row")
        let safari = NowPlayingParser.choose(from: "music\tpaused\tSong\tBand\nsafari\tplaying\tClip\tPage\thttps://example.com/cover.jpg\n")
        check(safari?.source == .safari && safari?.isPlaying == true, "playing Safari media beats paused Music")
        check(safari?.artworkURL == "https://example.com/cover.jpg", "Safari artwork URL is kept")

        let power = PowerReader.read()
        if power.mode == .battery {
            check((0...100).contains(power.percent ?? -1), "battery percent is in range, got \(power.percent ?? -1)")
        } else {
            check(power.compactText == "Power", "a desktop Mac shows Power instead of a fake battery")
        }

        if let snapshot = MemoryReader.read() {
            check((0...100).contains(snapshot.pressureScore), "live pressure score is in range, got \(snapshot.pressureScore)")
            check(snapshot.physicalBytes > 0, "physical memory is reported")
        } else {
            failures.append("live memory sample failed")
        }

        if failures.isEmpty {
            print("OK")
        } else {
            for failure in failures {
                print("FAIL \(failure)")
            }
            exit(1)
        }
    }
}
