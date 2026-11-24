import Foundation

/// A passkey kept on "this Mac" for one profile (Chromium's profile
/// authenticator; docs/FEATURE-SPECS/PASSKEYS-AND-SITE-PERMISSIONS.md, 1.7,
/// security review PK-07). The key is in the Secure Enclave and its site and
/// account are sealed with a secret in the profile, so the engine names them
/// (`ReArcProfileGetLocalPasskeys`, ABI 1.72).
public struct LocalPasskey: Equatable, Identifiable, Sendable {
    /// The credential's ID in lower-case hex: what a delete names.
    public let id: String
    /// The site it signs in to (the relying party's ID, a domain).
    public let site: String
    /// The account, as the site named it when the passkey was made. Either may be empty.
    public let userName: String
    public let displayName: String

    public init(id: String, site: String, userName: String = "", displayName: String = "") {
        self.id = id
        self.site = site
        self.userName = userName
        self.displayName = displayName
    }

    /// An ID the engine takes: hex, a whole number of bytes, at most 1024 of them.
    public static func isValidID(_ id: String) -> Bool {
        let bytes = id.utf8
        guard !bytes.isEmpty, bytes.count % 2 == 0, bytes.count <= 2048 else { return false }
        return bytes.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    /// The site as one short line. Chromium checked it when the passkey was
    /// made, but it is still text from outside: cleaned and cut like the
    /// account (`PasskeyStep.pageText`).
    public var siteLine: String {
        let text = PasskeyStep.pageText(site, limit: Self.siteLimit)
        return text.isEmpty ? LocalPasskeyText.noSite : text
    }

    /// The account as one short line: the page's own text, never part of one
    /// of Darni's sentences (security review PK-04).
    public var accountLine: String {
        let name = PasskeyStep.pageText(userName)
        if !name.isEmpty { return name }
        let display = PasskeyStep.pageText(displayName)
        return display.isEmpty ? LocalPasskeyText.noAccount : display
    }

    /// The account's other name, when it has two that differ.
    public var secondLine: String? {
        let name = PasskeyStep.pageText(userName), display = PasskeyStep.pageText(displayName)
        return !name.isEmpty && !display.isEmpty && display != name ? display : nil
    }

    /// A domain name is at most 253 characters; the list shows less.
    public static let siteLimit = 80
}

/// The engine's answer to a list or a delete: always the list as it is now.
public struct LocalPasskeyAnswer: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// The list was read; after a delete, the passkey is gone.
        case ok
        /// A delete named a passkey this profile does not have (any more).
        case notFound
        /// The keychain refused, the engine could not be asked, or its answer could not be read.
        case failed
    }

    public var status: Status
    /// This build can keep passkeys on this Mac (it is signed with their keychain group).
    public var available: Bool
    public var passkeys: [LocalPasskey]

    public init(status: Status, available: Bool, passkeys: [LocalPasskey]) {
        self.status = status
        self.available = available
        self.passkeys = passkeys
    }

    /// No answer could be had.
    public static let failed = LocalPasskeyAnswer(status: .failed, available: true, passkeys: [])
    /// This build keeps no passkeys on this Mac.
    public static let unavailable = LocalPasskeyAnswer(status: .ok, available: false, passkeys: [])

    /// The engine's JSON (C-ABI.md, "This Mac passkeys"). Unknown keys are
    /// ignored. A row without a usable ID or site is left out: it could not
    /// be named or deleted. nil when the text is not that object.
    public init?(json: String, status: Status = .ok) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let available = object["available"] as? Bool else { return nil }
        let rows = object["passkeys"] as? [[String: Any]] ?? []
        var seen = Set<String>()
        let passkeys = rows.compactMap { row -> LocalPasskey? in
            guard let id = row["id"] as? String, LocalPasskey.isValidID(id),
                  let site = row["rp_id"] as? String, !site.isEmpty, seen.insert(id).inserted else { return nil }
            return LocalPasskey(id: id, site: site, userName: row["user_name"] as? String ?? "",
                                displayName: row["user_display_name"] as? String ?? "")
        }
        self.init(status: status, available: available, passkeys: available ? passkeys : [])
    }

    /// The engine's word on a call (C-ABI.md): its status, 0 ok and 4
    /// not_found, and the JSON its completion carried. Any other status, no
    /// JSON, or text that is not the object: `failed`.
    public init(engineStatus: Int32, json: String?) {
        let status: Status
        switch engineStatus {
        case 0: status = .ok
        case 4: status = .notFound
        default: status = .failed
        }
        guard status != .failed, let json, let answer = LocalPasskeyAnswer(json: json, status: status) else {
            self = .failed
            return
        }
        self = answer
    }

    /// The same object, for a fixture file and for tests.
    public var json: String {
        let rows = passkeys.map { ["id": $0.id, "rp_id": $0.site, "user_name": $0.userName, "user_display_name": $0.displayName] }
        let object: [String: Any] = ["available": available, "passkeys": rows]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Where a profile's "this Mac" passkeys are listed and deleted.
public protocol LocalPasskeyStoring: AnyObject {
    /// Answers once, later, on the main thread.
    func list(_ receive: @escaping (LocalPasskeyAnswer) -> Void)
    /// Deletes one for good and answers with the list afterwards.
    func delete(id: String, _ receive: @escaping (LocalPasskeyAnswer) -> Void)
}

/// A store with nothing in it and no way to anything: what a launch gets
/// that must not reach real passkeys and was given no fixture.
public final class UnavailableLocalPasskeyStore: LocalPasskeyStoring {
    public init() {}
    public func list(_ receive: @escaping (LocalPasskeyAnswer) -> Void) { receive(.unavailable) }
    public func delete(id: String, _ receive: @escaping (LocalPasskeyAnswer) -> Void) { receive(.unavailable) }
}

/// Passkeys that exist only in memory (security review PK-08): the store of
/// tests, of the self-test and of on-screen checks. It answers as the engine
/// does and never touches a keychain, so nothing it lists or deletes is real.
public final class FixtureLocalPasskeyStore: LocalPasskeyStoring {
    public private(set) var passkeys: [LocalPasskey]
    /// What was asked of it, in order: "list", "delete <id>".
    public private(set) var calls: [String] = []
    /// Set to make the next answers fail, as a keychain that refuses.
    public var fails = false
    /// Answers are handed to this to run; a test holds them back with it.
    public var deliver: (@escaping () -> Void) -> Void = { $0() }

    public init(passkeys: [LocalPasskey]) {
        self.passkeys = Self.sorted(passkeys)
    }

    /// From a file in the engine's format; nil when it is not one.
    public convenience init?(fileURL: URL) {
        guard let data = try? Data(contentsOf: fileURL),
              let answer = LocalPasskeyAnswer(json: String(decoding: data, as: UTF8.self)) else { return nil }
        self.init(passkeys: answer.passkeys)
    }

    public func list(_ receive: @escaping (LocalPasskeyAnswer) -> Void) {
        calls.append("list")
        let answer = fails ? LocalPasskeyAnswer.failed : LocalPasskeyAnswer(status: .ok, available: true, passkeys: passkeys)
        deliver { receive(answer) }
    }

    public func delete(id: String, _ receive: @escaping (LocalPasskeyAnswer) -> Void) {
        calls.append("delete \(id)")
        var answer = LocalPasskeyAnswer(status: .ok, available: true, passkeys: passkeys)
        if fails {
            answer.status = .failed
        } else if let index = passkeys.firstIndex(where: { $0.id == id }) {
            passkeys.remove(at: index)
            answer.passkeys = passkeys
        } else {
            answer.status = .notFound
        }
        deliver { receive(answer) }
    }

    /// By site, then account: the order of a list people scan for a site.
    static func sorted(_ passkeys: [LocalPasskey]) -> [LocalPasskey] {
        passkeys.sorted { ($0.site, $0.userName, $0.id) < ($1.site, $1.userName, $1.id) }
    }
}

/// Which store a launch may use (security advance read 2026-11-24, point 5).
///
/// Only the person's ordinary launch, on their own data, asks the engine for
/// real passkeys. Every other launch is a test of some kind: a release
/// verification bundle, a launch on another data folder (`REARC_DATA_DIR`,
/// `--user-data-dir`), the self-test, the bench. Such a launch may be signed
/// by the same team and started on a copy of a person's profile, where the
/// engine would list, and this view delete, that person's real passkeys. It
/// gets the fixture it was given, or nothing.
public enum LocalPasskeyStorePolicy {
    public enum Choice: Equatable, Sendable {
        /// The engine's list and delete: real passkeys.
        case engine
        /// The passkeys of a fixture file, in memory only.
        case fixture(path: String)
        /// No list at all.
        case none
    }

    /// A file in the engine's format for a test launch's list. Ignored by an ordinary launch.
    public static let fixtureEnvironmentKey = "REARC_LOCAL_PASSKEYS_FIXTURE"

    /// `ordinaryLaunch`: a run on the person's own data that is no test
    /// (`ChromiumNativeMessagingHosts.runs`, the same rule that keeps test
    /// runs away from the person's native messaging hosts).
    public static func choice(ordinaryLaunch: Bool, environment: [String: String]) -> Choice {
        if ordinaryLaunch { return .engine }
        if let path = environment[fixtureEnvironmentKey], !path.isEmpty { return .fixture(path: path) }
        return .none
    }
}

/// The texts of Settings › Profiles › Passkeys on This Mac.
public enum LocalPasskeyText {
    public static let title = "Passkeys on This Mac"
    public static let noSite = "Unknown site"
    public static let noAccount = "No account name"

    /// Under the title: what these are, and what they are not.
    public static func intro(profile: String) -> String {
        "Passkeys you saved on this Mac in \(profile). Each one stays in this profile on this Mac, "
            + "protected by Touch ID or your Mac password. They do not sync, and they are not in iCloud Keychain or on your phone."
    }

    public static let empty = "No passkeys are saved on this Mac for this profile."
    public static let emptyDetail = "When a site offers to create a passkey, choose This Mac to keep it here."
    public static let loading = "Reading the passkeys…"
    public static let failed = "The passkeys could not be read."
    public static let failedDetail = "macOS did not answer for the keychain. Nothing was changed."
    public static let unavailable = "This build of Darni does not keep passkeys on this Mac."
    public static let fixtureNote = "Test list: these passkeys are not real, and deleting one changes nothing on this Mac."

    public static func count(_ count: Int) -> String {
        count == 1 ? "1 passkey" : "\(count) passkeys"
    }

    // MARK: Deleting (security advance read, point 8: it asks first, names the site and the account, and is final)

    public static let deleteQuestion = "Delete this passkey?"
    public static let deleteSiteLabel = "Site"
    public static let deleteAccountLabel = "Account"
    /// The site and the account stand on lines of their own above this; it names neither.
    public static let deleteWarning = "This Mac will no longer be able to sign you in to this account with it. "
        + "This cannot be undone: the passkey is not in iCloud or on any other device, and Darni keeps no copy. "
        + "If it is your only way into the account, add another way to sign in on the site first."
    public static let deleteButton = "Delete Passkey"
    public static let cancelButton = "Cancel"

    public static let deleted = "The passkey was deleted."
    public static let alreadyGone = "That passkey was already gone. Nothing was deleted."
    public static let deleteFailed = "The passkey could not be deleted. It is still on this Mac."
    public static let changedMeanwhile = "The list changed, so nothing was deleted. Check the passkey and try again."

    /// For VoiceOver, where the two lines are read as one label.
    public static func rowLabel(_ passkey: LocalPasskey) -> String {
        "\(passkey.siteLine), \(passkey.accountLine)"
    }
}
