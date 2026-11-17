import AppKit
import Darwin
import SidebarModel

/// The 1Password desktop app on this Mac. ReArc only finds it, sees whether
/// it is running and opens it: it passes the app nothing and never touches
/// 1Password's own files.
protocol OnePasswordAppLocating {
    /// Looks for the installed app without holding up the caller;
    /// `completion` gets its URL, or nil, on the main thread.
    func locate(_ completion: @escaping (URL?) -> Void)
    /// The app is running now.
    var isRunning: Bool { get }
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

    /// By bundle ID, from the workspace's list of running apps.
    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == OnePasswordConnect.appBundleID && !$0.isTerminated
        }
    }

    /// 1Password declares no URL for its Browser settings (its schemes add
    /// an account or a one-time password), so the app itself opens.
    func open(_ app: URL) {
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// ReArc's own direct children (`OnePasswordConnection`).
protocol ChildProcessListing {
    func snapshot() -> ChildProcessSnapshot
}

/// The kernel's list of this process's children, and for each its
/// executable path and start time. The engine starts a native messaging
/// host with `posix_spawn` from the browser process (Chromium's
/// `LaunchContext::LaunchNativeProcess`), which in ReArc is this process, so
/// 1Password's helper is a direct child and no descendants are walked.
///
/// Process facts only: no file is opened, no arguments or environment are
/// read, no task port is taken and nothing is signalled or started.
/// `proc_pidinfo` fills a fixed record; of it this reads the start time,
/// and the parent to drop a process number that has passed to another
/// program since the list was made.
struct SystemChildProcesses: ChildProcessListing {
    func snapshot() -> ChildProcessSnapshot {
        let parent = getpid()
        let now = Date()
        // Sized for every process on the Mac, so the list cannot be cut short.
        let needed = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), nil, 0)
        guard needed > 0 else { return ChildProcessSnapshot(takenAt: now, children: []) }
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.stride)
        let filled = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), $0.baseAddress, Int32($0.count))
        }
        guard filled > 0 else { return ChildProcessSnapshot(takenAt: now, children: []) }

        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let recordSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        var children: [ChildProcessFact] = []
        for pid in pids.prefix(Int(filled) / MemoryLayout<pid_t>.stride) where pid > 0 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, recordSize) == recordSize,
                  info.pbi_ppid == UInt32(parent),
                  proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let started = TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1_000_000
            children.append(ChildProcessFact(executablePath: String(cString: path),
                                             startTime: Date(timeIntervalSince1970: started)))
        }
        return ChildProcessSnapshot(takenAt: now, children: children)
    }
}

/// "Connect 1Password to ReArc": a card above the bottom bar, where Finish
/// setup sits, and a row in Settings › General (`OnePasswordConnect`). The
/// card shows when the 1Password app is installed and its extension has an
/// action in some tab, until Done or the close button, and stays away while
/// 1Password's helper is seen attached to ReArc (`OnePasswordConnection`).
extension BrowserViewModel {
    /// Launch looks for the app only while the card could still show; after
    /// Done with no connection ever seen, or the last close, a launch does
    /// nothing here.
    func locateOnePasswordAppIfPromptMayShow() {
        guard OnePasswordConnect.watchesConnection(preference: onePasswordPreference,
                                                   connection: onePasswordConnection) else { return }
        locateOnePasswordApp()
        watchOnePasswordConnection()
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
                                             dismissedThisLaunch: onePasswordDismissedThisLaunch,
                                             connectionHidesPrompt: onePasswordConnection.hidesPrompt) else { return false }
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

    // MARK: The connection

    /// Settings' "Connected": from this launch's readings only, and only
    /// while one is fresh. It says the helper stayed attached, not that
    /// 1Password trusts ReArc, so the row keeps the steps beside it.
    var isOnePasswordConnected: Bool {
        onePasswordConnection.isConnected(uptime: onePasswordUptime())
    }

    /// A reading can change what shows: the Settings row is on screen, or
    /// the card could show or go.
    private var readsOnePasswordConnection: Bool {
        if isOnePasswordSettingsRowShown { return true }
        return onePasswordAppURL != nil && watchesOnePasswordConnection && hasOnePasswordExtension
    }

    private var watchesOnePasswordConnection: Bool {
        OnePasswordConnect.watchesConnection(preference: onePasswordPreference, connection: onePasswordConnection,
                                             dismissedThisLaunch: onePasswordDismissedThisLaunch)
    }

    /// Reads every `OnePasswordConnection.pollInterval` for as long as a
    /// reading can change what shows, then stops by itself.
    func watchOnePasswordConnection() {
        guard onePasswordConnectionTimer == nil else { return }
        let timer = Timer(timeInterval: OnePasswordConnection.pollInterval, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.pollOnePasswordConnection()
        }
        RunLoop.main.add(timer, forMode: .common)
        onePasswordConnectionTimer = timer
        pollOnePasswordConnection()
    }

    /// One turn of the watch. The app not found yet, or no extension in a
    /// tab yet, skips the turn; a watch with nothing left to change ends.
    func pollOnePasswordConnection() {
        if readsOnePasswordConnection {
            readOnePasswordConnection()
        } else if !isOnePasswordSettingsRowShown, !watchesOnePasswordConnection {
            onePasswordConnectionTimer?.invalidate()
            onePasswordConnectionTimer = nil
        }
    }

    /// One reading. The children are listed only when the answer could be
    /// "attached": the app is running and ReArc copied 1Password's manifest.
    func readOnePasswordConnection() {
        let appRunning = onePasswordApp.isRunning
        let snapshot = appRunning && onePasswordHelperPath != nil ? onePasswordProcesses.snapshot() : nil
        let reading = OnePasswordConnection.reading(of: snapshot, helperPath: onePasswordHelperPath, appRunning: appRunning,
                                                    extensionInstalled: hasOnePasswordExtension)
        switch onePasswordConnection.record(reading, uptime: onePasswordUptime()) {
        case .nothingNew, .connected, .notConnected(lost: false):
            break
        case .notConnected(lost: true):
            // Done was said of a connection that is gone: the card may come back.
            onePasswordPreference.connectionLost()
        }
    }

    /// Settings › General shows the row: read now, and keep reading while it shows.
    func onePasswordSettingsRowAppeared() {
        isOnePasswordSettingsRowShown = true
        // A new watch starts with a reading.
        if onePasswordConnectionTimer == nil { watchOnePasswordConnection() } else { readOnePasswordConnection() }
    }

    /// The row went, with its pane or with the Settings window. The watch
    /// ends at its next turn unless the card still needs it.
    func onePasswordSettingsRowDisappeared() {
        isOnePasswordSettingsRowShown = false
    }
}
