import Foundation

/// One step of a passkey or security key request, as the engine reports it
/// (Chromium ABI 1.68 `webauthn_prompts`, C-ABI.md "WebAuthn steps"). The
/// engine runs the request; the shell shows each step in its own sheet and
/// sends the person's answer back. The QR text and a PIN are secrets: they
/// are shown and sent, never logged or stored.
public struct PasskeyStep: Equatable, Sendable {
    public enum PinMode: Equatable, Sendable {
        /// The key's PIN.
        case enter
        /// A new PIN for a key that has none.
        case setUp
        /// The key demands a new PIN.
        case change
    }

    public enum Failure: String, Equatable, Sendable {
        case noTransports = "error_no_transports"
        case noPasskeys = "error_no_passkeys"
        case notRecognized = "error_not_recognized"
        case timeout = "error_timeout"
        case keyNotRegistered = "error_key_not_registered"
        case keyAlreadyRegistered = "error_key_already_registered"
        case missingCapability = "error_missing_capability"
        case storageFull = "error_storage_full"
        case pinSoftBlock = "error_pin_soft_block"
        case pinHardBlock = "error_pin_hard_block"
        case keyRemoved = "error_key_removed"
    }

    public enum Kind: Equatable, Sendable {
        case choose, confirm, securityKey, qr
        case phoneConnecting, phoneConnected, phoneError
        case bluetoothOff, bluetoothDenied
        case privateNotice
        case pin(PinMode)
        case touchAgain, fingerprintEnroll, verifyAgain
        case account, createThisMac
        /// macOS shows its own prompt (Touch ID); the shell shows nothing.
        case system
        case hidden
        case failure(Failure)
        /// A step this shell has no sheet for (Google Password Manager, a later engine's).
        case unsupported

        init(name: String) {
            switch name {
            case "choose": self = .choose
            case "confirm": self = .confirm
            case "security_key": self = .securityKey
            case "qr": self = .qr
            case "phone_connecting": self = .phoneConnecting
            case "phone_connected": self = .phoneConnected
            case "phone_error": self = .phoneError
            case "bluetooth_off": self = .bluetoothOff
            case "bluetooth_denied": self = .bluetoothDenied
            case "private_notice": self = .privateNotice
            case "pin": self = .pin(.enter)
            case "pin_setup": self = .pin(.setUp)
            case "pin_change": self = .pin(.change)
            case "touch_again": self = .touchAgain
            case "fingerprint_enroll": self = .fingerprintEnroll
            case "verify_again": self = .verifyAgain
            case "account": self = .account
            case "create_this_mac": self = .createThisMac
            case "system": self = .system
            case "hidden": self = .hidden
            default: self = Failure(rawValue: name).map(Kind.failure) ?? .unsupported
            }
        }
    }

    /// One way to sign in on the "choose" and "confirm" steps.
    public struct Mechanism: Equatable, Identifiable, Sendable {
        public var index: Int
        /// "passkey", "phone", "security_key", "this_mac", "icloud_keychain", "password", "google", "other".
        public var kind: String
        /// The engine's own strings; a passkey's name is its account.
        public var name: String
        public var detail: String
        /// Where a passkey is kept: "this_mac", "icloud_keychain", "phone", "security_key", "google", "other".
        public var source: String
        public var id: Int { index }

        public init(index: Int, kind: String, name: String = "", detail: String = "", source: String = "") {
            self.index = index
            self.kind = kind
            self.name = name
            self.detail = detail
            self.source = source
        }

        public var title: String {
            switch kind {
            case "passkey", "password": return name.isEmpty ? "Passkey" : name
            case "phone": return "Phone or Tablet"
            case "security_key": return "USB Security Key"
            case "this_mac": return "This Mac"
            case "icloud_keychain": return "iCloud Keychain"
            case "google": return "Google Password Manager"
            default: return name.isEmpty ? "Another Way" : name
            }
        }

        public var subtitle: String {
            switch kind {
            case "passkey": return PasskeyStep.sourceLabel(source)
            case "password": return "Saved password"
            case "phone": return "Scan a QR code with its camera"
            case "security_key": return "Insert it and touch it"
            case "this_mac": return "Touch ID or your Mac password"
            default: return detail
            }
        }

        public var symbol: String {
            switch kind {
            case "passkey": return "person.badge.key.fill"
            case "password": return "key.fill"
            case "phone": return "qrcode"
            case "security_key": return "cable.connector"
            case "this_mac": return "touchid"
            case "icloud_keychain": return "key.icloud.fill"
            default: return "ellipsis.circle"
            }
        }
    }

    public struct Account: Equatable, Identifiable, Sendable {
        public var index: Int
        public var name: String
        public var displayName: String
        public var source: String
        public var id: Int { index }

        public init(index: Int, name: String, displayName: String = "", source: String = "") {
            self.index = index
            self.name = name
            self.displayName = displayName
            self.source = source
        }

        public var title: String { name.isEmpty ? (displayName.isEmpty ? "Unnamed account" : displayName) : name }
        public var subtitle: String { displayName == title ? "" : displayName }
    }

    public var kind: Kind
    /// A new passkey is being made (false: signing in with one).
    public var isCreate: Bool
    public var relyingParty: String
    public var origin: String
    public var isPrivate: Bool
    /// The engine works: only Cancel answers.
    public var isBusy: Bool
    public var canChooseAnother: Bool
    public var canTryAgain: Bool
    public var mechanisms: [Mechanism]
    /// The way offered first on "confirm".
    public var priority: Int?
    public var accounts: [Account]
    /// The text of the QR code a phone's camera reads. A secret of this one request.
    public var qr: String?
    public var securityKeyToo: Bool
    public var bluetoothOn: Bool
    public var canPowerOnBluetooth: Bool
    public var pinMinLength: Int
    public var pinAttempts: Int?
    /// "none", "wrong", "too_short", "invalid_characters", "same_as_current", "fingerprint_locked".
    public var pinError: String
    public var attempts: Int?
    public var samples: Int?
    public var samplesRemaining: Int?
    /// The account the page names for a new passkey. The page chooses it:
    /// it is cleaned (`pageText`) and shown on a line of its own, never
    /// inside one of ReArc's sentences.
    public var userName: String
    /// What a touch of a security key tells the site: "none", "model" (its
    /// make and model) or "serial" (enterprise attestation: which key it is).
    public var attestation: String
    /// A record of the visit is kept on the security key: "no", "maybe", "yes".
    public var storedOnKey: String
    /// What the engine says of the page's tab as the step goes out: "visible",
    /// "occluded" or "hidden"; empty when it does not say. For the log: a
    /// request's first step goes to a visible page only (security review PK-10).
    public var pageVisibility: String

    public init(kind: Kind, isCreate: Bool = false, relyingParty: String = "", origin: String = "", isPrivate: Bool = false,
                isBusy: Bool = false, canChooseAnother: Bool = false, canTryAgain: Bool = true,
                mechanisms: [Mechanism] = [], priority: Int? = nil, accounts: [Account] = [], qr: String? = nil,
                securityKeyToo: Bool = false, bluetoothOn: Bool = false, canPowerOnBluetooth: Bool = false,
                pinMinLength: Int = 4, pinAttempts: Int? = nil, pinError: String = "none", attempts: Int? = nil,
                samples: Int? = nil, samplesRemaining: Int? = nil, userName: String = "",
                attestation: String = "none", storedOnKey: String = "no", pageVisibility: String = "") {
        self.kind = kind
        self.isCreate = isCreate
        self.relyingParty = relyingParty
        self.origin = origin
        self.isPrivate = isPrivate
        self.isBusy = isBusy
        self.canChooseAnother = canChooseAnother
        self.canTryAgain = canTryAgain
        self.mechanisms = mechanisms
        self.priority = priority
        self.accounts = accounts
        self.qr = qr
        self.securityKeyToo = securityKeyToo
        self.bluetoothOn = bluetoothOn
        self.canPowerOnBluetooth = canPowerOnBluetooth
        self.pinMinLength = pinMinLength
        self.pinAttempts = pinAttempts
        self.pinError = pinError
        self.attempts = attempts
        self.samples = samples
        self.samplesRemaining = samplesRemaining
        self.userName = PasskeyStep.pageText(userName)
        self.attestation = attestation
        self.storedOnKey = storedOnKey
        self.pageVisibility = PasskeyRefusal.visibilityName(pageVisibility) ?? ""
    }

    /// The longest page-chosen text the sheet shows, in Unicode scalars (so in characters too).
    public static let pageTextLimit = 64
    /// The most combining marks one character keeps.
    public static let pageTextMarkLimit = 2

    /// A name the page chose (an account, a display name), made safe to
    /// show: control, format and direction-override characters and line
    /// breaks are removed, a character keeps two combining marks, and it is
    /// cut at a fixed length. It then reads as one short line that cannot
    /// pose as the sheet's own text, draw over the lines around it or push
    /// the buttons out of the window.
    public static func pageText(_ raw: String, limit: Int = pageTextLimit) -> String {
        var scalars = String.UnicodeScalarView()
        var marks = 0
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                // A line break or a tab separated two words.
                if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == "\u{2028}" || scalar == "\u{2029}" {
                    scalars.append(" ")
                    marks = 0
                }
            case .nonspacingMark, .enclosingMark:
                // Marks stack above and below their letter without limit.
                marks += 1
                if marks <= pageTextMarkLimit { scalars.append(scalar) }
            case .spacingMark:
                // Beside its letter, and the marks after it are still that letter's.
                scalars.append(scalar)
            default:
                scalars.append(scalar)
                marks = 0
            }
        }
        let text = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        // Counted in scalars: one character can be a long run of them.
        guard text.unicodeScalars.count > limit else { return text }
        var kept = "", count = 0
        for character in text {
            count += character.unicodeScalars.count
            if count > limit { break }
            kept.append(character)
        }
        return (kept.isEmpty ? String(text.unicodeScalars.prefix(limit)) : kept) + "…"
    }

    /// The engine's JSON for a step. Nil when it is not the object the ABI describes.
    public init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let step = object["step"] as? String else { return nil }
        let pin = object["pin"] as? [String: Any] ?? [:]
        let user = object["user"] as? [String: Any] ?? [:]
        self.init(
            kind: Kind(name: step),
            isCreate: object["request"] as? String == "create",
            relyingParty: object["rp_id"] as? String ?? "",
            origin: object["origin"] as? String ?? "",
            isPrivate: object["private"] as? Bool ?? false,
            isBusy: object["busy"] as? Bool ?? false,
            canChooseAnother: object["can_choose_another"] as? Bool ?? false,
            canTryAgain: object["can_try_again"] as? Bool ?? false,
            mechanisms: (object["mechanisms"] as? [[String: Any]] ?? []).compactMap { row in
                guard let index = row["index"] as? Int, index >= 0 else { return nil }
                // A passkey's name is its account, which a page chose.
                return Mechanism(index: index, kind: row["kind"] as? String ?? "other",
                                 name: PasskeyStep.pageText(row["name"] as? String ?? ""),
                                 detail: PasskeyStep.pageText(row["description"] as? String ?? ""),
                                 source: row["source"] as? String ?? "")
            },
            priority: object["priority"] as? Int,
            accounts: (object["accounts"] as? [[String: Any]] ?? []).compactMap { row in
                guard let index = row["index"] as? Int, index >= 0 else { return nil }
                return Account(index: index, name: PasskeyStep.pageText(row["name"] as? String ?? ""),
                               displayName: PasskeyStep.pageText(row["display_name"] as? String ?? ""),
                               source: row["source"] as? String ?? "")
            },
            qr: (object["qr"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            securityKeyToo: object["security_key_too"] as? Bool ?? false,
            bluetoothOn: object["bluetooth_on"] as? Bool ?? false,
            canPowerOnBluetooth: object["can_power_on"] as? Bool ?? false,
            pinMinLength: pin["min_length"] as? Int ?? 4,
            pinAttempts: pin["attempts"] as? Int,
            pinError: pin["error"] as? String ?? "none",
            attempts: object["attempts"] as? Int,
            samples: object["samples"] as? Int,
            samplesRemaining: object["samples_remaining"] as? Int,
            userName: (user["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? user["display_name"] as? String ?? "",
            attestation: object["attestation"] as? String ?? "none",
            storedOnKey: object["stored_on_key"] as? String ?? "no",
            pageVisibility: object["visibility"] as? String ?? ""
        )
    }

    public static func sourceLabel(_ source: String) -> String {
        switch source {
        case "this_mac": return "Passkey on this Mac"
        case "icloud_keychain": return "Passkey in iCloud Keychain"
        case "phone": return "Passkey on your phone or tablet"
        case "security_key": return "Passkey on a security key"
        case "google": return "Passkey in Google Password Manager"
        default: return "Passkey"
        }
    }

    // MARK: What the sheet shows

    /// The shell shows a sheet for this step. Not for the system's own
    /// prompt, nor while the engine has nothing to show.
    public var showsSheet: Bool { kind != .system && kind != .hidden }

    /// The site as the sheet names it: the relying party, else the asking page's host.
    public var site: String {
        if !relyingParty.isEmpty { return relyingParty }
        return PageOrigin.promptHost(origin) ?? "this site"
    }

    /// The asking frame is a web page. An extension page may claim a site it
    /// has access to as the relying party, and the sheet names the relying
    /// party: such a request gets no sheet (security review PK-03).
    public var isFromWebPage: Bool {
        origin.hasPrefix("https://") || origin.hasPrefix("http://")
    }

    /// The one line every step starts with: the site the request is for and
    /// whether a passkey is made or used. Touching a key or scanning the
    /// code is the person's consent to this site, whichever step the request
    /// opens on.
    public var requestLine: String {
        isCreate ? "Create a passkey for \(site)" : "Sign in to \(site)"
    }

    public var title: String {
        switch kind {
        case .choose, .confirm: return isCreate ? "Choose where to save your passkey" : "Choose how to sign in"
        case .securityKey: return "Insert your security key and touch it"
        case .qr: return isCreate ? "Save a passkey on a phone or tablet" : "Use a passkey on a phone or tablet"
        case .phoneConnecting: return "Connecting to your device…"
        case .phoneConnected: return "Continue on your device"
        case .phoneError: return "Could not connect to your device"
        case .bluetoothOff: return "Turn on Bluetooth"
        case .bluetoothDenied: return "ReArc needs Bluetooth access"
        case .privateNotice: return "This passkey stays after you close the private window"
        case .pin(.enter): return "Enter the PIN of your security key"
        case .pin(.setUp): return "Create a PIN for your security key"
        case .pin(.change): return "Choose a new PIN for your security key"
        case .touchAgain: return "Touch your security key again"
        case .fingerprintEnroll: return "Add your fingerprint to the security key"
        case .verifyAgain: return "Try your fingerprint again"
        case .account: return "Choose an account"
        case .createThisMac: return "Save a passkey on this Mac?"
        case .system, .hidden: return ""
        case .unsupported: return "This way to sign in is not available in ReArc"
        case .failure(let failure):
            switch failure {
            case .noTransports: return "No way to use a passkey here"
            case .noPasskeys: return "No passkeys for \(site)"
            case .notRecognized: return isCreate ? "The passkey was not saved" : "This Mac has no passkey for \(site)"
            case .timeout: return "The request timed out"
            case .keyNotRegistered: return "This security key is not registered with \(site)"
            case .keyAlreadyRegistered: return "This security key is already registered with \(site)"
            case .missingCapability: return "This security key cannot be used with \(site)"
            case .storageFull: return "This security key is full"
            case .pinSoftBlock: return "Too many wrong PINs"
            case .pinHardBlock: return "Your security key is locked"
            case .keyRemoved: return "The security key was removed"
            }
        }
    }

    public var message: String {
        switch kind {
        case .choose, .confirm, .account, .system, .hidden, .touchAgain: return ""
        case .securityKey: return "Plug it into this Mac if it is not already, then touch its button or sensor."
        case .qr:
            let scan = "Scan this code with the camera of the device. Keep the device near this Mac with Bluetooth on."
            return securityKeyToo ? scan + " A USB security key works too: insert it and touch it." : scan
        case .phoneConnecting: return "Keep your device near this Mac."
        case .phoneConnected: return "Follow the steps on your phone or tablet."
        case .phoneError: return "Check that Bluetooth is on on both devices and that the device is online."
        case .bluetoothOff:
            return "A phone or tablet proves it is near this Mac over Bluetooth. Nothing is paired and no data is sent over it."
        case .bluetoothDenied:
            return "Allow ReArc under System Settings › Privacy & Security › Bluetooth, then try again. macOS may ask you to reopen ReArc."
        case .privateNotice:
            return "A passkey you create in a private window is kept on the device you choose and can sign you in later."
        case .pin(let mode):
            if let problem = pinProblem { return problem }
            switch mode {
            case .enter: return "The PIN belongs to the key, not to \(site)."
            case .setUp, .change: return "At least \(pinMinLength) characters. You will need it each time you use the key."
            }
        case .fingerprintEnroll:
            guard let samples, let samplesRemaining else { return "Touch the key's sensor several times." }
            return samplesRemaining <= 0 ? "Your fingerprint was added." : "Touch the sensor again (\(samples - samplesRemaining) of \(samples))."
        case .verifyAgain:
            return attempts.map { "\($0) attempt\($0 == 1 ? "" : "s") left." } ?? ""
        case .createThisMac:
            // The account's name is the page's text: it has a line of its own (`accountLine`).
            let kept = "The passkey will be kept by ReArc on this Mac, protected by Touch ID or your Mac password. "
                + "It does not sync to your other devices."
            return isPrivate ? kept + " It stays after you close this private window." : kept
        case .unsupported: return canChooseAnother ? "Choose another way to sign in." : ""
        case .failure(let failure):
            switch failure {
            case .noTransports: return "This Mac has no Bluetooth, USB key or passkey storage that \(site) accepts."
            case .noPasskeys: return "None of your devices offered a passkey for this site."
            case .notRecognized: return isCreate ? "The request was cancelled or did not finish." : "Try a phone, tablet or security key that has one."
            case .timeout: return "\(site) stopped waiting. Reload the page to try again."
            case .keyNotRegistered: return "Try another key, or another way to sign in."
            case .keyAlreadyRegistered: return "You do not need to register it again."
            case .missingCapability: return "The site asks for something this key does not support."
            case .storageFull: return "Delete a passkey from the key to make room."
            case .pinSoftBlock: return "Remove the key, insert it again and try once more."
            case .pinHardBlock: return "It was locked after too many wrong PINs and must be reset before it can be used."
            case .keyRemoved: return "Insert it again and try once more."
            }
        }
    }

    /// The account a new passkey is for, on the step that confirms it: the
    /// page's own text, on its own line.
    public var accountLine: String? {
        kind == .createThisMac && !userName.isEmpty ? userName : nil
    }

    /// What touching a security key gives the site, said before the touch as
    /// Chromium's dialog does: on the steps a key can be touched at.
    public var keyNotices: [String] {
        switch kind {
        case .securityKey, .touchAgain: break
        case .qr where securityKeyToo: break
        default: return []
        }
        var notices: [String] = []
        switch attestation {
        case "model": notices.append("\(site) will learn the make and model of your security key.")
        case "serial": notices.append("\(site) wants to learn the ID number of your security key. It will know exactly which key you use.")
        default: break
        }
        switch storedOnKey {
        case "yes": notices.append("A record of your visit to this site will be kept on your security key.")
        case "maybe": notices.append("A record of your visit to this site may be kept on your security key.")
        default: break
        }
        return notices
    }

    /// The engine's complaint about the last PIN, if any.
    public var pinProblem: String? {
        switch pinError {
        case "wrong":
            guard let pinAttempts else { return "That PIN is wrong." }
            return "That PIN is wrong. \(pinAttempts) attempt\(pinAttempts == 1 ? "" : "s") left."
        case "too_short": return "That PIN is too short. Use at least \(pinMinLength) characters."
        case "invalid_characters": return "That PIN has characters the key does not accept."
        case "same_as_current": return "The new PIN must differ from the current one."
        case "fingerprint_locked": return "The fingerprint reader is locked. Enter the key's PIN."
        default: return nil
        }
    }

    public var symbol: String {
        switch kind {
        case .choose, .confirm, .account: return "person.badge.key.fill"
        case .securityKey, .touchAgain: return "cable.connector"
        case .qr: return "qrcode"
        case .phoneConnecting, .phoneConnected: return "iphone.gen3.radiowaves.left.and.right"
        case .bluetoothOff, .bluetoothDenied: return SiteAccessType.bluetoothSymbol
        case .privateNotice: return "eyeglasses"
        case .pin: return "lock.fill"
        case .fingerprintEnroll, .verifyAgain, .createThisMac: return "touchid"
        case .system, .hidden: return "person.badge.key.fill"
        case .phoneError, .failure, .unsupported: return "exclamationmark.triangle.fill"
        }
    }

    /// The sheet's main button, when the step has one.
    public var primary: (title: String, action: PasskeyAction)? {
        guard !isBusy else { return nil }
        switch kind {
        case .confirm: return ("Continue", .proceed)
        case .privateNotice, .createThisMac: return ("Continue", .proceed)
        case .bluetoothOff:
            if canPowerOnBluetooth { return ("Turn On Bluetooth", .proceed) }
            return bluetoothOn ? ("Continue", .proceed) : nil
        case .bluetoothDenied: return ("Open System Settings", .proceed)
        case .fingerprintEnroll: return ((samplesRemaining ?? 1) <= 0 ? "Done" : "Skip", .proceed)
        case .phoneError: return canTryAgain ? ("Try Again", .startOver) : nil
        case .failure(let failure):
            // The request is over after a timeout: only Close.
            return failure != .timeout && canTryAgain ? ("Try Again", .startOver) : nil
        case .choose, .securityKey, .qr, .phoneConnecting, .phoneConnected, .pin, .touchAgain, .verifyAgain, .account,
             .system, .hidden, .unsupported:
            return nil
        }
    }

    /// "Another way": back to the list of ways to sign in.
    public var offersAnotherWay: Bool {
        guard canChooseAnother, !isBusy else { return false }
        switch kind {
        case .confirm, .securityKey, .qr, .bluetoothOff, .bluetoothDenied, .pin, .verifyAgain, .account, .createThisMac, .unsupported:
            return true
        case .choose, .phoneConnecting, .phoneConnected, .phoneError, .privateNotice, .touchAgain, .fingerprintEnroll,
             .system, .hidden, .failure:
            return false
        }
    }

    /// Cancel for a request in flight, Close once it has failed for good.
    public var dismissTitle: String {
        if case .failure = kind { return "Close" }
        return "Cancel"
    }

    /// The ways to sign in the list shows: on "confirm" only the one offered first.
    public var listedMechanisms: [Mechanism] {
        switch kind {
        case .choose: return mechanisms
        case .confirm: return mechanisms.filter { $0.index == priority }
        default: return []
        }
    }

    /// A step that waits for the person at a device, with a spinner.
    public var showsProgress: Bool {
        isBusy || kind == .phoneConnecting || kind == .securityKey || kind == .touchAgain
    }
}

/// The person's answer to a step (`ReArcWebAuthnRespond`).
public enum PasskeyAction: Equatable, Sendable {
    case cancel
    case chooseMechanism(Int)
    /// The step's own "continue".
    case proceed
    case pin(String)
    case chooseAccount(Int)
    /// Another way, or try again.
    case startOver

    /// action, index and text of the ABI call.
    public var engineValues: (action: UInt32, index: UInt32, text: String?) {
        switch self {
        case .cancel: return (0, 0, nil)
        case .chooseMechanism(let index): return (1, UInt32(max(0, index)), nil)
        case .proceed: return (2, 0, nil)
        case .pin(let pin): return (3, 0, pin)
        case .chooseAccount(let index): return (4, UInt32(max(0, index)), nil)
        case .startOver: return (5, 0, nil)
        }
    }

    /// For logs: what was answered, never the PIN.
    public var logName: String {
        switch self {
        case .cancel: return "cancel"
        case .chooseMechanism(let index): return "mechanism \(index)"
        case .proceed: return "continue"
        case .pin: return "pin"
        case .chooseAccount(let index): return "account \(index)"
        case .startOver: return "start over"
        }
    }
}

/// What the sheet checks before a PIN goes to the engine. The key checks the
/// rest (CTAP: 4 to 63 bytes of UTF-8, the key's own minimum).
public enum PasskeyPin {
    public static let maxBytes = 63

    /// Nil when the PIN may be sent; else what to tell the person.
    public static func problem(pin: String, confirmation: String, mode: PasskeyStep.PinMode, minLength: Int) -> String? {
        if pin.isEmpty { return "Enter a PIN." }
        if pin.utf8.count > maxBytes { return "That PIN is too long." }
        guard mode != .enter else { return nil }
        if pin.count < minLength { return "Use at least \(minLength) characters." }
        if pin != confirmation { return "The two PINs do not match." }
        return nil
    }
}

extension PasskeyStep.Kind {
    /// The ABI's name of the step, for the log.
    public var logName: String {
        switch self {
        case .choose: return "choose"
        case .confirm: return "confirm"
        case .securityKey: return "security_key"
        case .qr: return "qr"
        case .phoneConnecting: return "phone_connecting"
        case .phoneConnected: return "phone_connected"
        case .phoneError: return "phone_error"
        case .bluetoothOff: return "bluetooth_off"
        case .bluetoothDenied: return "bluetooth_denied"
        case .privateNotice: return "private_notice"
        case .pin(.enter): return "pin"
        case .pin(.setUp): return "pin_setup"
        case .pin(.change): return "pin_change"
        case .touchAgain: return "touch_again"
        case .fingerprintEnroll: return "fingerprint_enroll"
        case .verifyAgain: return "verify_again"
        case .account: return "account"
        case .createThisMac: return "create_this_mac"
        case .system: return "system"
        case .hidden: return "hidden"
        case .failure(let failure): return failure.rawValue
        case .unsupported: return "unsupported"
        }
    }
}

extension PasskeyStep {
    /// The log line for a request's first step (information level, no
    /// address in it): what the engine said of the page's visibility then.
    public func firstStepLogLine(request: UInt64, tab: UInt64) -> String {
        "passkey request \(request) of tab \(tab): first step \(kind.logName) (\(isCreate ? "create" : "get")), page "
            + (pageVisibility.isEmpty ? "visibility not reported by this engine" : pageVisibility)
    }
}

/// A passkey request the engine refused because nobody sees its page: a
/// background tab, a hidden or minimised window, a window another app's
/// window covers (ABI 1.68, the end event with "refused"; security review
/// PK-10 and AH-02). It never had a sheet; the shell writes it to its log.
public struct PasskeyRefusal: Equatable, Sendable {
    public enum Place: String, Equatable, Sendable {
        /// Chromium's own rule, when a request starts (and when a new passkey's result arrives).
        case focusCheck = "focus_check"
        /// The page went out of sight between the start and the request's first step with UI.
        case firstStep = "first_step"
    }

    public var place: Place
    /// "occluded" (its window is covered) or "hidden" (a background tab, a hidden or minimised window).
    public var visibility: String
    /// "create" or "get"; nil at Chromium's check, which knows the page and not the request.
    public var request: String?
    /// The step the engine did not send.
    public var step: String?

    public init(place: Place, visibility: String, request: String? = nil, step: String? = nil) {
        self.place = place
        self.visibility = visibility
        self.request = request
        self.step = step
    }

    /// Nil for an ordinary end of a request ("{}") and for a reason this shell does not know.
    public init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              object["refused"] as? String == "not_visible",
              let place = (object["at"] as? String).flatMap(Place.init(rawValue:)) else { return nil }
        self.init(place: place,
                  visibility: Self.visibilityName(object["visibility"] as? String ?? "") ?? "state not reported",
                  request: (object["request"] as? String).flatMap { ["create", "get"].contains($0) ? $0 : nil },
                  step: (object["step"] as? String).flatMap(Self.stepName))
    }

    /// One line, information level. Tab and request numbers, the engine's own words for the rest: no address.
    public func logLine(request id: UInt64, tab: UInt64) -> String {
        let page = tab == 0 ? "a page that is no tab" : "tab \(tab)"
        switch place {
        case .focusCheck:
            return "passkey request of \(page) refused: its page is not visible (\(visibility)), at Chromium's focus check"
        case .firstStep:
            let what = [request, step].compactMap { $0 }.joined(separator: ", ")
            return "passkey request \(id) of \(page) refused: its page is not visible (\(visibility)), at its first step"
                + (what.isEmpty ? "" : " (\(what))")
        }
    }

    static func visibilityName(_ name: String) -> String? {
        ["visible", "occluded", "hidden"].contains(name) ? name : nil
    }

    /// A step name as the ABI writes them: lower case letters and "_".
    static func stepName(_ name: String) -> String? {
        !name.isEmpty && name.count <= 40 && name.allSatisfy { ("a"..."z").contains($0) || $0 == "_" } ? name : nil
    }
}
