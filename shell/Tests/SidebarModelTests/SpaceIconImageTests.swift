import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SidebarModel

/// A picture as a space's icon (owner, 2026-11-19): made favicon-sized, kept whole,
/// beside the space's glyph, and synced in a record of its own.
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
        let picture = try SpaceIconImage.picture(normalizing: png(width: 1200, height: 400, alpha: 0.5))
        XCTAssertTrue(picture.starts(with: SpaceIconImage.pngSignature))
        let image = try XCTUnwrap(SpaceIconImage.image(from: picture))
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 21, "kept whole, not cropped to a square")
    }

    func testASmallImageKeepsItsSizeAndAnOpaqueOneIsAJPEG() throws {
        let picture = try SpaceIconImage.picture(normalizing: png(width: 16, height: 16))
        XCTAssertTrue(picture.starts(with: SpaceIconImage.jpegSignature))
        let image = try XCTUnwrap(SpaceIconImage.image(from: picture))
        XCTAssertEqual(image.width, 16)
        XCTAssertEqual(image.height, 16)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB, "drawn from a fresh sRGB bitmap")
    }

    func testBytesNotMadeHereAreNotDrawn() throws {
        XCTAssertNil(SpaceIconImage.image(from: Data("not an image".utf8)))
        XCTAssertNil(SpaceIconImage.image(from: png(width: 100, height: 100)), "bigger than an icon: not made here")
        // A JPEG's bytes declared as a PNG (and the other way) are refused before decoding.
        let jpeg = try SpaceIconImage.picture(normalizing: png(width: 16, height: 16))
        XCTAssertNil(SpaceIconImage.image(from: Data(SpaceIconImage.pngSignature) + jpeg.dropFirst(3)))
        XCTAssertNil(SpaceIconImage.validated(Data(count: SpaceIconImage.maxBytes + 1)))
        XCTAssertNil(SpaceIconImage.picture(fromSync: .string("!!!")))
        XCTAssertNil(SpaceIconImage.picture(fromSync: .string(Data("GIF89a".utf8).base64EncodedString())))
    }

    func testTheStoreKeepsThePictureBesideTheGlyph() throws {
        let store = SidebarStore(spaces: [Space(name: "Home", iconName: "🐶", sortRank: "b")])
        let id = try XCTUnwrap(store.spaces.first?.id)
        let picture = try SpaceIconImage.picture(normalizing: png(width: 300, height: 300, alpha: 0.5))
        store.setSpacePicture(id, picture: picture)
        XCTAssertEqual(store.space(withID: id)?.iconPicture, picture)
        XCTAssertEqual(store.space(withID: id)?.iconName, "🐶", "the glyph stays for older builds")
        XCTAssertTrue(try XCTUnwrap(store.space(withID: id)).hasIcon)

        store.setSpacePicture(id, picture: png(width: 100, height: 100))
        XCTAssertEqual(store.space(withID: id)?.iconPicture, picture, "a picture that cannot be drawn is ignored")

        // The picture survives sidebar.json as it is.
        let space = try XCTUnwrap(store.space(withID: id))
        let decoded = try JSONDecoder().decode(Space.self, from: JSONEncoder().encode(space))
        XCTAssertEqual(decoded.iconPicture, picture)

        store.setSpaceIcon(id, iconName: "🐶")
        XCTAssertNil(store.space(withID: id)?.iconPicture, "choosing a glyph, even the same one, replaces the picture")
        store.setSpacePicture(id, picture: picture)
        store.setSpacePicture(id, picture: nil)
        XCTAssertNil(store.space(withID: id)?.iconPicture)
        XCTAssertEqual(store.space(withID: id)?.iconName, "🐶")
    }

    func testADraftCarriesItsPicture() throws {
        let store = SidebarStore(spaces: [Space(name: "Home", sortRank: "b")])
        var draft = SpaceDraft.blank(in: store)
        draft.name = "Logo"
        draft.iconPicture = try SpaceIconImage.picture(normalizing: png(width: 40, height: 40, alpha: 0.5))
        let space = try XCTUnwrap(store.createSpace(from: draft))
        XCTAssertEqual(space.iconPicture, draft.iconPicture)
    }

    /// Security SI-01: the picture syncs in a record of its own, which builds from before
    /// pictures drop. The space record keeps its shape, so such a build never writes the
    /// space back without the picture.
    func testThePictureSyncsInItsOwnRecord() throws {
        let store = SidebarStore(spaces: [Space(name: "Home", iconName: "star.fill", sortRank: "b"), Space(name: "Work", sortRank: "c")])
        let home = store.spaces[0].id, work = store.spaces[1].id
        let picture = try SpaceIconImage.picture(normalizing: png(width: 64, height: 64, alpha: 0.5))
        store.setSpacePicture(home, picture: picture)

        let records = SidebarSyncProjection.extract(store.makeSnapshot())
        let space = try XCTUnwrap(records[SyncRecordKind.space.recordName(for: home)])
        XCTAssertNil(space.values["iconPicture"])
        XCTAssertEqual(space.values["iconName"], .string("star.fill"))
        let icon = try XCTUnwrap(records[SyncRecordKind.spaceIcon.recordName(for: home)])
        XCTAssertEqual(icon.kind, .spaceIcon)
        XCTAssertEqual(icon.values["space"], .string(home.uuidString.lowercased()))
        XCTAssertNil(records[SyncRecordKind.spaceIcon.recordName(for: work)], "only spaces with a picture have one")
        XCTAssertEqual(SyncRecordKind.spaceIcon.rawValue, "SidebarSpaceIconRecord")
        XCTAssertEqual(SyncRecordKind.parse(recordName: SyncRecordKind.spaceIcon.recordName(for: home))?.kind, .spaceIcon)

        let stamp = SyncStamp(millis: 1, device: "A")
        let payloads = records.mapValues { SyncRecordPayload(kind: $0.kind, fields: $0.values.mapValues { SyncField(value: $0, stamp: stamp) }) }
        let applied = SidebarSyncProjection.apply(payloads, onto: SidebarStore().makeSnapshot())
        XCTAssertEqual(applied.spaces.first { $0.id == home }?.iconPicture, picture)
        XCTAssertNil(applied.spaces.first { $0.id == work }?.iconPicture)

        // No icon record: the glyph, whatever this Mac had.
        var removed = payloads
        removed[SyncRecordKind.spaceIcon.recordName(for: home)] = nil
        XCTAssertNil(SidebarSyncProjection.apply(removed, onto: store.makeSnapshot()).spaces.first { $0.id == home }?.iconPicture)

        let name = SyncRecordKind.spaceIcon.recordName(for: home)
        XCTAssertTrue(SidebarSyncProjection.canMaterialize(name, payloads[name]!))
        let junk = SyncRecordPayload(kind: .spaceIcon, fields: ["picture": SyncField(value: .string("!!!"), stamp: stamp)])
        XCTAssertFalse(SidebarSyncProjection.canMaterialize(name, junk), "an unreadable one is left alone")
        var bad = payloads
        bad[name] = junk
        XCTAssertNil(SidebarSyncProjection.apply(bad, onto: SidebarStore().makeSnapshot()).spaces.first { $0.id == home }?.iconPicture)
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
