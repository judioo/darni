import Foundation
import SidebarModel

/// One profile's "this Mac" passkeys, for Settings › Profiles › Passkeys on
/// This Mac (docs/FEATURE-SPECS/PASSKEYS-AND-SITE-PERMISSIONS.md, 1.7). It
/// keeps nothing: the list is the store's last answer.
///
/// Deleting is final, so it has one way through. `ask` names a passkey of
/// the list and shows the confirmation; only `confirmDelete` deletes, and
/// only that passkey, as the confirmation named it. There is no call that
/// deletes by an ID alone.
@Observable
final class LocalPasskeysModel {
    enum Phase: Equatable {
        /// Asked, no answer yet.
        case loading
        /// The list is the store's answer.
        case loaded
        /// This build keeps no passkeys on this Mac.
        case unavailable
        /// The store could not be read.
        case failed
    }

    private(set) var phase = Phase.loading
    private(set) var passkeys: [LocalPasskey] = []
    /// The passkey the confirmation is showing; nil when none is asked about.
    private(set) var asking: LocalPasskey?
    /// A delete is out: nothing else is taken until it answers.
    private(set) var isDeleting = false
    /// What the last delete came to, shown under the list until the next action.
    private(set) var notice: String?

    @ObservationIgnored let store: LocalPasskeyStoring
    /// The passkeys are a fixture's: the sheet says so.
    @ObservationIgnored let isFixture: Bool
    /// Told what happened, without a site or an account: "listed 3", "deleted", "delete failed".
    @ObservationIgnored var log: (String) -> Void = { _ in }
    @ObservationIgnored private var listing = false
    @ObservationIgnored private var stale = false

    init(store: LocalPasskeyStoring, isFixture: Bool = false) {
        self.store = store
        self.isFixture = isFixture
    }

    /// Asks the store. A request made while one is out is made once more
    /// when it returns, so the last state always arrives.
    func refresh() {
        guard !isDeleting else { return }
        guard !listing else {
            stale = true
            return
        }
        listing = true
        store.list { [weak self] answer in
            guard let self else { return }
            listing = false
            take(answer)
            log(answer.status == .ok ? (answer.available ? "listed \(answer.passkeys.count)" : "not available in this build") : "list failed")
            if stale {
                stale = false
                refresh()
            }
        }
    }

    /// Opens the confirmation for a passkey of the list. Nothing is deleted.
    func ask(_ passkey: LocalPasskey) {
        guard phase == .loaded, !isDeleting, passkeys.contains(passkey) else { return }
        notice = nil
        asking = passkey
    }

    func cancelDelete() {
        guard !isDeleting else { return }
        asking = nil
    }

    /// The person confirmed: deletes the passkey the confirmation named. If
    /// the list no longer has that passkey as it was shown (another answer
    /// arrived meanwhile), nothing is deleted and the person is told.
    func confirmDelete() {
        guard let passkey = asking, !isDeleting else { return }
        guard phase == .loaded, passkeys.contains(passkey) else {
            asking = nil
            notice = LocalPasskeyText.changedMeanwhile
            return
        }
        isDeleting = true
        store.delete(id: passkey.id) { [weak self] answer in
            guard let self else { return }
            isDeleting = false
            asking = nil
            let gone = answer.available && !answer.passkeys.contains(where: { $0.id == passkey.id })
            switch answer.status {
            case .ok where gone:
                notice = LocalPasskeyText.deleted
                log("deleted")
            case .notFound:
                notice = LocalPasskeyText.alreadyGone
                log("delete: not found")
            default:
                // Refused, or "ok" with the passkey still listed: it was not deleted.
                notice = LocalPasskeyText.deleteFailed
                log("delete failed")
            }
            if answer.status == .failed {
                // The answer carries no list worth showing: ask again.
                refresh()
            } else {
                take(answer)
            }
        }
    }

    private func take(_ answer: LocalPasskeyAnswer) {
        switch (answer.status, answer.available) {
        case (.failed, _):
            phase = .failed
            passkeys = []
        case (_, false):
            phase = .unavailable
            passkeys = []
        default:
            phase = .loaded
            if passkeys != answer.passkeys { passkeys = answer.passkeys }
        }
        // A confirmation for a passkey that is no longer there has nothing to confirm.
        if let asking, !isDeleting, !passkeys.contains(asking) { self.asking = nil }
    }
}

/// The app's way to a profile's passkeys: which store this launch may use
/// (`LocalPasskeyStorePolicy`), and the engine's, when one has attached.
@Observable
final class LocalPasskeysController {
    /// The engine's store for a profile (or a container), set at ready by an
    /// engine that has the calls and is signed for them. nil: no list.
    @ObservationIgnored var engineStore: ((Profile.ID) -> LocalPasskeyStoring)?
    /// What this launch may use. `.none` until the engine host says.
    @ObservationIgnored private(set) var choice = LocalPasskeyStorePolicy.Choice.none
    /// The fixture's passkeys, shared by every profile's sheet of a test launch.
    @ObservationIgnored private var fixture: FixtureLocalPasskeyStore?
    /// Changes when a store attaches: Settings then shows or hides the row.
    private(set) var revision = 0

    /// Set once the launch is known. A fixture that cannot be read is no list at all.
    func configure(choice: LocalPasskeyStorePolicy.Choice) {
        self.choice = choice
        if case .fixture(let path) = choice {
            fixture = FixtureLocalPasskeyStore(fileURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        } else {
            fixture = nil
        }
        revision += 1
    }

    func attach(engineStore: @escaping (Profile.ID) -> LocalPasskeyStoring) {
        self.engineStore = engineStore
        revision += 1
    }

    /// Settings shows the row: this launch has a store with passkeys to manage.
    var isOffered: Bool {
        _ = revision
        switch choice {
        case .engine: return engineStore != nil
        case .fixture: return fixture != nil
        case .none: return false
        }
    }

    /// The store for a profile's sheet. Never the engine's unless this
    /// launch may reach real passkeys.
    func store(for profile: Profile.ID) -> LocalPasskeyStoring {
        switch choice {
        case .engine: return engineStore?(profile) ?? UnavailableLocalPasskeyStore()
        case .fixture: return fixture ?? UnavailableLocalPasskeyStore()
        case .none: return UnavailableLocalPasskeyStore()
        }
    }

    func model(for profile: Profile.ID) -> LocalPasskeysModel {
        let isFixture: Bool
        if case .fixture = choice { isFixture = true } else { isFixture = false }
        return LocalPasskeysModel(store: store(for: profile), isFixture: isFixture)
    }
}

/// The keychain access groups this process is signed with.
enum SignedKeychainGroups {
    /// The profile authenticator's group ends in ".webauthn"
    /// (`<team>.<bundle id>.webauthn`): with it, the engine offers "this Mac".
    static let passkeyGroupSuffix = ".webauthn"

    static var current: [String] {
        CloudKitSyncAvailability.signedEntitlement("keychain-access-groups") as? [String] ?? []
    }

    static var hasPasskeyGroup: Bool { hasPasskeyGroup(in: current) }

    static func hasPasskeyGroup(in groups: [String]) -> Bool {
        groups.contains { $0.hasSuffix(passkeyGroupSuffix) }
    }
}
