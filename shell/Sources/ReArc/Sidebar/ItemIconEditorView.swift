import SwiftUI
import SidebarModel

/// Arc's Emoji / Icon picker, anchored below the item it changes (beside it
/// near the window's edge, `ItemIconPopover`). A pick applies at once;
/// dismissing the popover leaves the item alone.
struct ItemIconEditorView: View {
    let model: BrowserViewModel
    let itemID: UUID

    var body: some View {
        let current = model.store.customIcon(for: itemID)
        VStack(spacing: 10) {
            IconGridPicker(symbols: Space.iconChoices, startsOnEmoji: current?.isEmoji ?? true,
                           isSelected: { $0 == current }) { apply($0) }
            HStack {
                Button { apply(nil) } label: { Image(systemName: "trash") }
                    .help("Remove Icon").accessibilityLabel("Remove Icon")
                Spacer()
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .frame(width: 306)
        .onExitCommand { model.itemIconEditorID = nil }
    }

    private func apply(_ icon: SidebarItemIcon?) {
        model.store.setCustomIcon(icon, for: itemID)
        model.itemIconEditorID = nil
    }
}

/// The picker under its item, or beside it when under would leave the
/// window: a row near the window's left edge pushed the centred popover about
/// 50 pt past it (QA 2026-11-08 #21). The item's frame is read only while
/// the picker is asked for, and the popover waits for it.
struct ItemIconPopover: ViewModifier {
    let model: BrowserViewModel
    let itemID: UUID
    @State private var anchor: NSView?

    /// The popover's window across, arrow and border included (306 pt of
    /// content; measured), and the room it keeps from the window's edges.
    static let width: CGFloat = 332
    static let margin: CGFloat = 8

    /// `item` in window points, x from the window's left. Under the item
    /// (`.bottom`) when the centred popover fits across the window; otherwise
    /// right of it (`.trailing`), or left of it (`.leading`), where it fits.
    static func arrowEdge(item: CGRect, windowWidth: CGFloat) -> Edge {
        let half = width / 2
        if item.midX - half >= margin, item.midX + half <= windowWidth - margin { return .bottom }
        if item.maxX + width <= windowWidth - margin { return .trailing }
        if item.minX - width >= margin { return .leading }
        return .bottom
    }

    func body(content: Content) -> some View {
        let requested = model.itemIconEditorID == itemID
        content
            .background { if requested { AnchorReader { anchor = $0 } } }
            .popover(isPresented: Binding(
                get: { requested && anchor != nil },
                set: { if !$0, model.itemIconEditorID == itemID { model.itemIconEditorID = nil } }
            ), arrowEdge: edge) {
                ItemIconEditorView(model: model, itemID: itemID)
            }
            .onChange(of: requested) { _, now in if !now { anchor = nil } }
    }

    private var edge: Edge {
        guard let anchor, let window = anchor.window else { return .bottom }
        return Self.arrowEdge(item: anchor.convert(anchor.bounds, to: nil), windowWidth: window.frame.width)
    }
}

struct ItemIconMenu: View {
    let model: BrowserViewModel
    let itemID: UUID

    var body: some View {
        Button("Change Icon…") { model.itemIconEditorID = itemID }
        Button("Reset Icon") { model.store.setCustomIcon(nil, for: itemID) }
            .disabled(model.store.customIcon(for: itemID) == nil)
    }
}
