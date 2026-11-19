import Foundation
import Testing
@testable import SidebarModel

/// ReArc was renamed Darni at build 1054. What people read says Darni. What an installed copy
/// depends on keeps the name ReArc, and a change to any of it strands data or updates.
struct BrandTests {
    @Test func theNamePeopleReadIsDarni() {
        #expect(Brand.name == "Darni")
        #expect(Brand.wordmarkLead + Brand.wordmarkTail == Brand.name, "the two-tone wordmark spells the name")
        #expect((Brand.wordmarkLead, Brand.wordmarkTail) == ("Dar", "ni"), "split at Dar (brand board, option B)")
        #expect((Brand.arcOnLight, Brand.arcOnDark) == (0x2740FF, 0x8EA0FF))
    }

    /// The motto is an open decision; whatever it becomes, it is written once.
    @Test func theMottoIsWrittenOnce() {
        let motto = Brand.motto
        #expect(motto.words == [motto.cleanStart, motto.restored, motto.name])
        #expect(motto.name == "\(Brand.name).", "the last word is the name")
        #expect(motto.capitals == "REFOCUSED · RESTORED · DARNI")
        #expect(Motto(cleanStart: "Focus", restored: "Restore.", name: "Go.").capitals == "FOCUS · RESTORE · GO")
    }

    @Test func theIdentifiersKeepTheOldName() {
        #expect(ShellDataLocation.defaultRoot.lastPathComponent == "ReArc", "Application Support/ReArc: where every install's data is")
        #expect(BlocklistMirror.latestURL.absoluteString == "https://rearc.imara.ae/blocklists/latest.json")
        #expect(UpdateFeedMarker.prefix == "rearc" && UpdateFeedMarker.requiredBelowKey == "rearc:requiredBelow",
                "installed builds read the marker by this prefixed name")
        #expect(UpdateFeedMarker.namespaceURI == "https://rearc.imara.ae/xml-namespaces/update")
        #expect(CloudKitSyncAvailability.defaultContainerIdentifier == "iCloud.com.rearc.browser", "CloudKit containers cannot be renamed")
        #expect(CloudKitSyncAvailability.infoPlistKey == "ReArcICloudContainer")
        #expect(ShellDataLocation.environmentKey == "REARC_DATA_DIR")
    }
}
