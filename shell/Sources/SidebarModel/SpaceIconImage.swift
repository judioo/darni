import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture as a space's icon. It is favicon-sized, so it is kept inside the
/// space's icon name as a `data:` URL and goes wherever the name goes: sidebar.json,
/// the synced space record, a new space's draft. Nothing else in the model changes.
///
/// The name is untrusted (a hand-edited file, another Mac): it is used only when its
/// prefix, length and bytes check out, and only ImageIO reads the bytes, as PNG or JPEG.
public enum SpaceIconImage {
    /// The longer side, in pixels. A space icon is drawn at most 16 pt, so this is
    /// sharp at 2× with room to spare.
    public static let maxSide = 64
    /// What a 64 × 64 PNG of noise needs, with headroom; anything bigger was not made here.
    static let maxBytes = 48 * 1024
    static let pngPrefix = "data:image/png;base64,"
    static let jpegPrefix = "data:image/jpeg;base64,"

    /// The picture's bytes made fit for a space icon (`ProfileAvatarImage.normalizing`,
    /// kept whole and at most `maxSide`), as an icon name.
    public static func iconName(normalizing source: Data) throws -> String {
        let image = try ProfileAvatarImage.normalizing(source, maxSide: maxSide, shape: .whole)
        guard let name = iconName(for: image) else { throw ProfileAvatarImageError.notAnImage }
        return name
    }

    static func iconName(for image: ProfileAvatarImage) -> String? {
        guard image.data.count <= maxBytes else { return nil }
        return (image.format == .png ? pngPrefix : jpegPrefix) + image.data.base64EncodedString()
    }

    /// Whether `iconName` names a picture (well formed or not): such a name is never
    /// cut short, read as a symbol or drawn as text.
    public static func isImageName(_ iconName: String) -> Bool {
        iconName.hasPrefix("data:image/")
    }

    /// The picture's bytes, or nil when `iconName` is not a picture this build would make.
    public static func data(from iconName: String) -> Data? {
        let base64: Substring
        if iconName.hasPrefix(pngPrefix) {
            base64 = iconName.dropFirst(pngPrefix.count)
        } else if iconName.hasPrefix(jpegPrefix) {
            base64 = iconName.dropFirst(jpegPrefix.count)
        } else {
            return nil
        }
        guard base64.count <= (maxBytes / 3 + 1) * 4, let data = Data(base64Encoded: String(base64)), !data.isEmpty else { return nil }
        return data
    }

    /// The picture, decoded; nil for anything but a PNG or JPEG of at most `maxSide`.
    public static func image(from iconName: String) -> CGImage? {
        guard let data = data(from: iconName),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.jpeg.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maxSide).contains(width), (1...maxSide).contains(height) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
