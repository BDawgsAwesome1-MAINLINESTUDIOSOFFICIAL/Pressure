import Foundation

enum AppPriority {
    /// Quitting these would take down the session. They stay protected even
    /// if someone removes them from the settings list.
    static let sessionCriticalBundleIDs: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.systemuiserver",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.WindowManager",
        "com.apple.coreservices.uiagent",
        "com.apple.SecurityAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.Spotlight",
        "com.apple.TextInputMenuAgent",
        "com.apple.controlcenter.helper"
    ]

    static let sessionCriticalNames: [(name: String, bundleIdentifier: String)] = [
        ("Finder", "com.apple.finder"),
        ("Dock", "com.apple.dock"),
        ("SystemUIServer", "com.apple.systemuiserver"),
        ("Control Center", "com.apple.controlcenter"),
        ("Notification Center", "com.apple.notificationcenterui"),
        ("WindowManager", "com.apple.WindowManager"),
        ("Spotlight", "com.apple.Spotlight")
    ]

    static func isSessionCritical(_ bundleIdentifier: String) -> Bool {
        sessionCriticalBundleIDs.contains(bundleIdentifier)
    }

    static func protectedIdentifiers(in config: AppConfig, selfBundleID: String?) -> Set<String> {
        var protected = sessionCriticalBundleIDs
        protected.formUnion(config.protectedBundleIDs)
        if let selfBundleID {
            protected.insert(selfBundleID)
        }
        return protected
    }

    /// Lowest-priority running app that the user explicitly listed.
    /// The bottom of `config.priority` is closed first. The frontmost app is skipped.
    static func autoCloseTarget(
        apps: [RankedApp],
        config: AppConfig,
        selfBundleID: String?,
        excluding excluded: Set<String> = []
    ) -> RankedApp? {
        let protected = protectedIdentifiers(in: config, selfBundleID: selfBundleID)
        let order = config.priority.map(\.bundleIdentifier)
        let eligible = apps.filter { app in
            app.isUserApp
                && !app.isFrontmost
                && !protected.contains(app.bundleIdentifier)
                && !excluded.contains(app.bundleIdentifier)
                && order.contains(app.bundleIdentifier)
        }
        return eligible.max { lhs, rhs in
            let left = order.firstIndex(of: lhs.bundleIdentifier) ?? -1
            let right = order.firstIndex(of: rhs.bundleIdentifier) ?? -1
            return left < right
        }
    }

    static func manualCloseTarget(
        apps: [RankedApp],
        config: AppConfig,
        selfBundleID: String?
    ) -> RankedApp? {
        let protected = protectedIdentifiers(in: config, selfBundleID: selfBundleID)
        return apps
            .filter { $0.isUserApp && !protected.contains($0.bundleIdentifier) }
            .max { $0.residentBytes < $1.residentBytes }
    }
}
