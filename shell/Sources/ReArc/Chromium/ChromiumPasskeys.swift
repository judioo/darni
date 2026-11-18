#if REARC_CHROMIUM
import Darwin
import Foundation
import ReArcEngine
import SidebarModel

/// The engine's WebAuthn step channel (ABI 1.68, feature `webauthn_prompts`;
/// C-ABI.md "WebAuthn steps", engine patch `tab/097-webauthn-host-steps`).
/// Chromium's own dialog needs Browser UI a bridge tab does not have, so the
/// engine gives each step of a passkey or security key request to the shell,
/// and the shell's sheet answers. Looked up with `dlsym`, as the other calls
/// newer than this shell's header; JSON and scalars, no struct to mirror.
///
/// An engine without the feature or without both symbols has no channel:
/// such a request shows nothing and ends at the site's timeout, as before.
struct ChromiumPasskeyCalls {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, UInt32, UnsafePointer<CChar>?) -> Void
    typealias SetCallback = @convention(c) (Callback?, UnsafeMutableRawPointer?) -> Void
    typealias Respond = @convention(c) (UInt64, UInt32, UInt32, UnsafePointer<CChar>?) -> ReArcStatus

    static let symbols = ["ReArcEngineSetWebAuthnCallback", "ReArcWebAuthnRespond"]

    let setCallback: SetCallback
    let respond: Respond

    static func resolve() -> ChromiumPasskeyCalls? {
        guard let found = ChromiumSymbols.resolve(symbols) else { return nil }
        return ChromiumPasskeyCalls(setCallback: unsafeBitCast(found[0], to: SetCallback.self),
                                    respond: unsafeBitCast(found[1], to: Respond.self))
    }

    static var missingSymbols: [String] {
        ChromiumSymbols.missing(symbols)
    }
}

private let passkeyCallback: ChromiumPasskeyCalls.Callback = { context, request, tabID, phase, json in
    guard let context else { return }
    // The string is borrowed for the callback: decoded here. It can hold the
    // QR code's text, so it is never logged.
    let step = phase == 0 ? json.flatMap { PasskeyStep(json: String(cString: $0)) } : nil
    let refusal = phase == 1 ? json.flatMap { PasskeyRefusal(json: String(cString: $0)) } : nil
    MainActor.assumeIsolated {
        if let refusal {
            return ChromiumPasskeyChannel.note(refusal, request: request, tab: tabID)
        }
        ChromiumPasskeyChannel.handle(request: request, tab: tabID, ended: phase != 0, step: step,
                                      runtime: Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue())
    }
}

/// The one engine's passkey channel. Main thread, as every ABI call.
enum ChromiumPasskeyChannel {
    private(set) static var calls: ChromiumPasskeyCalls?
    /// Steps and ends received, answers sent: for logs and the self-test.
    private(set) static var events = 0
    private(set) static var replies = 0
    /// Requests the engine refused because nobody sees their page, and the last one's log line.
    private(set) static var refusals = 0
    private(set) static var lastRefusal = ""
    /// The requests whose first step went to the log.
    private static var logged: Set<UInt64> = []

    /// At `ready`, before any tab exists, so no request falls to the engine's no-host cancel.
    static func register(runtime: ChromiumRuntime, context: UnsafeMutableRawPointer) {
        guard runtime.capabilities.passkeyPrompts, let calls = ChromiumPasskeyCalls.resolve() else {
            let missing = ChromiumPasskeyCalls.missingSymbols
            ChromiumLog.info("passkeys: no step channel in this engine (feature \(runtime.capabilities.passkeyPrompts ? "advertised" : "not advertised")"
                + (missing.isEmpty ? "" : ", missing \(missing.joined(separator: ", "))") + "); a passkey request shows no sheet")
            return
        }
        self.calls = calls
        calls.setCallback(passkeyCallback, context)
    }

    /// A request of a page nobody sees: the engine refused it and it never had
    /// a sheet. One line at information level, so a launch without tracing
    /// shows the rule at work (security review AH-02).
    fileprivate static func note(_ refusal: PasskeyRefusal, request: UInt64, tab: UInt64) {
        refusals += 1
        lastRefusal = refusal.logLine(request: request, tab: tab)
        ChromiumLog.info(lastRefusal)
    }

    fileprivate static func handle(request: UInt64, tab: UInt64, ended: Bool, step: PasskeyStep?, runtime: ChromiumRuntime) {
        events += 1
        if ended {
            logged.remove(request)
        } else if let step, logged.insert(request).inserted {
            ChromiumLog.info(step.firstStepLogLine(request: request, tab: tab))
        }
        guard let engine = runtime.engine(forTab: tab) else {
            // A tab the shell does not know cannot show a sheet: the conservative answer, at once.
            if !ended { respond(request, .cancel) }
            return
        }
        if ended {
            ChromiumLog.trace("passkey request \(request) tab \(tab) ended")
            return engine.pagePrompts.endPasskey(id: request)
        }
        guard let step else {
            ChromiumLog.info("passkey request \(request) tab \(tab): a step this shell cannot read; cancelled")
            respond(request, .cancel)
            return engine.pagePrompts.endPasskey(id: request)
        }
        guard step.isFromWebPage else {
            // The engine cancels these itself; an engine that did not gets the same answer here.
            ChromiumLog.info("passkey request \(request) tab \(tab): not asked by a web page; cancelled")
            respond(request, .cancel)
            return engine.pagePrompts.endPasskey(id: request)
        }
        ChromiumLog.trace("passkey request \(request) tab \(tab) step \(step.kind) busy \(step.isBusy)")
        engine.pagePrompts.presentPasskey(id: request, step: step) { action in
            respond(request, action) == .rearcOK
        }
    }

    @discardableResult
    static func respond(_ request: UInt64, _ action: PasskeyAction) -> ReArcStatus {
        guard let calls else { return ReArcStatus(REARC_UNSUPPORTED) }
        let values = action.engineValues
        let status: ReArcStatus
        if let text = values.text {
            status = text.withCString { calls.respond(request, values.action, values.index, $0) }
        } else {
            status = calls.respond(request, values.action, values.index, nil)
        }
        replies += 1
        // `logName` never holds the PIN.
        if status == .rearcOK {
            ChromiumLog.trace("passkey reply \(request) \(action.logName) -> ok")
        } else {
            ChromiumLog.info("passkey reply \(request) \(action.logName) -> \(status.rearcName)")
        }
        return status
    }
}

extension ChromiumRuntime {
    /// Registered at `ready`, before any tab exists.
    func registerPasskeyChannel(context: UnsafeMutableRawPointer) {
        ChromiumPasskeyChannel.register(runtime: self, context: context)
    }
}
#endif
