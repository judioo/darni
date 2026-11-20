import Foundation

/// The self-test's reading of files for a text that must be in none of them
/// ("blocked list in memory only": the sites a page's requests were blocked
/// for are never written to disk).
///
/// It reads every file of the folders it is given, so those must be folders
/// the app alone writes to: the engine's profile folder and the folder of
/// the shell's own files. The step once read the parent of the shell's
/// sidebar file, and the self-test kept that file directly in the temporary
/// folder: with `TMPDIR` at `/tmp` it read 30 GB in 75 s, and files of other
/// apps with them. `sharedFolders` names such a folder, and the step fails
/// on it without reading it.
///
/// Here, outside `REARC_CHROMIUM`, so the unit tests hold it.
enum SelfTestDiskScan {
    /// A file over this size is not read.
    static let fileSizeLimit = 256 * 1024 * 1024

    /// The files under `folders` that hold `text` as plain bytes. A
    /// compressed copy would not be seen.
    static func files(containing text: String, in folders: [URL]) -> [String] {
        let needle = Data(text.utf8)
        var found: Set<String> = []
        for folder in folders {
            guard let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { continue }
            for case let file as URL in files {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true,
                      (values.fileSize ?? 0) <= fileSizeLimit else { continue }
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.range(of: needle) != nil else { continue }
                found.insert(file.path)
            }
        }
        return found.sorted()
    }

    /// Places other programs write to as well.
    static var sharedPlaces: [URL] {
        [FileManager.default.temporaryDirectory, FileManager.default.homeDirectoryForCurrentUser,
         URL(fileURLWithPath: "/tmp", isDirectory: true), URL(fileURLWithPath: "/var/tmp", isDirectory: true)]
    }

    /// Those of `folders` that are not the app's alone: a shared place
    /// itself, or a folder above one. A folder inside one is fine.
    static func sharedFolders(among folders: [URL], sharedPlaces: [URL] = SelfTestDiskScan.sharedPlaces) -> [String] {
        let places = sharedPlaces.map(canonicalPath)
        return folders.map(canonicalPath).filter { folder in
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            return places.contains { $0 == folder || $0.hasPrefix(prefix) }
        }
    }

    /// The path with its symbolic links followed (`/tmp` is `/private/tmp`),
    /// for a folder that is not there yet too. By `realpath`: Foundation's
    /// own ways (`resolvingSymlinksInPath`, `standardizedFileURL`) take
    /// `/private` off again, and `/private` would then not count as a folder
    /// above `/private/tmp`.
    static func canonicalPath(_ url: URL) -> String {
        let path = url.path
        if let real = realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != path else { return path }
        return (canonicalPath(URL(fileURLWithPath: parent, isDirectory: true)) as NSString)
            .appendingPathComponent((path as NSString).lastPathComponent)
    }
}
