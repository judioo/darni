@testable import ReArc
import SidebarModel

/// The window presenter tests give the model (`BrowserViewModel.windowPresenter`):
/// it opens nothing and records every call, so a test reads what was asked.
/// A new requirement of `BrowserWindowPresenting` is added here once.
final class RecordingWindowPresenter: BrowserWindowPresenting {
    /// A Little Darni window asked for, and whether in front and key.
    struct Shown: Equatable {
        var id: LittleArcWindow.ID
        var inFront: Bool
    }

    var shown: [Shown] = []
    /// The Little Darni windows asked for, in order.
    var littleArc: [LittleArcWindow.ID] { shown.map(\.id) }
    var dismissed: [LittleArcWindow.ID] = []
    var privateWindows: [PrivateWindowModel] = []
    /// "present" and "dismiss", one for each DevTools window call.
    var devTools: [String] = []
    var focused: [SidebarWindowID] = []
    var browserWindows = 0

    func presentLittleArcWindow(_ id: LittleArcWindow.ID, inFront: Bool) { shown.append(Shown(id: id, inFront: inFront)) }
    func dismissLittleArcWindow(_ id: LittleArcWindow.ID) { dismissed.append(id) }
    func presentPrivateWindow(_ window: PrivateWindowModel) { privateWindows.append(window) }
    func presentDevToolsWindow(for tabID: Tab.ID) { devTools.append("present") }
    func dismissDevToolsWindow(for tabID: Tab.ID) { devTools.append("dismiss") }
    func focusBrowserWindow(_ id: SidebarWindowID) { focused.append(id) }
    func presentBrowserWindow() { browserWindows += 1 }
}
