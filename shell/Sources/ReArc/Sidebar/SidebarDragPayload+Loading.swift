import SwiftUI
import UniformTypeIdentifiers
import SidebarModel

extension SidebarDragPayload {
    static let contentType = UTType(exportedAs: SidebarDragType.identifier)

    static func hasItem(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [contentType])
    }

    /// A sidebar drag the model does not know (`BrowserViewModel.sidebarDrag`
    /// is how a drop target in any window learns the dragged row): its id is
    /// read from the drag. Only a drag that carries the sidebar's type is
    /// read, so arbitrary text is never taken for a row.
    ///
    /// The id is read from the text beside the type. SwiftUI hands a drop
    /// target providers that hold only the types the system knows, and the
    /// sidebar's type is not declared to it: its provider comes back with no
    /// type at all. Loading from that one failed, so the drop was accepted
    /// and then moved nothing.
    static func load(_ info: DropInfo, move: @escaping (UUID) -> Void) -> Bool {
        guard hasItem(info) else { return false }
        return load(info.itemProviders(for: [contentType]), move: move)
            || loadText(info.itemProviders(for: [.plainText]), move: move)
    }

    /// From the sidebar's own type: the provider a drag is made with.
    static func load(_ providers: [NSItemProvider], move: @escaping (UUID) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(SidebarDragType.identifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: SidebarDragType.identifier) { data, _ in
            guard let data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async { move(id) }
        }
        return true
    }

    /// From the UUID text every sidebar drag also carries. The caller has
    /// checked that the drag is a sidebar drag.
    static func loadText(_ providers: [NSItemProvider], move: @escaping (UUID) -> Void) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = object as? String, let id = UUID(uuidString: text) else { return }
            DispatchQueue.main.async { move(id) }
        }
        return true
    }
}
