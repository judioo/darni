#if REARC_CHROMIUM
import Darwin
import Foundation
import ReArcEngine
import SidebarModel

/// The engine's screen sharing channel (ABI 1.70, feature `display_capture`;
/// C-ABI.md "Screen sharing", engine patch `tab/101-display-capture-host-picker`).
/// A page's `getDisplayMedia()` reaches Chromium's own handler, whose picker
/// is a Views dialog on a browser window a bridge tab does not have; the
/// engine asks the shell what to share instead, and the shell's sheet
/// answers: one of its tabs, or a window or the screen, which the person then
/// chooses in the macOS picker the engine opens. What is shared shows from
/// `media_capture`; `ReArcTabStopDisplayCapture` ends it. Looked up with
/// `dlsym`, as the other calls newer than this shell's header; JSON and
/// scalars, no struct to mirror.
///
/// An engine without the feature or without all three symbols has no
/// channel: such a request fails at once, as it did before.
struct ChromiumScreenShareCalls {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64, UInt32, UnsafePointer<CChar>?) -> Void
    typealias SetCallback = @convention(c) (Callback?, UnsafeMutableRawPointer?) -> Void
    typealias Respond = @convention(c) (UInt64, UInt32, UInt64, Bool) -> ReArcStatus
    typealias Stop = @convention(c) (UInt64) -> ReArcStatus

    static let symbols = ["ReArcEngineSetDisplayCaptureCallback", "ReArcDisplayCaptureRespond", "ReArcTabStopDisplayCapture"]

    let setCallback: SetCallback
    let respond: Respond
    let stop: Stop

    static func resolve() -> ChromiumScreenShareCalls? {
        guard let found = ChromiumSymbols.resolve(symbols) else { return nil }
        return ChromiumScreenShareCalls(setCallback: unsafeBitCast(found[0], to: SetCallback.self),
                                        respond: unsafeBitCast(found[1], to: Respond.self),
                                        stop: unsafeBitCast(found[2], to: Stop.self))
    }

    static var missingSymbols: [String] {
        ChromiumSymbols.missing(symbols)
    }
}

private let screenShareCallback: ChromiumScreenShareCalls.Callback = { context, request, tabID, phase, json in
    guard let context else { return }
    // The string is borrowed for the callback: decoded here.
    let text = json.map { String(cString: $0) } ?? ""
    MainActor.assumeIsolated {
        ChromiumScreenShareChannel.handle(request: request, tab: tabID, phase: phase, json: text,
                                          runtime: Unmanaged<ChromiumRuntime>.fromOpaque(context).takeUnretainedValue())
    }
}

/// The one engine's screen sharing channel. Main thread, as every ABI call.
enum ChromiumScreenShareChannel {
    private(set) static var calls: ChromiumScreenShareCalls?
    /// Requests and ends received, answers and stops sent: for logs and the self-test.
    private(set) static var events = 0
    private(set) static var replies = 0
    private(set) static var stops = 0
    /// How the last request ended, in the log's words.
    private(set) static var lastOutcome = ""

    /// At `ready`, before any tab exists, so no request falls to the engine's no-host refusal.
    static func register(runtime: ChromiumRuntime, context: UnsafeMutableRawPointer) {
        guard runtime.capabilities.screenSharing, let calls = ChromiumScreenShareCalls.resolve() else {
            let missing = ChromiumScreenShareCalls.missingSymbols
            ChromiumLog.info("screen sharing: no channel in this engine (feature \(runtime.capabilities.screenSharing ? "advertised" : "not advertised")"
                + (missing.isEmpty ? "" : ", missing \(missing.joined(separator: ", "))") + "); a page's request to share fails")
            return
        }
        self.calls = calls
        calls.setCallback(screenShareCallback, context)
    }

    fileprivate static func handle(request: UInt64, tab: UInt64, phase: UInt32, json: String, runtime: ChromiumRuntime) {
        events += 1
        guard let engine = runtime.engine(forTab: tab) else {
            // A tab the shell does not know cannot show a sheet: the conservative answer, at once.
            if phase == 0 { respond(request, .cancel) }
            return
        }
        if phase != 0 {
            let outcome = ScreenShareOutcome(json: json)
            lastOutcome = outcome.logName
            // Tab numbers and kinds only: no address and no title.
            ChromiumLog.info("screen share request \(request) of tab \(tab) ended: \(outcome.logName)")
            return engine.pagePrompts.endScreenShare(id: request, outcome: outcome)
        }
        guard let asked = ScreenShareRequest(json: json), asked.isFromWebPage else {
            // The engine refuses a request no web page made itself; one this shell cannot read gets the same answer.
            ChromiumLog.info("screen share request \(request) of tab \(tab): unreadable or not asked by a web page; cancelled")
            respond(request, .cancel)
            return
        }
        ChromiumLog.info("screen share request \(request) of tab \(tab): sound \(asked.wantsAudio), window \(asked.offersWindow), "
            + "screen \(asked.offersScreen), system picker \(asked.usesSystemPicker), screen recording \(asked.screenRecording.rawValue)")
        engine.pagePrompts.presentScreenShare(id: request, asker: tab, request: asked) { choice in
            respond(request, choice) == .rearcOK
        }
    }

    @discardableResult
    static func respond(_ request: UInt64, _ choice: ScreenShareChoice) -> ReArcStatus {
        guard let calls else { return ReArcStatus(REARC_UNSUPPORTED) }
        let values = choice.engineValues
        let status = calls.respond(request, values.choice, values.targetTab, values.audio)
        replies += 1
        ChromiumLog.info("screen share reply \(request) \(choice.logName) -> \(status.rearcName)")
        return status
    }

    /// Ends everything the tab's page shares.
    @discardableResult
    static func stop(tab: UInt64) -> ReArcStatus {
        guard let calls else { return ReArcStatus(REARC_UNSUPPORTED) }
        let status = calls.stop(tab)
        stops += 1
        ChromiumLog.info("screen share stop tab \(tab) -> \(status.rearcName)")
        return status
    }
}

extension ChromiumRuntime {
    /// Registered at `ready`, before any tab exists.
    func registerScreenShareChannel(context: UnsafeMutableRawPointer) {
        ChromiumScreenShareChannel.register(runtime: self, context: context)
    }
}
#endif
