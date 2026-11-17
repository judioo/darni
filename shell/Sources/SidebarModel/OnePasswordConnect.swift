import Foundation

/// "Connect 1Password to ReArc": a one-time setup step the person does in
/// 1Password. ReArc copies 1Password's native messaging host manifest
/// (`ChromiumNativeMessagingHosts`), but the 1Password app talks only to
/// browsers it trusts. Arc and Chrome are built in; ReArc has to be added in
/// 1Password › Settings › Browser, and until then the extension stays locked
/// while the app is unlocked. That is the person's trust decision: ReArc
/// never adds itself and never reads or writes 1Password's files. ReArc
/// cannot see whether 1Password trusts it either, so nothing here claims to
/// know: the prompt is a setup step, shown while the person has not said it
/// is done and no helper of 1Password's has stayed attached to ReArc
/// (`OnePasswordConnection`).
public enum OnePasswordConnect {
    /// The 1Password desktop app (version 8).
    public static let appBundleID = "com.1password.1password"
    public static let appPath = "/Applications/1Password.app"

    /// 1Password's extensions in the Chrome Web Store: the `allowed_origins`
    /// of its `com.1password.1password` host manifest (1Password 8.12).
    public static let extensionIDs: Set<String> = [
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa", // stable
        "khgocmkkpikpnmmkgmdnfckapcdkgfaf", // beta
        "gejiddohjgogedgjnonbofjigllpkmbf", // nightly
        "bkpbhnjcbehoklfkljkkbbmipaphipgl",
        "dppgmdbiimibapkepcbdbmkaabgiofem",
        "hjlinigoblmkhjejkmbegnoaljkphmgo",
    ]

    public static func isExtension(_ id: String) -> Bool { extensionIDs.contains(id) }

    /// The close button puts the prompt away until a later launch. After
    /// this many closes it does not come back by itself: shown, closed, shown
    /// once more, closed.
    public static let maximumDismissals = 2

    /// The prompt shows by itself: the app and the extension are both here,
    /// the person has not pressed Done, and has closed it neither in this
    /// launch nor `maximumDismissals` times, and the connection is not
    /// evidently working (`OnePasswordConnectionState.hidesPrompt`).
    public static func showsPrompt(appInstalled: Bool, extensionInstalled: Bool,
                                   preference: OnePasswordConnectPreference,
                                   dismissedThisLaunch: Bool = false,
                                   connectionHidesPrompt: Bool = false) -> Bool {
        appInstalled && extensionInstalled && !preference.isDone && !dismissedThisLaunch
            && preference.dismissals < maximumDismissals && !connectionHidesPrompt
    }

    /// A reading of the connection can still change the prompt in this
    /// launch. It cannot once the prompt is closed for the launch or for
    /// good, or once a helper was seen attached. After Done only a lost
    /// connection brings the prompt back, and this launch's verdict settles
    /// that. None of this turns back within a launch.
    public static func watchesConnection(preference: OnePasswordConnectPreference,
                                         connection: OnePasswordConnectionState,
                                         dismissedThisLaunch: Bool = false) -> Bool {
        guard !dismissedThisLaunch, preference.dismissals < maximumDismissals,
              !connection.wasConnectedThisLaunch else { return false }
        return !preference.isDone || (connection.stored && !connection.hasVerdict)
    }

    /// Settings › General keeps the instructions for as long as the app is
    /// installed, whatever the prompt's state.
    public static func showsSettingsRow(appInstalled: Bool) -> Bool { appInstalled }

    public static let title = "Connect 1Password to ReArc"
    /// The step itself, in the same words wherever it shows.
    public static let steps = "Settings › Browser › Add Browser, then choose ReArc. Restart ReArc afterwards."
    public static let message = "1Password unlocks in ReArc once you add ReArc as a browser in 1Password: " + steps
    public static let open = "Open 1Password"
    public static let done = "Done"
    /// The Settings row's label.
    public static let settingsLabel = "1Password"
    /// The Settings row while a helper is attached. The steps stay under
    /// it: an attached helper is not 1Password's word that it trusts ReArc.
    public static let connected = "Connected"
    public static let connectedMessage = "If 1Password stays locked in ReArc, add ReArc as a browser in 1Password: " + steps

    /// The words under the Settings row's label: the steps, in every state.
    public static func settingsMessage(connected: Bool) -> String { connected ? connectedMessage : message }
    /// The mini sidebar's space menu, which has no room for the card.
    public static let menuTitle = "Connect 1Password to ReArc…"
    public static let menuHide = "Hide Connect 1Password"
}

/// What the person has told the prompt, kept like the other one-time
/// preferences.
public struct OnePasswordConnectPreference: Equatable, Sendable {
    public static let doneKey = "rearc.onePasswordConnectDone"
    public static let dismissalsKey = "rearc.onePasswordConnectDismissals"

    /// Done: the prompt never shows by itself again.
    public var isDone: Bool
    /// Times the close button was pressed, one a launch at most.
    public var dismissals: Int

    public init(isDone: Bool = false, dismissals: Int = 0) {
        self.isDone = isDone
        self.dismissals = max(dismissals, 0)
    }

    public static func load(from defaults: UserDefaults) -> Self {
        Self(isDone: defaults.bool(forKey: doneKey), dismissals: defaults.integer(forKey: dismissalsKey))
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(isDone, forKey: Self.doneKey)
        defaults.set(dismissals, forKey: Self.dismissalsKey)
    }

    /// A connection seen in an earlier launch is gone
    /// (`OnePasswordConnectionState.Outcome.notConnected(lost: true)`). Done
    /// was said of that connection, so the prompt may come back, once: one
    /// close ends it, and a prompt already closed for good stays closed.
    public mutating func connectionLost() {
        guard isDone else { return }
        isDone = false
        dismissals = max(dismissals, OnePasswordConnect.maximumDismissals - 1)
    }
}
