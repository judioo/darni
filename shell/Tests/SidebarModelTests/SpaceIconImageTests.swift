import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SidebarModel

/// A picture as a space's icon (owner, 2026-11-19): made favicon-sized, kept whole,
/// and carried inside the icon name.
final class SpaceIconImageTests: XCTestCase {
    private func png(width: Int, height: Int, alpha: CGFloat = 1) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: 0.9, green: 0.2, blue: 0.1, alpha: alpha)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testABigWideImageIsScaledDownWhole() throws {
        let name = try SpaceIconImage.iconName(normalizing: png(width: 1200, height: 400, alpha: 0.5))
        XCTAssertTrue(name.hasPrefix("data:image/png;base64,"))
        let image = try XCTUnwrap(SpaceIconImage.image(from: name))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 21, "kept whole, not cropped to a square")
    }

    func testASmallImageKeepsItsSizeAndAnOpaqueOneIsAJPEG() throws {
        let name = try SpaceIconImage.iconName(normalizing: png(width: 16, height: 16))
        XCTAssertTrue(name.hasPrefix("data:image/jpeg;base64,"))
        let image = try XCTUnwrap(SpaceIconImage.image(from: name))
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 16)
    }

    func testANameNotMadeHereIsNotDrawn() {
        XCTAssertNil(SpaceIconImage.image(from: "data:image/png;base64,!!!"))
        XCTAssertNil(SpaceIconImage.image(from: "data:image/svg+xml;base64,PHN2Zz4="))
        // Well formed but bigger than an icon: not one this build made.
        XCTAssertNil(SpaceIconImage.image(from: "data:image/png;base64," + png(width: 100, height: 100).base64EncodedString()))
        XCTAssertTrue(SpaceIconImage.isImageName("data:image/png;base64,!!!"))
        XCTAssertFalse(SpaceIconImage.isImageName("🐶"))
    }

    func testTheStoreKeepsAPictureWholeAndIgnoresABrokenOne() throws {
        let store = SidebarStore(spaces: [Space(name: "Home", sortRank: "b")])
        let id = try XCTUnwrap(store.spaces.first?.id)
        let name = try SpaceIconImage.iconName(normalizing: png(width: 300, height: 300, alpha: 0.5))
        store.setSpaceIcon(id, iconName: name)
        XCTAssertEqual(store.space(withID: id)?.iconName, name)
        XCTAssertNotNil(SpaceIconImage.image(from: try XCTUnwrap(store.space(withID: id)?.iconName)))

        store.setSpaceIcon(id, iconName: "data:image/png;base64,!!!")
        XCTAssertEqual(store.space(withID: id)?.iconName, name, "a broken picture name is ignored, not cut to two characters")

        store.setSpaceIcon(id, iconName: "🐶")
        XCTAssertEqual(store.space(withID: id)?.iconName, "🐶")

        // The picture survives sidebar.json as it is.
        store.setSpaceIcon(id, iconName: name)
        let space = try XCTUnwrap(store.space(withID: id))
        let decoded = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space))
        XCTAssertEqual(decoded.iconName, name)
    }
}

final class EmojiCatalogTests: XCTestCase {
    func testSearchFindsCuratedWordsAndUnicodeNames() {
        XCTAssertEqual(EmojiCatalog.matches("  SMILE ").first, "😀")
        XCTAssertTrue(EmojiCatalog.matches("work").contains("💼"))
        let dogs = EmojiCatalog.matches("dog")
        XCTAssertTrue(dogs.contains("🐶") && dogs.contains("🐕"), "found by Unicode name too")
        XCTAssertTrue(EmojiCatalog.matches("face cat").contains("🐱"), "every word must match, in any order")
        XCTAssertTrue(EmojiCatalog.matches("zzqx").isEmpty)
    }

    func testEveryEmojiOnceAndPlenty() {
        let all = EmojiCatalog.matches("")
        XCTAssertGreaterThan(all.count, 1000)
        let bare = all.map { String(String.UnicodeScalarView($0.unicodeScalars.filter { $0.value != 0xFE0F })) }
        XCTAssertEqual(Set(bare).count, bare.count)
        XCTAssertFalse(all.contains("🇦"), "no lone regional indicator letter")
        XCTAssertFalse(all.contains("🏽"), "no lone skin tone")
    }

    func testATypedEmojiComesFirst() {
        XCTAssertEqual(EmojiCatalog.matches("👩🏽‍💻"), ["👩🏽‍💻"])
        XCTAssertEqual(EmojiCatalog.matches("🇦🇪").first, "🇦🇪")
        XCTAssertEqual(EmojiCatalog.matches("❤️"), ["❤️"])
        XCTAssertEqual(EmojiCatalog.matches("🔥"), ["🔥"])
        XCTAssertNil(EmojiCatalog.typedEmoji("a"))
        XCTAssertNil(EmojiCatalog.typedEmoji("1"))
    }
}
