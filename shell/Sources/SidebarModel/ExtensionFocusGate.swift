import Foundation

/// Whether a program (an extension, or a page's new tab) may change the space
/// on screen.
///
/// To extensions each space is a window, and only the space on screen is the
/// focused one. An extension in a profile that is not on screen therefore sees
/// no focused window at all. Two profiles' copies of one extension that each
/// bring their own tab forward then take the window from each other for ever
/// (the Claude extension did, owner's report 2026-11-22: a space switch about
/// every 0.35 s for as long as it ran).
///
/// The rule is Chrome's, read for spaces: `tabs.create` and
/// `tabs.update({active})` make a tab the active one of its own window, which
/// is the selected tab of its own space. They do not bring that window
/// forward. The space on screen changes only when the user started it:
///
/// - the extension belongs to the profile on screen (the user cannot have
///   clicked anything of a profile that is not), and
/// - the user pressed a key or a mouse button in Darni in the last
///   `userInputWindow` seconds, and no program has spent that input yet. One
///   input pays for one switch, as one click pays for one popup.
///
/// A page's own new tab (`window.open`, target=_blank) has passed Chromium's
/// popup blocker already, so it needs no input here. It is still counted by
/// the loop breaker.
///
/// The loop breaker is the backstop for whatever the rule lets through: when
/// programs bring the window back to a space it left more than `loopReturns`
/// times in `loopWindow` seconds, no program moves it for `loopPause` seconds.
///
/// A window an extension makes (`windows.create`, a Little Darni window) is
/// asked for like any other move, as `newWindow`. Nothing can come back to a
/// window that did not exist, so the loop breaker counts new windows
/// themselves: the first one brought forward is the way out, each further one
/// in `loopWindow` seconds counts as a return.
public struct ExtensionFocusGate: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// tabs.create, tabs.update({active}), windows.update({focused}), openOptionsPage.
        case extensionRequest
        /// A tab the engine made for a page (popup, target=_blank).
        case pageOpenedTab
    }

    public enum Refusal: String, Equatable, Sendable {
        case otherProfile = "the extension's profile is not on screen"
        case noUserInput = "no user input started it"
        case loop = "programs kept switching between the same spaces"
    }

    public enum Verdict: Equatable, Sendable {
        /// Show the target space.
        case follow
        /// Keep the space on screen; the tab becomes the selected tab of its own space.
        case stay(Refusal)
    }

    /// How long one key or button press lets an extension move the window
    /// (HTML's transient activation lasts as long).
    public static let userInputWindow: TimeInterval = 5
    public static let loopWindow: TimeInterval = 10
    public static let loopReturns = 3
    public static let loopPause: TimeInterval = 60

    private struct Switch: Equatable, Sendable {
        var from: UUID
        var to: UUID
        var at: Date
        var newWindow = false
    }

    private var unspentInput: Date?
    private var switches: [Switch] = []
    /// While set and in the future, the loop breaker refuses every program.
    public private(set) var pausedUntil: Date?
    /// How often the loop breaker has tripped (the shell logs each one once).
    public private(set) var trips = 0

    public init() {}

    /// A key or mouse button went down in one of Darni's windows.
    public mutating func noteUserInput(at now: Date = Date()) {
        unspentInput = now
    }

    public func isPaused(at now: Date = Date()) -> Bool {
        pausedUntil.map { now < $0 } ?? false
    }

    /// Asked only when `target` is not the space on screen (`shown`). A
    /// `.follow` is recorded as a switch the caller then makes. `newWindow`:
    /// `target` is a window the program has just made.
    public mutating func decide(from shown: UUID, to target: UUID, source: Source, sameProfile: Bool,
                                newWindow: Bool = false, at now: Date = Date()) -> Verdict {
        guard shown != target else { return .follow }
        if isPaused(at: now) { return .stay(.loop) }
        pausedUntil = nil
        if source == .extensionRequest {
            guard sameProfile else { return .stay(.otherProfile) }
            guard let input = unspentInput, now >= input, now.timeIntervalSince(input) <= Self.userInputWindow else {
                return .stay(.noUserInput)
            }
        }
        switches.removeAll { now.timeIntervalSince($0.at) > Self.loopWindow }
        let candidate = Switch(from: shown, to: target, at: now, newWindow: newWindow)
        if returns(in: switches + [candidate]) > Self.loopReturns {
            switches = []
            pausedUntil = now.addingTimeInterval(Self.loopPause)
            trips += 1
            return .stay(.loop)
        }
        switches.append(candidate)
        if source == .extensionRequest { unspentInput = nil }
        return .follow
    }

    /// Switches that came back to a space an earlier one had left, and new
    /// windows brought forward after the first.
    private func returns(in switches: [Switch]) -> Int {
        var left: Set<UUID> = []
        var madeWindow = false
        var count = 0
        for entry in switches {
            if entry.newWindow {
                if madeWindow { count += 1 }
                madeWindow = true
            } else if left.contains(entry.to) {
                count += 1
            }
            left.insert(entry.from)
        }
        return count
    }
}

/// How fast an extension may ask for new tabs and windows.
///
/// `ExtensionBlankTabs` stops the one form of the 2026-11-22 flood that was
/// seen, blank tabs nobody used. A client that retries the same failing call
/// with an address in it (`tabs.create({url})`) is not a blank tab request,
/// and filled the sidebar just the same (security RC-2026.1122.1231 FX-01).
/// So every request to make a tab or a window is counted, per extension and
/// profile, whatever it asks for: once an extension has asked `limit` times
/// in `window` seconds its next request is declined, and the extension's
/// Promise fails as it does in Chrome with no window to open in.
///
/// Declined requests are counted too. A client that keeps retrying therefore
/// stays declined for as long as it retries, instead of getting `limit` more
/// tabs every `window` seconds, and is let in again `window` seconds after it
/// slows down.
///
/// The numbers: an extension that opens tabs at the user's click opens a few
/// (a search in several sites, a handful of links), so 10 at once pass; the
/// flood asked 4.4 times a second for 142 s. A tool that opens more than 10
/// tabs at one click (a saved session) gets its first 10.
public struct ExtensionTabRate: Equatable, Sendable {
    public static let limit = 10
    public static let window: TimeInterval = 10

    public enum Verdict: Equatable, Sendable {
        case open
        /// Over the cap. `firstOfBurst` is true once per burst, for the one
        /// toast and log line: a burst is a run of declined requests with no
        /// gap of `window` seconds between them.
        case decline(firstOfBurst: Bool)
    }

    private struct Recent: Equatable, Sendable {
        /// When it asked, oldest first; never more than `limit` are kept.
        var asked: [Date] = []
        var lastDeclined: Date?
    }

    private var recent: [String: Recent] = [:]

    public init() {}

    private static func key(_ extensionID: String, _ profile: UUID) -> String {
        "\(extensionID)|\(profile.uuidString)"
    }

    private static func isRecent(_ date: Date, at now: Date) -> Bool {
        date <= now && now.timeIntervalSince(date) < window
    }

    /// An extension asks for a new tab or window. The request is counted
    /// whatever the answer.
    public mutating func ask(by extensionID: String, in profile: UUID, at now: Date = Date()) -> Verdict {
        // Extensions that have been quiet for the window are forgotten.
        recent = recent.filter { entry in
            entry.value.asked.last.map { Self.isRecent($0, at: now) } ?? false
                || entry.value.lastDeclined.map { Self.isRecent($0, at: now) } ?? false
        }
        let key = Self.key(extensionID, profile)
        var entry = recent[key] ?? Recent()
        entry.asked.removeAll { !Self.isRecent($0, at: now) }
        defer { recent[key] = entry }
        guard entry.asked.count >= Self.limit else {
            entry.asked.append(now)
            return .open
        }
        // The newest `limit` requests decide; a flood does not grow the list.
        entry.asked.removeFirst()
        entry.asked.append(now)
        let first = !(entry.lastDeclined.map { Self.isRecent($0, at: now) } ?? false)
        entry.lastDeclined = now
        return .decline(firstOfBurst: first)
    }
}

/// The blank tabs an extension opened that nothing has used since.
///
/// An extension that asks for `chrome://newtab` gets a blank Today tab and is
/// expected to load a page into it. One that keeps asking without ever using
/// them (a call that fails after its tab exists, tried again by its client)
/// filled the owner's sidebar with 628 "New Tab" rows in 142 s (2026-11-22).
/// While an extension holds `limit` blank tabs of its own that are still
/// blank, its next request for a blank tab is declined; the extension's
/// Promise fails, as it does in Chrome with no window to open in. A tab stops
/// counting once a page loads in it or it is closed.
public struct ExtensionBlankTabs: Equatable, Sendable {
    public static let limit = 6

    private var tabs: [String: [UUID]] = [:]

    public init() {}

    private static func key(_ extensionID: String, _ profile: UUID) -> String {
        "\(extensionID)|\(profile.uuidString)"
    }

    /// How many of the extension's blank tabs are still unused. `stillBlank`
    /// says whether a sidebar tab is open and shows no page yet; the rest are forgotten.
    public mutating func unused(for extensionID: String, in profile: UUID, stillBlank: (UUID) -> Bool) -> Int {
        let key = Self.key(extensionID, profile)
        let open = (tabs[key] ?? []).filter(stillBlank)
        tabs[key] = open.isEmpty ? nil : open
        return open.count
    }

    public mutating func opened(_ tab: UUID, by extensionID: String, in profile: UUID) {
        tabs[Self.key(extensionID, profile), default: []].append(tab)
    }
}

public extension ExtensionTabRequest {
    /// A new tab with no page of its own (`chrome://newtab` reaches the shell as about:blank).
    var isForBlankTab: Bool {
        kind == .createTab && (url.isEmpty || url == "about:blank")
    }
}
