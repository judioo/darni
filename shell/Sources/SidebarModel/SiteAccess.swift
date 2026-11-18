import Foundation

/// What the engine holds for the site of a page (Chromium ABI 1.67
/// `site_permissions`, C-ABI.md "Site permissions"): every setting the site
/// has, the devices chosen for it and what the page uses now. It is the
/// engine's answer, decoded; the shell keeps no permission state of its own
/// for an engine that answers.
public struct SiteAccess: Equatable, Sendable {
    public enum Setting: String, Sendable {
        case allow, block, ask
    }

    /// Where a setting comes from.
    public enum Source: String, Sendable {
        /// No rule for the site: the profile's default applies.
        case siteDefault = "default"
        /// The person's rule for the site.
        case user
        case policy
        case `extension`
        /// Blocked for a while after the prompt was dismissed several times.
        case embargo
        case other
    }

    public struct Permission: Equatable, Identifiable, Sendable {
        /// Chromium's name of the content setting ("notifications", "media-stream-camera").
        public var type: String
        public var setting: Setting
        public var defaultSetting: Setting
        public var source: Source
        /// The site holds it: Chromium's page info would list it.
        public var isHeld: Bool
        public var isChangeable: Bool
        /// Allowed for this visit only.
        public var isOneTime: Bool
        public var id: String { type }

        public init(type: String, setting: Setting, defaultSetting: Setting = .ask, source: Source = .user,
                    isHeld: Bool = true, isChangeable: Bool = true, isOneTime: Bool = false) {
            self.type = type
            self.setting = setting
            self.defaultSetting = defaultSetting
            self.source = source
            self.isHeld = isHeld
            self.isChangeable = isChangeable
            self.isOneTime = isOneTime
        }
    }

    /// A device the person chose for the site in a device chooser.
    public struct Device: Equatable, Identifiable, Sendable {
        /// "usb", "hid", "serial" or "bluetooth".
        public var kind: String
        /// The grant's identity for the engine's revoke call.
        public var key: String
        public var name: String
        public var isChangeable: Bool
        public var id: String { kind + "\u{1F}" + key }

        public init(kind: String, key: String, name: String, isChangeable: Bool = true) {
            self.kind = kind
            self.key = key
            self.name = name
            self.isChangeable = isChangeable
        }
    }

    /// The site, serialized ("https://example.com").
    public var origin: String
    public var isPrivate: Bool
    public var permissions: [Permission]
    public var devices: [Device]
    /// What the page uses now: "camera", "microphone", "screen", "location",
    /// "bluetooth", "usb", "hid", "serial".
    public var inUse: Set<String>

    public init(origin: String, isPrivate: Bool = false, permissions: [Permission] = [], devices: [Device] = [], inUse: Set<String> = []) {
        self.origin = origin
        self.isPrivate = isPrivate
        self.permissions = permissions
        self.devices = devices
        self.inUse = inUse
    }

    /// The engine's JSON. Nil for a page without a site (`"origin": ""`) and
    /// for anything that is not the object the ABI describes. A row with a
    /// state this shell does not know is left out, never guessed.
    public init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let origin = object["origin"] as? String, !origin.isEmpty else { return nil }
        self.origin = origin
        isPrivate = object["off_the_record"] as? Bool ?? false
        permissions = (object["permissions"] as? [[String: Any]] ?? []).compactMap { row in
            guard let type = row["type"] as? String, !type.isEmpty,
                  let setting = (row["setting"] as? String).flatMap(Setting.init(rawValue:)) else { return nil }
            return Permission(
                type: type, setting: setting,
                defaultSetting: (row["default"] as? String).flatMap(Setting.init(rawValue:)) ?? .ask,
                source: (row["source"] as? String).flatMap(Source.init(rawValue:)) ?? .other,
                isHeld: row["held"] as? Bool ?? false,
                isChangeable: row["changeable"] as? Bool ?? false,
                isOneTime: row["one_time"] as? Bool ?? false)
        }
        devices = (object["devices"] as? [[String: Any]] ?? []).compactMap { row in
            guard let kind = row["kind"] as? String, let key = row["key"] as? String, !kind.isEmpty, !key.isEmpty else { return nil }
            return Device(kind: kind, key: key, name: row["name"] as? String ?? "", isChangeable: row["changeable"] as? Bool ?? false)
        }
        inUse = Set(object["in_use"] as? [String] ?? [])
    }

    /// Whether the page uses what this setting guards right now.
    public func isInUse(_ permission: Permission) -> Bool {
        !inUse.isDisjoint(with: SiteAccessType.describe(permission.type).inUseNames)
    }

    /// The rows a site panel shows: what the site holds, and anything in use.
    public var shownPermissions: [Permission] {
        permissions.filter { $0.isHeld || isInUse($0) }
    }

    /// Something of the person's is in use by the page now.
    public var isAnythingInUse: Bool { !inUse.isEmpty }
}

/// How a content setting reads in the panel. Types this shell has no name
/// for still show, with Chromium's name made readable.
public struct SiteAccessType: Equatable, Sendable {
    public var title: String
    public var symbol: String
    /// The `in_use` names that mean this setting is being used.
    public var inUseNames: [String]

    public static func describe(_ type: String) -> SiteAccessType {
        switch type {
        case "geolocation", "geolocation-with-options": return .init(title: "Location", symbol: "location.fill", inUseNames: ["location"])
        case "media-stream-camera": return .init(title: "Camera", symbol: "video.fill", inUseNames: ["camera"])
        case "camera-pan-tilt-zoom": return .init(title: "Camera movement", symbol: "video.fill", inUseNames: ["camera"])
        case "media-stream-mic": return .init(title: "Microphone", symbol: "mic.fill", inUseNames: ["microphone"])
        case "sensors": return .init(title: "Motion sensors", symbol: "gyroscope", inUseNames: [])
        case "notifications": return .init(title: "Notifications", symbol: "bell.fill", inUseNames: [])
        case "javascript": return .init(title: "JavaScript", symbol: "curlybraces", inUseNames: [])
        case "images": return .init(title: "Images", symbol: "photo", inUseNames: [])
        case "popups": return .init(title: "Pop-ups and redirects", symbol: "macwindow.on.rectangle", inUseNames: [])
        case "window-placement": return .init(title: "Window management", symbol: "macwindow", inUseNames: [])
        case "background-sync": return .init(title: "Background sync", symbol: "arrow.triangle.2.circlepath", inUseNames: [])
        case "sound": return .init(title: "Sound", symbol: "speaker.wave.2.fill", inUseNames: [])
        case "automatic-downloads": return .init(title: "Automatic downloads", symbol: "arrow.down.circle", inUseNames: [])
        case "midi-sysex": return .init(title: "MIDI devices", symbol: "pianokeys", inUseNames: [])
        case "clipboard": return .init(title: "Clipboard", symbol: "doc.on.clipboard", inUseNames: [])
        case "usb-guard": return .init(title: "USB devices", symbol: "cable.connector", inUseNames: ["usb"])
        case "hid-guard": return .init(title: "HID devices", symbol: "keyboard", inUseNames: ["hid"])
        case "serial-guard": return .init(title: "Serial ports", symbol: "cable.connector.horizontal", inUseNames: ["serial"])
        case "file-system-write-guard": return .init(title: "File editing", symbol: "square.and.pencil", inUseNames: [])
        case "local-fonts": return .init(title: "Fonts", symbol: "textformat", inUseNames: [])
        case "bluetooth-guard": return .init(title: "Bluetooth devices", symbol: SiteAccessType.bluetoothSymbol, inUseNames: ["bluetooth"])
        case "bluetooth-scanning": return .init(title: "Bluetooth scanning", symbol: SiteAccessType.bluetoothSymbol, inUseNames: ["bluetooth"])
        case "hand-tracking": return .init(title: "Hand tracking", symbol: "hand.point.up.left.fill", inUseNames: [])
        case "vr": return .init(title: "Virtual reality", symbol: "visionpro", inUseNames: [])
        case "ar": return .init(title: "Augmented reality", symbol: "arkit", inUseNames: [])
        case "idle-detection": return .init(title: "Your device use", symbol: "moon.zzz.fill", inUseNames: [])
        case "webid-api": return .init(title: "Third-party sign-in", symbol: "person.badge.key.fill", inUseNames: [])
        case "captured-surface-control": return .init(title: "Scroll and zoom shared tabs", symbol: "rectangle.on.rectangle", inUseNames: ["screen"])
        case "automatic-fullscreen": return .init(title: "Automatic full screen", symbol: "arrow.up.left.and.arrow.down.right", inUseNames: [])
        case "keyboard-lock": return .init(title: "Keyboard lock", symbol: "keyboard", inUseNames: [])
        case "pointer-lock": return .init(title: "Pointer lock", symbol: "cursorarrow", inUseNames: [])
        case "local-network": return .init(title: "Devices on your local network", symbol: "network", inUseNames: [])
        case "loopback-network": return .init(title: "Apps on this Mac", symbol: "network", inUseNames: [])
        default:
            let words = type.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            return .init(title: words.prefix(1).uppercased() + words.dropFirst(), symbol: "hand.raised.fill", inUseNames: [])
        }
    }

    /// SF Symbols has no Bluetooth mark; radio waves stand for it.
    public static let bluetoothSymbol = "dot.radiowaves.left.and.right"

    /// A chosen device's kind, as the panel names it.
    public static func deviceKindTitle(_ kind: String) -> String {
        switch kind {
        case "usb": return "USB device"
        case "hid": return "HID device"
        case "serial": return "Serial port"
        case "bluetooth": return "Bluetooth device"
        default: return "Device"
        }
    }

    public static func deviceSymbol(_ kind: String) -> String {
        switch kind {
        case "bluetooth": return bluetoothSymbol
        case "hid": return "keyboard"
        case "serial": return "cable.connector.horizontal"
        default: return "cable.connector"
        }
    }

    /// What is in use, most significant first, for the address's indicator.
    public static let inUseOrder = ["camera", "microphone", "screen", "location", "bluetooth", "usb", "hid", "serial"]

    public static func inUseSymbol(_ name: String) -> String {
        switch name {
        case "camera": return "video.fill"
        case "microphone": return "mic.fill"
        case "screen": return "rectangle.inset.filled.and.person.filled"
        case "location": return "location.fill"
        case "bluetooth": return bluetoothSymbol
        case "hid": return "keyboard"
        case "serial": return "cable.connector.horizontal"
        default: return "cable.connector"
        }
    }

    /// "your camera", for "example.com is using your camera".
    public static func inUsePhrase(_ name: String) -> String {
        switch name {
        case "camera": return "your camera"
        case "microphone": return "your microphone"
        case "screen": return "your screen"
        case "location": return "your location"
        case "bluetooth": return "a Bluetooth device"
        case "usb": return "a USB device"
        case "hid": return "a HID device"
        case "serial": return "a serial port"
        default: return name
        }
    }
}

// MARK: - Site panel rows from the engine's state

extension SiteControlCenter {
    /// "Allowed", "Blocked by default", "Allowed this time · In use".
    public static func siteAccessState(_ permission: SiteAccess.Permission, inUse: Bool) -> String {
        var state: String
        switch permission.setting {
        case .allow: state = permission.isOneTime ? "Allowed this time" : "Allowed"
        case .block: state = "Blocked"
        case .ask: state = "Asks first"
        }
        switch permission.source {
        case .siteDefault: if permission.setting != .ask { state += " by default" }
        case .policy: state += " by your organisation"
        case .extension: state += " by an extension"
        case .embargo: state = "Blocked after repeated dismissals"
        case .user, .other: break
        }
        return inUse ? state + " · In use" : state
    }

    /// What a click on a permission row offers. A row the person does not
    /// control is a label. Reset is there when the site has a rule of its own
    /// (or an embargo) to take away.
    public static func siteAccessActions(_ permission: SiteAccess.Permission) -> [SettingAction] {
        guard permission.isChangeable else { return [] }
        var actions: [SettingAction]
        switch permission.setting {
        case .allow: actions = [.block]
        case .block: actions = [.allow]
        case .ask: actions = [.allow, .block]
        }
        if permission.source == .user || permission.source == .embargo { actions.append(.reset) }
        return actions
    }

    /// The engine's rows: the settings the site holds or uses now, in the
    /// engine's order, then the devices chosen for it.
    public static func siteAccessRows(_ access: SiteAccess) -> [SettingRow] {
        var rows = access.shownPermissions.map { permission in
            let type = SiteAccessType.describe(permission.type)
            return SettingRow(kind: .sitePermission(permission.type), title: type.title,
                              state: siteAccessState(permission, inUse: access.isInUse(permission)),
                              symbol: type.symbol, isBlocked: permission.setting == .block,
                              actions: siteAccessActions(permission))
        }
        rows += access.devices.map { device in
            let kind = SiteAccessType.deviceKindTitle(device.kind)
            let inUse = access.inUse.contains(device.kind)
            return SettingRow(kind: .siteDevice(kind: device.kind, key: device.key),
                              title: device.name.isEmpty ? kind : device.name,
                              state: inUse ? kind + " · In use" : kind,
                              symbol: SiteAccessType.deviceSymbol(device.kind), isBlocked: false,
                              actions: device.isChangeable ? [.removeDevice] : [])
        }
        return rows
    }

    /// A change may not reach a page that is already loaded (a stream or a
    /// device it holds stays until a reload): the panel offers the reload.
    public static let reloadToApplyRow = SettingRow(
        kind: .reloadToApply, title: "Reload to apply your changes", state: "This page keeps what it had until then",
        symbol: "arrow.clockwise", isBlocked: false, actions: [.reloadPage])
}

/// The site information entry at the start of the address: the connection,
/// or what the page is using now (camera, microphone, a Bluetooth device).
public struct SiteInfoBadge: Equatable, Sendable {
    public var symbol: String
    /// The connection is not secure, or the site is dangerous.
    public var isWarning: Bool
    /// Something of the person's is in use by the page.
    public var isInUse: Bool
    public var help: String

    public static func make(host: String, connection: SiteControlCenter.Connection, access: SiteAccess?) -> SiteInfoBadge {
        // In use first: it is what the person most needs to see, and the
        // connection is one click away in the panel.
        if let access, let first = SiteAccessType.inUseOrder.first(where: access.inUse.contains) {
            let all = SiteAccessType.inUseOrder.filter(access.inUse.contains).map(SiteAccessType.inUsePhrase)
            return SiteInfoBadge(symbol: SiteAccessType.inUseSymbol(first), isWarning: connection == .dangerous, isInUse: true,
                                 help: "\(host) is using \(ListFormatter.localizedString(byJoining: all))")
        }
        switch connection {
        case .dangerous:
            return SiteInfoBadge(symbol: "exclamationmark.octagon.fill", isWarning: true, isInUse: false, help: "\(host) is dangerous")
        case .insecure:
            return SiteInfoBadge(symbol: "exclamationmark.triangle.fill", isWarning: true, isInUse: false,
                                 help: "Your connection to \(host) is not secure")
        case .secure, .unknown:
            return SiteInfoBadge(symbol: "slider.horizontal.3", isWarning: false, isInUse: false, help: "Site information for \(host)")
        }
    }
}
