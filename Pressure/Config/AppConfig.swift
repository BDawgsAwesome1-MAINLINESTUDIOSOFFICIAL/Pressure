import Combine
import Foundation

struct AppConfig: Codable, Equatable {
    var warningThreshold: Double = 70
    var criticalThreshold: Double = 85
    var autoCloseThreshold: Double = 90
    var autoCloseEnabled: Bool = true
    var notifyOnWarning: Bool = true
    var notifyBeforeAutoClose: Bool = true
    var launchAtLogin: Bool = false
    var priority: [AppPriorityEntry] = []
    var protectedBundleIDs: [String] = []

    mutating func normalizeThresholds() {
        warningThreshold = warningThreshold.clamped(to: 50...97)
        criticalThreshold = max(criticalThreshold, warningThreshold + 1).clamped(to: 51...98)
        autoCloseThreshold = max(autoCloseThreshold, criticalThreshold + 1).clamped(to: 52...99)
    }

    private enum CodingKeys: String, CodingKey {
        case warningThreshold
        case criticalThreshold
        case autoCloseThreshold
        case autoCloseEnabled
        case notifyOnWarning
        case notifyBeforeAutoClose
        case launchAtLogin
        case priority
        case protectedBundleIDs
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        warningThreshold = try container.decodeIfPresent(Double.self, forKey: .warningThreshold) ?? 70
        criticalThreshold = try container.decodeIfPresent(Double.self, forKey: .criticalThreshold) ?? 85
        autoCloseThreshold = try container.decodeIfPresent(Double.self, forKey: .autoCloseThreshold) ?? 90
        autoCloseEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoCloseEnabled) ?? true
        notifyOnWarning = try container.decodeIfPresent(Bool.self, forKey: .notifyOnWarning) ?? true
        notifyBeforeAutoClose = try container.decodeIfPresent(Bool.self, forKey: .notifyBeforeAutoClose) ?? true
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        priority = try container.decodeIfPresent([AppPriorityEntry].self, forKey: .priority) ?? []
        protectedBundleIDs = try container.decodeIfPresent([String].self, forKey: .protectedBundleIDs) ?? []
        normalizeThresholds()
    }
}

struct AppPriorityEntry: Codable, Equatable, Identifiable {
    var bundleIdentifier: String
    var displayName: String

    var id: String { bundleIdentifier }
}

enum PressureLevel: Equatable {
    case ok
    case warning
    case critical

    static func resolve(score: Double, config: AppConfig) -> PressureLevel {
        if score >= config.criticalThreshold {
            return .critical
        }
        if score >= config.warningThreshold {
            return .warning
        }
        return .ok
    }
}

enum KernelPressure: Equatable {
    case normal
    case warning
    case urgent
    case critical
    case unknown(UInt32)

    /// `kern.memorystatus_vm_pressure_level` uses the XNU bit flags:
    /// normal = 1, warning = 2, urgent = 4, critical = 8.
    init(rawLevel: UInt32) {
        switch rawLevel {
        case 0, 1:
            self = .normal
        case 2:
            self = .warning
        case 4:
            self = .urgent
        case 8:
            self = .critical
        default:
            self = .unknown(rawLevel)
        }
    }
}

struct RankedApp: Equatable {
    var bundleIdentifier: String
    var displayName: String
    var pid: Int32
    var residentBytes: UInt64
    var isFrontmost: Bool
    var isUserApp: Bool
}

struct AutoCloseDecision: Equatable {
    var episodeActive: Bool
    var wantsClose: Bool
    var closesThisEpisode: Int
}

enum PressurePolicy {
    static let maxClosesPerEpisode = 5

    static func effectiveScore(_ score: Double, kernel: KernelPressure, config: AppConfig) -> Double {
        var value = score
        switch kernel {
        case .normal, .unknown:
            break
        case .warning:
            value = max(value, config.warningThreshold)
        case .urgent:
            value = max(value, config.criticalThreshold)
        case .critical:
            value = max(value, config.autoCloseThreshold)
        }
        return min(max(value, 0), 100)
    }

    /// Closing starts at the auto-close threshold and continues until pressure
    /// falls below the critical threshold.
    static func step(
        score: Double,
        config: AppConfig,
        episodeActive: Bool,
        closesThisEpisode: Int,
        isClosing: Bool
    ) -> AutoCloseDecision {
        if score < config.criticalThreshold {
            return AutoCloseDecision(episodeActive: false, wantsClose: false, closesThisEpisode: 0)
        }

        let episode = episodeActive || score >= config.autoCloseThreshold
        let wantsClose = episode
            && config.autoCloseEnabled
            && !isClosing
            && closesThisEpisode < maxClosesPerEpisode
        return AutoCloseDecision(
            episodeActive: episode,
            wantsClose: wantsClose,
            closesThisEpisode: closesThisEpisode
        )
    }
}

enum EventBuffer {
    static let limit = 20

    static func prepend<T>(_ item: T, to items: [T]) -> [T] {
        var next = items
        next.insert(item, at: 0)
        if next.count > limit {
            next.removeLast(next.count - limit)
        }
        return next
    }
}

enum ByteFormat {
    static func string(_ bytes: UInt64) -> String {
        let clamped = Int64(min(bytes, UInt64(Int64.max)))
        return ByteCountFormatter.string(fromByteCount: clamped, countStyle: .memory)
    }
}

enum PercentFormat {
    static func string(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var config: AppConfig

    private let defaults: UserDefaults
    private let storageKey = "config"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
        } else {
            config = AppConfig()
        }
    }

    func update(_ mutate: (inout AppConfig) -> Void) {
        var next = config
        mutate(&next)
        next.normalizeThresholds()
        config = next
        persist()
    }

    func setLaunchAtLoginFlag(_ enabled: Bool) {
        update { $0.launchAtLogin = enabled }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
