import Foundation

/// Screen sharing: a page's `navigator.mediaDevices.getDisplayMedia()`
/// (Chromium ABI 1.70 `display_capture`, C-ABI.md "Screen sharing", engine
/// patch `tab/101-display-capture-host-picker`). The engine asks what to
/// share; Darni's own sheet answers with one of its tabs, or hands over to
/// the macOS picker for a window or the screen. Pure values here: the
/// request as the engine words it, the answer, the outcome, and the record
/// of what is being shared now, which the sharing bar and card draw.

public enum ScreenShareKind: String, Equatable, Sendable, CaseIterable {
    case tab
    case window
    case screen
}

/// What the engine says may be offered for one request (phase 0 JSON).
public struct ScreenShareRequest: Equatable, Sendable {
    public enum Preference: String, Equatable, Sendable {
        case none = ""
        case currentTab = "current_tab"
        case tab
        case window
        case screen
    }

    /// macOS's Screen Recording permission, as the engine reads it (never asked for by reading).
    public enum ScreenRecording: String, Equatable, Sendable {
        /// macOS 15 and later: choosing in the system picker is the permission.
        case notNeeded = "not_needed"
        case granted
        /// macOS 14 without the permission: Darni explains and opens System Settings.
        case missing
    }

    /// The asking frame, and the tab's page (they differ for a frame of another site).
    public var origin: String
    public var topOrigin: String
    /// The page asked for sound too.
    public var wantsAudio: Bool
    /// The asking tab itself may be shared (false: the page excluded it).
    public var allowsCurrentTab: Bool
    public var offersWindow: Bool
    public var offersScreen: Bool
    public var tabAudio: Bool
    public var windowAudio: Bool
    public var screenAudio: Bool
    public var preference: Preference
    /// A window or the screen is chosen in the macOS picker, which opens after the answer.
    public var usesSystemPicker: Bool
    public var screenRecording: ScreenRecording

    public init(origin: String, topOrigin: String = "", wantsAudio: Bool = false, allowsCurrentTab: Bool = true,
                offersWindow: Bool = true, offersScreen: Bool = true, tabAudio: Bool = false,
                windowAudio: Bool = false, screenAudio: Bool = false, preference: Preference = .none,
                usesSystemPicker: Bool = true, screenRecording: ScreenRecording = .notNeeded) {
        self.origin = origin
        self.topOrigin = topOrigin.isEmpty ? origin : topOrigin
        self.wantsAudio = wantsAudio
        self.allowsCurrentTab = allowsCurrentTab
        self.offersWindow = offersWindow
        self.offersScreen = offersScreen
        self.tabAudio = tabAudio
        self.windowAudio = windowAudio
        self.screenAudio = screenAudio
        self.preference = preference
        self.usesSystemPicker = usesSystemPicker
        self.screenRecording = screenRecording
    }

    /// nil for anything that is not the engine's object with an origin: such a request is cancelled.
    public init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let origin = object["origin"] as? String, !origin.isEmpty else { return nil }
        func flag(_ key: String) -> Bool { object[key] as? Bool ?? false }
        self.init(
            origin: origin,
            topOrigin: object["top_origin"] as? String ?? "",
            wantsAudio: flag("audio"),
            // Absent means the engine did not say: the conservative reading is that the page excluded itself.
            allowsCurrentTab: flag("current_tab"),
            offersWindow: flag("window"),
            offersScreen: flag("screen"),
            tabAudio: flag("tab_audio"),
            windowAudio: flag("window_audio"),
            screenAudio: flag("screen_audio"),
            preference: Preference(rawValue: object["prefer"] as? String ?? "") ?? .none,
            usesSystemPicker: flag("system_picker"),
            // An engine that does not say is read as "missing": Darni then explains instead of opening a picker.
            screenRecording: ScreenRecording(rawValue: object["screen_recording_permission"] as? String ?? "") ?? .missing
        )
    }

    /// Only a web page gets the sheet (the engine refuses the others itself).
    public var isFromWebPage: Bool {
        origin.hasPrefix("https://") || origin.hasPrefix("http://")
    }

    /// Who asks, as the sheet names it: the frame's host ("meet.google.com").
    public var site: String { Self.host(of: origin) }

    /// The tab's own site when a frame of another site asks, else nil.
    public var embeddingSite: String? {
        let top = Self.host(of: topOrigin)
        return top == site ? nil : top
    }

    public var title: String { "Share with \(site)" }

    /// The line under the title when the asker is a frame inside another site's page.
    public var frameNote: String? {
        embeddingSite.map { "\(site) is a frame inside \($0)." }
    }

    /// The page asked for its own tab (`preferCurrentTab`). The sheet still
    /// offers everything else, the person's choice, and says what was asked.
    public var preferenceNote: String? {
        preference == .currentTab && allowsCurrentTab ? "\(site) asked to share its own tab." : nil
    }

    /// Sound can go with this kind of share.
    public func offersAudio(for kind: ScreenShareKind) -> Bool {
        switch kind {
        case .tab: tabAudio
        case .window: windowAudio
        case .screen: screenAudio
        }
    }

    /// Whether the sound box starts ticked. A tab's own sound, when the page
    /// asked for sound: yes. The whole Mac's sound: never without the person
    /// ticking it, because it carries every app's sound, not what they chose.
    public func audioDefault(for kind: ScreenShareKind) -> Bool {
        kind == .tab && tabAudio
    }

    public func audioLabel(for kind: ScreenShareKind) -> String {
        switch kind {
        case .tab: "Also share the tab's sound"
        case .window: "Also share sound"
        case .screen: "Also share this Mac's sound"
        }
    }

    public func offers(_ kind: ScreenShareKind) -> Bool {
        switch kind {
        case .tab: true
        case .window: offersWindow
        case .screen: offersScreen
        }
    }

    /// A window or the screen cannot be offered yet: macOS must allow Darni
    /// to record the screen first (macOS 14). Darni says so and opens System
    /// Settings; it never asks macOS on the person's behalf beyond that.
    public var needsScreenRecordingPermission: Bool {
        screenRecording == .missing && (offersWindow || offersScreen)
    }

    /// The kind the sheet opens on: what the page prefers when it is offered, else a tab.
    public var initialKind: ScreenShareKind {
        switch preference {
        case .window where offersWindow && !needsScreenRecordingPermission: .window
        case .screen where offersScreen && !needsScreenRecordingPermission: .screen
        default: .tab
        }
    }

    static func host(of origin: String) -> String {
        guard let components = URLComponents(string: origin), let host = components.host, !host.isEmpty else { return origin }
        if let port = components.port { return "\(host):\(port)" }
        return host
    }
}

/// The person's answer (`ReArcDisplayCaptureRespond`).
public enum ScreenShareChoice: Equatable, Sendable {
    case cancel
    /// An engine tab of the same profile.
    case tab(UInt64, audio: Bool)
    case window(audio: Bool)
    case screen(audio: Bool)

    public var kind: ScreenShareKind? {
        switch self {
        case .cancel: nil
        case .tab: .tab
        case .window: .window
        case .screen: .screen
        }
    }

    /// choice: 0 cancel, 1 tab, 2 window, 3 screen.
    public var engineValues: (choice: UInt32, targetTab: UInt64, audio: Bool) {
        switch self {
        case .cancel: (0, 0, false)
        case .tab(let id, let audio): (1, id, audio)
        case .window(let audio): (2, 0, audio)
        case .screen(let audio): (3, 0, audio)
        }
    }

    public var logName: String {
        switch self {
        case .cancel: "cancel"
        case .tab(let id, let audio): "tab \(id)\(audio ? " with sound" : "")"
        case .window(let audio): "window\(audio ? " with sound" : "")"
        case .screen(let audio): "screen\(audio ? " with sound" : "")"
        }
    }
}

/// How a request ended (phase 1 JSON).
public enum ScreenShareOutcome: Equatable, Sendable {
    case shared(ScreenShareKind, targetTab: UInt64?, audio: Bool)
    /// The person, in Darni's sheet or in the macOS picker.
    case cancelled
    /// The macOS picker could not open.
    case failed
    /// The page went, navigated or asked again.
    case withdrawn

    /// Anything unreadable ends the request as withdrawn: the sheet closes and nothing is recorded as shared.
    public init(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let outcome = object["outcome"] as? String else {
            self = .withdrawn
            return
        }
        switch outcome {
        case "shared":
            guard let kind = (object["kind"] as? String).flatMap(ScreenShareKind.init(rawValue:)) else {
                self = .withdrawn
                return
            }
            self = .shared(kind, targetTab: (object["target_tab"] as? String).flatMap { UInt64($0) },
                           audio: object["audio"] as? Bool ?? false)
        case "cancelled": self = .cancelled
        case "failed": self = .failed
        default: self = .withdrawn
        }
    }

    public var logName: String {
        switch self {
        case .shared(let kind, let target, let audio):
            "shared \(kind.rawValue)" + (target.map { " \($0)" } ?? "") + (audio ? " with sound" : "")
        case .cancelled: "cancelled"
        case .failed: "failed"
        case .withdrawn: "withdrawn"
        }
    }
}

/// One thing a tab's page shares: what kind, and for a tab which one.
public struct ScreenShare<TabID: Hashable & Sendable>: Equatable, Sendable {
    public var kind: ScreenShareKind
    /// The shared tab (kind `.tab`).
    public var target: TabID?
    public var audio: Bool

    public init(kind: ScreenShareKind, target: TabID? = nil, audio: Bool = false) {
        self.kind = kind
        self.target = target
        self.audio = audio
    }
}

/// What is being shared now, by the tab whose page shares it.
///
/// The engine says two things at two moments: what was chosen, when the
/// request is answered (`noteChosen`), and whether the tab's page holds a
/// live share stream (`captureChanged`, from `media_capture`'s
/// `capturing_display`). A choice is shown only while the stream is live:
/// before that nothing leaves the Mac, and when the stream ends (the page's
/// own Stop, Darni's Stop, the shared tab closing) every share of that tab is
/// over. A live stream with no recorded choice still shows, as "something":
/// the indicator must never be missing while a page captures.
public struct ScreenShareLedger<TabID: Hashable & Sendable>: Equatable, Sendable {
    private var chosen: [TabID: [ScreenShare<TabID>]] = [:]
    private var live: Set<TabID> = []

    public init() {}

    /// The request of `capturer` was answered with this share.
    public mutating func noteChosen(_ share: ScreenShare<TabID>, by capturer: TabID) {
        chosen[capturer, default: []].append(share)
    }

    /// `media_capture` for `capturer`: its page holds a share stream or not.
    public mutating func captureChanged(_ capturer: TabID, isCapturingDisplay: Bool) {
        if isCapturingDisplay {
            live.insert(capturer)
        } else if live.remove(capturer) != nil {
            // The streams ended: what was chosen for them is over too.
            chosen[capturer] = nil
        }
    }

    /// The tab is gone.
    public mutating func forget(_ tab: TabID) {
        live.remove(tab)
        chosen[tab] = nil
        for (capturer, shares) in chosen {
            chosen[capturer] = shares.map { share in
                var share = share
                if share.target == tab { share.target = nil }
                return share
            }
        }
    }

    /// Tabs whose page shares something now.
    public var capturers: Set<TabID> { live }

    public var isEmpty: Bool { live.isEmpty }

    /// What `capturer` shares now; empty when its stream is live but no choice was recorded.
    public func shares(of capturer: TabID) -> [ScreenShare<TabID>] {
        live.contains(capturer) ? chosen[capturer] ?? [] : []
    }

    public func isSharing(_ capturer: TabID) -> Bool { live.contains(capturer) }

    /// The tabs whose pages share `tab` now.
    public func capturers(of tab: TabID) -> [TabID] {
        live.filter { capturer in (chosen[capturer] ?? []).contains { $0.kind == .tab && $0.target == tab } }
    }

    /// Short words for what `capturer` shares: "this tab", "a tab", "a window", "your screen".
    public func summary(of capturer: TabID, titleOf: (TabID) -> String?) -> String {
        let shares = shares(of: capturer)
        guard let first = shares.first else { return "your screen or a window" }
        if shares.count > 1 { return "\(shares.count) things" }
        switch first.kind {
        case .screen: return "your screen"
        case .window: return "a window"
        case .tab:
            guard let target = first.target else { return "a tab" }
            if target == capturer { return "this tab" }
            return titleOf(target).map { "“\($0)”" } ?? "a tab"
        }
    }
}

/// The words of the sharing bar over a page and of the sidebar's sharing card.
public enum ScreenShareText {
    /// Over the page that shares: "Sharing your screen with meet.google.com".
    public static func capturerLine(summary: String, site: String) -> String {
        "Sharing \(summary) with \(site)"
    }

    /// Over a tab another tab's page shares: "meet.google.com is sharing this tab".
    public static func capturedLine(site: String) -> String {
        "\(site) is sharing this tab"
    }

    public static let stop = "Stop Sharing"

    /// macOS 14 without the Screen Recording permission.
    public static let permissionTitle = "macOS has not allowed Darni to share a window or the screen"
    public static let permissionBody = "To share a window or your screen, allow Darni under Screen & System Audio Recording in System Settings › Privacy & Security, then ask the site to share again. Sharing a tab works without it."
    public static let openSettings = "Open System Settings"
    public static let systemPickerNote = "You choose it in the macOS picker next."
}
