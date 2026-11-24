#if REARC_CHROMIUM
import Darwin
import Foundation
import ReArcEngine
import SidebarModel

/// The engine's "this Mac" passkey entry points (ABI 1.72, feature
/// `local_passkeys`; C-ABI.md "This Mac passkeys", engine patch
/// `tab/104-local-passkeys`). They are newer than the header this shell
/// builds against, so each is looked up with `dlsym` and typed here, as the
/// site permission calls are. The state crosses as JSON: there is no struct
/// to mirror.
struct ChromiumLocalPasskeyCalls {
    /// `void (*)(void* context, ReArcStatus status, uint64_t profile_id, const char* json)`
    typealias Completion = @convention(c) (UnsafeMutableRawPointer?, ReArcStatus, UInt64, UnsafePointer<CChar>?) -> Void
    /// `ReArcStatus ReArcProfileGetLocalPasskeys(uint64_t profile_id, completion, void* context)`
    typealias Get = @convention(c) (UInt64, Completion?, UnsafeMutableRawPointer?) -> ReArcStatus
    /// `ReArcStatus ReArcProfileDeleteLocalPasskey(uint64_t profile_id, const char* credential_id, completion, void* context)`
    typealias Delete = @convention(c) (UInt64, UnsafePointer<CChar>?, Completion?, UnsafeMutableRawPointer?) -> ReArcStatus

    static let symbols = ["ReArcProfileGetLocalPasskeys", "ReArcProfileDeleteLocalPasskey"]

    let get: Get
    let delete: Delete

    /// Both symbols, or nothing: half an interface is not used.
    static func resolve() -> ChromiumLocalPasskeyCalls? {
        guard let found = ChromiumSymbols.resolve(symbols) else { return nil }
        return ChromiumLocalPasskeyCalls(get: unsafeBitCast(found[0], to: Get.self),
                                         delete: unsafeBitCast(found[1], to: Delete.self))
    }

    static var missingSymbols: [String] { ChromiumSymbols.missing(symbols) }
}

/// One answer's receiver, retained from the call to its completion.
private final class LocalPasskeyReceiver {
    let receive: (ReArcStatus, String?) -> Void
    init(_ receive: @escaping (ReArcStatus, String?) -> Void) { self.receive = receive }
}

private let localPasskeyCompletion: ChromiumLocalPasskeyCalls.Completion = { context, status, _, json in
    guard let context else { return }
    let receiver = Unmanaged<LocalPasskeyReceiver>.fromOpaque(context).takeRetainedValue()
    // The string is borrowed for the callback: copied here.
    let text = json.map { String(cString: $0) }
    MainActor.assumeIsolated { receiver.receive(status, text) }
}

/// The engine's two calls. Main thread, as every ABI call.
final class ChromiumLocalPasskeyEngine {
    private unowned let runtime: ChromiumRuntime
    private let calls: ChromiumLocalPasskeyCalls

    init(runtime: ChromiumRuntime, calls: ChromiumLocalPasskeyCalls) {
        self.runtime = runtime
        self.calls = calls
    }

    private var isUsable: Bool { runtime.isReady && !runtime.isStopping }

    /// The raw call, for the self-test: the status the engine returned at
    /// once, and its completion's status and JSON when it accepted.
    func rawList(engineProfile: UInt64, receive: @escaping (ReArcStatus, String?) -> Void) -> ReArcStatus {
        guard isUsable else { return ReArcStatus(REARC_ENGINE_NOT_READY) }
        let receiver = Unmanaged.passRetained(LocalPasskeyReceiver(receive))
        let status = calls.get(engineProfile, localPasskeyCompletion, receiver.toOpaque())
        if status != .rearcOK { receiver.release() }  // Rejected: no completion will come.
        return status
    }

    func rawDelete(engineProfile: UInt64, id: String, receive: @escaping (ReArcStatus, String?) -> Void) -> ReArcStatus {
        guard isUsable else { return ReArcStatus(REARC_ENGINE_NOT_READY) }
        let receiver = Unmanaged.passRetained(LocalPasskeyReceiver(receive))
        let status = id.withCString { calls.delete(engineProfile, $0, localPasskeyCompletion, receiver.toOpaque()) }
        if status != .rearcOK { receiver.release() }
        return status
    }

    /// At ready: an engine with `local_passkeys`, in a launch that may reach
    /// real passkeys, becomes the store of Settings › Profiles › Passkeys on
    /// This Mac. Any other launch gets its fixture or nothing
    /// (`LocalPasskeyStorePolicy`), and the engine's calls are not attached
    /// at all.
    @MainActor
    static func attach(to model: BrowserViewModel, runtime: ChromiumRuntime) {
        let choice = LocalPasskeyStorePolicy.choice(ordinaryLaunch: runtime.isOrdinaryLaunch,
                                                    environment: ProcessInfo.processInfo.environment)
        model.localPasskeys.configure(choice: choice)
        guard choice == .engine else {
            ChromiumLog.info("local passkeys: this launch does not reach real passkeys (\(choice == .none ? "no list" : "a fixture's list"))")
            return
        }
        guard runtime.capabilities.localPasskeys, let calls = ChromiumLocalPasskeyCalls.resolve() else {
            let missing = ChromiumLocalPasskeyCalls.missingSymbols
            ChromiumLog.info("local passkeys: not in this engine (feature \(runtime.capabilities.localPasskeys ? "advertised" : "not advertised")"
                + (missing.isEmpty ? "" : ", missing \(missing.joined(separator: ", "))") + "); Settings has no list")
            return
        }
        guard SignedKeychainGroups.hasPasskeyGroup else {
            ChromiumLog.info("local passkeys: this build is not signed with the passkey group; Settings has no list")
            return
        }
        let engine = ChromiumLocalPasskeyEngine(runtime: runtime, calls: calls)
        model.localPasskeys.attach { [weak runtime] profile in
            ChromiumLocalPasskeyStore(engine: engine, runtime: runtime, profile: profile)
        }
    }
}

/// One profile's passkeys in the engine. The profile is opened for the call
/// when it is not open yet, as a tab of it would open it.
final class ChromiumLocalPasskeyStore: LocalPasskeyStoring {
    private let engine: ChromiumLocalPasskeyEngine
    private weak var runtime: ChromiumRuntime?
    private let profile: Profile.ID

    init(engine: ChromiumLocalPasskeyEngine, runtime: ChromiumRuntime?, profile: Profile.ID) {
        self.engine = engine
        self.runtime = runtime
        self.profile = profile
    }

    func list(_ receive: @escaping (LocalPasskeyAnswer) -> Void) {
        withEngineProfile(receive) { [engine] id in
            engine.rawList(engineProfile: id) { status, json in
                receive(LocalPasskeyAnswer(engineStatus: status, json: json))
            }
        }
    }

    func delete(id: String, _ receive: @escaping (LocalPasskeyAnswer) -> Void) {
        guard LocalPasskey.isValidID(id) else { return receive(.failed) }
        withEngineProfile(receive) { [engine] engineProfile in
            let status = engine.rawDelete(engineProfile: engineProfile, id: id) { status, json in
                // The site and the account stay out of the log.
                ChromiumLog.info("local passkeys: profile \(engineProfile) delete: \(status.rearcName)")
                receive(LocalPasskeyAnswer(engineStatus: status, json: json))
            }
            if status != .rearcOK { ChromiumLog.info("local passkeys: profile \(engineProfile) delete refused: \(status.rearcName)") }
            return status
        }
    }

    /// Runs `call` with the engine's ID of the profile. A profile that
    /// cannot be opened, or a call the engine refuses at once (then no
    /// completion comes), answers `failed`.
    private func withEngineProfile(_ receive: @escaping (LocalPasskeyAnswer) -> Void, _ call: @escaping (UInt64) -> ReArcStatus) {
        guard let runtime else { return receive(.failed) }
        runtime.withEngineProfile(.persistent(profile)) { id in
            guard let id, call(id) == .rearcOK else { return receive(.failed) }
        }
    }
}
#endif
