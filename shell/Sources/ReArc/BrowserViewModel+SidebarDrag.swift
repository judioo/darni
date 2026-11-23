import AppKit
import SwiftUI
import SidebarModel

/// The sidebar drag, shared by every window (`SidebarDragSession`). The row
/// under the pointer belongs to one drag wherever the pointer goes, so the
/// window it began in and the window it is dropped in read the same value.
extension BrowserViewModel {

    /// The dragged row as `window`'s sidebar sees it: nil until the drag
    /// began in it or has been over it.
    func sidebarDragItem(in window: SidebarWindowID?) -> UUID? {
        guard let drag = sidebarDrag, drag.isShown(in: window) else { return nil }
        return drag.itemID
    }

    /// What `window`'s views hold as "the dragged item". A row that begins a
    /// drag writes its id; a drop, or the end of the drag, writes nil.
    func sidebarDragBinding(in window: SidebarWindowID?) -> Binding<UUID?> {
        Binding(
            get: { [weak self] in self?.sidebarDragItem(in: window) },
            set: { [weak self] id in
                if let id {
                    self?.beginSidebarDrag(id, in: window)
                } else {
                    self?.endSidebarDrag()
                }
            }
        )
    }

    func beginSidebarDrag(_ id: UUID, in window: SidebarWindowID?) {
        let drag = SidebarDragSession(itemID: id, sourceWindow: window)
        // A row writes its id again while its own drag goes on: the windows reached stay.
        if sidebarDrag?.itemID != id || sidebarDrag?.sourceWindow != window { sidebarDrag = drag }
        watchSidebarDragPointer()
    }

    /// The drag is over, wherever it ended: a drop in any window, or let go
    /// over nothing.
    func endSidebarDrag() {
        sidebarDragPointerWatch?.invalidate()
        sidebarDragPointerWatch = nil
        if sidebarDrag != nil { sidebarDrag = nil }
        sidebarDragEnded()
    }

    /// The drag is over `window`: its sidebar opens for the drop, as the
    /// sidebar the drag began in did at the start. Its drop targets say so
    /// when they are offered the drag, and the pointer watch says so for the
    /// places that are not drop targets yet (a space with no rows).
    func sidebarDragReached(_ window: SidebarWindowID?) {
        guard var drag = sidebarDrag, drag.reach(window) else { return }
        sidebarDrag = drag
    }

    /// Whether the drag began in `window`. Only there does the page offer
    /// its split drop zones: a drop on another window's page does nothing,
    /// as before.
    func sidebarDragBegan(in window: SidebarWindowID?) -> Bool {
        sidebarDrag?.began(in: window) ?? true
    }

    /// The row a drop target is offered. `local` is its window's own view of
    /// the drag, as before. Without it, a drag that carries the sidebar's
    /// type is the one under way, begun in another window: its row comes
    /// from here, since a drop target cannot read it back from the drag. A
    /// drag without the type (a link from a page) is never taken for it.
    func sidebarDragItem(offered local: UUID?, carriesSidebarItem: Bool) -> UUID? {
        local ?? (carriesSidebarItem ? sidebarDrag?.itemID : nil)
    }

    /// A favorites strip takes plain tabs, and only its own profile's: a
    /// tab of another profile would change session with no question asked
    /// (`asksBeforeProfileDrop` refuses the move, so the strip refuses the drop).
    func canDropOnFavorites(_ id: UUID, of profileID: Profile.ID) -> Bool {
        guard case .tab = store.entry(withID: id) else { return false }
        return !store.crossesProfile([id], to: .favorites(profileID))
    }

    // MARK: - The pointer over another window

    /// AppKit tells a view of a drag only when the view is registered for
    /// it, and a sidebar with its drop areas closed has places that are not.
    /// So while a drag is under way the pointer's window is read a few times
    /// a second. In the common modes: a drag runs the loop in event tracking.
    private func watchSidebarDragPointer() {
        guard sidebarDragPointerWatch == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readSidebarDragPointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sidebarDragPointerWatch = timer
    }

    private func readSidebarDragPointer() {
        guard sidebarDrag != nil else { return endSidebarDrag() }
        // The button is up: the drag is over, or its drop is on the way. Nothing
        // more opens, and whatever ends the drag clears it (a drop, the next move).
        guard NSEvent.pressedMouseButtons & 1 != 0, let app = NSApp else {
            sidebarDragPointerWatch?.invalidate()
            sidebarDragPointerWatch = nil
            return
        }
        let pointer = NSEvent.mouseLocation
        let window = app.orderedWindows.first { $0.isVisible && $0.frame.contains(pointer) }
        if let id = sidebarWindowID(of: window) { sidebarDragReached(id) }
    }
}
