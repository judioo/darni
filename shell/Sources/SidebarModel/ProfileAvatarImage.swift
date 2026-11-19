import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A profile picture's file name: the SHA-256 of its normalised bytes and
/// its format. Checked when decoded, so a synced or hand-edited name never
/// reaches outside `ProfileAvatarImageStore.directory`.
public struct ProfileAvatarImageName: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, ProfileAvatarImage.Format(rawValue: String(parts[1])) != nil,
              parts[0].count == 64, parts[0].allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let raw = try c.decode(String.self)
        guard let name = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Not a profile avatar image name")
        }
        self = name
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public var description: String { rawValue }
}

public enum ProfileAvatarImageError: Error, Equatable, Sendable {
    case unreadable
    case tooLarge
    case notAnImage
    case animated
    case badDimensions

    public var message: String {
        switch self {
        case .unreadable: return "ReArc couldn't read that file."
        case .tooLarge: return "That file is over 20 MB. Choose a smaller image."
        case .notAnImage: return "That isn't an image ReArc can use. Choose a JPEG, PNG, HEIC, GIF, TIFF or WebP file."
        case .animated: return "That image is animated. Choose a still image."
        case .badDimensions: return "That image's size can't be used. Choose one up to 20,000 pixels on each side."
        }
    }
}

/// A picture made fit for an avatar. The person's file is untrusted: only
/// ImageIO reads it, and what is kept is a fresh encoding of its pixels,
/// cropped to a centred square of at most 256 × 256, with no metadata.
public struct ProfileAvatarImage: Equatable, Sendable {
    public enum Format: String, Sendable {
        case jpeg = "jpg"
        case png

        var typeIdentifier: CFString { (self == .jpeg ? UTType.jpeg : UTType.png).identifier as CFString }
    }

    /// What is kept of the picture: a centred square (an avatar), or all of
    /// it, scaled to fit (a space icon, where a wide logo must not lose its ends).
    public enum Shape: Sendable {
        case centredSquare
        case whole
    }

    public let data: Data
    public let format: Format
    /// The longer side in pixels.
    public let side: Int
    public let name: ProfileAvatarImageName

    public static let maxFileBytes = 20 * 1024 * 1024
    public static let maxSide = 256
    public static let maxSourceSide = 20_000
    public static let maxSourcePixels = 64_000_000

    /// Still-image formats only: no PDF or SVG (they can name other files),
    /// no camera raw decoders.
    static let acceptedTypes: Set<String> = [
        UTType.jpeg, .png, .heic, .heif, .gif, .tiff, .webP, .bmp,
    ].reduce(into: Set(["public.avif"])) { $0.insert($1.identifier) }
    static let animatableTypes: Set<String> = [UTType.gif.identifier, UTType.png.identifier, UTType.webP.identifier]

    /// `maxSide` caps the longer side of what is kept; a smaller picture keeps its size.
    public static func normalizing(_ source: Data, maxSide: Int = maxSide, shape: Shape = .centredSquare) throws -> ProfileAvatarImage {
        guard source.count <= maxFileBytes else { throw ProfileAvatarImageError.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let image = CGImageSourceCreateWithData(source as CFData, options),
              CGImageSourceGetStatus(image) == .statusComplete,
              let type = CGImageSourceGetType(image) as String?, acceptedTypes.contains(type) else {
            throw ProfileAvatarImageError.notAnImage
        }
        let count = CGImageSourceGetCount(image)
        guard count > 0 else { throw ProfileAvatarImageError.notAnImage }
        if count > 1, animatableTypes.contains(type) { throw ProfileAvatarImageError.animated }
        let index = CGImageSourceGetPrimaryImageIndex(image)
        // The size from the header, before anything is decoded.
        guard let properties = CGImageSourceCopyPropertiesAtIndex(image, index, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw ProfileAvatarImageError.notAnImage
        }
        guard width > 0, height > 0, width <= maxSourceSide, height <= maxSourceSide,
              width * height <= maxSourcePixels else { throw ProfileAvatarImageError.badDimensions }

        // Decode at the size the crop needs: its short side becomes the square.
        // Kept whole, the long side is what is capped.
        let short = min(width, height), long = max(width, height)
        let decodeSide: Int
        switch shape {
        case .centredSquare:
            decodeSide = short <= maxSide ? long : min(long, Int((Double(long) * Double(maxSide) / Double(short)).rounded(.up)))
        case .whole:
            decodeSide = min(long, maxSide)
        }
        let decode = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: decodeSide,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(image, index, decode) else {
            throw ProfileAvatarImageError.notAnImage
        }
        let cropped: CGImage
        let outWidth: Int, outHeight: Int
        switch shape {
        case .centredSquare:
            let square = min(decoded.width, decoded.height)
            let crop = CGRect(x: (decoded.width - square) / 2, y: (decoded.height - square) / 2, width: square, height: square)
            guard square > 0, let image = decoded.cropping(to: crop) else { throw ProfileAvatarImageError.notAnImage }
            cropped = image
            outWidth = min(square, maxSide)
            outHeight = outWidth
        case .whole:
            // ImageIO's thumbnail already fits `maxSide`; this only guards a decoder that ignored it.
            let scale = min(1, Double(maxSide) / Double(max(decoded.width, decoded.height)))
            cropped = decoded
            outWidth = max(1, Int((Double(decoded.width) * scale).rounded()))
            outHeight = max(1, Int((Double(decoded.height) * scale).rounded()))
        }

        // Redrawn into a plain sRGB bitmap: nothing of the file but its pixels survives.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8, bytesPerRow: outWidth * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ProfileAvatarImageError.notAnImage
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
        let format: Format = Self.hasTransparency(context, pixels: outWidth * outHeight, alpha: cropped.alphaInfo) ? .png : .jpeg
        guard let pixels = context.makeImage() else { throw ProfileAvatarImageError.notAnImage }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, format.typeIdentifier, 1, nil) else {
            throw ProfileAvatarImageError.notAnImage
        }
        let encoding = format == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil
        CGImageDestinationAddImage(destination, pixels, encoding)
        guard CGImageDestinationFinalize(destination) else { throw ProfileAvatarImageError.notAnImage }
        let data = output as Data
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let name = ProfileAvatarImageName(rawValue: "\(hash).\(format.rawValue)") else { throw ProfileAvatarImageError.notAnImage }
        return ProfileAvatarImage(data: data, format: format, side: max(outWidth, outHeight), name: name)
    }

    private static func hasTransparency(_ context: CGContext, pixels: Int, alpha: CGImageAlphaInfo) -> Bool {
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(alpha), let base = context.data else { return false }
        let bytes = base.bindMemory(to: UInt8.self, capacity: pixels * 4)
        return stride(from: 3, to: pixels * 4, by: 4).contains { bytes[$0] < 255 }
    }

    /// The bytes of a chosen or dropped file: a regular file only, never
    /// through a symbolic link, and no more than `maxFileBytes`.
    public static func readCandidate(at url: URL) throws -> Data {
        guard url.isFileURL else { throw ProfileAvatarImageError.unreadable }
        // O_NONBLOCK: a FIFO would otherwise hang the open until a writer comes.
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw ProfileAvatarImageError.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ProfileAvatarImageError.unreadable }
        guard info.st_size <= maxFileBytes else { throw ProfileAvatarImageError.tooLarge }
        guard let data = try handle.read(upToCount: maxFileBytes + 1) else { throw ProfileAvatarImageError.notAnImage }
        guard data.count <= maxFileBytes else { throw ProfileAvatarImageError.tooLarge }
        return data
    }
}

/// Profile pictures in `ProfileAvatars/` beside sidebar.json, owner-only,
/// each named by its content hash; the avatar holds only the name, so
/// sidebar.json and the synced profile record stay small. The pictures
/// themselves stay on this Mac.
public struct ProfileAvatarImageStore: Sendable {
    public static let folderName = "ProfileAvatars"
    public static let shared = ProfileAvatarImageStore(besideSidebarFile: SidebarFilePersistence.defaultFileURL)
    /// Our own files are at most 256 × 256; anything bigger was not written by us.
    static let maxStoredBytes = 2 * 1024 * 1024

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public init(besideSidebarFile file: URL) {
        self.init(directory: file.deletingLastPathComponent().appendingPathComponent(Self.folderName, isDirectory: true))
    }

    func url(for name: ProfileAvatarImageName) -> URL {
        directory.appendingPathComponent(name.rawValue, isDirectory: false)
    }

    @discardableResult
    public func save(_ image: ProfileAvatarImage) throws -> ProfileAvatarImageName {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let file = url(for: image.name)
        if !contains(image.name) {
            try image.data.write(to: file, options: [.atomic])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return image.name
    }

    public func contains(_ name: ProfileAvatarImageName) -> Bool {
        let values = try? url(for: name).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    /// The stored picture, or nil when this Mac does not have it.
    public func image(named name: ProfileAvatarImageName) -> CGImage? {
        let path = url(for: name).path
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= Self.maxStoredBytes,
              let data = try? handle.read(upToCount: Self.maxStoredBytes), !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier].contains(type) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    public func remove(_ name: ProfileAvatarImageName) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// Deletes our pictures no profile names; other files are left alone.
    @discardableResult
    public func removeUnused(keeping used: Set<ProfileAvatarImageName>) -> [ProfileAvatarImageName] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let unused = entries.compactMap(ProfileAvatarImageName.init(rawValue:)).filter { !used.contains($0) }
        unused.forEach(remove)
        return unused.sorted { $0.rawValue < $1.rawValue }
    }
}

extension SidebarStore {
    /// The pictures the profiles name, to keep when cleaning up.
    public var profileAvatarImageNames: Set<ProfileAvatarImageName> {
        Set(profiles.compactMap(\.avatar.image))
    }
}
