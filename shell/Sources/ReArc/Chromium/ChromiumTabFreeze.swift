#if REARC_CHROMIUM
import Darwin
import Foundation
import ReArcEngine

/// The engine's tab freezing calls (ABI 1.71, feature `tab_freeze`; C-ABI.md
/// "Tab freezing", engine patch `tab/103-tab-freeze`). A hidden page is frozen
/// before it is unloaded: it stays in memory, runs no script and no timer, and
/// goes on at once when its tab is shown. The freezing is Chromium's own
/// (a freezing vote, with every reason Chromium has not to freeze a page);
/// the engine refuses what Chromium does not know about a tab of the shell's
/// (the shared tab, a passkey or permission request, a download).
/// Looked up with `dlsym`, as the other calls newer than this shell's header;
/// scalars only, no struct to mirror.
///
/// An engine without the feature or without all three symbols freezes
/// nothing: its pages run until they are unloaded.
struct ChromiumTabFreezeCalls {
    typealias Ask = @convention(c) (UInt64) -> ReArcStatus
    typealias State = @convention(c) (UInt64, UnsafeMutablePointer<Bool>?, UnsafeMutablePointer<Bool>?) -> ReArcStatus

    static let symbols = ["ReArcTabFreeze", "ReArcTabUnfreeze", "ReArcTabGetFreezeState"]

    let freeze: Ask
    let unfreeze: Ask
    let state: State

    static func resolve() -> ChromiumTabFreezeCalls? {
        guard let found = ChromiumSymbols.resolve(symbols) else { return nil }
        return ChromiumTabFreezeCalls(freeze: unsafeBitCast(found[0], to: Ask.self),
                                      unfreeze: unsafeBitCast(found[1], to: Ask.self),
                                      state: unsafeBitCast(found[2], to: State.self))
    }

    static var missingSymbols: [String] {
        ChromiumSymbols.missing(symbols)
    }

    /// Looked up at the first use: the engine is loaded long before a tab can be frozen.
    static let shared: ChromiumTabFreezeCalls? = resolve()
}
#endif
