import AppKit
import SidebarModel
import UniformTypeIdentifiers

/// A picture for a profile (or a space's icon) from Choose Image…, a drop or a
/// paste: read, normalised (`ProfileAvatarImage`) and stored. Only the normalised copy
/// is kept, and nothing but ImageIO sees the original bytes.
enum ProfileAvatarImageIntake {
    enum Source: Sendable {
        case file(URL)
        case data(Data)
    }

    /// Pasteboard image flavours, in the order they are tried after a file URL.
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.png, .tiff] + [UTType.jpeg, .heic].map { NSPasteboard.PasteboardType($0.identifier) }

    static func bytes(of source: Source) throws -> Data {
        switch source {
        case .file(let url): return try ProfileAvatarImage.readCandidate(at: url)
        case .data(let data): return data
        }
    }

    static func adopt(_ source: Source, into images: ProfileAvatarImageStore) throws -> ProfileAvatarImageName {
        try images.save(ProfileAvatarImage.normalizing(bytes(of: source)))
    }

    /// Decoding a large photo takes a moment: done off the main thread.
    static func adopt(_ source: Source, into images: ProfileAvatarImageStore,
                      completion: @escaping @MainActor (Result<ProfileAvatarImageName, ProfileAvatarImageError>) -> Void) {
        offMain({ try adopt(source, into: images) }, completion: completion)
    }

    /// The same picture made a space icon (`SpaceIconImage`): kept whole, at most
    /// 64 pixels on its longer side. It goes in the space (and its sync record), not on disk.
    static func spacePicture(from source: Source, completion: @escaping @MainActor (Result<Data, ProfileAvatarImageError>) -> Void) {
        offMain({ try SpaceIconImage.picture(normalizing: bytes(of: source)) }, completion: completion)
    }

    private static func offMain<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value,
                                                 completion: @escaping @MainActor (Result<Value, ProfileAvatarImageError>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try work() }.mapError { $0 as? ProfileAvatarImageError ?? .unreadable }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    /// Choose Image…: one image file from an open panel; nil when it was cancelled.
    @MainActor static func chooseFile(message: String) -> Source? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // An alias is read as the alias file, never followed to what it names.
        panel.resolvesAliases = false
        panel.message = message
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return .file(url)
    }

    /// What Paste Image says when the pasteboard holds no image.
    static let nothingToPaste = "There's no image to paste. Copy an image or an image file first."

    /// A copied file first (Finder), then image data (a screenshot, a browser's Copy Image).
    static func source(from pasteboard: NSPasteboard) -> Source? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first {
            return .file(url)
        }
        for type in pasteboardTypes {
            if let data = pasteboard.data(forType: type) { return .data(data) }
        }
        return nil
    }

    static let dropTypes: [UTType] = [.fileURL, .image]

    /// The first dropped or pasted item; `completion` runs on the main thread.
    static func loadSource(from providers: [NSItemProvider], completion: @escaping @MainActor (Source?) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        @Sendable func finish(_ source: Source?) { DispatchQueue.main.async { MainActor.assumeIsolated { completion(source) } } }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
                finish(data.flatMap { URL(dataRepresentation: $0, relativeTo: nil) }.map(Source.file))
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in finish(data.map(Source.data)) }
            return true
        }
        return false
    }
}
