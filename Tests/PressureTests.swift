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
