import Foundation

/// The Dock menu (P3.22): each open Little Arc by its title, then the new
/// window commands. The shell turns the entries into an NSMenu.
public enum LittleArcDockMenu {
    public enum Entry: Equatable {
        case littleArc(id: LittleArcWindow.ID, title: String)
        case separator
        case newLittleArc
        case newWindow
    }

    /// `canOpenBrowserWindow` is false where the shell has no New Window (WebKit).
    public static func entries(for windows: [LittleArcWindow], canOpenBrowserWindow: Bool) -> [Entry] {
        var entries = windows.map { Entry.littleArc(id: $0.id, title: title(of: $0)) }
        if !entries.isEmpty { entries.append(.separator) }
        entries.append(.newLittleArc)
        if canOpenBrowserWindow { entries.append(.newWindow) }
        return entries
    }

    /// A blank window's stored title. Windows saved before the rename (build 1054) hold
    /// "Little ReArc", and they are restored across launches and updates.
    static let blankTitles: Set<String> = ["Little Darni", "Little ReArc", "Little Arc"]

    /// The page title, else its host, else "Little Darni" (a blank one).
    public static func title(of window: LittleArcWindow) -> String {
        let trimmed = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !blankTitles.contains(trimmed) { return trimmed }
        return window.url.host() ?? "Little Darni"
    }
}
