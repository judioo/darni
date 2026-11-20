import AppKit
import SidebarModel
import SwiftUI

/// Engines that report a ⌥⌘-click on a link instead of following it.
protocol LittleArcLinkOpening: AnyObject {
    var littleArcLinkHandler: ((URL) -> Void)? { get set }
}

/// Wave 26 Little Arc: its toolbar (address field, back, forward, reload,
/// profile), New Little Arc Window, the global hotkey and ⌥⌘-click
/// (PEEK-LITTLE-BROWSER §2–§2.2).
/// A toast shown on one Little Darni window (`showLittleArcToast`).
struct LittleArcToast: Equatable {
    var windowID: LittleArcWindow.ID
    var toast: ShellToast
}

extension BrowserViewModel {

    /// The key window's Little Arc engine, for navigation commands.
    var keyLittleArcEngine: (any WebEngine)? {
        guard let id = keyLittleArcID, store.littleArcWindow(withID: id) != nil else { return nil }
        return littleArcEngine(for: id)
    }

    /// New Little Arc Window (⌥⌘N, the global hotkey): a blank Little Arc
    /// with its address field ready for typing.
    @discardableResult
    func openBlankLittleArc() -> LittleArcWindow {
        let record = openLittleArc(url: URL(string: "about:blank")!, title: "Little Darni")
        littleArcFocusRequest = record.id
        return record
    }

    /// Return in the Little Arc address field: a URL or a search, in that window.
    @discardableResult
    func navigateLittleArc(_ id: LittleArcWindow.ID, to text: String) -> Bool {
        guard store.littleArcWindow(withID: id) != nil,
              let url = URLEntry.resolve(text, engine: engineHost.navigationSchemes, provider: searchProvider),
              NavigationURLPolicy.allows(url, engine: engineHost.navigationSchemes) else { return false }
        store.updateLittleArcWindow(id: id, title: url.host(), url: url)
        littleArcEngine(for: id).load(url)
        return true
    }

    /// The Little Arc's profile menu: the page reloads with that profile's storage.
    func changeLittleArcProfile(_ id: LittleArcWindow.ID, to profileID: Profile.ID) {
        guard let record = store.littleArcWindow(withID: id), store.setLittleArcProfile(id, to: profileID) else { return }
        let current = engineHost.existingLittleArcEngine(id, profileID: record.profileID)?.currentURL
        engineHost.removeLittleArc(id, profileID: record.profileID)
        if let current, current.absoluteString != "about:blank" {
            store.updateLittleArcWindow(id: id, title: nil, url: current)
        }
        loadLittleArcIfNeeded(id)
    }

    /// The opt-in system-wide ⌥⌘N.
    var isLittleArcHotkeyEnabled: Bool {
        get { littleArcHotkeyPreference.isEnabled }
        set {
            littleArcHotkeyPreference.isEnabled = newValue
            littleArcHotkeyPreference.save(to: littleArcHotkeyDefaults)
            updateLittleArcHotkey()
        }
    }

    /// Registers or drops the global hotkey to match the preference. Returns
    /// false when it is on but the system refused the combination.
    @discardableResult
    func updateLittleArcHotkey() -> Bool {
        guard littleArcHotkeyPreference.isEnabled else {
            littleArcHotkey = nil
            return true
        }
        guard littleArcHotkey == nil else { return true }
        littleArcHotkey = GlobalHotkey(keyCode: LittleArcHotkeyPreference.keyCode, modifiers: [.command, .option]) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.openBlankLittleArc()
        }
        return littleArcHotkey != nil
    }

    /// The keys held at the last mouse-down (the app-wide monitor records
    /// them): Chromium's new-tab event for that click arrives later, when
    /// the keys may already be up.
    func noteMouseDown(modifiers: NSEvent.ModifierFlags, at date: Date = Date()) {
        lastMouseDown = (modifiers.intersection(.deviceIndependentFlagsMask), date)
    }

    /// True once for a Chromium-created tab that a ⌥⌘-click made in the last two seconds.
    func takeLittleArcClick(now: Date = Date()) -> Bool {
        guard littleArcOnModifiedClick, let click = lastMouseDown, now.timeIntervalSince(click.at) < 2 else { return false }
        let flags = click.modifiers
        guard LittleArcChrome.clickOpensLittleArc(
            command: flags.contains(.command), option: flags.contains(.option),
            shift: flags.contains(.shift), control: flags.contains(.control)
        ) else { return false }
        lastMouseDown = nil
        return true
    }

    /// ⌥⌘-click in a sidebar tab's page: Little Arc in the source page's profile.
    /// Off in Settings › Links: the click follows the link as usual.
    func configureLittleArcClicks(on engine: any WebEngine, profileID: Profile.ID) {
        guard littleArcOnModifiedClick else {
            (engine as? LittleArcLinkOpening)?.littleArcLinkHandler = nil
            return
        }
        (engine as? LittleArcLinkOpening)?.littleArcLinkHandler = { [weak self] url in
            self?.openLittleArc(url: url, profileID: profileID)
        }
    }

    /// At launch: the saved hotkey preference, registered when it is on.
    func startLittleArcHotkey() {
        guard !littleArcHotkeyStarted else { return }
        littleArcHotkeyStarted = true
        littleArcHotkeyPreference = .load(from: littleArcHotkeyDefaults)
        updateLittleArcHotkey()
    }
}

extension BrowserViewModel {
    /// The address a Little Darni window shows, as its profile menu and split
    /// button take it: its engine's, or its record's until the engine has one.
    func littleArcAddress(_ id: LittleArcWindow.ID) -> URL? {
        guard let record = store.littleArcWindow(withID: id) else { return nil }
        if let current = engineHost.existingLittleArcEngine(id, profileID: record.profileID)?.currentURL,
           current.absoluteString != "about:blank" {
            return current
        }
        return record.url
    }

    /// The main button and ⌘O: Open in the target space, which is the last
    /// focused browser window's, whatever its profile (`littleArcTargetSpace`).
    /// It goes the way a row of the picker goes, through the same `choice`:
    /// the page moves when the space is of the window's own session, and
    /// another session asks first (OI-01) and takes only a web address
    /// (OI-02). The target is read here, when the button is pressed, never
    /// from the label as it was drawn.
    @discardableResult
    func openLittleArcWindowInTarget(_ id: LittleArcWindow.ID) -> LittleArcOpenInMenu.Choice? {
        guard let target = store.littleArcTargetSpace(for: id) else { return nil }
        return openLittleArcWindow(id, in: target.id)
    }

    /// A space chosen in Open in's ⌄ picker. What the choice does is asked of
    /// the store here, when it is made, and never taken from the picker as it
    /// was drawn. A space of the window's own session takes the page, unasked.
    /// Any other space is another session (S-01): a web
    /// address waits for the person's answer (`pendingLittleArcOpenIn`, OI-01),
    /// with the address taken now (OI-03), and any other address stays where it
    /// is, with a toast on the window (OI-02). Nil, and nothing happens, when
    /// the window or the space is gone, and while this window's question is
    /// up: a second Open in (the main button, ⌘O from the menu bar or a row)
    /// never replaces the address or the space the person is being asked
    /// about (LP-01).
    @discardableResult
    func openLittleArcWindow(_ id: LittleArcWindow.ID, in spaceID: Space.ID) -> LittleArcOpenInMenu.Choice? {
        guard pendingLittleArcOpenIn?.windowID != id,
              let url = littleArcAddress(id),
              let choice = LittleArcOpenInMenu.choice(store: store, windowID: id, spaceID: spaceID, url: url) else { return nil }
        switch choice {
        case .move: promoteLittleArcWindow(id, into: spaceID)
        case .ask(let question): pendingLittleArcOpenIn = question
        case .refuse: showLittleArcToast(LittleArcOpenInMenu.webOnlyMessage, in: id)
        }
        return choice
    }

    /// The question's words, in Move to Profile's style (`profileMoveMessage`).
    func littleArcOpenInMessage(_ question: LittleArcOpenInMenu.Question) -> (title: String, message: String, action: String) {
        let target = store.space(withID: question.spaceID)
        let name = "“\(target?.name ?? "Space")”"
        // Whose space it is: a container's is named as the menu marks it.
        let owner = target.map { store.isContainer($0.profileID) ? "Container" : sessionName(of: $0.profileID) }
        let source = store.littleArcWindow(withID: question.windowID).map { sessionName(of: $0.profileID) } ?? "this profile"
        return ("Open in \(name)?",
                "The page at \(question.host) will open as a new tab in \(name)\(owner.map { " (\($0))" } ?? ""), without this window's sign-ins. "
                    + "Cookies, sign-ins and site data stay in \(source), so you may need to sign in again. "
                    + "This window closes, and its back and forward history is lost.",
                "Open")
    }

    /// Yes to the question of the window `id`: the address it named opens in
    /// the space it named. Another window's question is not this one's to
    /// answer, as with Cancel (LP-01): it stays, and nothing opens. False,
    /// and the window stays, when nothing opened: no question of this window,
    /// or the window or the space went, or the space joined the window's
    /// session, while it was up.
    @discardableResult
    func confirmLittleArcOpenIn(for id: LittleArcWindow.ID) -> Bool {
        guard let question = pendingLittleArcOpenIn, question.windowID == id else { return false }
        pendingLittleArcOpenIn = nil
        return reopenLittleArcWindow(question)
    }

    /// Cancel: nothing opens and the window stays as it is.
    func cancelLittleArcOpenIn(for id: LittleArcWindow.ID? = nil) {
        guard id == nil || pendingLittleArcOpenIn?.windowID == id else { return }
        pendingLittleArcOpenIn = nil
    }

    /// Open in ▸ a space of another profile or container, once confirmed. The
    /// address the person was asked about opens as a new tab in that space,
    /// loaded by that space's own engine, and the last focused browser window
    /// shows the space. The window's engine is dropped, never handed over, so
    /// its page, cookies and sign-ins stay in the session it was opened in.
    private func reopenLittleArcWindow(_ question: LittleArcOpenInMenu.Question) -> Bool {
        let id = question.windowID
        guard let record = store.littleArcWindow(withID: id) else { return false }
        // The last focused browser window: Little Arc never becomes it.
        let target = store.keyWindowID
        guard store.reopenLittleArcAsTab(id: id, in: question.spaceID, url: question.url) != nil else { return false }
        engineHost.removeLittleArc(id, profileID: record.profileID)
        if focusedLittleArcID == id { focusedLittleArcID = nil }
        if keyLittleArcID == id { keyLittleArcID = nil }
        loadSelectedIfNeeded()
        if let target { windowPresenter?.focusBrowserWindow(target) }
        return true
    }

    /// A toast on one Little Darni window: the shell's toast, drawn there and
    /// not on the browser window behind it.
    func showLittleArcToast(_ message: String, systemImage: String = "", in id: LittleArcWindow.ID,
                            duration: TimeInterval = ShellToast.defaultDuration) {
        let toast = ShellToast(message: message, systemImage: systemImage, placement: .belowToolbar)
        withAnimation(ShellToast.inAnimation) { littleArcToast = LittleArcToast(windowID: id, toast: toast) }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.littleArcToast?.toast.id == toast.id else { return }
            withAnimation(ShellToast.outAnimation) { self.littleArcToast = nil }
        }
    }

    func canSplitLittleArcWindow(_ id: LittleArcWindow.ID) -> Bool {
        store.keyWindowID != nil && store.canSplitLittleArcToCurrentTab(id: id)
    }

    /// Open the live page beside the last focused browser window's tab.
    /// Like Open in, this closes the Little Arc only after the split exists.
    @discardableResult
    func splitLittleArcWindow(_ id: LittleArcWindow.ID) -> Bool {
        guard let target = store.keyWindowID, let record = store.littleArcWindow(withID: id) else { return false }
        if let tab = store.selectedTab, store.splitContaining(tabID: tab.id)?.split.isFull == true {
            showSplitFullToast()
            return false
        }
        guard canSplitLittleArcWindow(id) else { return false }
        if let engine = engineHost.existingLittleArcEngine(id, profileID: record.profileID) {
            store.updateLittleArcWindow(id: id, title: engine.pageTitle.flatMap { $0.isEmpty ? nil : $0 }, url: engine.currentURL)
        }
        guard store.splitLittleArcToCurrentTab(id: id) != nil else { return false }
        engineHost.removeLittleArc(id, profileID: record.profileID)
        if focusedLittleArcID == id { focusedLittleArcID = nil }
        if keyLittleArcID == id { keyLittleArcID = nil }
        closeLibrary(in: target)
        loadSelectedIfNeeded()
        windowPresenter?.focusBrowserWindow(target)
        windowPresenter?.dismissLittleArcWindow(id)
        return true
    }
}
