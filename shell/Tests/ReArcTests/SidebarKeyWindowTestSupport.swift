import SidebarModel
@testable import ReArc

/// The key window's sidebar, for tests: what ⌘S would act on, read and set in
/// one word. The app has no such form. There a view asks about its own window
/// (`isSidebarVisible(in:)`) and a command passes `store.keyWindowID`, so
/// that no view can draw the key window's sidebar by mistake, which was the
/// bug (`BrowserViewModel+SidebarVisibility`).
extension BrowserViewModel {
    var isSidebarVisible: Bool {
        get { isSidebarVisible(in: store.keyWindowID) }
        set { sidebarVisibility.update(in: store.keyWindowID) { $0.isVisible = newValue } }
    }

    var isSidebarLaidOut: Bool {
        get { isSidebarLaidOut(in: store.keyWindowID) }
        set { sidebarVisibility.update(in: store.keyWindowID) { $0.isLaidOut = newValue } }
    }

    var sidebarReveal: Double {
        get { sidebarReveal(in: store.keyWindowID) }
        set { sidebarVisibility.update(in: store.keyWindowID) { $0.reveal = newValue } }
    }

    var isSidebarSliding: Bool {
        isSidebarSliding(in: store.keyWindowID)
    }

    var isSidebarPeeking: Bool {
        get { isSidebarPeeking(in: store.keyWindowID) }
        set { sidebarVisibility.update(in: store.keyWindowID) { $0.isPeeking = newValue } }
    }
}
