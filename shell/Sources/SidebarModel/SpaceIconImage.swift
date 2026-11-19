import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A picture as a space's icon (`Space.iconPicture`): favicon-sized PNG or JPEG bytes.
/// The space's `iconName` keeps its symbol or emoji, which older builds show instead.
/// The picture syncs in its own record (`SyncRecordKind.spaceIcon`), which builds from
/// before pictures drop: they never write the space back without it (security SI-01).
///
/// The bytes are untrusted when they come from sidebar.json or another Mac: they are
/// used only when their size, their first bytes and ImageIO's reading all agree on a
/// PNG or JPEG of at most `maxSide` pixels a side, and are drawn from a fresh sRGB
/// bitmap, never from the file's own colour profile.
public enum SpaceIconImage {
    /// The longer side, in pixels. A space icon is drawn at most 16 pt, so this is
    /// sharp at 2× with room to spare.
    public static let maxSide = 64
    /// What a 64 × 64 PNG of noise needs, with headroom; anything bigger was not made here.
    public static let maxBytes = 48 * 1024

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]

    /// The picture's bytes made fit for a space icon (`ProfileAvatarImage.normalizing`,
    /// kept whole and at most `maxSide`).
    public static func picture(normalizing source: Data) throws -> Data {
        let image = try ProfileAvatarImage.normalizing(source, maxSide: maxSide, shape: .whole)
        guard drawable(image.data) != nil else { throw ProfileAvatarImageError.notAnImage }
        return image.data
    }

    /// `data` when it is small enough and starts as a PNG or a JPEG; nil otherwise.
    /// The cheap first step of `image(from:)`, not a reason to keep bytes: what is
    /// kept, from anywhere, is what `drawable` passes.
    static func validated(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maxBytes, declaredType(of: data) != nil else { return nil }
        return data
    }

    /// `data` when `image(from:)` can draw it: what is kept from the picker, from
    /// sidebar.json and from sync, so bytes that never draw are not stored (security
    /// review of 92cea6c4).
    public static func drawable(_ data: Data) -> Data? {
        image(from: data) == nil ? nil : data
    }

    /// The type the first bytes declare (security SI-03): ImageIO's own reading must agree.
    static func declaredType(of data: Data) -> UTType? {
        if data.starts(with: pngSignature) { return .png }
        if data.starts(with: jpegSignature) { return .jpeg }
        return nil
    }

    /// The picture as a plain sRGB bitmap; nil for anything but a PNG or JPEG of at most
    /// `maxSide` a side whose first bytes and ImageIO agree on its type.
    public static func image(from data: Data) -> CGImage? {
        guard validated(data) != nil, let declared = declaredType(of: data),
              let source = CGImageSourceCreateWithData(data as CFData, [
                  kCGImageSourceShouldCache: false,
                  kCGImageSourceTypeIdentifierHint: declared.identifier as CFString,
              ] as CFDictionary),
              CGImageSourceGetType(source) as String? == declared.identifier,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...maxSide).contains(width), (1...maxSide).contains(height),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              decoded.width == width, decoded.height == height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The bytes as a sync value, and back (`SyncRecordKind.spaceIcon`).
    static func syncValue(_ data: Data) -> SyncValue { .string(data.base64EncodedString()) }

    static func picture(fromSync value: SyncValue?) -> Data? {
        guard let text = value?.stringValue, text.count <= (maxBytes / 3 + 1) * 4,
              let data = Data(base64Encoded: text) else { return nil }
        return drawable(data)
    }
}
