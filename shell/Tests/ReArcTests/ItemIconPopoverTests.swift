import Testing
import SidebarModel
@testable import ReArc

@MainActor
struct ItemIconPopoverTests {
    @Test func emojiSearchFindsNamesAndGraphemes() {
        #expect(IconGridPicker.emojiChoices(matching: "  SMILE ").first == "😀")
        #expect(IconGridPicker.emojiChoices(matching: "❤️") == ["❤️"])
        #expect(IconGridPicker.emojiChoices(matching: "zzqx").isEmpty)
        #expect(IconGridPicker.emojiChoices(matching: "").count > 1000)
    }

    @Test func acceptsCustomEmojiAndSymbolsWithoutSplittingGraphemes() {
        #expect(IconGridPicker.emojiChoices(matching: "👩🏽‍💻") == ["👩🏽‍💻"])
        #expect(IconGridPicker.symbolChoices(matching: "arrow.uturn.backward.circle.fill").contains("arrow.uturn.backward.circle.fill"))
        #expect(IconGridPicker.symbolChoices(matching: "not-a-symbol").isEmpty)
        #expect(SidebarItemIcon.emoji("🐶").isEmoji && !SidebarItemIcon.sfSymbol(name: "star.fill").isEmoji)
        #expect(SpaceIconPicker.isEmoji("🐶") && !SpaceIconPicker.isEmoji("star.fill") && !SpaceIconPicker.isEmoji(""))
    }
}
