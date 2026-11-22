import SidebarModel
import SwiftUI

/// A Little Darni window an extension opened behind the window in front
/// (`BrowserViewModel.presentExtensionLittleArc`), until the user brings it
/// forward or closes it.
struct ExtensionWindowBehind: Equatable {
    var windowID: LittleArcWindow.ID
    var extensionID: String
}

/// What every browser window says about those windows: one notice for all of
/// them, with Show and a dismiss button. Unlike a toast it has no time limit:
/// the extension's sign-in or permission question waits in one of them.
struct ExtensionWindowNotice: Equatable {
    static let systemImage = "macwindow.on.rectangle"

    var message: String
    /// The windows still behind, oldest first.
    var windows: [LittleArcWindow.ID]

    /// `names`: what a toast calls the extension that opened each window
    /// (`BrowserViewModel.extensionToastName`), oldest first. One extension is
    /// named; several are "Extensions".
    static func message(names: [String]) -> String {
        let subject = Set(names).count == 1 ? names[0] : "Extensions"
        return names.count == 1 ? "\(subject) opened a window behind this one" : "\(subject) opened \(names.count) windows behind this one"
    }

    /// The notice drawn as the toasts are (`ShellToastView`).
    var toast: ShellToast { ShellToast(message: message, systemImage: Self.systemImage, action: .show) }
}

/// The notice of windows extensions opened behind the window in front
/// (owner's decision 2026-11-22, after security FX-02 put them there). The
/// model keeps one list for the app, so every browser window shows the same
/// notice and an answer in one answers it in all.
extension BrowserViewModel {
    /// The notice, or nil when no such window is waiting. A window that
    /// closed, whoever closed it and however (archived, opened in a space,
    /// split), is no longer counted: the list is read against the store's
    /// open windows.
    var extensionWindowNotice: ExtensionWindowNotice? {
        let waiting = extensionWindowsBehind.filter { store.littleArcWindow(withID: $0.windowID) != nil }
        guard !waiting.isEmpty else { return nil }
        return ExtensionWindowNotice(message: ExtensionWindowNotice.message(names: waiting.map { extensionToastName($0.extensionID) }),
                                     windows: waiting.map(\.windowID))
    }

    /// What browser window `window` shows of it: the same in every one, key
    /// or not, so it is seen whichever is in front. (A toast shows in the key
    /// browser window only.)
    func extensionWindowNotice(in window: SidebarWindowID?) -> ExtensionWindowNotice? {
        extensionWindowNotice
    }

    /// An extension's window opened behind the window in front. It joins the
    /// notice, and when Darni is not the active app the Dock icon bounces
    /// once, so someone working elsewhere notices. One bounce until the user
    /// is next at Darni (`noteUserInput`) or the notice is answered: a burst
    /// of windows is one bounce, not one each.
    func noteExtensionWindowBehind(_ id: LittleArcWindow.ID, by extensionID: String) {
        var waiting = extensionWindowsBehind.filter { $0.windowID != id && store.littleArcWindow(withID: $0.windowID) != nil }
        // Every earlier window closed: this is a new notice.
        if waiting.isEmpty { extensionWindowAttentionRequested = false }
        waiting.append(ExtensionWindowBehind(windowID: id, extensionID: extensionID))
        withAnimation(ShellToast.inAnimation) { extensionWindowsBehind = waiting }
        if !appIsActive(), !extensionWindowAttentionRequested {
            extensionWindowAttentionRequested = true
            requestDockAttention()
        }
    }

    /// The notice's Show button: every window it counts comes to the front,
    /// oldest first, so the most recent ends in front with the keyboard, and
    /// the notice goes from every browser window. All of them, not only the
    /// last: one press leaves no question hidden, and Show always answers
    /// the notice. The user's own click, so the focus gate is not asked.
    func showExtensionWindowsBehind() {
        let windows = extensionWindowNotice?.windows ?? []
        dismissExtensionWindowNotice()
        for id in windows { requestLittleArcWindow(id) }
    }

    /// The notice's dismiss button: it goes from every browser window. The
    /// windows stay where they are, behind.
    func dismissExtensionWindowNotice() {
        extensionWindowAttentionRequested = false
        guard !extensionWindowsBehind.isEmpty else { return }
        withAnimation(ShellToast.outAnimation) { extensionWindowsBehind = [] }
    }

    /// Little Darni window `id` took the keyboard (a click on it, the Window
    /// menu, Mission Control): it is not behind any more.
    func extensionWindowCameForward(_ id: LittleArcWindow.ID) {
        guard extensionWindowsBehind.contains(where: { $0.windowID == id }) else { return }
        withAnimation(ShellToast.outAnimation) { extensionWindowsBehind.removeAll { $0.windowID == id } }
        if extensionWindowsBehind.isEmpty { extensionWindowAttentionRequested = false }
    }
}
