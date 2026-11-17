import AppKit
import SidebarModel

/// The 1Password desktop app on this Mac. ReArc only finds it and opens it:
/// it passes the app nothing and never touches 1Password's own files.
protocol OnePasswordAppLocating {
    /// Looks for the installed app without holding up the caller;
    /// `completion` gets its URL, or nil, on the main thread.
    func locate(_ completion: @escaping (URL?) -> Void)
    /// Brings the app forward, launching it if need be.
    func open(_ app: URL)
}

/// /Applications first (a bundle read), then LaunchServices by bundle ID
/// for an app kept elsewhere. Both run on a utility queue.
struct SystemOnePasswordApp: OnePasswordAppLocating {
    func locate(_ completion: @escaping (URL?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let url = Self.installedAppURL()
            DispatchQueue.main.async { completion(url) }
        }
    }

    static func installedAppURL() -> URL? {
        let standard = URL(fileURLWithPath: OnePasswordConnect.appPath, isDirectory: true)
        if Bundle(url: standard)?.bundleIdentifier == OnePasswordConnect.appBundleID { return standard }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: OnePasswordConnect.appBundleID)
    }

    /// 1Password declares no URL for its Browser settings (its schemes add
    /// an account or a one-time password), so the app itself opens.
    func open(_ app: URL) {
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// "Connect 1Password to ReArc": a card above the bottom bar, where Finish
/// setup sits, and a row in Settings › General (`OnePasswordConnect`). The
/// card shows when the 1Password app is installed and its extension has an
/// action in some tab, until Done or the close button.
extension BrowserViewModel {
    /// Launch looks for the app only while the card could still show; after
    /// Done, or the last close, a launch does nothing here.
    func locateOnePasswordAppIfPromptMayShow() {
        guard OnePasswordConnect.showsPrompt(appInstalled: true, extensionInstalled: true,
                                             preference: onePasswordPreference) else { return }
        locateOnePasswordApp()
    }

    /// Launch, and Settings › General each time it appears (the app may have
    /// been installed or removed since).
    func locateOnePasswordApp() {
        guard !isLocatingOnePasswordApp else { return }
        isLocatingOnePasswordApp = true
        onePasswordApp.locate { [weak self] url in
            guard let self else { return }
            self.isLocatingOnePasswordApp = false
            if self.onePasswordAppURL != url { self.onePasswordAppURL = url }
        }
    }

    /// 1Password's extension is installed and enabled in a profile in use.
    var hasOnePasswordExtension: Bool {
        extensions.hasAction(where: OnePasswordConnect.isExtension)
    }

    /// The sidebar's card (and the mini sidebar's badge and menu items).
    /// The extensions are read last: once Done, nothing looks at them.
    var showsOnePasswordPrompt: Bool {
        guard OnePasswordConnect.showsPrompt(appInstalled: onePasswordAppURL != nil, extensionInstalled: true,
                                             preference: onePasswordPreference,
                                             dismissedThisLaunch: onePasswordDismissedThisLaunch) else { return false }
        return hasOnePasswordExtension
    }

    var showsOnePasswordSettingsRow: Bool {
        OnePasswordConnect.showsSettingsRow(appInstalled: onePasswordAppURL != nil)
    }

    /// Open 1Password: the person adds ReArc there themselves.
    func openOnePassword() {
        guard let url = onePasswordAppURL else { return }
        onePasswordApp.open(url)
    }

    /// Done: the card never shows by itself again. Settings keeps the row.
    func markOnePasswordConnected() {
        guard !onePasswordPreference.isDone else { return }
        onePasswordPreference.isDone = true
    }

    /// The close button: away for this launch, and counted once.
    func dismissOnePasswordPrompt() {
        guard !onePasswordDismissedThisLaunch else { return }
        onePasswordDismissedThisLaunch = true
        onePasswordPreference.dismissals += 1
    }
}
