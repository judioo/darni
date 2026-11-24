import Foundation

/// How long a loaded tab may sit unseen before the shell unloads it
/// (Chromium: a preserving `ReArcTabDiscard`, ABI 1.25; WebKit: its engine is
/// dropped). The tab stays in the sidebar and reloads when it is shown.
public enum TabUnloadThreshold: String, CaseIterable, Codable, Sendable {
    case never
    case thirtyMinutes
    case oneHour
    case fourHours
    case twelveHours

    public static let defaultsKey = "ReArcTabUnloadThreshold"
    public static let `default`: TabUnloadThreshold = .fourHours

    public var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        case .fourHours: return 4 * 60 * 60
        case .twelveHours: return 12 * 60 * 60
        }
    }

    public var title: String {
        switch self {
        case .never: return "Never"
        case .thirtyMinutes: return "After 30 Minutes"
        case .oneHour: return "After 1 Hour"
        case .fourHours: return "After 4 Hours"
        case .twelveHours: return "After 12 Hours"
        }
    }

    public static func load(from defaults: UserDefaults) -> TabUnloadThreshold {
        defaults.string(forKey: defaultsKey).flatMap(TabUnloadThreshold.init(rawValue:)) ?? .default
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// How long a loaded tab may sit unseen before its page is frozen: the step
/// before the unload. A frozen page stays in memory and runs nothing (no
/// timers, no scripts), and goes on at once when the tab is shown, with no
/// reload (Chromium `ReArcTabFreeze`, ABI 1.71). An engine that cannot freeze
/// (WebKit, an older Chromium) leaves the page running until the unload.
public enum TabFreezeThreshold: String, CaseIterable, Codable, Sendable {
    case never
    case fifteenMinutes
    case thirtyMinutes
    case oneHour

    public static let defaultsKey = "ReArcTabFreezeThreshold"
    public static let `default`: TabFreezeThreshold = .thirtyMinutes

    public var interval: TimeInterval? {
        switch self {
        case .never: return nil
        case .fifteenMinutes: return 15 * 60
        case .thirtyMinutes: return 30 * 60
        case .oneHour: return 60 * 60
        }
    }

    public var title: String {
        switch self {
        case .never: return "Never"
        case .fifteenMinutes: return "After 15 Minutes"
        case .thirtyMinutes: return "After 30 Minutes"
        case .oneHour: return "After 1 Hour"
        }
    }

    public static func load(from defaults: UserDefaults) -> TabFreezeThreshold {
        defaults.string(forKey: defaultsKey).flatMap(TabFreezeThreshold.init(rawValue:)) ?? .default
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}

/// One tab with a live engine, as the freeze and unload checks see it.
public struct TabUnloadCandidate: Equatable, Sendable {
    public var tabID: Tab.ID
    /// Last time the tab was shown (selected, or a pane of the shown split).
    public var lastActive: Date
    /// On screen in some window now.
    public var isVisible: Bool
    /// Playing sound, or capturing: unloading would cut it off.
    public var isAudible: Bool
    /// Already unloaded (discarded) or loading.
    public var isUnloaded: Bool
    /// A dialog or prompt is waiting on the page: a question of the page's, a
    /// permission, a passkey or security key request, a sharing sheet.
    public var hasPendingPrompt: Bool
    /// The page uses the camera or the microphone, is in a call, or shares a
    /// tab, a window or the screen.
    public var isCapturing: Bool
    /// Another page shares this tab: its picture must keep moving.
    public var isShared: Bool
    /// A download the page started is still running.
    public var hasDownload: Bool
    /// The page is in Peek or a Little Darni window, not a tab of the sidebar.
    public var isTransient: Bool
    /// The engine already holds a request to freeze the page.
    public var isFrozen: Bool

    public init(tabID: Tab.ID, lastActive: Date, isVisible: Bool = false, isAudible: Bool = false,
                isUnloaded: Bool = false, hasPendingPrompt: Bool = false, isCapturing: Bool = false,
                isShared: Bool = false, hasDownload: Bool = false, isTransient: Bool = false, isFrozen: Bool = false) {
        self.tabID = tabID
        self.lastActive = lastActive
        self.isVisible = isVisible
        self.isAudible = isAudible
        self.isUnloaded = isUnloaded
        self.hasPendingPrompt = hasPendingPrompt
        self.isCapturing = isCapturing
        self.isShared = isShared
        self.hasDownload = hasDownload
        self.isTransient = isTransient
        self.isFrozen = isFrozen
    }

    /// In use: neither frozen nor unloaded, however long ago it was shown.
    public var isInUse: Bool {
        isVisible || isAudible || hasPendingPrompt || isCapturing || isShared || hasDownload || isTransient
    }
}

public enum TabUnloadPolicy {
    /// Tabs to unload now, least recently shown first.
    public static func tabsToUnload(_ candidates: [TabUnloadCandidate], threshold: TabUnloadThreshold, now: Date) -> [Tab.ID] {
        due(candidates.filter { !$0.isUnloaded }, after: threshold.interval, now: now)
    }

    /// Tabs to freeze now, least recently shown first: loaded, not in use,
    /// not frozen already, and unseen for the threshold.
    public static func tabsToFreeze(_ candidates: [TabUnloadCandidate], threshold: TabFreezeThreshold, now: Date) -> [Tab.ID] {
        due(candidates.filter { !$0.isUnloaded && !$0.isFrozen }, after: threshold.interval, now: now)
    }

    /// Frozen tabs that must run again now: in use, or no longer due (the
    /// threshold was raised or turned off). A tab the engine thawed itself
    /// (shown, shared, playing) is not frozen and is not listed.
    public static func tabsToThaw(_ candidates: [TabUnloadCandidate], threshold: TabFreezeThreshold, now: Date) -> [Tab.ID] {
        candidates
            .filter(\.isFrozen)
            .filter { candidate in
                guard let interval = threshold.interval, !candidate.isInUse else { return true }
                return now.timeIntervalSince(candidate.lastActive) < interval
            }
            .sorted { $0.lastActive < $1.lastActive }
            .map(\.tabID)
    }

    private static func due(_ candidates: [TabUnloadCandidate], after interval: TimeInterval?, now: Date) -> [Tab.ID] {
        guard let interval else { return [] }
        return candidates
            .filter { !$0.isInUse && now.timeIntervalSince($0.lastActive) >= interval }
            .sorted { $0.lastActive < $1.lastActive }
            .map(\.tabID)
    }
}
