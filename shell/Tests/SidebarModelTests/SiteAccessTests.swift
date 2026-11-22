import Foundation
import XCTest
@testable import SidebarModel

/// The engine's site permission state (Chromium ABI 1.67) and the panel rows made from it.
final class SiteAccessTests: XCTestCase {
    /// What `ReArcTabGetSitePermissions` answers, as C-ABI.md describes it.
    private let json = """
    {"origin":"https://meet.example","off_the_record":false,
     "permissions":[
      {"type":"geolocation","setting":"ask","default":"ask","source":"default","held":false,"changeable":true,"one_time":false},
      {"type":"media-stream-camera","setting":"allow","default":"ask","source":"user","held":true,"changeable":true,"one_time":false},
      {"type":"media-stream-mic","setting":"allow","default":"ask","source":"user","held":true,"changeable":true,"one_time":true},
      {"type":"notifications","setting":"block","default":"ask","source":"embargo","held":true,"changeable":true,"one_time":false},
      {"type":"popups","setting":"allow","default":"block","source":"policy","held":true,"changeable":false,"one_time":false},
      {"type":"sound","setting":"block","default":"block","source":"default","held":true,"changeable":true,"one_time":false},
      {"type":"bluetooth-guard","setting":"ask","default":"ask","source":"default","held":false,"changeable":true,"one_time":false},
      {"type":"some-later-setting","setting":"allow","default":"ask","source":"user","held":true,"changeable":true,"one_time":false},
      {"type":"clipboard","setting":"sometimes","default":"ask","source":"user","held":true,"changeable":true}
     ],
     "devices":[
      {"kind":"usb","key":"1050;0407;A1","name":"YubiKey OTP+FIDO+CCID","changeable":true},
      {"kind":"bluetooth","key":"AA:BB","name":"","changeable":false}
     ],
     "in_use":["camera","bluetooth"],
     "a_later_key":42}
    """

    func testDecodesTheEnginesAnswer() throws {
        let access = try XCTUnwrap(SiteAccess(json: json))
        XCTAssertEqual(access.origin, "https://meet.example")
        XCTAssertFalse(access.isPrivate)
        // A state this shell does not know is left out, never guessed.
        XCTAssertEqual(access.permissions.map(\.type), [
            "geolocation", "media-stream-camera", "media-stream-mic", "notifications", "popups", "sound", "bluetooth-guard",
            "some-later-setting",
        ])
        let microphone = try XCTUnwrap(access.permissions.first { $0.type == "media-stream-mic" })
        XCTAssertEqual(microphone, SiteAccess.Permission(type: "media-stream-mic", setting: .allow, defaultSetting: .ask, source: .user,
                                                         isHeld: true, isChangeable: true, isOneTime: true))
        XCTAssertEqual(access.devices.map(\.kind), ["usb", "bluetooth"])
        XCTAssertEqual(access.inUse, ["camera", "bluetooth"])
    }

    func testAPageWithoutASiteAndBrokenAnswersDecodeToNothing() {
        XCTAssertNil(SiteAccess(json: #"{"origin":""}"#), "an empty tab, a file or an internal page")
        XCTAssertNil(SiteAccess(json: "{}"))
        XCTAssertNil(SiteAccess(json: "[]"))
        XCTAssertNil(SiteAccess(json: "not json"))
        // Missing lists are empty lists.
        XCTAssertEqual(SiteAccess(json: #"{"origin":"https://a.example"}"#), SiteAccess(origin: "https://a.example"))
    }

    func testRowsAreWhatTheSiteHoldsPlusWhatIsInUse() throws {
        let access = try XCTUnwrap(SiteAccess(json: json))
        let rows = SiteControlCenter.siteAccessRows(access)
        // Location is neither held nor in use; Bluetooth is not held but in use.
        XCTAssertEqual(rows.map(\.title), [
            "Camera", "Microphone", "Notifications", "Pop-ups and redirects", "Sound", "Bluetooth devices", "Some later setting",
            "YubiKey OTP+FIDO+CCID", "Bluetooth device",
        ])
        XCTAssertEqual(rows.map(\.state), [
            "Allowed · In use", "Allowed this time", "Blocked after repeated dismissals", "Allowed by your organisation",
            "Blocked by default", "Asks first · In use", "Allowed", "USB device", "Bluetooth device · In use",
        ])
        XCTAssertEqual(rows.map(\.isBlocked), [false, false, true, false, true, false, false, false, false])
        XCTAssertEqual(rows[0].kind, .sitePermission("media-stream-camera"))
        XCTAssertEqual(rows[7].kind, .siteDevice(kind: "usb", key: "1050;0407;A1"))
        XCTAssertEqual(rows[0].symbol, "video.fill")
    }

    func testEachRowOffersWhatTheEngineWillTake() throws {
        let access = try XCTUnwrap(SiteAccess(json: json))
        let rows = Dictionary(uniqueKeysWithValues: SiteControlCenter.siteAccessRows(access).map { ($0.title, $0.actions) })
        XCTAssertEqual(rows["Camera"], [.block, .reset], "the site's own rule: change it or take it away")
        XCTAssertEqual(rows["Notifications"], [.allow, .reset], "reset ends an embargo")
        XCTAssertEqual(rows["Pop-ups and redirects"], [], "policy decides: a label")
        XCTAssertEqual(rows["Sound"], [.allow], "the default applies: there is no rule to reset")
        XCTAssertEqual(rows["Bluetooth devices"], [.block], "a device guard asks or blocks: the engine refuses Allow (PK-09)")
        XCTAssertEqual(rows["YubiKey OTP+FIDO+CCID"], [.removeDevice])
        XCTAssertEqual(rows["Bluetooth device"], [], "a policy grant")
        XCTAssertEqual(SiteControlCenter.SettingAction.removeDevice.title, "Remove Access")
        // A guard the person blocked goes back to asking with Reset; one blocked by default has nothing to offer.
        for guardType in ["usb-guard", "hid-guard", "serial-guard", "bluetooth-guard", "bluetooth-scanning"] {
            XCTAssertEqual(SiteControlCenter.siteAccessActions(.init(type: guardType, setting: .block, source: .user)), [.reset], guardType)
            XCTAssertEqual(SiteControlCenter.siteAccessActions(.init(type: guardType, setting: .block, source: .siteDefault)), [], guardType)
            XCTAssertEqual(SiteControlCenter.siteAccessActions(.init(type: guardType, setting: .ask, source: .siteDefault)), [.block], guardType)
        }
        XCTAssertEqual(SiteControlCenter.siteAccessActions(.init(type: "notifications", setting: .block, source: .user)), [.allow, .reset])
    }

    func testThePanelShowsTheEnginesRowsInsteadOfTheShellsRecord() throws {
        let access = try XCTUnwrap(SiteAccess(json: json))
        let recorded = [(type: PermissionType.camera, entry: SitePermissionStore.Entry(decision: .deny, remembered: true, date: Date()))]
        let rows = SiteControlCenter.settingRows(siteAccess: access, needsReload: true, permissions: recorded, permissionsInEngine: true,
                                                 autoPiP: .enabled, autoPiPEnabled: true)
        XCTAssertEqual(rows.first, SiteControlCenter.reloadToApplyRow)
        XCTAssertEqual(rows.first?.actions, [.reloadPage])
        XCTAssertFalse(rows.contains { $0.kind == .permission("camera_stream") }, "the engine's Camera row is the truth")
        XCTAssertEqual(rows.filter { $0.title == "Camera" }.map(\.state), ["Allowed · In use"])
        XCTAssertEqual(rows.last?.kind, .autoPictureInPicture)
        // An engine that reports nothing yet for the site shows no stale answers either.
        let empty = SiteControlCenter.settingRows(siteAccess: SiteAccess(origin: "https://meet.example"), permissions: recorded,
                                                  permissionsInEngine: true, autoPiP: .enabled, autoPiPEnabled: true)
        XCTAssertEqual(empty.map(\.kind), [.autoPictureInPicture])
        // Without the engine's state the record shows as before.
        let before = SiteControlCenter.settingRows(permissions: recorded, permissionsInEngine: true, autoPiP: .enabled, autoPiPEnabled: true)
        XCTAssertEqual(before.first?.kind, .permission("camera_stream"))
        XCTAssertEqual(before.first?.actions, [])
    }

    func testTheAddressBadgeShowsWhatIsInUseBeforeTheConnection() throws {
        let access = try XCTUnwrap(SiteAccess(json: json))
        let inUse = SiteInfoBadge.make(host: "meet.example", connection: .secure, access: access)
        XCTAssertEqual(inUse.symbol, "video.fill", "the camera leads")
        XCTAssertTrue(inUse.isInUse)
        XCTAssertFalse(inUse.isWarning)
        XCTAssertEqual(inUse.help, "meet.example is using your camera and a Bluetooth device")

        let quiet = SiteInfoBadge.make(host: "meet.example", connection: .secure, access: SiteAccess(origin: "https://meet.example"))
        XCTAssertEqual(quiet, SiteInfoBadge(symbol: "slider.horizontal.3", isWarning: false, isInUse: false,
                                            help: "Site information for meet.example"))
        XCTAssertEqual(SiteInfoBadge.make(host: "a.example", connection: .unknown, access: nil).symbol, "slider.horizontal.3")
        let insecure = SiteInfoBadge.make(host: "a.example", connection: .insecure, access: nil)
        XCTAssertTrue(insecure.isWarning)
        XCTAssertEqual(insecure.symbol, "exclamationmark.triangle.fill")
        let dangerous = SiteInfoBadge.make(host: "a.example", connection: .dangerous, access: access)
        XCTAssertTrue(dangerous.isWarning && dangerous.isInUse, "a dangerous site using the camera says both")
    }

    func testEveryListedSettingHasANameAndInUseNamesAreKnown() {
        // The engine's list (rearc_site_permissions.cc kTypes), by Chromium's registry names.
        let types = [
            "geolocation", "geolocation-with-options", "media-stream-camera", "camera-pan-tilt-zoom", "media-stream-mic", "sensors",
            "notifications", "javascript", "images", "popups", "window-placement", "background-sync", "sound", "automatic-downloads",
            "midi-sysex", "clipboard", "usb-guard", "hid-guard", "serial-guard", "file-system-write-guard", "local-fonts",
            "bluetooth-guard", "bluetooth-scanning", "hand-tracking", "vr", "ar", "idle-detection", "webid-api",
            "captured-surface-control", "automatic-fullscreen", "keyboard-lock", "pointer-lock", "local-network", "loopback-network",
        ]
        for type in types {
            let described = SiteAccessType.describe(type)
            // The fallback's symbol: a listed setting has a row of its own.
            XCTAssertNotEqual(described.symbol, "hand.raised.fill", "\(type) has its own row")
            XCTAssertFalse(described.title.isEmpty, type)
            XCTAssertTrue(Set(described.inUseNames).isSubset(of: SiteAccessType.inUseOrder), type)
        }
        XCTAssertEqual(SiteAccessType.describe("a-later-setting").title, "A later setting")
        XCTAssertEqual(SiteAccessType.inUseOrder.map(SiteAccessType.inUsePhrase).filter { $0.isEmpty }, [])
    }
}
