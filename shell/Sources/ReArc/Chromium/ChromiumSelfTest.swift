#if REARC_CHROMIUM
import AppKit
import CryptoKit
import Foundation
import Network
import PDFKit
import ScreenCaptureKit
import ReArcEngine
import SidebarModel
import SwiftUI

/// `--rearc-selftest`: drives ChromiumEngines through the real shell code
/// paths (engine, SwiftUI host view, boost mapping, script evaluation with
/// document identity, boost editor/picker over page messages, zoom, two
/// windows sharing a tab, named and off-the-record profiles, trusted
/// navigation, the real ChromiumShell windows, shutdown) and exits 0 only if
/// every step passed and the engine
/// shut down cleanly. Optional steps run only when the engine advertises
/// them; an older engine logs ABI-GAP lines instead.
final class ChromiumSelfTest {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let watchdogSeconds = 300.0
    static let titleA = "ReArc Selftest A"
    static let titleData = "ReArc Selftest Data"
    static let boostPackageID = UUID(uuidString: "5E1F7E57-B005-4000-8000-000000000001")!

    private let runtime: ChromiumRuntime
    private var failures: [String] = []
    /// Why the client-certificate fixture is or is not running (set before the engine starts).
    var mutualTLSNote = ""
    private var server: LoopbackFixtureServer?
    /// The loopback fixture's origin ("http://127.0.0.1:<port>").
    private var serverBase = ""
    /// Wave 32: the live video's compositor and page frame counters both advanced.
    private(set) var liveFramesAdvancing = false
    private var engine: ChromiumEngine?
    private var window: NSWindow?
    private var shutdownStatus: ReArcStatus?
    private let started = Date()
    /// The blocking fixture's page loads so far: each load has a number of its own (`SelfTestBlockingFixture`).
    private var blockingRun = 0

    init(runtime: ChromiumRuntime) {
        self.runtime = runtime
    }

    func start() {
        ChromiumLog.traceEnabled = true
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.watchdogSeconds) {
            print("SELFTEST FAIL: watchdog fired after \(Int(Self.watchdogSeconds)) s")
            fflush(stdout)
            _exit(124)
        }
        Task { @MainActor in
            do {
                if SelfTestBlockingFixture.isColdLaunch(CommandLine.arguments) {
                    try await self.contentBlockingColdLaunch()
                } else {
                    try await self.run()
                }
            } catch {
                self.failures.append(String(describing: error))
                self.log("FAIL \(error)")
            }
            self.shutdown()
        }
    }

    func exitCode(runResult: Int32) -> Int32 {
        log("ReArcEngineRun returned \(runResult)")
        let clean = runResult == 0 && shutdownStatus == .rearcOK && runtime.shutdownCompleted
        if failures.isEmpty && clean {
            log("RESULT PASS")
            return 0
        }
        log("RESULT FAIL (failures: \(failures.count), shutdown: \(shutdownStatus?.rearcName ?? "none"), run: \(runResult))")
        return 1
    }

    private func log(_ message: String) {
        print(String(format: "[selftest %6.2fs] ", Date().timeIntervalSince(started)) + message)
        fflush(stdout)
    }

    private func check(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw Failure(description: message()) }
    }

    @MainActor
    private func wait(_ label: String, timeout: TimeInterval = 15, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                throw Failure(description: "timed out waiting for \(label) [\(engineState)]")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private func waitAsync(_ label: String, timeout: TimeInterval = 10, until condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline {
                throw Failure(description: "timed out waiting for \(label) [\(engineState)]")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private var engineState: String {
        engine.map {
            "tab \($0.tabID) url \($0.currentURL?.absoluteString ?? "nil") title \($0.pageTitle ?? "nil") "
                + "loading \($0.isLoading) progress \($0.loadProgress) error \($0.lastError ?? "none")"
        } ?? "no engine"
    }

    /// Runs `body`, which must fail with a script-evaluation error.
    @MainActor
    private func expectEvaluationError(_ label: String, _ body: () async throws -> Any) async throws -> ChromiumScriptError {
        do {
            let value = try await body()
            throw Failure(description: "\(label): expected an evaluation error, got \(value)")
        } catch let error as ChromiumScriptError {
            return error
        }
    }

    @MainActor
    private func run() async throws {
        let capabilities = runtime.capabilities
        log("engine ABI \(ReArcEngineABIVersion()), bridge \(String(cString: ReArcEngineBridgeVersion())), Chromium \(String(cString: ReArcEngineVersion())), default profile \(runtime.defaultProfileID)")
        log("capabilities: \(capabilities.summary)")
        switch runtime.keychainMode {
        case .system:
            log("keychain: macOS Keychain ('\(capabilities.safeStorageKeychainItem)')")
        case .devMock:
            log("keychain: MOCK (--use-mock-keychain, development bundle; cookies not Keychain-encrypted)")
        case .devMockRefused:
            log("keychain: macOS Keychain (mock keychain refused in a release build)")
        }
        let features = ["native_view", "navigation", "navigation_extended", "media_session", "media_metadata_snapshot",
                        "favicon", "security_state", "user_scripts", "script_evaluation", "link_peek",
                        "snapshot_viewport", "snapshot_full_page", "pip_control", "pip_native",
                        "profiles", "profile_off_the_record", "script_evaluation_identity", "page_zoom",
                        "isolated_page_messages", "rearc_safe_storage_branding", "os_permission_shutdown",
                        "shutdown_pending_closes", "profile_directory", "webui_daily_pages", "history_recording",
                        "password_autofill", "find_in_page", "downloads", "javascript_dialogs", "file_chooser",
                        "permission_prompts", "context_menu", "password_prompts", "history_query",
                        "dangerous_downloads", "tab_discard", "search_autocomplete", "html_fullscreen", "printing",
                        "page_drops", "picture_in_picture", "extension_tab_helpers", "extension_install_prompts",
                        "extension_actions", "autofill_suggestions", "password_leak_detection", "extension_windows",
                        "autofill_save_prompts", "http_auth", "link_open_requests"]
        let foreground = ChromiumLaunchArguments.selfTestForegroundSwitches.filter(CommandLine.arguments.contains)
        log("renderer foreground switches (self-test only): "
            + ChromiumLaunchArguments.selfTestForegroundSwitches.joined(separator: " ")
            + "; app active \(NSApp.isActive)\(foreground.isEmpty ? "" : "; also on the command line")")
        log("features: " + features.map { "\($0)=\(ReArcEngineHasFeature($0) ? 1 : 0)" }.joined(separator: " "))
        try check(runtime.defaultProfileID != 0, "ready delivered a zero default profile")
        // 0. early_window (ABI 1.45): the application-exists stage ran inside Run, before ready.
        if capabilities.earlyWindow {
            try check(runtime.earlyWindowAt != nil, "early_window advertised but its callback never ran")
            let lead = ((runtime.readyAt ?? 0) - (runtime.earlyWindowAt ?? .infinity)) * 1000
            try check(lead > 0, "the early_window callback did not run before ready")
            log(String(format: "PASS early_window callback ran once, %.0f ms before ready", lead))
        } else {
            log("ABI-GAP early_window not advertised (ABI minor \(capabilities.abiMinorVersion.map(String.init) ?? "absent") < 45): "
                + "the browser window waits for ready")
        }

        // 1. Tab creation through the shell engine (shell UUIDs map to engine uint64 IDs).
        let shellTabID = UUID()
        let engine = ChromiumEngine(
            runtime: runtime,
            context: EngineProfileContext(profileID: UUID()),
            role: .tab,
            shellID: shellTabID
        )
        self.engine = engine
        try check(await engine.waitForTab(), "ReArcTabCreate returned no tab (\(engine.lastError ?? "no error"))")
        log("PASS tab created: shell \(shellTabID) -> engine tab \(engine.tabID), \(engine.profileKey) -> engine profile \(engine.engineProfileID)")
        try await wait("tab.created snapshot") { engine.contentGeneration != 0 }
        log("PASS tab.created event: content_generation \(engine.contentGeneration)")

        // 1b. Wave 27: the leak check off before any sign-in, so nothing reaches Google's leak service.
        try leakDetectionChecks()

        // 2. data: URL with a known title (trusted navigation, ABI 1.5 navigation_extended).
        let dataURL = URL(string: "data:text/html,<title>\(Self.titleData)</title>".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)!
        let dataStatus = engine.navigateNow(dataURL)
        if capabilities.navigationExtended {
            try check(dataStatus == .rearcOK, "data: URL rejected synchronously: \(dataStatus.rearcName)")
            // The first renderer starts cold; under a heavy engine build that alone took over 15 s (wave 28).
            try await wait("data: commit with title '\(Self.titleData)'", timeout: 45) {
                engine.currentURL?.scheme == "data" && engine.pageTitle == Self.titleData
            }
            log("PASS data: URL committed with title '\(engine.pageTitle ?? "")'")
            if capabilities.scriptEvaluation {
                let title = try await engine.evaluate("document.title", in: .page)
                try check(title as? String == Self.titleData, "data: document.title evaluated to \(title)")
                log("PASS evaluation on the data: document (main world): document.title = '\(title)'")
            }
        } else {
            log("ABI-GAP data: URL navigation rejected synchronously: \(dataStatus.rearcName) (engine lacks navigation_extended); using a loopback http fixture instead")
            try check(dataStatus == ReArcStatus(REARC_INVALID_URL), "unexpected data: URL status \(dataStatus.rearcName)")
        }

        let server = try LoopbackFixtureServer()
        self.server = server
        let port = try await server.start()
        let base = "http://127.0.0.1:\(port)"
        serverBase = base
        log("fixture server on \(base)")
        // Shell tabs load before they are first shown (background/adopted tabs), so try that first.
        engine.load(URL(string: "\(base)/a")!)
        var loadedHidden = true
        do {
            try await wait("hidden-tab title event '\(Self.titleA)'", timeout: 8) { engine.pageTitle == Self.titleA }
        } catch {
            loadedHidden = false
            log("NOTE never-attached (hidden) tab did not finish loading within 8 s; continuing after attach")
        }
        if loadedHidden {
            try await wait("page A load stop") { !engine.isLoading }
            log("PASS title event '\(engine.pageTitle ?? "")' url \(engine.currentURL?.absoluteString ?? "nil") (hidden tab)")
        }

        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]

        // 3. Attach through the SwiftUI NSViewRepresentable host in a registered window.
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 900, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "ReArc Chromium selftest"
        window.contentView = NSHostingView(rootView: engine.makeView().frame(minWidth: 400, minHeight: 300))
        self.window = window
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try await wait("view attachment") { engine.attachmentID != nil }
        let host = window.contentView?.firstDescendant(ofType: ChromiumHostView.self)
        let nativeParented = host?.subviews.isEmpty == false
        try check(nativeParented, "attached NSView is not parented in the host view")
        log("PASS view attached: lease \(engine.attachmentID ?? 0), host \(host.map { NSStringFromRect($0.frame) } ?? "-"), scale \(window.backingScaleFactor)")
        if !loadedHidden {
            do {
                try await wait("title event '\(Self.titleA)' after attach") { engine.pageTitle == Self.titleA }
            } catch {
                if runtime.keychainMode != .devMock, capabilities.navigationExtended {
                    // Cookie access for http(s) waits for the Safe Storage key; data: needs no cookies.
                    log("KEYCHAIN-STALL first http load still loading (progress \(engine.loadProgress)) ~23 s after it started, "
                        + "while the cookie-free data: document committed. With the real macOS Keychain this matches the "
                        + "'\(capabilities.safeStorageKeychainItem)' read waiting on Keychain authorization "
                        + "(C-ABI.md 'First-load and Keychain findings'). Grant access and rerun, or use --dev-mock-keychain "
                        + "for development bundles.")
                }
                throw error
            }
            try await wait("page A load stop") { !engine.isLoading }
            log("PASS title event '\(engine.pageTitle ?? "")' url \(engine.currentURL?.absoluteString ?? "nil") (after attach)")
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        // 3b. Favicon (ABI services kind 0 + ReArcFaviconGet): page A declares /favicon.png.
        if ReArcEngineHasFeature("favicon") {
            try await wait("favicon event and ReArcFaviconGet PNG", timeout: 15) { engine.faviconData != nil }
            let icon = engine.faviconData ?? Data()
            try check(Array(icon.prefix(4)) == pngSignature, "favicon is not a PNG (\(icon.count) bytes)")
            let (staleStatus, staleData) = engine.fetchFavicon(ref: "rearc-selftest-stale-ref")
            try check(staleStatus != .rearcOK && staleData == nil, "stale favicon ref returned \(staleStatus.rearcName)")
            log("PASS favicon: icon_ref \(engine.faviconRef ?? "-") -> ReArcFaviconGet \(icon.count)-byte PNG; "
                + "stale ref -> \(staleStatus.rearcName)")
        } else {
            log("ABI-GAP favicon not advertised: sidebar rows keep letter tokens on Chromium")
        }
        let png = try await engine.captureSnapshot(scope: .visible)
        try check(png.count > 24 && Array(png.prefix(4)) == pngSignature, "viewport snapshot is not a PNG (\(png.count) bytes)")
        let width = png[16..<20].reduce(0) { $0 << 8 | UInt32($1) }
        let height = png[20..<24].reduce(0) { $0 << 8 | UInt32($1) }
        let snapshotURL = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-viewport.png")
        try? png.write(to: snapshotURL)
        log("PASS viewport snapshot: \(png.count) bytes, \(width)x\(height) PNG (\(snapshotURL.path))")

        // 5. Boost: install, then navigate; the engine defers the navigation until the install completes.
        let boost = BoostRuntimeEntry(
            packageID: Self.boostPackageID,
            order: 0,
            hostScope: [BoostHostRule(host: "127.0.0.1", hostMatch: .exact, pathPrefix: "/boost", schemes: ["http"])],
            css: "body { background: rgb(1, 2, 3) !important; }",
            cssRules: [BoostCSSRule(id: "bg", css: "body { background: rgb(1, 2, 3) !important; }")],
            js: "globalThis.rearcBoostSecret = 'isolated'; document.documentElement.dataset.rearcBoost = 'js';",
            scriptUserEnabled: true
        )
        let installsBefore = engine.boostInstallCount
        engine.installBoosts([boost])
        engine.load(URL(string: "\(base)/boost")!)
        try await wait("boost install acknowledgement") { engine.boostInstallCount > installsBefore }
        log("PASS boost plan acknowledged (navigations deferred behind install: \(engine.navigationsDeferredForBoosts))")
        try await wait("boosted page title", timeout: 15) {
            guard let title = engine.pageTitle else { return false }
            return title.hasPrefix("boost-ok") || title.hasPrefix("boost-fail")
        }
        let boostTitle = engine.pageTitle ?? ""
        try check(boostTitle == "boost-ok:js:rgb(1, 2, 3):isolated", "boost title '\(boostTitle)'")
        log("PASS boost JS + CSS applied in an isolated world: '\(boostTitle)'")

        // 6. Back / forward.
        try await wait("canGoBack") { engine.canGoBack }
        engine.goBack()
        try await wait("back to /a") { engine.currentURL?.path == "/a" && engine.pageTitle == Self.titleA && !engine.isLoading }
        try await wait("canGoForward") { engine.canGoForward }
        log("PASS back: \(engine.currentURL?.absoluteString ?? "") '\(engine.pageTitle ?? "")' canGoForward=\(engine.canGoForward)")
        engine.goForward()
        try await wait("forward to /boost") {
            engine.currentURL?.path == "/boost" && engine.pageTitle?.hasPrefix("boost-ok") == true && !engine.isLoading
        }
        log("PASS forward: \(engine.currentURL?.absoluteString ?? "") '\(engine.pageTitle ?? "")'")

        // 7. Media surface: mute is independent of sessions. PiP without a video:
        //    invalid_state with the ABI 1.30 callback, unsupported before it.
        engine.setMuted(true)
        try await wait("muted media event", timeout: 5) { engine.isMuted }
        let pip = engine.requestPictureInPicture()
        let expectedPiP = ReArcStatus(capabilities.pictureInPicture ? REARC_INVALID_STATE : REARC_UNSUPPORTED)
        try check(pip == expectedPiP, "PiP on a page without video returned \(pip.rearcName), expected \(expectedPiP.rearcName)")
        let media = engine.mediaState
        log("PASS mute observed via media event (metadata title \(media.title ?? "nil") artist \(media.artist ?? "nil") album \(media.album ?? "nil")); "
            + "PiP without a video -> \(pip.rearcName)\(capabilities.pictureInPicture ? "" : " (not advertised)")")

        // 8-10. Script evaluation, cancellation and the Chromium boost editor/picker.
        if capabilities.scriptEvaluation {
            try await scriptEvaluationChecks(engine: engine)
            try await cancellationOnNavigationCheck(engine: engine, base: base)
            try await boostEditorChecks(engine: engine, host: host)
            if capabilities.scriptEvaluationIdentity {
                try await identityMismatchCheck(engine: engine, base: base)
            } else {
                log("ABI-GAP script_evaluation_identity not advertised: results are checked by content generation only")
            }
        } else {
            log("ABI-GAP script_evaluation not advertised: boost editor and element picker stay WebKit-only")
        }

        // 11. Page zoom round trip, and the picker's zoom-corrected coordinates.
        if capabilities.pageZoom {
            try await zoomChecks(engine: engine)
        } else {
            log("ABI-GAP page_zoom not advertised: zoom commands are inert on Chromium")
        }

        // 12. Isolated-world page messages (boost and editor worlds), never the main world.
        if capabilities.isolatedPageMessages, capabilities.scriptEvaluation {
            try await pageMessageChecks(engine: engine, window: window)
        } else {
            log("ABI-GAP isolated_page_messages not advertised: the picker uses the native overlay only")
        }

        // 12b. Find in page (ABI 1.16) through the shell's find bar model, on the attached tab.
        if capabilities.findInPage {
            try await findInPageChecks(engine: engine, base: base)
        } else {
            log("ABI-GAP find_in_page not advertised (ABI minor \(capabilities.abiMinorVersion.map(String.init) ?? "absent") < 16): Cmd+F is hidden on Chromium")
        }

        // 12c. Downloads (ABI 1.17) into a temporary policy directory, through the tray's controller.
        if capabilities.downloads {
            try await downloadChecks(engine: engine, base: base)
        } else {
            log("ABI-GAP downloads not advertised (ABI minor \(capabilities.abiMinorVersion.map(String.init) ?? "absent") < 17): the tray shows WebKit downloads only")
        }

        // 12d. Host prompt channels (ABI 1.18–1.22) through the tab's PagePromptCenter.
        try await promptChannelChecks(engine: engine, base: base, window: window)

        // 12e. Wave 24: printing (ABI 1.28) and drops into pages (ABI 1.29) on the attached tab.
        if capabilities.printing {
            try await printingChecks(engine: engine, base: base, window: window)
        } else {
            log("ABI-GAP printing not advertised (ABI minor \(capabilities.abiMinorVersion.map(String.init) ?? "absent") < 28): Print and Export as PDF are hidden on Chromium")
        }
        if capabilities.pageDrops {
            try await pageDropChecks(engine: engine, base: base, window: window)
        } else {
            log("ABI-GAP page_drops not advertised (ABI minor \(capabilities.abiMinorVersion.map(String.init) ?? "absent") < 29): drops into pages stay aborted")
        }
        engine.load(URL(string: "\(base)/a")!)
        try await wait("page A after the wave 24 page checks") { engine.pageTitle == Self.titleA && !engine.isLoading }

        // 12f. Wave 25: this bundle's iCloud sync gate (never creates a CKContainer unentitled).
        try syncGateChecks()

        // 13. Two windows: the tab's one lease moves to a second window and back.
        try await twoWindowChecks(engine: engine, first: window)

        // 14. Trusted WebUI / view-source navigation and the settings entry point.
        if capabilities.navigationExtended {
            try await trustedNavigationChecks(engine: engine, base: base)
        }

        // 14a. Two-finger swipe back and forward: the edge probe on pages built from
        // custom elements and shadow roots, and a swipe through the real event path.
        if capabilities.scriptEvaluation {
            try await historySwipeChecks(engine: engine, base: base, window: window)
        }

        // 15. Named profiles are isolated; an off-the-record child sees neither; teardown order.
        if capabilities.profiles {
            try await profileChecks(base: base)
            if capabilities.profileDirectory {
                try await profileDirectoryChecks()
            } else {
                log("ABI-GAP profile_directory not advertised: the startup Default directory is not adopted")
            }
        } else {
            log("ABI-GAP profiles not advertised: every shell profile shares the startup profile")
        }

        // 16. The real shell: browser windows, split view, peek, Little Arc, private
        //     windows and zoom commands through BrowserViewModel; closing every
        //     window leaves the app running.
        try await shellChecks(base: base)

        // 17. Every accepted evaluation completed once and released its context.
        try await wait("evaluations drained") { engine.evaluationsOutstanding == 0 }
        try check(runtime.liveScriptContexts == 0, "\(runtime.liveScriptContexts) evaluation context(s) never released")
        try check(runtime.liveProfileContexts == 0, "\(runtime.liveProfileContexts) profile request context(s) never released")
        try check(runtime.liveCommandBarContexts == 0, "\(runtime.liveCommandBarContexts) command-bar call context(s) never released")
        log("PASS every evaluation, profile request and command-bar call context released exactly once "
            + "(live script contexts: \(runtime.liveScriptContexts), profile contexts: \(runtime.liveProfileContexts), "
            + "command-bar contexts: \(runtime.liveCommandBarContexts))")

        // 18. A quit a page vetoes leaves the runtime active; a page asked for during it waits for Chromium.
        //     Last: the quit closes tabs ahead of the vetoing one (every one before bridge 0.71.0).
        if capabilities.javascriptDialogs {
            try await vetoedQuitChecks(engine: engine, base: base, window: window)
        }

        // 19. Blocking at a cold launch (security CB-02): another process, a restored tab on
        //     the blocking fixture. After everything that needs this window in front.
        try await contentBlockingColdLaunchChecks()
    }

    // MARK: Script evaluation

    @MainActor
    private func scriptEvaluationChecks(engine: ChromiumEngine) async throws {
        // Isolated vs main world on the boosted page: globals are per world, the DOM is shared.
        let probe = """
        (function(){ return {
          secret: typeof rearcBoostSecret === 'undefined' ? null : rearcBoostSecret,
          pageFunction: typeof check,
          marker: document.documentElement.dataset.rearcBoost || null
        }; })()
        """
        let boostWorld = try await engine.evaluate(probe, in: .boost(Self.boostPackageID)) as? [String: Any]
        let pageWorld = try await engine.evaluate(probe, in: .page) as? [String: Any]
        let editorWorld = try await engine.evaluate(probe, in: .editor) as? [String: Any]
        try check(boostWorld?["secret"] as? String == "isolated" && boostWorld?["pageFunction"] as? String == "undefined",
                  "boost world probe: \(String(describing: boostWorld))")
        try check(pageWorld?["secret"] is NSNull && pageWorld?["pageFunction"] as? String == "function",
                  "page world probe: \(String(describing: pageWorld))")
        try check(editorWorld?["secret"] is NSNull && editorWorld?["pageFunction"] as? String == "undefined",
                  "editor world probe: \(String(describing: editorWorld))")
        try check([boostWorld, pageWorld, editorWorld].allSatisfy { $0?["marker"] as? String == "js" },
                  "worlds disagree on the shared DOM marker")
        log("PASS worlds: boost \(Self.boostPackageID.uuidString.lowercased()) sees rearcBoostSecret='isolated'; "
            + "main world sees page function check() but not the boost global; editor world sees neither; all share the DOM")
        _ = try await engine.evaluate("(function(){ window.__rearcMainProbe = 42; return window.__rearcMainProbe; })()", in: .page)
        let leaked = try await engine.evaluate("typeof window.__rearcMainProbe", in: .editor) as? String
        try check(leaked == "undefined", "main-world global visible in the editor world (\(leaked ?? "nil"))")
        log("PASS main-world global (window.__rearcMainProbe) is invisible to the editor isolated world")

        // JSON results are decoded, never double-encoded.
        let object = try await engine.evaluate(
            "({ n: 1.5, s: 'q\"uote', a: [1, true, null], o: { k: 'v' }, u: undefined })", in: .editor
        ) as? [String: Any]
        let array = object?["a"] as? [Any]
        try check(object?["n"] as? Double == 1.5 && object?["s"] as? String == "q\"uote"
                  && array?.count == 3 && array?[0] as? Int == 1 && array?[1] as? Bool == true && array?[2] is NSNull
                  && (object?["o"] as? [String: Any])?["k"] as? String == "v" && object?["u"] == nil,
                  "object result decoded as \(String(describing: object))")
        let string = try await engine.evaluate("'plain string'", in: .editor)
        try check(string as? String == "plain string", "string result decoded as \(string)")
        let undefinedValue = try await engine.evaluate("undefined", in: .editor)
        try check(undefinedValue is NSNull, "undefined decoded as \(undefinedValue)")
        let promised = try await engine.evaluate("Promise.resolve([3, 2, 1])", in: .page) as? [Int]
        try check(promised == [3, 2, 1], "awaited Promise decoded as \(String(describing: promised))")
        log("PASS JSON results: nested object/array, quoted string -> String, undefined -> null, awaited Promise -> [3, 2, 1]")

        // A thrown exception and a rejected Promise report script_error with structured details.
        let thrown = try await expectEvaluationError("exception") {
            try await engine.evaluate("(function(){ throw new Error('selftest-boom'); })()", in: .editor)
        }
        guard case .script(let thrownInfo) = thrown,
              thrownInfo.message.contains("selftest-boom") || thrownInfo.detailsJSON?.contains("selftest-boom") == true else {
            throw Failure(description: "exception reported as \(thrown)")
        }
        log("PASS exception -> script_error code '\(thrownInfo.code)' message '\(thrownInfo.message)' details \(thrownInfo.detailsJSON.map { String($0.prefix(160)) } ?? "none")")
        let rejected = try await expectEvaluationError("rejected Promise") {
            try await engine.evaluate("Promise.reject(new Error('selftest-reject'))", in: .page)
        }
        guard case .script(let rejectedInfo) = rejected else {
            throw Failure(description: "rejected Promise reported as \(rejected)")
        }
        log("PASS rejected Promise -> script_error '\(rejectedInfo.message)'")

        // A never-settling Promise hits the deadline; the tab still evaluates afterwards.
        let timeoutStart = Date()
        let timedOut = try await expectEvaluationError("timeout") {
            try await engine.evaluate("new Promise(function(){})", in: .editor, timeoutMS: 300)
        }
        let timeoutElapsed = Date().timeIntervalSince(timeoutStart)
        try check(timedOut == .timeout, "never-settling Promise reported as \(timedOut)")
        let after = try await engine.evaluate("1 + 1", in: .editor)
        try check(after as? Int == 2, "evaluation after timeout returned \(after)")
        log(String(format: "PASS timeout: 300 ms deadline -> timeout after %.2f s; next evaluation OK (1 + 1 = 2)", timeoutElapsed))
    }

    @MainActor
    private func cancellationOnNavigationCheck(engine: ChromiumEngine, base: String) async throws {
        let documentBefore = engine.currentDocumentIdentity
        let pending = Task { @MainActor in
            try await engine.evaluate(
                "new Promise(function(resolve){ setTimeout(function(){ resolve('late'); }, 8000); })",
                in: .page,
                timeoutMS: 20000
            )
        }
        try await wait("evaluation accepted", timeout: 5) { engine.evaluationInFlight }
        let navigationStart = Date()
        engine.load(URL(string: "\(base)/a")!)
        let outcome = await pending.result
        let elapsed = Date().timeIntervalSince(navigationStart)
        guard case .failure(let error) = outcome, error as? ChromiumScriptError == .cancelled else {
            throw Failure(description: "evaluation pending across navigation ended with \(outcome)")
        }
        log(String(format: "PASS cross-document navigation cancelled the pending evaluation after %.2f s (status cancelled)", elapsed))
        try await wait("page A after cancellation") {
            engine.currentURL?.path == "/a" && engine.pageTitle == Self.titleA && !engine.isLoading
        }
        let title = try await engine.evaluate("document.title", in: .page)
        let documentAfter = engine.currentDocumentIdentity
        try check(title as? String == Self.titleA, "fresh evaluation after navigation returned \(title)")
        if runtime.capabilities.scriptEvaluationIdentity {
            guard let documentBefore, let documentAfter, !documentAfter.isSameDocument(as: documentBefore) else {
                throw Failure(description: "document identity did not change across navigation (\(String(describing: documentBefore)) -> \(String(describing: documentAfter)))")
            }
        }
        log("PASS fresh evaluation on the new document: '\(title)' (document \(documentBefore.map { "\($0.documentGeneration)" } ?? "?") -> \(documentAfter.map { "\($0.documentGeneration)" } ?? "?"))")
    }

    // MARK: Boost editor and picker

    @MainActor
    private func boostEditorChecks(engine: ChromiumEngine, host: ChromiumHostView?) async throws {
        try check(engine.supportsBoostEditor, "ChromiumEngine does not offer the boost editor")
        engine.setBoostEditorOpen(true)
        engine.setBoostPickerMode(true)
        if engine.usesPickerOverlay {
            try check(host?.pickerOverlay != nil && host?.subviews.last === host?.pickerOverlay,
                      "picker overlay is not installed above the Chromium view")
        } else {
            // http(s) with page messages: the page's own input picks in the editor world.
            try check(host?.pickerOverlay == nil, "picker overlay installed although page messages carry picks")
        }
        let center = try await engine.evaluate(
            "(function(){ var r = document.querySelector('h1').getBoundingClientRect(); return { x: r.left + 20, y: r.top + r.height / 2 }; })()",
            in: .page
        ) as? [String: Double]
        guard let x = center?["x"], let y = center?["y"] else {
            throw Failure(description: "could not locate page A's <h1>: \(String(describing: center))")
        }
        var picked: PickedElementSnapshot?
        engine.onBoostEditorPick = { picked = $0 }
        // The overlay's mouseDown path, at view (= CSS) coordinates inside page A's <h1>.
        engine.pickerClick(at: CGPoint(x: x, y: y))
        try await wait("picker pick", timeout: 10) { picked != nil }
        try check(picked?.descriptor.tag == "h1", "picker picked \(String(describing: picked?.descriptor))")
        let bounds = picked.map { String(format: "%.0fx%.0f at %.0f,%.0f", $0.bounds.width, $0.bounds.height, $0.bounds.x, $0.bounds.y) } ?? "-"
        log(String(format: "PASS picker: view hit (%.0f,%.0f) -> editor-world snapshotAt -> ", x, y)
            + "<\(picked?.descriptor.tag ?? "")> path \(picked?.descriptor.structuralPath.joined(separator: ">") ?? "") bounds \(bounds)")
        engine.setBoostPickerMode(false)
        try check(host?.pickerOverlay == nil, "picker overlay still installed after leaving pick mode")

        let backgroundProbe = "getComputedStyle(document.body).backgroundColor"
        engine.applyEditorLiveCSS("body { background: rgb(4, 5, 6) !important; }")
        try await waitAsync("editor live CSS") {
            (try? await engine.evaluate(backgroundProbe, in: .page)) as? String == "rgb(4, 5, 6)"
        }
        log("PASS editor live CSS (editor world) applies to the page: body background rgb(4, 5, 6)")

        var scan: [PickedElementSnapshot]?
        engine.fetchRepairScan { scan = $0 }
        try await wait("repair scan", timeout: 10) { scan != nil }
        try check(scan?.contains { $0.descriptor.tag == "a" } == true, "repair scan returned \(scan?.map(\.descriptor.tag) ?? [])")
        log("PASS repair scan returned a JSON array of \(scan?.count ?? 0) candidate(s): \(scan?.map(\.descriptor.tag) ?? [])")

        engine.clearEditorLiveCSS()
        try await waitAsync("editor live CSS cleared") {
            let value = (try? await engine.evaluate(backgroundProbe, in: .page)) as? String
            return value != nil && value != "rgb(4, 5, 6)"
        }
        engine.setBoostEditorOpen(false)
        try await wait("editor scripts drained") { engine.evaluationsOutstanding == 0 }
        log("PASS editor live CSS cleared; editor closed")
    }


    // MARK: Document identity

    /// A result evaluated in a document the caller no longer expects is discarded.
    @MainActor
    private func identityMismatchCheck(engine: ChromiumEngine, base: String) async throws {
        guard let old = engine.currentDocumentIdentity else {
            throw Failure(description: "ReArcTabGetDocumentIdentity failed on page A")
        }
        let matching = try await engine.evaluate("document.title", in: .editor, expecting: old, sameNavigation: true)
        try check(matching as? String == Self.titleA, "evaluation with the current identity returned \(matching)")
        engine.reload()
        try await wait("reload of page A") {
            guard let now = engine.currentDocumentIdentity else { return false }
            return !now.isSameDocument(as: old) && !engine.isLoading && engine.pageTitle == Self.titleA
        }
        let discardedBefore = engine.staleResultsDiscarded
        let mismatch = try await expectEvaluationError("evaluation expecting the pre-reload document") {
            try await engine.evaluate("document.title", in: .editor, expecting: old)
        }
        try check(mismatch == .staleDocument && engine.staleResultsDiscarded == discardedBefore + 1,
                  "identity mismatch reported as \(mismatch) (discarded \(discardedBefore) -> \(engine.staleResultsDiscarded))")
        let current = engine.currentDocumentIdentity
        log("PASS EvaluateScript2 identity mismatch rejected: expected [\(old)], tab shows [\(current.map(String.init(describing:)) ?? "?")] -> staleDocument")
    }

    // MARK: Zoom

    @MainActor
    private func zoomChecks(engine: ChromiumEngine) async throws {
        try check(PageZoom.isDefault(engine.refreshZoomFactor() ?? 0), "initial zoom is \(engine.zoomFactor)")
        let status = engine.requestZoomFactor(1.5)
        try check(status == .rearcOK, "ReArcTabSetZoomFactor(1.5) returned \(status.rearcName)")
        try await wait("zoom event 1.5") { abs(engine.zoomFactor - 1.5) < PageZoom.tolerance }
        let queried = engine.refreshZoomFactor() ?? 0
        try check(abs(queried - 1.5) < PageZoom.tolerance, "ReArcTabGetZoomFactor returned \(queried) after the event")
        let invalid = engine.requestZoomFactor(.infinity)
        try check(invalid == ReArcStatus(REARC_INVALID_ARGUMENT), "non-finite zoom returned \(invalid.rearcName)")

        // The picker maps view points to CSS pixels by the zoom factor.
        let rect = try await engine.evaluate(
            "(function(){ var r = document.querySelector('h1').getBoundingClientRect(); return { x: r.left + 20, y: r.top + r.height / 2 }; })()",
            in: .page
        ) as? [String: Double]
        guard let cssX = rect?["x"], let cssY = rect?["y"] else {
            throw Failure(description: "could not locate <h1> at zoom 1.5: \(String(describing: rect))")
        }
        let viewPoint = PageZoom.viewPoint(fromCSSPoint: CGPoint(x: cssX, y: cssY), zoom: engine.zoomFactor)
        engine.setBoostEditorOpen(true)
        engine.setBoostPickerMode(true)
        let picked = try await engine.pickElement(atViewPoint: viewPoint)
        engine.setBoostPickerMode(false)
        engine.setBoostEditorOpen(false)
        try check(picked?.descriptor.tag == "h1", "zoomed pick at view \(viewPoint) found \(String(describing: picked?.descriptor.tag))")

        engine.setZoomFactor(PageZoom.factor(after: .reset, from: engine.zoomFactor))
        try await wait("zoom event 1.0") { PageZoom.isDefault(engine.zoomFactor) }
        log(String(format: "PASS zoom round trip: set 1.5 -> zoom event %.2f, get %.2f; infinity rejected (invalid_argument); ", 1.5, queried)
            + String(format: "picker at view (%.0f,%.0f) = CSS (%.0f,%.0f) -> <h1>; reset -> %.2f", viewPoint.x, viewPoint.y, cssX, cssY, engine.zoomFactor))
    }

    // MARK: Page messages

    @MainActor
    private func pageMessageChecks(engine: ChromiumEngine, window: NSWindow) async throws {
        // The main world gets no binding.
        let mainWorld = try await engine.evaluate("typeof rearcPostMessage", in: .page) as? String
        try check(mainWorld == "undefined", "main world sees rearcPostMessage as \(mainWorld ?? "nil")")

        // A boost world message carries the package ID and arrives as JSON data.
        engine.load(URL(string: engine.currentURL!.absoluteString.replacingOccurrences(of: "/a", with: "/boost"))!)
        try await wait("boosted page for page messages") { engine.pageTitle?.hasPrefix("boost-ok") == true && !engine.isLoading }
        var boostMessages: [ChromiumPageMessage] = []
        engine.onBoostPageMessage = { boostMessages.append($0) }
        _ = try await engine.evaluate("(rearcPostMessage(JSON.stringify({ kind: 'selftest', n: 7 })), true)",
                                      in: .boost(Self.boostPackageID))
        try await wait("boost page message", timeout: 5) { !boostMessages.isEmpty }
        let boostMessage = boostMessages[0]
        let decoded = try? JSONSerialization.jsonObject(with: Data(boostMessage.json.utf8)) as? [String: Any]
        try check(boostMessage.boostID == Self.boostPackageID.uuidString.lowercased()
                  && decoded?["kind"] as? String == "selftest" && decoded?["n"] as? Int == 7
                  && boostMessage.document.tabID == engine.tabID,
                  "boost message \(boostMessage.boostID) \(boostMessage.json)")
        engine.onBoostPageMessage = nil
        log("PASS boost-world page message: boost \(boostMessage.boostID) json \(boostMessage.json) document [\(boostMessage.document)]; main world has no rearcPostMessage")

        // Editor world: a real (trusted) click on the page picks through the channel, no polling.
        engine.goBack()
        try await wait("page A for the editor picker") { engine.currentURL?.path == "/a" && !engine.isLoading }
        var picks: [PickedElementSnapshot] = []
        var cancels = 0
        engine.onBoostEditorPick = { picks.append($0) }
        engine.onBoostEditorCancel = { cancels += 1 }
        engine.setBoostEditorOpen(true)
        engine.setBoostPickerMode(true)
        try await wait("editor scripts installed") { engine.evaluationsOutstanding == 0 }
        let droppedBefore = engine.droppedEditorMessages
        _ = try await engine.evaluate("(rearcPostMessage(JSON.stringify({ type: 'bogus' })), true)", in: .editor)
        try await wait("unknown editor message dropped", timeout: 5) { engine.droppedEditorMessages > droppedBefore }

        let center = try await engine.evaluate(
            "(function(){ var r = document.querySelector('h1').getBoundingClientRect(); return { x: r.left + 20, y: r.top + r.height / 2 }; })()",
            in: .page
        ) as? [String: Double]
        guard let x = center?["x"], let y = center?["y"],
              let host = window.contentView?.firstDescendant(ofType: ChromiumHostView.self) else {
            throw Failure(description: "no <h1> or host for the trusted click")
        }
        window.makeKeyAndOrderFront(nil)
        var via = "trusted click -> editor-world listener -> rearcPostMessage"
        // Synthesized NSEvents reach the renderer as trusted input only while the app
        // is active and the window key and visible; otherwise Chromium drops them.
        // Decide that up front instead of waiting for a click that cannot arrive.
        let canDeliverInput = NSApp.isActive && window.isKeyWindow && window.occlusionState.contains(.visible)
        if canDeliverInput {
            let viewPoint = PageZoom.viewPoint(fromCSSPoint: CGPoint(x: x, y: y), zoom: engine.zoomFactor)
            let local = NSPoint(x: viewPoint.x, y: host.isFlipped ? viewPoint.y : host.bounds.height - viewPoint.y)
            let location = host.convert(local, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            do {
                try await wait("editor pick page message", timeout: 5) { !picks.isEmpty }
            } catch {
                log("NOTE synthesized click produced no page message although the window was key and visible")
            }
        } else {
            log("NOTE app inactive or window not visible (active \(NSApp.isActive), key \(window.isKeyWindow), "
                + "visible \(window.occlusionState.contains(.visible))): synthesized input cannot reach the page; "
                + "posting the editor pick from the editor world")
        }
        if picks.isEmpty {
            via = "editor-world rearcPostMessage(snapshotAt)"
            let started = Date()
            _ = try await engine.evaluate(
                BoostEditorScripts.withPicker("(rearcPostMessage(JSON.stringify(p.snapshotAt(\(x), \(y)))), true)"),
                in: .editor,
                timeoutMS: 15_000
            )
            try await wait("editor pick page message (direct)", timeout: 10) { !picks.isEmpty }
            via += String(format: " in %.0f ms", Date().timeIntervalSince(started) * 1000)
        }
        try check(picks.first?.descriptor.tag == "h1", "page-message pick was \(String(describing: picks.first?.descriptor.tag))")
        _ = try await engine.evaluate("(rearcPostMessage(JSON.stringify({ type: 'cancel' })), true)", in: .editor, timeoutMS: 15_000)
        try await wait("editor cancel page message", timeout: 10) { cancels > 0 }
        engine.setBoostPickerMode(false)
        engine.setBoostEditorOpen(false)
        engine.onBoostEditorPick = nil
        engine.onBoostEditorCancel = nil
        try await wait("editor scripts drained") { engine.evaluationsOutstanding == 0 }
        log("PASS editor page messages: \(via) -> <\(picks.first?.descriptor.tag ?? "")>; cancel delivered; "
            + "unknown kind dropped (dropped \(droppedBefore) -> \(engine.droppedEditorMessages))")
    }

    // MARK: Find in page (ABI 1.16)

    @MainActor
    private func findInPageChecks(engine: ChromiumEngine, base: String) async throws {
        engine.load(URL(string: "\(base)/find")!)
        try await wait("find fixture loaded") { engine.pageTitle == "find" && !engine.isLoading }
        try check(engine.attachmentID != nil, "find needs an attached tab (a 0x0 view reports no matches)")
        let invalid = ReArcTabFindNext(engine.tabID, true)
        try check(invalid == ReArcStatus(REARC_INVALID_STATE), "FindNext without a session returned \(invalid.rearcName)")
        let empty = "".withCString { text -> ReArcStatus in
            var session: UInt64 = 0
            return ReArcTabFindStart(engine.tabID, text, UInt32(REARC_FIND_FORWARD), &session)
        }
        try check(empty == ReArcStatus(REARC_INVALID_ARGUMENT), "empty find text returned \(empty.rearcName)")

        var terminals: [FindInPageEvent.Reason] = []
        let find = FindBarModel()
        find.present(on: engine)
        // The bar owns onFindEvent; wrap it to also count terminals.
        let barHandler = engine.onFindEvent
        engine.onFindEvent = { event in
            if event.reason != .result { terminals.append(event.reason) }
            barHandler?(event)
        }
        find.setQuery("needl")
        find.setQuery("needle")
        try await wait("find: 1 of 4") { find.statusText == "1 of 4" }
        try check(terminals.contains(.replaced), "the first keystroke's session did not end as replaced (\(terminals))")
        var steps = [find.statusText]
        for forward in [true, false, false] {
            let before = find.state.activeOrdinal
            find.next(forward: forward)
            try await wait("find \(forward ? "next" : "previous") from \(before)") { find.state.activeOrdinal != before }
            steps.append(find.statusText)
        }
        try check(steps == ["1 of 4", "2 of 4", "1 of 4", "4 of 4"], "find ordinals \(steps)")
        find.setMatchCase(true)
        try await wait("case-sensitive count") { find.state.matchCase && find.state.matchCount == 2 }
        find.setQuery("zzz-not-on-page")
        try await wait("no matches") { find.hasNoMatches }
        let noMatches = find.statusText
        find.setQuery("needle")
        try await wait("case-sensitive needle again") { find.state.matchCount == 2 }
        let stopsBefore = terminals.filter { $0 == .stopped }.count
        find.close()
        // Closing detaches the bar's handler; the stop terminal is delivered after this turn.
        engine.onFindEvent = { event in if event.reason != .result { terminals.append(event.reason) } }
        try await wait("stop terminal") { terminals.filter { $0 == .stopped }.count == stopsBefore + 1 }
        try check(engine.findSessionID == 0, "engine still holds find session \(engine.findSessionID)")

        // A navigation ends the session exactly once; Return then searches the new document.
        find.present(on: engine)
        let handler = engine.onFindEvent
        engine.onFindEvent = { event in
            if event.reason != .result { terminals.append(event.reason) }
            handler?(event)
        }
        try await wait("reopened bar repeats the query") { find.state.matchCount == 2 }
        engine.load(URL(string: "\(base)/a")!)
        try await wait("navigation terminal") { terminals.last == .navigated && find.state.sessionID == 0 }
        try await wait("page A after find") { engine.pageTitle == Self.titleA && !engine.isLoading }
        try check(find.statusText.isEmpty, "count still shown after navigation: '\(find.statusText)'")
        find.close()
        engine.onFindEvent = nil
        log("PASS find in page (ABI 1.16, FindBarModel on the attached tab): 'needle' -> \(steps.joined(separator: " -> ")) "
            + "(backward wrap); match case -> 2; '\(noMatches)' for a missing word; terminals \(terminals.map { "\($0)" }); "
            + "FindNext without a session -> invalid_state, empty text -> invalid_argument")
    }

    // MARK: Downloads (ABI 1.17)

    @MainActor
    private func downloadChecks(engine: ChromiumEngine, base: String) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rearc-selftest-downloads-\(UUID().uuidString)", isDirectory: true)
        let controller = DownloadsController(fileURL: directory.appendingPathComponent("Downloads.json"))
        controller.setDirectory(directory)
        let backend = ChromiumDownloadBackend(runtime: runtime, controller: controller)
        backend.install()
        defer {
            runtime.onDownloadEvent = nil
            runtime.onDownloadEvents = nil
        }
        try check(runtime.downloadDirectory == directory.standardizedFileURL, "policy directory \(runtime.downloadDirectory?.path ?? "nil")")
        let rejected = "relative/dir".withCString { ReArcDownloadSetPolicy(engine.engineProfileID, $0, 0) }
        try check(rejected == ReArcStatus(REARC_INVALID_ARGUMENT), "relative policy directory returned \(rejected.rearcName)")
        let picker = directory.path.withCString { ReArcDownloadSetPolicy(engine.engineProfileID, $0, 1) }
        let expectedPicker = runtime.capabilities.fileChooser ? ReArcStatus.rearcOK : ReArcStatus(REARC_UNSUPPORTED)
        try check(picker == expectedPicker, "prompt mode 1 returned \(picker.rearcName)")
        try check(runtime.applyDownloadPolicy(profile: engine.engineProfileID) == .rearcOK, "policy for engine profile \(engine.engineProfileID)")

        // 1. A small attachment lands in the policy directory without a picker or a navigation.
        func row(_ name: String) -> DownloadRecord? {
            controller.records.first { $0.fileName.hasPrefix(name) || $0.url.hasSuffix("/\(name)") }
        }
        let started = engine.navigateNow(URL(string: "\(base)/download/rearc-small.bin")!)
        try check(started == .rearcOK, "navigating to the attachment returned \(started.rearcName)")
        try await wait("small download complete", timeout: 20) { row("rearc-small.bin")?.state == .complete }
        let small = try XUnwrap(row("rearc-small.bin"))
        let size = (try? FileManager.default.attributesOfItem(atPath: small.targetPath))?[.size] as? Int ?? -1
        try check(small.targetPath.hasPrefix(directory.standardizedFileURL.path), "saved to \(small.targetPath), not the policy directory")
        try check(size == LoopbackFixtureServer.smallDownloadSize, "saved file has \(size) bytes")
        try check(controller.startCount >= 1, "a new download did not pulse the downloads button")
        try check(!controller.isTrayPresented, "a new download opened the tray popover")
        // The pending entry's URL may show while the navigation turns into a download; it must not stick.
        try await wait("tab still on page A after the attachment", timeout: 5) { engine.currentURL?.path == "/a" }
        controller.perform(.remove, on: small.id)
        try await wait("removed event drops the row") { row("rearc-small.bin") == nil }
        let removedHandle = backend.handle(for: small.id)
        try check(removedHandle == nil, "backend kept a handle for the removed item")

        // 2. A trickled 1 MiB file: pause -> resume -> progress -> cancel -> remove.
        try check(engine.navigateNow(URL(string: "\(base)/download/rearc-trickle.bin")!) == .rearcOK, "trickle navigation rejected")
        try await wait("trickle started", timeout: 20) { (row("rearc-trickle.bin")?.receivedBytes ?? 0) > 0 }
        let id = try XUnwrap(row("rearc-trickle.bin")).id
        let handle = try XUnwrap(backend.handle(for: id))
        controller.perform(.pause, on: id)
        try await wait("paused") { controller.list.record(withID: id).map { $0.isPaused && $0.canResume } ?? false }
        let pausedAt = controller.list.record(withID: id)?.receivedBytes ?? 0
        let pauseAgain = runtime.downloadAction(profile: handle.profile, id: handle.id, action: 0)
        try check(pauseAgain == ReArcStatus(REARC_INVALID_STATE), "pausing a paused item returned \(pauseAgain.rearcName)")
        controller.perform(.resume, on: id)
        try await wait("resumed with progress", timeout: 20) {
            guard let record = controller.list.record(withID: id) else { return false }
            return !record.isPaused && record.receivedBytes > pausedAt
        }
        let resumedAt = controller.list.record(withID: id)?.receivedBytes ?? 0
        controller.perform(.cancel, on: id)
        try await wait("cancelled") { controller.list.record(withID: id)?.state == .cancelled }
        let status = controller.list.record(withID: id)?.statusText ?? ""
        controller.perform(.remove, on: id)
        try await wait("cancelled row removed") { controller.list.record(withID: id) == nil }
        let gone = runtime.downloadAction(profile: handle.profile, id: handle.id, action: 4)
        try check(gone == ReArcStatus(REARC_NOT_FOUND), "reveal after remove returned \(gone.rearcName)")
        let dangerous = runtime.capabilities.dangerousDownloads
            ? try await dangerousDownloadChecks(engine: engine, base: base, controller: controller, directory: directory)
            : "ABI-GAP dangerous_downloads not advertised: dangerous items are reviewed on chrome://downloads"
        log(dangerous)
        let asked = runtime.capabilities.downloadSavePrompt
            ? try await askWhereToSaveChecks(engine: engine, base: base, controller: controller, backend: backend, directory: directory)
            : "ABI-GAP Ask where to save needs file_chooser (ABI 1.19)"
        controller.save()
        let saved = DownloadListFile.load(from: directory.appendingPathComponent("Downloads.json"))
        try check(saved.directory == directory.standardizedFileURL.path && saved.list.records.isEmpty,
                  "persisted tray: \(saved.directory ?? "nil"), \(saved.list.records.count) row(s)")
        try? FileManager.default.removeItem(at: directory)
        log("PASS downloads (ABI 1.17, DownloadsController + ChromiumDownloadBackend): \(LoopbackFixtureServer.smallDownloadSize)-byte "
            + "attachment saved without a picker to the policy directory (tab stayed on /a), button pulsed and tray stayed closed, remove -> removed event; "
            + "trickle paused at \(pausedAt) B (pause again -> invalid_state), resumed to \(resumedAt) B, '\(status)', "
            + "removed (reveal -> not_found); relative directory -> invalid_argument, prompt 1 -> \(picker.rearcName); "
            + "\(backend.eventCount) events; \(asked)")
    }

    private func XUnwrap<T>(_ value: T?, _ label: String = #function) throws -> T {
        guard let value else { throw Failure(description: "unexpected nil in \(label)") }
        return value
    }

    // MARK: Two windows

    /// One live attachment per tab: showing the tab in a second window detaches
    /// it from the first before re-attaching; closing the second window hands it
    /// back without ending the app.
    @MainActor
    private func twoWindowChecks(engine: ChromiumEngine, first: NSWindow) async throws {
        guard let firstHost = first.contentView?.firstDescendant(ofType: ChromiumHostView.self),
              let firstLease = firstHost.leaseAttachmentID else {
            throw Failure(description: "first window holds no lease")
        }
        let windowsBefore = runtime.registeredWindowCount
        let second = NSWindow(
            contentRect: NSRect(x: 220, y: 160, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        second.isReleasedWhenClosed = false
        second.title = "ReArc Chromium selftest (second window)"
        second.contentView = NSHostingView(rootView: engine.makeView().frame(minWidth: 400, minHeight: 300))
        second.makeKeyAndOrderFront(nil)
        try await wait("lease moved to the second window") {
            guard let secondHost = second.contentView?.firstDescendant(ofType: ChromiumHostView.self) else { return false }
            return secondHost.leaseAttachmentID != nil && engine.leaseHolder === secondHost
        }
        let secondHost = second.contentView?.firstDescendant(ofType: ChromiumHostView.self)
        let secondLease = secondHost?.leaseAttachmentID ?? 0
        try check(firstHost.leaseAttachmentID == nil, "first window kept its lease \(firstLease) after the move")
        try check(secondLease != firstLease && engine.attachmentID == secondLease,
                  "lease ids: first \(firstLease), second \(secondLease), engine \(engine.attachmentID ?? 0)")
        try check(runtime.registeredWindowCount == windowsBefore + 1, "second window not registered")
        let title = try await engine.evaluate("document.title", in: .page)
        log("PASS tab moved to a second window: lease \(firstLease) detached, then \(secondLease) attached in window 2; "
            + "window 1 shows a placeholder; page still live ('\(title)')")

        ChromiumHostView.dismantleAll(in: second)
        second.close()
        try await wait("lease returned to the first window") { firstHost.leaseAttachmentID != nil && engine.leaseHolder === firstHost }
        try await wait("second window unregistered") { runtime.registeredWindowCount == windowsBefore }
        try check(first.isVisible && NSApp.isRunning, "closing the second window ended the app or hid the first")
        second.contentView = nil
        log("PASS second window closed without quitting: lease \(firstHost.leaseAttachmentID ?? 0) re-attached in window 1, "
            + "registered windows \(runtime.registeredWindowCount)")
    }

    // MARK: Profiles

    @MainActor
    private func makeEngine(_ context: EngineProfileContext, privateSession: UUID? = nil) async throws -> ChromiumEngine {
        let engine = ChromiumEngine(runtime: runtime, context: context, role: .tab, shellID: UUID(), privateSession: privateSession)
        try check(await engine.waitForTab(), "no tab for \(engine.profileKey): \(engine.lastError ?? "no error")")
        return engine
    }

    @MainActor
    private func loadPageA(_ engine: ChromiumEngine, base: String) async throws {
        engine.load(URL(string: "\(base)/a")!)
        try await wait("page A in \(engine.profileKey)", timeout: 20) {
            engine.pageTitle == Self.titleA && !engine.isLoading
        }
    }

    @MainActor
    private func cookies(_ engine: ChromiumEngine) async throws -> String {
        // Never-attached (hidden) tabs can be slow to run script in this debug build; under a heavy
        // engine build next to it 10 s was not enough (wave 28), so this takes the ABI's 30 s maximum.
        try await engine.evaluate("document.cookie", in: .page, timeoutMS: 30_000) as? String ?? ""
    }

    @MainActor
    private func profileChecks(base: String) async throws {
        let profileA = UUID()
        let profileB = UUID()
        let a1 = try await makeEngine(EngineProfileContext(profileID: profileA))
        let a2 = try await makeEngine(EngineProfileContext(profileID: profileA))
        let b = try await makeEngine(EngineProfileContext(profileID: profileB))
        try check(a1.engineProfileID == a2.engineProfileID && a1.engineProfileID != b.engineProfileID
                  && a1.engineProfileID != runtime.defaultProfileID && b.engineProfileID != runtime.defaultProfileID,
                  "engine profiles: A \(a1.engineProfileID)/\(a2.engineProfileID), B \(b.engineProfileID), default \(runtime.defaultProfileID)")
        for engine in [a1, a2, b] { try await loadPageA(engine, base: base) }
        _ = try await a1.evaluate("(document.cookie = 'rearc_profile=A; path=/; max-age=3600', document.cookie)", in: .page)
        let inA2 = try await cookies(a2)
        let inB = try await cookies(b)
        try check(inA2.contains("rearc_profile=A"), "same-profile tab does not see the cookie ('\(inA2)')")
        try check(!inB.contains("rearc_profile"), "profile B sees profile A's cookie ('\(inB)')")
        log("PASS profiles isolated: \(a1.profileKey) -> engine profile \(a1.engineProfileID), \(b.profileKey) -> \(b.engineProfileID); "
            + "cookie set in A visible to A's second tab ('\(inA2)'), invisible in B ('\(inB)')")

        // Off the record under A: in memory, sees neither A's cookies nor leaks its own.
        let session = UUID()
        let otr = try await makeEngine(EngineProfileContext(profileID: profileA, isEphemeral: true), privateSession: session)
        let otrKey = otr.profileKey
        try check(otrKey == .offTheRecord(session: session, parent: profileA)
                  && otr.engineProfileID != a1.engineProfileID && otr.engineProfileID != 0,
                  "OTR key \(otrKey) engine profile \(otr.engineProfileID)")
        try await loadPageA(otr, base: base)
        let inOTR = try await cookies(otr)
        try check(!inOTR.contains("rearc_profile"), "off-the-record tab sees the parent's cookie ('\(inOTR)')")
        _ = try await otr.evaluate("(document.cookie = 'rearc_otr=1; path=/', document.cookie)", in: .page)
        let parentAfter = try await cookies(a2)
        try check(!parentAfter.contains("rearc_otr"), "parent profile sees the off-the-record cookie ('\(parentAfter)')")
        log("PASS off-the-record window profile \(otr.engineProfileID) under \(a1.engineProfileID): parent cookie invisible ('\(inOTR)'), "
            + "its own cookie stays out of the parent ('\(parentAfter)')")

        // Teardown: closing A closes the OTR child first, then A; keep engines until the completion.
        var events: [String] = []
        runtime.onProfileEvent = { events.append($0) }
        var closed: (ReArcStatus, Bool)?
        let oldA = a1.engineProfileID
        runtime.closeProfile(.persistent(profileA), force: true) { closed = ($0, $1) }
        try await wait("profile A close", timeout: 20) { closed != nil }
        runtime.onProfileEvent = nil
        try check(closed?.0 == .rearcOK && closed?.1 == false, "profile A close: \(closed?.0.rearcName ?? "-") cancelled \(closed?.1 ?? false)")
        let closedOrder = events.filter { $0.hasPrefix("closed ") }
        try check(closedOrder.count == 2 && closedOrder[0].contains("private session") && closedOrder[1].contains(ChromiumProfileKey.storageKey(for: profileA)),
                  "teardown order: \(closedOrder)")
        try check(runtime.engineProfileID(for: otrKey) == nil && runtime.engineProfileID(for: .persistent(profileA)) == nil,
                  "profiles still open after close")
        log("PASS teardown order: " + closedOrder.joined(separator: " then "))
        _ = (a1, a2, otr)

        // Reopening A yields a new engine ID; its persistent cookie survived.
        let reopened = try await makeEngine(EngineProfileContext(profileID: profileA))
        try await loadPageA(reopened, base: base)
        let persisted = try await cookies(reopened)
        try check(reopened.engineProfileID != oldA && persisted.contains("rearc_profile=A") && !persisted.contains("rearc_otr"),
                  "reopened A: engine \(oldA) -> \(reopened.engineProfileID), cookies '\(persisted)'")
        log("PASS reopened \(reopened.profileKey): engine profile \(oldA) -> \(reopened.engineProfileID), persistent cookie kept ('\(persisted)')")
        _ = b
    }

    // MARK: Shell windows

    /// What the window shows instead of `tab`: the selection, overlays, and every tab engine with its lease.
    @MainActor
    private func shellReport(_ model: BrowserViewModel, _ store: SidebarStore, tab: Tab, engine: ChromiumEngine) -> String {
        func describe(_ id: UUID?) -> String {
            guard let id else { return "nothing" }
            if let item = store.tab(withID: id) { return "'\(item.title)' \(item.kind) \(item.url.absoluteString)" }
            if let split = store.split(withID: id) { return "split of \(split.tabs.map(\.title))" }
            return "item \(id.uuidString.prefix(8))"
        }
        let engines = model.engineHost.allTabEngines().compactMap { id, _, other -> String? in
            guard let other = other as? ChromiumEngine else { return nil }
            return "\(describe(id)) = tab \(other.tabID) lease \(other.attachmentID ?? 0) url \(other.currentURL?.absoluteString ?? "-")"
        }
        return "selected \(describe(store.selectedItemID)) (wanted \(describe(tab.id))); source tab \(engine.tabID) lease "
            + "\(engine.attachmentID ?? 0) title \(engine.pageTitle ?? "-") loading \(engine.isLoading); command bar "
            + "\(model.isCommandBarPresented) peek \(model.peekSession != nil) library \(model.librarySection(in: store.keyWindowID).map { "\($0)" } ?? "-") "
            + "space \(store.spaceContaining(tabID: tab.id) == store.activeSpaceID ? "active" : "other"); engines: "
            + engines.joined(separator: "; ")
    }

    @MainActor
    private func shellEngine(_ model: BrowserViewModel, _ tab: Tab) throws -> ChromiumEngine {
        guard let engine = model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab)) as? ChromiumEngine else {
            throw Failure(description: "no ChromiumEngine for shell tab \(tab.title)")
        }
        return engine
    }

    @MainActor
    private func checkOneLease(_ engine: ChromiumEngine, _ label: String) throws {
        let leases = runtime.liveLeaseCount(forTab: engine.tabID)
        try check(leases == 1, "\(label): tab \(engine.tabID) holds \(leases) live attachments")
    }

    /// A new Little Darni window opens where the last one was left, on that
    /// screen (owner, 2026-11-23: it always opened in the same place). One
    /// opened while another sits there steps off it. The self-test's shell
    /// keeps the place in memory, never in the user's defaults.
    @MainActor
    private func littleArcPlacementChecks(model: BrowserViewModel, shell: ChromiumShell, store: SidebarStore,
                                          base: String) async throws {
        let address = try XUnwrap(URL(string: "\(base)/a?placement=1"), "placement address")
        let screen = try XUnwrap(NSScreen.screens.last?.visibleFrame, "a screen")
        let target = NSRect(x: screen.maxX - 700, y: screen.minY + 40, width: 640, height: 480)

        let first = model.openLittleArc(url: address)
        let firstWindow = try XUnwrap(shell.window(forLittleArc: first.id), "the first Little Darni window")
        firstWindow.setFrame(target, display: true)
        try await wait("placement: the moved window's frame was remembered") { shell.littleArcFrames.frame == firstWindow.frame }
        let left = firstWindow.frame
        shell.dismissLittleArcWindow(first.id)
        try await wait("placement: the first window closed") {
            shell.window(forLittleArc: first.id) == nil && store.littleArcWindow(withID: first.id) == nil
        }

        let second = model.openLittleArc(url: address)
        let secondWindow = try XUnwrap(shell.window(forLittleArc: second.id), "the second Little Darni window")
        try check(secondWindow.frame == left,
                  "placement: the next window opened at \(secondWindow.frame), not where the last was left (\(left))")
        let third = model.openLittleArc(url: address)
        let thirdWindow = try XUnwrap(shell.window(forLittleArc: third.id), "the third Little Darni window")
        try check(thirdWindow.frame.minX > left.minX && thirdWindow.frame.maxY < left.maxY && thirdWindow.frame.size == left.size,
                  "placement: a window opened over an open one did not step off it (\(thirdWindow.frame) over \(left))")
        for id in [second.id, third.id] { shell.dismissLittleArcWindow(id) }
        try await wait("placement: the windows closed") {
            shell.window(forLittleArc: second.id) == nil && shell.window(forLittleArc: third.id) == nil
        }
        log("PASS Little Darni placement: moved to \(left) on screen \(NSScreen.screens.count - 1) of \(NSScreen.screens.count); "
            + "the next opened there, one opened over it at \(thirdWindow.frame.origin)")
    }

    /// Little Darni's Open in across profiles (owner reports 2026-11-20): a
    /// window in a profile with one space, while the browser window is on a
    /// profile with several. The main button names the browser window's
    /// space, in the other profile, and follows it when it changes space. The
    /// picker lists every space, the window's own first. The main button, ⌘O
    /// and a row of another profile all ask first (OI-01): Cancel keeps the
    /// window, an address that is not a web address is refused (OI-02), and
    /// Yes loads the address afresh in a new tab of that profile. The
    /// window's page is not moved: another engine tab, another engine
    /// profile, and a cookie set in the window is not there (S-01). The
    /// question is answered through the model, as the alert's buttons answer it.
    @MainActor
    private func littleArcOpenInOtherProfileChecks(model: BrowserViewModel, shell: ChromiumShell, store: SidebarStore,
                                                   base: String) async throws {
        let home = store.activeSpace
        let homeTab = store.selectedTab
        let second = store.addSpace(name: "Open In Second", profileID: home.profileID)
        let solo = store.addProfile(name: "Open In Solo")
        let soloSpace = try XUnwrap(store.spaces(in: solo.id).first, "the new profile's space")
        store.selectSpace(home.id)

        let address = try XUnwrap(URL(string: "\(base)/a?openin=1"), "open-in address")
        let record = model.openLittleArc(url: address, profileID: solo.id)
        guard shell.window(forLittleArc: record.id) != nil,
              let little = model.littleArcEngine(for: record.id) as? ChromiumEngine else {
            throw Failure(description: "open in: Little Darni opened no window/engine")
        }
        try await wait("open in: Little Darni loaded in the one-space profile", timeout: 20) {
            little.attachmentID != nil && little.pageTitle == Self.titleA && !little.isLoading
        }
        let littleTab = little.tabID, littleProfile = little.engineProfileID
        let homeTabs = store.displayTabs(in: home.id).map(\.id)
        _ = try await little.evaluate("(document.cookie = 'rearc_open_in=solo; path=/; max-age=600', document.cookie)", in: .page)

        // The target is the browser window's space, in the other profile, and it follows that
        // window when it changes space, into the window's own profile and back.
        try check(store.littleArcTargetSpace(for: record.id)?.id == home.id,
                  "open in: target \(store.littleArcTargetSpace(for: record.id)?.name ?? "nil"), expected the browser window's space")
        store.selectSpace(soloSpace.id)
        try check(store.littleArcTargetSpace(for: record.id)?.id == soloSpace.id
                  && LittleArcOpenInMenu.choice(store: store, windowID: record.id, spaceID: soloSpace.id, url: address) == .move,
                  "open in: the target did not follow the browser window to the window's own profile")
        store.selectSpace(second.id)
        try check(store.littleArcTargetSpace(for: record.id)?.id == second.id, "open in: the target did not follow the browser window's space")
        store.selectSpace(home.id)
        try check(store.littleArcTargetSpace(for: record.id)?.id == home.id, "open in: the target did not come back with the browser window")

        // The picker: the window's own space first, then every space of the other profile.
        let sections = LittleArcOpenInMenu.sections(store: store, windowID: record.id)
        let entries = sections.flatMap(\.entries)
        let homeOwner = store.owningProfileID(of: home.profileID)
        try check(sections.map(\.profileID) == [solo.id, homeOwner] && sections.allSatisfy { $0.header != nil }
                  && sections.first?.entries.map(\.spaceID) == [soloSpace.id] && sections.first?.entries.first?.kind == .move
                  && entries.contains { $0.spaceID == home.id } && entries.contains { $0.spaceID == second.id }
                  && entries.filter(\.isTarget).map(\.spaceID) == [home.id]
                  && entries.filter { $0.spaceID != soloSpace.id }.allSatisfy { $0.kind == .reopen },
                  "open in: picker \(sections.map { "\($0.header ?? "-"): \($0.entries.map { "\($0.title) \($0.kind)" })" })")
        let rows = LittleArcSpacePicker.rows(for: sections, query: second.name)
        try check(LittleArcSpacePicker.choosable(rows) == [second.id] && LittleArcSpacePicker.highlight(nil, in: rows) == second.id,
                  "open in: typing the space's name did not leave it as the row Return chooses (\(rows.map(\.id)))")

        // The main button and ⌘O: the target is another profile's, so both ask, and Cancel keeps everything.
        let main = LittleArcOpenInMenu.Question(windowID: record.id, spaceID: home.id, url: address, host: address.host() ?? "")
        try check(model.openLittleArcWindowInTarget(record.id) == .ask(main) && model.pendingLittleArcOpenIn == main,
                  "open in: the main button did not ask (question \(String(describing: model.pendingLittleArcOpenIn)))")
        model.cancelLittleArcOpenIn(for: record.id)
        model.keyLittleArcID = record.id
        model.openLittleArcOrPeekInSpace()
        try check(model.pendingLittleArcOpenIn == main, "open in: ⌘O did not ask (question \(String(describing: model.pendingLittleArcOpenIn)))")
        model.cancelLittleArcOpenIn(for: record.id)
        try check(store.littleArcWindow(withID: record.id) != nil && shell.window(forLittleArc: record.id) != nil
                  && store.displayTabs(in: home.id).map(\.id) == homeTabs && little.tabID == littleTab && little.attachmentID != nil,
                  "open in: the main button or ⌘O changed something before an answer")

        // Another profile's space asks first (OI-01), with the address taken then (OI-03).
        let asked = LittleArcOpenInMenu.Question(windowID: record.id, spaceID: second.id, url: address, host: address.host() ?? "")
        try check(entries.allSatisfy(\.isEnabled) && LittleArcOpenInMenu.note(for: sections) == nil,
                  "open in: a web address left rows disabled (\(entries.filter { !$0.isEnabled }.map(\.title)))")
        try check(model.openLittleArcWindow(record.id, in: second.id) == .ask(asked) && model.pendingLittleArcOpenIn == asked,
                  "open in: the other profile's space did not ask (question \(String(describing: model.pendingLittleArcOpenIn)))")
        let question = model.littleArcOpenInMessage(asked)
        try check(question.message.contains(asked.host) && question.message.contains("“\(second.name)”"),
                  "open in: the question names neither the host nor the space: '\(question.message)'")
        // Cancel: nothing opened and the window, its page and its cookie are as they were.
        model.cancelLittleArcOpenIn(for: record.id)
        try check(model.pendingLittleArcOpenIn == nil && shell.window(forLittleArc: record.id) != nil
                  && store.littleArcWindow(withID: record.id) != nil && store.activeSpaceID == home.id
                  && store.displayTabs(in: second.id).isEmpty && little.tabID == littleTab && little.attachmentID != nil,
                  "open in: Cancel changed something (window \(shell.window(forLittleArc: record.id) != nil), "
                  + "record \(store.littleArcWindow(withID: record.id) != nil), tabs \(store.displayTabs(in: second.id).count))")
        // An address that is not a web address stays in its window (OI-02), whatever the menu showed.
        // Only the window's own space (a move within its session) stays enabled; every row that
        // crosses sessions is disabled (LittleArcOpenInOtherProfileTests, OI-02).
        let local = try XUnwrap(URL(string: "data:text/html,open-in"), "open-in data address")
        try check(LittleArcOpenInMenu.choice(store: store, windowID: record.id, spaceID: second.id, url: local) == .refuse
                  && LittleArcOpenInMenu.sections(store: store, windowID: record.id, url: local).flatMap(\.entries)
                      .filter(\.isEnabled).map(\.spaceID) == [soloSpace.id]
                  && store.reopenLittleArcAsTab(id: record.id, in: second.id, url: local) == nil
                  && store.littleArcWindow(withID: record.id) != nil,
                  "open in: an address that is not a web address was not refused across profiles")
        // Asked again and answered Yes, as the alert's button answers it.
        try check(model.openLittleArcWindow(record.id, in: second.id) == .ask(asked), "open in: the second question was not put")
        try check(model.confirmLittleArcOpenIn(for: record.id), "open in: Yes opened nothing")
        try await wait("open in: the Little Darni window closed") {
            shell.window(forLittleArc: record.id) == nil && store.littleArcWindow(withID: record.id) == nil
        }
        guard let tab = store.selectedTab, tab.url == address, store.spaceContaining(tabID: tab.id) == second.id,
              store.activeSpaceID == second.id, model.profileID(for: tab) == home.profileID else {
            throw Failure(description: "open in: no tab with the address in the chosen space (selected \(store.selectedTab?.url.absoluteString ?? "nil") "
                          + "in space \(store.activeSpace.name))")
        }
        let engine = try shellEngine(model, tab)
        try await wait("open in: the address loaded in the other profile", timeout: 20) {
            engine.pageTitle == Self.titleA && engine.currentURL?.query == "openin=1" && !engine.isLoading
        }
        let seen = try await cookies(engine)
        try check(engine.tabID != littleTab && engine.engineProfileID != littleProfile && engine.role == .tab,
                  "open in: the tab is the window's page (engine tab \(engine.tabID) vs \(littleTab), engine profile "
                  + "\(engine.engineProfileID) vs \(littleProfile), role \(engine.role))")
        try check(!seen.contains("rearc_open_in"), "open in: the window's cookie reached the other profile ('\(seen)')")
        try check(model.engineHost.existingLittleArcEngine(record.id, profileID: solo.id) == nil
                  && !store.littleArcArchivedWindows.contains { $0.id == record.id }
                  && store.displayTabs(in: second.id).map(\.id) == [tab.id] && store.displayTabs(in: soloSpace.id).isEmpty,
                  "open in: the window's engine or record was kept, or more than one tab was made")
        log("PASS Little Darni Open in another profile: the target followed the browser window; picker \(entries.count) space(s), "
            + "the window's own a move and the rest reopen; the main button and ⌘O asked; asked \"\(question.title)\", "
            + "Cancel kept the window, a data: address was refused, Yes opened it; the address loaded afresh in "
            + "engine tab \(engine.tabID) of engine profile \(engine.engineProfileID) (the window was tab \(littleTab) of profile "
            + "\(littleProfile)); the window's cookie is not there ('\(seen)'); window closed, record removed")

        model.deleteTab(tab.id)
        store.selectSpace(home.id)
        _ = store.removeSpace(second.id)
        try check(model.deleteProfile(solo.id, deletingSpaces: true) == nil, "open in: the extra profile could not be deleted")
        if let homeTab {
            model.selectTab(homeTab.id)
            try await wait("open in: the first tab shown again", timeout: 15) { store.selectedTab?.id == homeTab.id && store.activeSpaceID == home.id }
        }
    }

    /// Drives `ChromiumShell` (the normal Chromium-path UI) with a throwaway
    /// sidebar: the same BrowserView, LittleArcWindowView and PrivateWindowView
    /// the app shows, through the model's own commands.
    @MainActor
    private func shellChecks(base: String) async throws {
        // A folder of its own for the shell's files. The model keeps its other files beside
        // the sidebar file, and "blocked list in memory only" reads every file of that folder:
        // with the sidebar file directly in the temporary folder it read all of that.
        let shellData = FileManager.default.temporaryDirectory
            .appendingPathComponent("rearc-selftest-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: shellData, withIntermediateDirectories: true)
        let sidebarFile = shellData.appendingPathComponent("sidebar.json")
        let store = SidebarStore()
        let tabA = store.addTab(kind: .today, title: "Shell A", url: URL(string: "\(base)/a")!)
        store.selectTab(tabA.id)
        // As ChromiumShell.makeModel does: the owner is named before the model loads tab A.
        runtime.legacyDefaultOwner = store.profiles.first?.id
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: sidebarFile),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        // Tab freezing has its own step (tabFreezeChecks). For the rest of the run it is off, in
        // a scratch domain: the person's choice is never written, and no step meets a page the
        // five-minute check froze behind it (a tab unseen for thirty minutes of a long run).
        let sleepDomain = "darni-selftest-sleep-\(UUID().uuidString)"
        let sleepDefaults = UserDefaults(suiteName: sleepDomain)
        if let sleepDefaults {
            model.tabUnloadDefaults = sleepDefaults
            model.tabFreezeThreshold = .never
        }
        defer { sleepDefaults?.removePersistentDomain(forName: sleepDomain) }
        // A temp session file: the user's window-session.json is never read or written.
        let sessionFile = shellData.appendingPathComponent("window-session.json")
        let shell = ChromiumShell(runtime: runtime, autosavesFrames: false, sessionFile: sessionFile)
        shell.start(model: model)
        // Before the first list check can start (it follows the bundles' verification, off this turn).
        model.contentBlocking.fetcher = SelfTestNoMirror()
        guard let first = shell.browserWindows.first else { throw Failure(description: "ChromiumShell opened no browser window") }
        let engineA = try shellEngine(model, tabA)
        try await wait("shell tab A attached and loaded", timeout: 20) {
            engineA.attachmentID != nil && engineA.pageTitle == Self.titleA && !engineA.isLoading
        }
        try check(engineA.leaseHolder?.window === first, "tab A's lease is not in the shell window")
        try checkOneLease(engineA, "shell window")
        log("PASS shell browser window: BrowserView attached tab A (lease \(engineA.attachmentID ?? 0), \(engineA.profileKey) "
            + "-> engine profile \(engineA.engineProfileID))")
        if runtime.capabilities.profileDirectory, let owner = store.profiles.first?.id {
            // Wave 16 adoption: the first shell profile opened the startup Default directory in place.
            let mapURL = runtime.userDataDir?.appendingPathComponent(ChromiumProfileStorageMap.fileName)
            let saved = mapURL.map(ChromiumProfileStorageMap.load(from:))
            try check(engineA.engineProfileID == runtime.defaultProfileID,
                      "first profile's tab is on engine profile \(engineA.engineProfileID), not the startup \(runtime.defaultProfileID)")
            try check(runtime.storageMap.legacyDefault == .adopted && runtime.storageMap.storage(for: owner) == .directory("Default"),
                      "storage map after adoption: \(runtime.storageMap)")
            try check(saved == runtime.storageMap, "persisted storage map \(String(describing: saved)) differs")
            log("PASS Default adopted in place: \(engineA.profileKey) -> startup engine profile \(runtime.defaultProfileID), "
                + "mapping persisted in \(mapURL?.lastPathComponent ?? "-")")
        }

        // A second browser window on the same space starts with nothing selected (each window
        // keeps its own tab, SidebarStore+Windows, c8ec449b): tab A stays in the first window
        // while the second is open and after it closes.
        let leaseBefore = engineA.attachmentID ?? 0
        guard let second = shell.openBrowserWindow() else { throw Failure(description: "New Window opened nothing") }
        try await wait("second browser window open") { shell.browserWindowCount == 2 && second.isVisible }
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(engineA.leaseHolder?.window === first && engineA.attachmentID != nil,
                  "opening a second window took tab A from the first (holder \(String(describing: engineA.leaseHolder?.window)))")
        try checkOneLease(engineA, "two browser windows")
        shell.closeWindow(second)
        try await wait("tab A still in the first browser window after closing the second") {
            shell.browserWindowCount == 1 && engineA.leaseHolder?.window === first && engineA.attachmentID != nil
        }
        try checkOneLease(engineA, "after closing window 2")
        try check(shell.browserWindowCount == 1 && first.isVisible && NSApp.isRunning, "closing window 2 changed the app")
        log("PASS New Window: starts with nothing selected; tab A stays in window 1 (lease \(leaseBefore) -> "
            + "\(engineA.attachmentID ?? 0)); one live attachment throughout; app still running")

        // Split view: both panes attach at once, each its own tab and lease.
        // With the page focused: its host's detach used to hide the first
        // responder mid-update and abort in AttributeGraph (QA 2026-11-10).
        try check(engineA.focusPage(), "tab A's page took no keyboard focus before Add Split View")
        model.addSplitView(orientation: .horizontal)
        guard let split = store.splitContaining(tabID: tabA.id)?.split,
              let companionTab = split.tabs.first(where: { $0.id != tabA.id }) else {
            throw Failure(description: "Add Split View created no split")
        }
        let companion = try shellEngine(model, companionTab)
        try await wait("both split panes attached", timeout: 20) {
            engineA.attachmentID != nil && companion.attachmentID != nil
                && engineA.leaseHolder?.window === first && companion.leaseHolder?.window === first
        }
        try checkOneLease(engineA, "split pane A")
        try checkOneLease(companion, "split companion")
        do {
            try await wait("tab A's page focused again in its split pane", timeout: 5) {
                engineA.leaseHolder?.pageKeyView.map { first.firstResponder === $0 } ?? false
            }
        } catch {
            // Who has the focus instead, and whether this app and window could take it at all.
            let responder = first.firstResponder.map { $0 === first ? "the window itself" : NSStringFromClass(Swift.type(of: $0)) } ?? "none"
            throw Failure(description: "\(error); first responder: \(responder); window key \(first.isKeyWindow), app active \(NSApp.isActive), "
                + "key window '\(NSApp.keyWindow?.title ?? "none")', frontmost \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "none") "
                + "(pid \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0), this is \(ProcessInfo.processInfo.processIdentifier)), "
                + "attached sheet \(first.attachedSheet.map { NSStringFromClass(Swift.type(of: $0)) } ?? "none"), "
                + "windows: \(NSApp.windows.filter(\.isVisible).map { "\(NSStringFromClass(Swift.type(of: $0))) '\($0.title)'" }.joined(separator: ", "))")
        }
        log("PASS Split View: tab \(engineA.tabID) lease \(engineA.attachmentID ?? 0) and companion tab \(companion.tabID) "
            + "lease \(companion.attachmentID ?? 0) attached side by side in window 1")
        try await splitPaneRowChecks(model: model, store: store, splitID: split.id, focused: engineA, other: companion,
                                     otherTab: companionTab.id, window: first)
        // Wave 26: flip the split, then Expand Current Split keeps the sibling open behind the focused pane.
        model.flipSplitOrientation()
        try await wait("split flipped, both panes attached", timeout: 20) {
            store.split(withID: split.id)?.orientation == split.orientation.flipped
                && engineA.attachmentID != nil && companion.attachmentID != nil
        }
        model.selectSplit(split.id, focusTabID: tabA.id)
        model.toggleExpandedSplitPane()
        let expanded = try XUnwrap(store.split(withID: split.id))
        try check(model.visibleSplitPanes(expanded, in: store.keyWindowID).map(\.id) == [tabA.id], "Expand Current Split shows "
                  + "\(model.visibleSplitPanes(expanded, in: store.keyWindowID).count) panes")
        try await wait("expanded pane attached, sibling still open", timeout: 20) {
            engineA.attachmentID != nil && engineA.leaseHolder?.window === first && companion.tabID != 0
        }
        model.toggleExpandedSplitPane()
        try await wait("split restored, both panes attached", timeout: 20) {
            engineA.attachmentID != nil && companion.attachmentID != nil
        }
        model.flipSplitOrientation()
        log("PASS Split View flip (\(split.orientation) -> \(split.orientation.flipped), panes re-attached) and Expand Current Split "
            + "(tab A alone, companion tab \(companion.tabID) kept open, restored)")
        try await splitPaneMoveChecks(model: model, store: store, splitID: split.id, paneA: engineA, tabA: tabA.id, paneB: companion,
                                      tabB: companionTab.id, base: base, window: first)
        model.closeTab(companionTab.id)
        model.selectTab(tabA.id)
        try await wait("tab A alone after closing the split companion") {
            store.splitContaining(tabID: tabA.id) == nil && engineA.attachmentID != nil
        }

        // Peek: an overlay engine in the same profile, attached over the page.
        model.showPeek(url: URL(string: "\(base)/a")!)
        guard let session = model.peekSession,
              let peek = model.engineHost.ephemeralEngine(withID: session.engineID, profileID: session.profileID) as? ChromiumEngine else {
            throw Failure(description: "Peek created no Chromium engine")
        }
        try await wait("peek attached and loaded", timeout: 20) {
            peek.attachmentID != nil && peek.pageTitle == Self.titleA && !peek.isLoading
        }
        try check(peek.role == .peek && peek.engineProfileID == engineA.engineProfileID && peek.leaseHolder?.window === first,
                  "peek role \(peek.role) profile \(peek.engineProfileID) vs \(engineA.engineProfileID)")
        log("PASS Peek: overlay tab \(peek.tabID) lease \(peek.attachmentID ?? 0) in window 1, same engine profile \(peek.engineProfileID)")
        model.dismissPeek()
        try await wait("peek dismissed") { model.peekSession == nil && runtime.liveLeaseCount(forTab: peek.tabID) == 0 }

        try await peekChromeChecks(model: model, store: store, base: base, window: first, tabA: tabA, engineA: engineA)
        try await automaticPeekChecks(model: model, store: store, base: base, window: first)
        model.selectTab(tabA.id)

        // Little Arc: its own NSWindow through BrowserWindowPresenting.
        let record = model.openLittleArc(url: URL(string: "\(base)/a")!)
        guard let littleWindow = shell.window(forLittleArc: record.id),
              let little = model.littleArcEngine(for: record.id) as? ChromiumEngine else {
            throw Failure(description: "Little ReArc opened no window/engine")
        }
        try await wait("Little ReArc attached and loaded", timeout: 20) {
            little.attachmentID != nil && little.pageTitle == Self.titleA && !little.isLoading
        }
        try check(little.role == .littleArc && little.leaseHolder?.window === littleWindow, "Little ReArc lease not in its window")
        let littleLease = little.attachmentID ?? 0
        // Wave 26 chrome: the address field loads in the Little Arc; Back (menu) acts on the key Little Arc.
        try check(model.navigateLittleArc(record.id, to: "\(base)/nav"), "Little ReArc address field refused /nav")
        try await wait("Little ReArc address field navigated", timeout: 20) {
            little.currentURL?.path == "/nav" && !little.isLoading && little.canGoBack
        }
        model.keyLittleArcID = record.id
        model.goBack()
        try await wait("Back in the key Little ReArc", timeout: 20) { little.currentURL?.path == "/a" && !little.isLoading }
        try check(engineA.currentURL?.path == "/a", "Back moved tab A instead of the Little ReArc")
        model.keyLittleArcID = nil
        log("PASS Little ReArc chrome: address field -> /nav in the Little ReArc, Back on the key Little ReArc -> /a (tab A untouched)")
        shell.dismissLittleArcWindow(record.id)
        try await wait("Little ReArc window closed and archived") {
            shell.window(forLittleArc: record.id) == nil && store.littleArcWindow(withID: record.id) == nil
        }
        try check(NSApp.isRunning && first.isVisible, "closing Little ReArc changed the app")
        log("PASS Little ReArc: own window with tab \(little.tabID) lease \(littleLease); closed (lease released: "
            + "\(little.attachmentID == nil)) and archived; app still running")
        try await littleArcOpenInOtherProfileChecks(model: model, shell: shell, store: store, base: base)
        try await littleArcPlacementChecks(model: model, shell: shell, store: store, base: base)

        // Zoom commands: Cmd+= on the focused tab; Chromium's per-host zoom also
        // reaches a sibling same-host tab of the same profile.
        let tabB = store.addTab(kind: .today, title: "Shell B", url: URL(string: "\(base)/boost")!)
        model.selectTab(tabA.id)
        // A background tab gets an engine only when something loads it (here, the test).
        try check(model.engineHost.engine(forTabID: tabB.id, profileID: model.profileID(for: tabB)) == nil,
                  "an unselected tab got an engine without being loaded")
        _ = model.engineHost.engine(for: tabB, profileID: model.profileID(for: tabB))
        let engineB = try shellEngine(model, tabB)
        engineB.load(tabB.url)
        try await wait("sibling tab B loaded", timeout: 20) { engineB.currentURL?.path == "/boost" && !engineB.isLoading }
        model.zoom(.zoomIn)
        let zoomed = PageZoom.factor(after: .zoomIn, from: 1.0)
        try await wait("zoom in on tab A and its same-host sibling") {
            abs(engineA.zoomFactor - zoomed) < PageZoom.tolerance && abs(engineB.zoomFactor - zoomed) < PageZoom.tolerance
        }
        model.zoom(.reset)
        try await wait("zoom reset on both") { PageZoom.isDefault(engineA.zoomFactor) && PageZoom.isDefault(engineB.zoomFactor) }
        log(String(format: "PASS zoom command: Zoom In -> tab A %.2f and same-host tab B %.2f (zoom events); Actual Size -> 1.00", zoomed, zoomed))

        try await sidebarNavigationChecks(model: model, store: store, tab: tabA, engine: engineA, base: base)
        try await shellFindAndHistoryChecks(model: model, engine: engineA, base: base)
        try await commandBarEngineChecks(model: model, engine: engineA, base: base)
        if runtime.capabilities.tabDiscard {
            try await discardChecks(model: model, shown: tabA, shownEngine: engineA, hidden: tabB, hiddenEngine: engineB)
        } else {
            log("ABI-GAP tab_discard not advertised: Unload Tab drops the engine")
        }
        try await passkeyHiddenTabChecks(model: model, store: store, base: base)
        try await passkeyStaleSheetChecks(model: model, store: store, base: base)
        try await passkeyHiddenLittleArcChecks(model: model, shell: shell, store: store, base: base)
        try await screenShareChecks(model: model, store: store, window: first, base: base)
        try await tabFreezeChecks(model: model, store: store, base: base)
        try await websiteDarkModeChecks(model: model, store: store, base: base)
        if runtime.capabilities.htmlFullscreen {
            try await fullscreenChecks(model: model, shell: shell, window: first, tab: tabA, engine: engineA, base: base)
        } else {
            log("ABI-GAP html_fullscreen not advertised: page fullscreen requests are refused")
        }
        try await wave26SidebarChecks(model: model, store: store, tab: tabA, engine: engineA, base: base, window: first)
        if runtime.capabilities.pictureInPicture {
            try await pictureInPictureChecks(model: model, tab: tabA, engine: engineA, other: tabB)
            if runtime.capabilities.pipEmbedded {
                try await liveVideoChecks(model: model, store: store, home: tabA, homeEngine: engineA, other: tabB, window: first)
                // The owner's black panel: YouTube's hardware-decoded MSE video, not /pip's software VP8.
                try await liveVideoChecks(model: model, store: store, home: tabA, homeEngine: engineA, other: tabB, window: first,
                                          path: "/pip-mse")
            } else {
                log("ABI-GAP pip_embedded not advertised (ABI minor < 43): PiP uses Chromium's window and strips have no track state")
            }
        } else {
            log("ABI-GAP picture_in_picture not advertised (ABI minor \(runtime.capabilities.abiMinorVersion.map(String.init) ?? "absent") < 30): Picture in Picture is WebKit-only")
        }
        try await codecChecks(model: model, store: store)
        try await prerenderChecks(model: model, store: store)
        try await taskManagerChecks(model: model, store: store, window: first)
        try await contentBlockingChecks(model: model, store: store)
        try await readerViewChecks(model: model, store: store)
        try await contentBlockingBlockedListChecks(model: model, store: store, shell: shell)
        try hostSitesChecks()
        try await siteNamesUsersChecks(model: model, store: store)
        try await wave27ShellChecks(model: model, store: store, shell: shell, tab: tabA, engine: engineA, base: base, window: first)
        try await wave28ShellChecks(model: model, store: store, tab: tabA, engine: engineA, base: base, window: first)
        try await devToolsChecks(model: model, store: store, shell: shell, tab: tabA, engine: engineA, base: base, window: first)
        try await clientCertificateChecks(model: model, store: store)
        // Closing the certificate tab selects its neighbor, which need not be
        // tab A. Restore the page used by the private-window and reopen checks.
        model.selectTab(tabA.id)
        try await wait("tab A selected after the certificate checks") {
            engineA.leaseHolder?.window === first && engineA.attachmentID != nil
        }
        try await shortcutChecks(model: model, store: store, tab: tabA, engine: engineA, base: base, window: first)
        try await settingsWindowChecks(model: model, shell: shell, window: first)
        try await searchEngineChecks(model: model, store: store)
        try await wave33UIChecks(model: model, store: store, tab: tabA, engine: engineA, other: tabB, window: first)
        try await pinnedLifecycleChecks(model: model, store: store, home: tabA, homeEngine: engineA, window: first)
        try await mediaStripElsewhereChecks(model: model, store: store, home: tabA, homeEngine: engineA, window: first)

        // Private window: PrivateWindowModel on an off-the-record profile under the
        // active profile; its end closes that profile, and a new one starts empty.
        _ = try await engineA.evaluate("(document.cookie = 'rearc_shell=normal; path=/; max-age=3600', document.cookie)", in: .page)
        let privateWindow = model.openPrivateWindow(url: URL(string: "\(base)/a")!)
        guard let privateEngine = privateWindow.engine as? ChromiumEngine else {
            throw Failure(description: "private window engine is not Chromium")
        }
        try await wait("private window attached and loaded", timeout: 20) {
            privateEngine.attachmentID != nil && privateEngine.pageTitle == Self.titleA && !privateEngine.isLoading
                && privateWindow.hostWindow != nil
        }
        let privateKey = privateEngine.profileKey
        try check(privateKey == .offTheRecord(session: privateWindow.session, parent: store.activeProfileID)
                  && privateEngine.role == .privateWindow && privateEngine.engineProfileID != engineA.engineProfileID
                  && privateEngine.leaseHolder?.window === privateWindow.hostWindow,
                  "private window: \(privateKey) engine profile \(privateEngine.engineProfileID)")
        let privateCookies = try await cookies(privateEngine)
        try check(!privateCookies.contains("rearc_shell"), "private window sees the normal cookie ('\(privateCookies)')")
        _ = try await privateEngine.evaluate("(document.cookie = 'rearc_private_window=1; path=/', document.cookie)", in: .page)
        let normalCookies = try await cookies(engineA)
        try check(!normalCookies.contains("rearc_private_window"), "normal tab sees the private cookie ('\(normalCookies)')")
        if NSApp.keyWindow === privateWindow.hostWindow {
            model.zoom(.zoomIn)
            try await wait("zoom command on the key private window") { !PageZoom.isDefault(privateEngine.zoomFactor) }
            try check(PageZoom.isDefault(engineA.zoomFactor), "private-window zoom changed the normal tab")
            log(String(format: "PASS zoom command targets the key private window (%.2f); normal tab stays 1.00", privateEngine.zoomFactor))
        } else {
            log("NOTE the private window is not key (app inactive); its zoom-command routing is not exercised")
        }
        let privateProfileID = privateEngine.engineProfileID
        var events: [String] = []
        runtime.onProfileEvent = { events.append($0) }
        guard let privateNSWindow = privateWindow.hostWindow else { throw Failure(description: "private window has no NSWindow") }
        shell.closeWindow(privateNSWindow)
        try await wait("private session closed", timeout: 20) {
            events.contains { $0.hasPrefix("closed private session") } && runtime.engineProfileID(for: privateKey) == nil
        }
        runtime.onProfileEvent = nil
        try check(model.privateWindows.isEmpty && NSApp.isRunning && first.isVisible, "closing the private window changed the app")
        let again = model.openPrivateWindow(url: URL(string: "\(base)/a")!)
        guard let againEngine = again.engine as? ChromiumEngine else { throw Failure(description: "second private engine") }
        try await wait("second private window loaded", timeout: 20) { againEngine.pageTitle == Self.titleA && !againEngine.isLoading }
        let againCookies = try await cookies(againEngine)
        try check(againEngine.engineProfileID != privateProfileID && !againCookies.contains("rearc_private_window"),
                  "new private session: engine profile \(againEngine.engineProfileID), cookies '\(againCookies)'")
        if let againWindow = again.hostWindow { shell.closeWindow(againWindow) }
        try await wait("second private session closed", timeout: 20) {
            model.privateWindows.isEmpty && runtime.engineProfileID(for: againEngine.profileKey) == nil
        }
        log("PASS private window: \(privateKey) -> engine profile \(privateProfileID), normal cookie invisible, private cookie "
            + "stays out of the normal tab; window close -> \(events.filter { $0.hasPrefix("closed") }.joined(separator: ", ")); "
            + "next private window -> new engine profile \(againEngine.engineProfileID) without the old cookie")

        // Closing every window keeps the app (and engine) running; activation reopens one.
        shell.closeWindow(first)
        try await wait("all shell windows closed") { shell.windowCount == 0 && engineA.attachmentID == nil }
        try check(NSApp.isRunning && runtime.isReady && !runtime.isStopping, "closing the last window stopped the app")
        shell.reopenIfNoWindows()
        guard let reopened = shell.browserWindows.first else { throw Failure(description: "reopen opened no window") }
        try await wait("tab A re-attached in the reopened window", timeout: 20) {
            engineA.leaseHolder?.window === reopened && engineA.attachmentID != nil
        }
        try checkOneLease(engineA, "reopened window")
        log("PASS closing the last window kept the app running (no quit); reopen attached tab A again (lease \(engineA.attachmentID ?? 0))")
        try await windowSessionChecks(shell: shell, model: model, sessionFile: sessionFile)
        try await sidebarPerWindowChecks(shell: shell, model: model)
        try? FileManager.default.removeItem(at: shellData)
    }

    /// Window session restore (docs/WINDOW-RESTORE.md): two browser windows on
    /// two ReArc spaces with set frames are saved, closed (as a quit would leave
    /// the file) and restored; frames, z-order, key window and spaces come back.
    /// Frames stay on the primary display, so this passes with one display; the
    /// display and desktop moves are the manual checks in WINDOW-RESTORE.md.
    @MainActor
    private func windowSessionChecks(shell: ChromiumShell, model: BrowserViewModel, sessionFile: URL) async throws {
        let store = model.store
        let home = store.activeSpace
        let work = store.addSpace(name: "Session Work")
        for window in shell.browserWindows where window !== shell.browserWindows.first { shell.closeWindow(window) }
        guard let first = shell.browserWindows.first, let second = shell.openBrowserWindow(),
              let firstID = shell.sidebarWindowID(of: first), let secondID = shell.sidebarWindowID(of: second) else {
            throw Failure(description: "session: two browser windows did not open")
        }
        guard let visible = NSScreen.screens.first?.visibleFrame else { throw Failure(description: "session: no display") }
        let frameA = WindowPlacement.clamp(CGRect(x: visible.minX + 40, y: visible.maxY - 700, width: 900, height: 640), into: visible)
        let frameB = WindowPlacement.clamp(CGRect(x: visible.minX + 260, y: visible.maxY - 780, width: 860, height: 600), into: visible)
        first.setFrame(frameA, display: true)
        second.setFrame(frameB, display: true)
        // Window 2 on the Work space, then window 1 key on Home (and in front).
        model.windowBecameKey(secondID)
        store.selectSpace(work.id)
        first.makeKeyAndOrderFront(nil)
        model.windowBecameKey(firstID)
        store.selectSpace(home.id)
        try check(store.focusedSpaceID(in: secondID) == work.id && store.focusedSpaceID(in: firstID) == home.id,
                  "session setup: window spaces \(store.focusedSpaceID(in: firstID)) / \(store.focusedSpaceID(in: secondID))")

        shell.saveWindowSession()
        let savedData = try Data(contentsOf: sessionFile)
        let saved = try XUnwrap(WindowSessionFile.decode(savedData))
        try check(saved.windows.count == 2, "session saved \(saved.windows.count) windows")
        let savedKey = try XUnwrap(saved.launchWindow)
        try check(savedKey.isKey && savedKey.frame == frameA && savedKey.spaceID == home.id,
                  "saved key window: \(savedKey.frame) space \(String(describing: savedKey.spaceID))")
        let savedOther = try XUnwrap(saved.otherWindows.first)
        try check(savedOther.frame == frameB && savedOther.spaceID == work.id && savedOther.profileID == work.profileID,
                  "saved second window: \(savedOther.frame) space \(String(describing: savedOther.spaceID))")
        try check(saved.windows.allSatisfy { $0.display?.uuid != nil && $0.appKitState?.isEmpty == false },
                  "saved windows lack a display UUID or AppKit (desktop) state")
        log("PASS window session saved: 2 windows, key \(savedKey.frame) on \(home.name), second \(savedOther.frame) on \(work.name), "
            + "display \(savedKey.display?.uuid ?? "-"), AppKit state \(savedKey.appKitState?.count ?? 0) bytes")

        shell.closeWindow(second)
        shell.closeWindow(first)
        try await wait("session windows closed") { shell.browserWindowCount == 0 }
        try await wait("closing them saved the session", timeout: 5) {
            WindowSessionFile.load(from: sessionFile).map { $0.windows.isEmpty && $0.lastClosed != nil } ?? false
        }
        // A quit saves before its windows close: put that file back, then launch-restore it.
        try savedData.write(to: sessionFile, options: [.atomic])
        let restored = shell.restoreWindowSession()
        try check(restored.count == 2, "restore opened \(restored.count) windows")
        let restoredIDs = restored.compactMap(shell.sidebarWindowID(of:))
        try check(restoredIDs.count == 2, "restored windows have no sidebar window ID")
        try check(restored[0].frame == frameA && restored[1].frame == frameB,
                  "restored frames \(restored[0].frame) / \(restored[1].frame), expected \(frameA) / \(frameB)")
        try check(store.focusedSpaceID(in: restoredIDs[1]) == work.id,
                  "restored second window shows \(store.focusedSpaceID(in: restoredIDs[1])), not \(work.name)")
        try await wait("restored key window back on its space") {
            store.keyWindowID == restoredIDs[0] && store.activeSpaceID == home.id
        }
        let order = NSApp.orderedWindows.filter { restored.contains($0) }
        try check(order.first === restored[0], "restored z-order: the key window is not in front")
        try check(restored.allSatisfy(\.isOnActiveSpace), "a restored window left the current desktop")
        log("PASS window session restored: frames \(restored[0].frame) / \(restored[1].frame), key window in front on "
            + "\(home.name), second on \(work.name); both on this desktop")
        shell.closeWindow(restored[1])
        try await wait("one window left") { shell.browserWindowCount == 1 }
        _ = store.removeSpace(work.id)
    }

    /// ⌘S per window. The owner's recording (builds 1080 and 1105) has two
    /// browser windows side by side and ⌘S pressed three times: both sidebars
    /// went and came back together, because the model the windows share held
    /// one shown-or-hidden value. Here: two windows, ⌘S in the second, and the
    /// first keeps its sidebar, in the model and on screen (its traffic
    /// lights, which go with the sidebar, and its page's width). Then the View
    /// menu's title follows the key window, a window opened from the hidden
    /// one starts hidden, a closed one is forgotten, and three presses in the
    /// first window leave the second as it was.
    @MainActor
    private func sidebarPerWindowChecks(shell: ChromiumShell, model: BrowserViewModel) async throws {
        guard let first = shell.browserWindows.first, let firstID = shell.sidebarWindowID(of: first) else {
            throw Failure(description: "per-window sidebar: no browser window")
        }
        func lightsHidden(_ window: NSWindow) -> Bool { window.standardWindowButton(.closeButton)?.isHidden ?? false }
        func pageWidth(_ window: NSWindow) -> CGFloat? { window.contentView?.firstDescendant(ofType: ChromiumHostView.self)?.bounds.width }
        func makeKey(_ window: NSWindow, _ id: SidebarWindowID, _ label: String) async -> KeyDelivery {
            let delivery: KeyDelivery = await bringToFront(window, for: label) ? .appKit : .direct
            window.makeKeyAndOrderFront(nil)
            model.windowBecameKey(id)
            return delivery
        }
        func commandS(in window: NSWindow, _ id: SidebarWindowID, _ label: String, shows: Bool) async throws {
            let delivery = await makeKey(window, id, label)
            press("s", keyCode: 1, .command, in: window, model: model, delivery: delivery)
            try await wait("⌘S \(shows ? "showed" : "hid") the sidebar of \(label)", timeout: 5) {
                model.isSidebarVisible(in: id) == shows && !model.isSidebarSliding(in: id)
            }
            try await wait("the traffic lights of \(label) went with its sidebar", timeout: 5) { lightsHidden(window) == !shows }
        }

        _ = await makeKey(first, firstID, "the first window")
        if !model.isSidebarVisible(in: firstID) { model.toggleSidebar(in: firstID) }
        try await wait("the first window shows its sidebar", timeout: 5) {
            model.sidebarVisibility.state(in: firstID) == .shown && !lightsHidden(first)
        }
        guard let second = shell.openBrowserWindow(), let secondID = shell.sidebarWindowID(of: second) else {
            throw Failure(description: "per-window sidebar: the second window did not open")
        }
        second.setFrame(first.frame.offsetBy(dx: 80, dy: -60), display: true)
        try check(model.isSidebarVisible(in: secondID), "a window opened from one with its sidebar shown came up hidden")
        try await Task.sleep(nanoseconds: 500_000_000)
        let firstWidth = pageWidth(first)

        // The bug: this hid the first window's sidebar too.
        try await commandS(in: second, secondID, "the second window", shows: false)
        try await Task.sleep(nanoseconds: 700_000_000)
        try check(model.sidebarVisibility.state(in: firstID) == .shown,
                  "⌘S in the second window changed the first window's sidebar: \(model.sidebarVisibility.state(in: firstID))")
        try check(!lightsHidden(first), "⌘S in the second window hid the first window's traffic lights, so its sidebar went too")
        if let firstWidth, let now = pageWidth(first) {
            try check(abs(now - firstWidth) < 1, "⌘S in the second window resized the first window's page (\(firstWidth) -> \(now))")
        }
        try check(model.sidebarMenuTitle == "Show Sidebar", "the View menu says \(model.sidebarMenuTitle) with the key window's sidebar hidden")

        // A window opened from the hidden one starts hidden, and closing it forgets it.
        guard let third = shell.openBrowserWindow(), let thirdID = shell.sidebarWindowID(of: third) else {
            throw Failure(description: "per-window sidebar: the third window did not open")
        }
        try check(!model.isSidebarVisible(in: thirdID), "a window opened from one with its sidebar hidden came up shown")
        try await wait("the third window came up without traffic lights", timeout: 5) { lightsHidden(third) }
        shell.closeWindow(third)
        try await wait("the closed window's sidebar state is forgotten", timeout: 5) {
            shell.browserWindowCount == 2 && !model.sidebarVisibility.isRegistered(thirdID)
        }

        // The recording's three presses, in the first window: the second never moves.
        _ = await makeKey(first, firstID, "the first window")
        try check(model.sidebarMenuTitle == "Hide Sidebar", "the View menu says \(model.sidebarMenuTitle) with the key window's sidebar shown")
        for shows in [false, true, false] {
            try await commandS(in: first, firstID, "the first window", shows: shows)
            try check(model.sidebarVisibility.state(in: secondID) == .hidden && lightsHidden(second),
                      "⌘S in the first window changed the second window's sidebar: \(model.sidebarVisibility.state(in: secondID))")
        }
        try await commandS(in: first, firstID, "the first window", shows: true)
        try check(!model.isSidebarVisible(in: secondID), "the second window's sidebar came back with the first window's")

        shell.closeWindow(second)
        try await wait("one window left after the per-window sidebar step") {
            shell.browserWindowCount == 1 && !model.sidebarVisibility.isRegistered(secondID)
        }
        _ = await makeKey(first, firstID, "the first window")
        try check(model.isSidebarVisible(in: model.store.keyWindowID), "the first window's sidebar is hidden after the step")
        log("PASS ⌘S per window: with two browser windows, ⌘S in the second hid only its sidebar (the first kept its sidebar, traffic "
            + "lights and page width\(firstWidth.map { " \(Int($0)) pt" } ?? "")); the View menu's title followed the key window; a window "
            + "opened from the hidden one started hidden and was forgotten when closed; three ⌘S in the first window left the second hidden")
    }

    // MARK: Sidebar navigation controls (wave 17)

    /// The shell's own paths: Cmd+F on BrowserView's tab, and command-bar
    /// history recorded from the navigations the shell just made.
    @MainActor
    private func shellFindAndHistoryChecks(model: BrowserViewModel, engine: ChromiumEngine, base: String) async throws {
        let navURL = URL(string: "\(base)/nav")!
        let visit = model.visitHistory.record(for: navURL)
        try check(visit != nil, "the shell recorded no visit for /nav (\(model.visitHistory.count) visit(s))")
        model.commandBarText = "nav:"
        let historyRow = model.commandBarResults.first { $0.kind == .history }
        try check(historyRow?.destinationURL.flatMap(VisitHistory.key(for:)) == VisitHistory.key(for: navURL),
                  "command bar history row: \(historyRow.map { "\($0.title) \($0.destinationURL?.absoluteString ?? "")" } ?? "none")")
        model.commandBarText = ""
        if runtime.capabilities.findInPage {
            model.showFindBar()
            try check(model.findBar.isShown(for: engine), "Cmd+F did not open the find bar on tab A")
            model.findBar.setQuery("selftest page")
            try await wait("shell find bar result") { model.findBar.statusText == "1 of 1" }
            model.findNext(forward: true)
            try await wait("shell find next wraps") { model.findBar.state.activeOrdinal == 1 && model.findBar.state.sessionID != 0 }
            model.closeFindBar()
            try check(!model.findBar.isPresented, "find bar still open")
        }
        log("PASS shell find and history: /nav recorded (\(visit?.visitCount ?? 0) visit(s), '\(visit?.title ?? "")'), "
            + "command bar 'nav:' -> history row '\(historyRow?.title ?? "")'"
            + (runtime.capabilities.findInPage ? "; Cmd+F on tab A -> '1 of 1', Cmd+G wraps, Esc closes" : ""))
    }

    // MARK: Wave 23: dangerous downloads (ABI 1.24)

    /// Two inert .sh downloads that Chromium's manual hash blocklist marks
    /// dangerous, started with a link transition (a typed navigation to a
    /// download skips the warning): Keep validates one to completion, Discard
    /// removes the other and its file. Nothing opens either file.
    @MainActor
    private func dangerousDownloadChecks(engine: ChromiumEngine, base: String, controller: DownloadsController, directory: URL) async throws -> String {
        func row(_ name: String) -> DownloadRecord? {
            controller.records.first { $0.fileName.hasPrefix(name) || $0.url.hasSuffix("/\(name)") }
        }
        func linkDownload(_ name: String) throws {
            let status = "\(base)/download/\(name)".withCString { ReArcTabNavigate(engine.tabID, $0, 1) }
            try check(status == .rearcOK, "link-transition download of \(name) returned \(status.rearcName)")
        }
        let size = ChromiumLaunchArguments.selfTestDangerousDownloadSize

        try linkDownload("rearc-danger-keep.sh")
        try await wait("dangerous download warning (keep)", timeout: 20) { row("rearc-danger-keep.sh").map(controller.canKeep) ?? false }
        let keepID = try XUnwrap(row("rearc-danger-keep.sh")).id
        let warning = try XUnwrap(controller.warnings[keepID])
        try check(warning.isDangerous && controller.hasDangerous, "keep warning \(warning)")
        try check(controller.keep(keepID), "Keep was not accepted")
        try await wait("kept download completes", timeout: 20) { row("rearc-danger-keep.sh")?.state == .complete }
        let kept = try XUnwrap(row("rearc-danger-keep.sh"))
        let keptSize = (try? FileManager.default.attributesOfItem(atPath: kept.targetPath))?[.size] as? Int ?? -1
        try check(keptSize == size && !controller.needsDecision(kept), "kept file \(kept.targetPath) has \(keptSize) bytes")

        try linkDownload("rearc-danger-discard.sh")
        try await wait("dangerous download warning (discard)", timeout: 20) { row("rearc-danger-discard.sh").map(controller.canKeep) ?? false }
        let discardRecord = try XUnwrap(row("rearc-danger-discard.sh"))
        controller.discard(discardRecord.id)
        try await wait("discarded download removed", timeout: 20) { row("rearc-danger-discard.sh") == nil }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        try check(!leftovers.contains { $0.contains("discard") || $0.hasSuffix(".crdownload") }, "discarded files left: \(leftovers)")
        try await wait("tab still on page A after the downloads", timeout: 5) { engine.currentURL?.path == "/a" }

        controller.perform(.remove, on: kept.id)
        try await wait("kept row removed") { row("rearc-danger-keep.sh") == nil }
        try? FileManager.default.removeItem(atPath: kept.targetPath)
        return "PASS dangerous downloads (ABI 1.24): danger \(warning.dangerType) on a blocklisted inert .sh -> tray Keep -> "
            + "complete \(keptSize) B; second -> tray Discard -> item and file removed (directory: \(leftovers.sorted()))"
    }

    // MARK: Wave 23: command bar from the engine (ABI 1.23, 1.26)

    @MainActor
    private func historyRows(_ profile: UInt64, _ text: String) async -> [ChromiumHistoryRow] {
        await withCheckedContinuation { continuation in
            let status = runtime.queryHistory(profile: profile, text: text, limit: 100) { _, rows in continuation.resume(returning: rows) }
            if status != .rearcOK { continuation.resume(returning: []) }
        }
    }

    /// History rows from HistoryService with Remove from History, the
    /// default search, classification and live suggestions (from a loopback
    /// provider, so nothing reaches a real search engine), and a superseded
    /// autocomplete query ending cancelled.
    @MainActor
    private func commandBarEngineChecks(model: BrowserViewModel, engine: ChromiumEngine, base: String) async throws {
        let capabilities = runtime.capabilities
        guard let services = model.commandBarServices as? ChromiumCommandBarServices else {
            throw Failure(description: "the Chromium shell did not install its command-bar services")
        }
        let profile = engine.engineProfileID
        let navURL = URL(string: "\(base)/nav")!
        var notes: [String] = []
        model.dismissCommandBar()
        if capabilities.searchAutocomplete {
            // A loopback default search first, so no typed text reaches a real search engine.
            let original = model.searchProvider
            let loopback = SearchProvider(id: "selftest", name: "ReArc Selftest Search", keyword: "search.selftest.invalid",
                                          searchTemplate: "\(base)/search?q=%s", suggestTemplate: "\(base)/suggest?q=%s")
            var setStatus: ReArcStatus?
            runtime.setDefaultSearchProvider(profile: profile, loopback) { setStatus = $0 }
            try await wait("default search set") { setStatus != nil }
            try check(setStatus == .rearcOK, "ReArcSearchSetDefaultProvider returned \(setStatus?.rearcName ?? "-")")
            services.refreshSearchProvider(for: model.store.activeProfileID)
            try await wait("default search read back", timeout: 10) { model.searchProvider.searchTemplate == loopback.searchTemplate }
            notes.append("default search '\(original.name)' -> loopback '\(model.searchProvider.name)' (ReArcSearchSetDefaultProvider)")
        }
        model.isCommandBarPresented = true

        if capabilities.historyQuery {
            var rows: [ChromiumHistoryRow] = []
            try await waitAsync("HistoryService lists /nav", timeout: 15) {
                rows = await historyRows(profile, "nav")
                return rows.contains { $0.url.hasSuffix("/nav") }
            }
            model.commandBarText = "nav"
            try await wait("engine history in the command bar", timeout: 10) {
                model.commandBarLive?.history?.contains { $0.url.path == "/nav" } == true
                    && model.commandBarResults.contains { $0.kind == .history && $0.destinationURL?.path == "/nav" }
            }
            let index = try XUnwrap(model.commandBarResults.firstIndex { $0.kind == .history && $0.destinationURL?.path == "/nav" })
            let engineVisits = rows.first { $0.url.hasSuffix("/nav") }?.visitCount ?? 0
            model.commandBarHighlightedIndex = index
            try check(model.deleteHighlightedCommandBarHistoryRow(), "Shift+Delete did not remove the /nav row")
            try await waitAsync("HistoryService forgets /nav", timeout: 15) {
                !(await historyRows(profile, "nav")).contains { $0.url.hasSuffix("/nav") }
            }
            try check(model.visitHistory.record(for: navURL) == nil, "History.json still lists /nav")
            try await wait("command bar re-queried without /nav", timeout: 10) {
                model.commandBarLive.map { $0.applies(to: "nav") && !($0.history ?? []).contains { $0.url.path == "/nav" } } ?? false
            }
            let refused = await withCheckedContinuation { continuation in
                let status = runtime.queryHistory(profile: profile, text: "", limit: 0) { status, _ in continuation.resume(returning: status) }
                if status != .rearcOK { continuation.resume(returning: status) }
            }
            try check(refused == ReArcStatus(REARC_INVALID_ARGUMENT), "limit 0 returned \(refused.rearcName)")
            notes.append("history: HistoryService /nav (\(engineVisits) visit(s)) -> command-bar row -> Shift+Delete removed it from "
                + "HistoryService and History.json; limit 0 -> \(refused.rearcName)")
        } else {
            notes.append("ABI-GAP history_query not advertised: the command bar uses History.json")
        }

        if capabilities.searchAutocomplete {
            let provider = model.searchProvider

            let suggestBefore = LoopbackFixtureServer.suggestQueries.count
            model.commandBarText = "panda selftest words"
            try await wait("classification and suggestions", timeout: 15) {
                guard let live = model.commandBarLive, live.applies(to: "panda selftest words"),
                      case .search(let url) = live.classification else { return false }
                // Remote suggestions arrive in a later partial result than the typed-text match.
                return url.absoluteString.hasPrefix("\(base)/search") && model.commandBarResults.contains { $0.kind == .suggestion }
            }
            let suggestion = try XUnwrap(model.commandBarResults.first { $0.kind == .suggestion })
            let suggestionRows = model.commandBarResults.filter { $0.kind == .suggestion }.count
            try check(suggestion.title == "panda selftest words suggestion one" && suggestion.destinationURL?.path == "/search",
                      "suggestion row \(suggestion.title) \(suggestion.destinationURL?.absoluteString ?? "")")
            try check(model.commandBarResults.last?.destinationURL?.absoluteString.hasPrefix("\(base)/search") == true,
                      "the search fallback does not use the engine's provider")
            try check(LoopbackFixtureServer.suggestQueries.count > suggestBefore, "no suggest request reached the provider")

            let address = "127.0.0.1:\(URL(string: base)?.port ?? 0)/a"
            model.commandBarText = address
            try await wait("an address classifies as a URL", timeout: 10) {
                guard let live = model.commandBarLive, live.applies(to: address), case .url(let url) = live.classification else { return false }
                return url.path == "/a"
            }
            try check(model.commandBarResults.first?.kind == .openURL, "the typed address is not the first row")

            var first: [ChromiumAutocompleteUpdate] = []
            var second: [ChromiumAutocompleteUpdate] = []
            let q1 = runtime.startAutocomplete(profile: profile, text: "rearc first") { first.append($0) }
            let q2 = runtime.startAutocomplete(profile: profile, text: "rearc second") { second.append($0) }
            try await wait("superseded autocomplete ends", timeout: 15) { first.last?.done == true && second.last?.done == true }
            try check(q1 != nil && q2 != nil && q1 != q2, "autocomplete query IDs \(String(describing: q1)) \(String(describing: q2))")
            try check(first.last?.status == ReArcStatus(REARC_CANCELLED) && second.last?.status == .rearcOK,
                      "superseded query ended \(first.last?.status.rearcName ?? "-"), newer \(second.last?.status.rearcName ?? "-")")
            notes.append("search: \(provider.searchTemplate); 'panda selftest words' -> search "
                + "with \(suggestionRows) suggestion row(s) from the provider's suggest endpoint; "
                + "'\(address)' -> URL; superseded query -> cancelled, newer -> OK; deliveries \(services.deliveries)")
        } else {
            notes.append("ABI-GAP search_autocomplete not advertised: the shell search preference and suggest fetch are used")
        }
        model.dismissCommandBar()
        try await wait("command-bar call contexts released", timeout: 10) { runtime.liveCommandBarContexts == 0 }
        log("PASS command bar from the engine: " + notes.joined(separator: "; "))
    }

    // MARK: Wave 23: tab discard (ABI 1.25)

    @MainActor
    private func discardChecks(model: BrowserViewModel, shown: Tab, shownEngine: ChromiumEngine, hidden: Tab, hiddenEngine: ChromiumEngine) async throws {
        try await wait("hidden tab idle", timeout: 15) { !hiddenEngine.isLoading && hiddenEngine.currentURL?.path == "/boost" }
        let visible = shownEngine.discard()
        try check(visible == .refusedForNow && !shownEngine.isDiscarded, "discarding the shown tab returned \(visible)")
        let generation = hiddenEngine.contentGeneration
        let documentBefore = runtime.documentIdentity(tab: hiddenEngine.tabID)
        model.unloadTab(hidden.id)
        try await wait("hidden tab discarded", timeout: 10) {
            hiddenEngine.isDiscarded && hiddenEngine.queryDiscardState() == true && model.isTabUnloaded(hidden.id)
        }
        try check(model.engineHost.engine(forTabID: hidden.id, profileID: model.profileID(for: hidden)) === hiddenEngine,
                  "discard dropped the engine")
        try check(!model.canUnloadTab(hidden.id), "Unload Tab still offered for a discarded tab")
        model.selectTab(hidden.id)
        try await wait("discarded tab restored when shown", timeout: 20) {
            guard !hiddenEngine.isDiscarded, hiddenEngine.attachmentID != nil, !hiddenEngine.isLoading,
                  !model.isTabUnloaded(hidden.id), let after = runtime.documentIdentity(tab: hiddenEngine.tabID) else { return false }
            // The restored page is a new document (its identity advances on commit).
            return documentBefore.map { !after.isSameDocument(as: $0) } ?? true
        }
        try check(hiddenEngine.queryDiscardState() == false && hiddenEngine.contentGeneration == generation,
                  "restored tab: discarded \(String(describing: hiddenEngine.queryDiscardState())) generation \(hiddenEngine.contentGeneration) vs \(generation)")
        model.selectTab(shown.id)
        try await wait("tab A shown again", timeout: 10) { shownEngine.attachmentID != nil }
        log("PASS tab discard (ABI 1.25): shown tab -> refused; Unload Tab on hidden tab B -> discarded (kind 5, state true, "
            + "engine and content generation \(generation) kept, row dimmed); selecting B restored it as a new document "
            + "(\(documentBefore.map { "\($0.documentGeneration)" } ?? "?") -> "
            + "\(runtime.documentIdentity(tab: hiddenEngine.tabID).map { "\($0.documentGeneration)" } ?? "?"))")
    }

    // MARK: Tab freezing (ABI 1.71)

    /// Tab sleep's first stage, end to end through the engine. A page in a
    /// tab nobody looks at is frozen by the model's own check once it is due:
    /// its timer stops (its title stops counting, and nothing asks the page:
    /// a script of the shell's would thaw it), it stays loaded and its row
    /// stays as it is. Showing the tab runs it again at once, in the same
    /// document: nothing is loaded again, and the page saw one freeze and
    /// one resume. A page that plays is not frozen, by the model's check or
    /// by the engine when asked. Turning the setting to Never thaws a frozen
    /// tab. The launch carries `selfTestFreezeSwitch`, so Chromium's five
    /// minutes of protection after a tab was on screen are one second here.
    @MainActor
    private func tabFreezeChecks(model: BrowserViewModel, store: SidebarStore, base: String) async throws {
        guard runtime.capabilities.tabFreeze, ChromiumTabFreezeCalls.shared != nil else {
            let missing = ChromiumTabFreezeCalls.missingSymbols
            return log("ABI-GAP \(ChromiumCapabilities.tabFreezeFeature) not advertised"
                + (missing.isEmpty ? "" : " (missing \(missing.joined(separator: ", ")))") + ": pages run until they are unloaded")
        }
        let previous = store.selectedTab?.id
        // The choice is the person's: this step writes it to a scratch domain and puts it back.
        let savedDefaults = model.tabUnloadDefaults
        let savedThreshold = model.tabFreezeThreshold
        let scratchName = "darni-selftest-sleep-\(UUID().uuidString)"
        guard let scratch = UserDefaults(suiteName: scratchName) else { throw Failure(description: "no scratch defaults for the freeze step") }
        model.tabUnloadDefaults = scratch
        model.tabFreezeThreshold = .thirtyMinutes
        defer {
            model.tabFreezeThreshold = savedThreshold
            model.tabUnloadDefaults = savedDefaults
            scratch.removePersistentDomain(forName: scratchName)
        }

        let sleepURL = URL(string: "\(base)/sleep")!
        let sleeper = store.addTab(kind: .today, title: "Sleeper", url: sleepURL)
        _ = model.engineHost.engine(for: sleeper, profileID: model.profileID(for: sleeper))
        let engine = try shellEngine(model, sleeper)
        engine.load(sleepURL)
        func ticks() -> Int { Int((engine.pageTitle ?? "").dropFirst("sleep ".count)) ?? -1 }
        func state() async throws -> [String] {
            ((try await engine.evaluate("sleepState()", in: .page)) as? String ?? "").split(separator: ":").map(String.init)
        }
        try await wait("the sleep fixture's timer runs in a tab never shown", timeout: 30) { ticks() >= 2 && !engine.isLoading }
        let boot = (try await engine.evaluate("sleepMark()", in: .page)) as? String ?? ""
        let document = runtime.documentIdentity(tab: engine.tabID)

        // Not due: seen a moment ago.
        model.tabLastShown[sleeper.id] = Date()
        try check(!model.runAutoFreeze().contains(sleeper.id) && !model.isTabFrozen(sleeper.id), "a tab seen a moment ago was frozen")
        // Due: the model's own check asks, and Chromium freezes the page.
        model.tabLastShown[sleeper.id] = Date().addingTimeInterval(-31 * 60)
        let asked = model.runAutoFreeze()
        try check(asked.contains(sleeper.id) && model.isTabFrozen(sleeper.id), "the check did not freeze a tab unseen for 31 minutes: asked \(asked.count)")
        try await wait("the page reports frozen", timeout: 20) { engine.queryFreezeState()?.frozen == true }
        let frozenAt = ticks()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        // At most the one tick that was on its way.
        try check(ticks() <= frozenAt + 1 && engine.queryFreezeState()?.frozen == true,
                  "the frozen page's timer ran: \(frozenAt) -> \(ticks()) ticks in 3 s")
        try check(!model.isTabUnloaded(sleeper.id) && !engine.isDiscarded && engine.activity == .idle,
                  "a frozen tab shows as unloaded")
        let silentTicks = ticks()

        // Shown: it runs again at once, and it is the same document.
        model.selectTab(sleeper.id)
        try await wait("the tab thaws when shown", timeout: 10) {
            engine.attachmentID != nil && engine.queryFreezeState().map { !$0.requested && !$0.frozen } == true
        }
        try await wait("the page's timer runs again", timeout: 20) { ticks() > silentTicks + 1 }
        let shown = try await state()
        try check(shown.count == 7 && shown[0] == boot && shown[6] == "false" && shown[5] == "false",
                  "the shown page is not the page that was frozen: \(shown) vs boot \(boot)")
        try check((Int(shown[2]) ?? 0) >= 2500 && shown[3] == "1" && shown[4] == "1",
                  "the page did not stop for the freeze: longest gap \(shown[2]) ms, freeze \(shown[3]), resume \(shown[4])")
        let documentAfter = runtime.documentIdentity(tab: engine.tabID)
        try check(document != nil && documentAfter.map { $0.isSameDocument(as: document!) } == true && !engine.isLoading,
                  "showing a frozen tab loaded a document: \(String(describing: document)) -> \(String(describing: documentAfter))")
        try check(engine.freeze() == .refusedForNow && !model.isTabFrozen(sleeper.id), "the engine took a freeze request for the tab on screen")

        // A page that plays is not frozen: not by the check, and not by the engine.
        let playURL = URL(string: "\(base)/pip")!
        let player = store.addTab(kind: .today, title: "Player", url: playURL)
        _ = model.engineHost.engine(for: player, profileID: model.profileID(for: player))
        let playerEngine = try shellEngine(model, player)
        model.selectTab(player.id)
        playerEngine.load(playURL)
        try await wait("the player plays", timeout: 30) { playerEngine.pageTitle == "pip-playing" }
        // Leave it: the sleeper is on screen, the player plays unseen (or in Picture in Picture).
        model.selectTab(sleeper.id)
        try await wait("the model knows the hidden player plays", timeout: 15) {
            let media = model.mediaState(for: player.id)
            return media.isPlaying || media.isAudible || media.isPictureInPicture
        }
        model.tabLastShown[player.id] = Date().addingTimeInterval(-31 * 60)
        try check(!model.runAutoFreeze().contains(player.id) && !model.isTabFrozen(player.id), "the check froze a tab that plays")
        let direct = playerEngine.freeze()
        try check(direct == .refusedForNow && playerEngine.queryFreezeState()?.requested == false,
                  "the engine took a freeze request for a playing tab: \(direct)")

        // Hidden again and due: frozen again once Chromium's protection time is over; Never thaws it.
        model.selectTab(player.id)
        model.tabLastShown[sleeper.id] = Date().addingTimeInterval(-31 * 60)
        // The engine refuses while the page is still leaving the screen: the check asks again.
        try await wait("a tab hidden again and due is taken by the engine", timeout: 15) {
            model.runAutoFreeze()
            return model.isTabFrozen(sleeper.id)
        }
        try await wait("the page is frozen again", timeout: 30) { engine.queryFreezeState()?.frozen == true }
        let again = ticks()
        model.tabFreezeThreshold = .never
        try check(!model.isTabFrozen(sleeper.id), "Never left a tab frozen")
        try await wait("the page runs again with freezing off", timeout: 20) { ticks() > again + 1 }
        try check(!model.runAutoFreeze().contains(sleeper.id), "Never froze a tab")

        model.closeTab(player.id)
        model.closeTab(sleeper.id)
        try await wait("the freeze tabs closed") { store.tab(withID: player.id) == nil && store.tab(withID: sleeper.id) == nil }
        if let previous { model.selectTab(previous) }
        log("PASS tab freezing (ABI 1.71): a tab unseen for 31 minutes -> frozen by the check (timer \(frozenAt) -> \(silentTicks) ticks in 3 s, "
            + "row not dimmed); shown -> running at once in the same document (longest gap \(shown[2]) ms, one freeze and one resume event, "
            + "no load); a playing tab -> not asked, engine \(direct); hidden again -> frozen again; Never -> thawed")
    }

    // MARK: Dark mode for websites (ABI 1.73)

    /// Dark mode for websites through the engine (engine patch tab/105, ABI
    /// 1.73): Settings › General's setting and the site controls row reach a
    /// real page. A page with no dark theme is darkened when the setting
    /// goes to Always, without a reload; the row turns it off for the site
    /// and back to the setting; each state survives a navigation, where the
    /// engine reads it again. The page says so itself (the CSS system colour
    /// Canvas as computed, `prefers-color-scheme`), and the engine says what
    /// the tab holds. What is drawn is checked by pixel in
    /// engine/tests/c_abi_dark_mode_host.mm. The setting is written to a
    /// throwaway defaults suite, never the app's own.
    @MainActor
    private func websiteDarkModeChecks(model: BrowserViewModel, store: SidebarStore, base: String) async throws {
        guard model.websiteDarkMode.isAvailable else {
            let missing = ChromiumWebsiteDarkModeCalls.missingSymbols
            return log("ABI-GAP \(ChromiumCapabilities.websiteDarkModeFeature) not advertised\(missing.isEmpty ? "" : " (missing \(missing.joined(separator: ", ")))"): "
                + "the dark mode setting is hidden and pages are as before")
        }
        let suite = "rearc-selftest-dark-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite), let url = URL(string: "\(base)/dark"),
              let site = SiteControlCenter.site(for: url) else { throw Failure(description: "no defaults suite or site for dark mode") }
        let realDefaults = model.externalLinkDefaults
        let savedSetting = model.websiteDarkModeSetting
        model.externalLinkDefaults = defaults
        let previous = store.selectedTab?.id
        let tab = store.addTab(kind: .today, title: "Dark", url: url)
        _ = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        let engine = try shellEngine(model, tab)
        defer {
            // Whatever happened: no choice for the fixture's site, the setting as it was, and
            // the app's own defaults never written (the setting saves to the suite until here).
            model.setWebsiteDarkMode(nil, forSiteOf: engine, site: site)
            model.websiteDarkModeSetting = savedSetting
            model.externalLinkDefaults = realDefaults
            defaults.removePersistentDomain(forName: suite)
        }
        model.websiteDarkModeSetting = .off
        model.selectTab(tab.id)
        engine.load(url)
        try await wait("dark mode fixture", timeout: 20) { engine.pageTitle == "dark-ready" && !engine.isLoading }

        // "<dark|light>:<prefers dark>:<document token>:<query>"
        func state() async -> String { ((try? await engine.evaluate("darkState()", in: .page)) as? String) ?? "" }
        func engineSaysDark() -> Bool? { model.websiteDarkMode.isDarkInEngine?(engine) }
        func row() -> SiteControlCenter.SettingRow? {
            model.siteControlSettingRows(for: engine, site: site).first { $0.kind == .websiteDarkMode }
        }
        func token(_ state: String) -> String { state.split(separator: ":").dropFirst(2).first.map(String.init) ?? "" }
        func navigate(_ query: String) async throws {
            guard let next = URL(string: "\(base)/dark?\(query)") else { throw Failure(description: "no URL for the dark mode fixture") }
            engine.load(next)
            try await waitAsync("the dark mode fixture's page \(query)", timeout: 20) { await state().hasSuffix(":?\(query)") }
            // The engine reads the rule when the navigation has finished; the page has it a moment later.
            try await Task.sleep(nanoseconds: 600_000_000)
        }

        // 1. Off: the page is as it was before this setting.
        let before = await state()
        try check(before.hasPrefix("light:") && engineSaysDark() == false && row()?.state == "Off" && row()?.actions == [.darkModeOnForSite],
                  "dark mode off: page \(before), engine \(String(describing: engineSaysDark())), row \(String(describing: row()))")

        // 2. Always: the open page is darkened and told to prefer dark, without a reload.
        model.websiteDarkModeSetting = .always
        try await waitAsync("the open page goes dark", timeout: 10) { await state().hasPrefix("dark:true:") }
        let dark = await state()
        try check(token(dark) == token(before) && !token(dark).isEmpty, "dark mode reloaded the page: \(before) then \(dark)")
        try check(engineSaysDark() == true && row()?.state == "On", "dark mode always: engine \(String(describing: engineSaysDark())), row \(String(describing: row()))")

        // 3. The site controls row: off for this site, at once and after a navigation.
        guard let onRow = row() else { throw Failure(description: "no dark mode row in the site controls") }
        model.performSiteSetting(.darkModeOffForSite, on: onRow, engine: engine, site: site)
        try await waitAsync("the site's page goes light", timeout: 10) { await state().hasPrefix("light:") }
        let light = await state()
        try check(token(light) == token(before) && engineSaysDark() == false && row()?.state == "Off for this site",
                  "dark mode off for the site: page \(light), engine \(String(describing: engineSaysDark())), row \(String(describing: row()))")
        try await navigate("2")
        let lightAfter = await state()
        try check(lightAfter.hasPrefix("light:") && engineSaysDark() == false, "after a navigation the site is dark again: \(lightAfter)")

        // 4. Back to the setting: dark, at once and after a navigation.
        guard let offRow = row() else { throw Failure(description: "no dark mode row in the site controls") }
        model.performSiteSetting(.darkModeDefaultForSite, on: offRow, engine: engine, site: site)
        try await waitAsync("the site's page follows the setting again", timeout: 10) { await state().hasPrefix("dark:true:") }
        try await navigate("3")
        let darkAfter = await state()
        try check(darkAfter.hasPrefix("dark:true:") && engineSaysDark() == true && row()?.state == "On",
                  "after a navigation the page is not dark: \(darkAfter), engine \(String(describing: engineSaysDark()))")

        // 5. Off again: nothing is left of it.
        model.websiteDarkModeSetting = .off
        try await waitAsync("the page goes light with the setting", timeout: 10) { await state().hasPrefix("light:") }
        try check(engineSaysDark() == false && model.websiteDarkMode.sites.choices(for: model.store.owningProfileID(of: model.profileID(for: tab))).isEmpty,
                  "dark mode off: engine \(String(describing: engineSaysDark())), sites left")

        model.closeTab(tab.id)
        try await wait("the dark mode tab closed") { store.tab(withID: tab.id) == nil }
        if let previous { model.selectTab(previous) }
        log("PASS dark mode for websites: a page with no dark theme is darkened by the setting without a reload, the site "
            + "controls row turns it off for the site and back, and each state holds after a navigation")
    }

    // MARK: Screen sharing (ABI 1.70)

    /// A page's getDisplayMedia(), end to end through the engine. Without a
    /// user gesture nothing reaches the shell. With a click Darni's sheet
    /// opens over the asking tab and lists it and the other loaded tab;
    /// Cancel refuses the page; an answer the engine cannot take (a tab that
    /// does not exist, a DevTools frontend: security review SS-02) leaves the
    /// request open; Share is ignored while the sheet has just changed
    /// (SS-01); sharing the other tab gives
    /// the page a live "browser" stream with sound and frames, the bar over
    /// both tabs and the model's record, and Darni's Stop ends it; that tab
    /// has never been shown and is shared again after it was, and both times
    /// its page stays hidden to its own scripts and hears no visibilitychange
    /// when the share starts or ends (engine patch tab/102); sharing
    /// its own tab and stopping from the page clears the same state; a page
    /// that navigates away takes its sheet with it. A window or the screen
    /// is chosen in the macOS picker, which only a person may answer: this
    /// step checks that they are offered and never opens that picker.
    @MainActor
    private func screenShareChecks(model: BrowserViewModel, store: SidebarStore, window: NSWindow, base: String) async throws {
        if !ChromiumScreenShareChannel.isEnabled {
            return try await screenShareOffChecks(model: model, store: store, window: window, base: base)
        }
        guard ChromiumScreenShareChannel.calls != nil else {
            let missing = ChromiumScreenShareCalls.missingSymbols
            let gap = !runtime.capabilities.screenSharing ? ChromiumCapabilities.displayCaptureFeature
                : ChromiumCapabilities.displayCaptureHiddenTabFeature
            return log("ABI-GAP \(gap) not advertised\(missing.isEmpty ? "" : " (missing \(missing.joined(separator: ", ")))"): "
                + "a page's request to share a tab, a window or the screen fails at once")
        }
        let previous = store.selectedTab?.id
        let otherURL = URL(string: "\(base)/a")!
        let other = store.addTab(kind: .today, title: "Shared", url: otherURL)
        _ = model.engineHost.engine(for: other, profileID: model.profileID(for: other))
        let otherEngine = try shellEngine(model, other)
        otherEngine.load(otherURL)
        let shareURL = URL(string: "\(base)/share")!
        let tab = store.addTab(kind: .today, title: "Share", url: shareURL)
        _ = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        let engine = try shellEngine(model, tab)
        model.selectTab(tab.id)
        engine.load(shareURL)
        try await wait("share fixture", timeout: 20) { engine.pageTitle == "share-ready" && !engine.isLoading && engine.attachmentID != nil }
        try await wait("the tab to share loaded", timeout: 20) { otherEngine.pageTitle == Self.titleA && !otherEngine.isLoading }
        let prompts = engine.pagePrompts
        let site = shareURL.host().map { "\($0):\(shareURL.port ?? 0)" } ?? ""
        func state() async -> String { ((try? await engine.evaluate("window.shareState", in: .page)) as? String) ?? "" }
        func frames() async -> Int { ((try? await engine.evaluate("window.shareFrames", in: .page)) as? NSNumber)?.intValue ?? -1 }
        // What the page of the tab to share can tell about itself: "<document.hidden>:<visibilitychange
        // events>:<devicePixelRatio>:<width>x<height>". A share may change the size of a tab that had
        // none, and nothing else: the page of a tab nobody looks at stays hidden, hears nothing when the
        // share starts or ends, and keeps its scale (engine patch tab/102, the security review's
        // condition). The first call starts the count, and a small change of the page four times a
        // second, so its picture has new frames.
        func sharedPage() async -> String {
            ((try? await otherEngine.evaluate("""
                (window.shareSeen === undefined && (window.shareSeen = 0,
                     document.addEventListener('visibilitychange', function () { window.shareSeen++; }),
                     setInterval(function () { document.body.style.opacity = document.body.style.opacity === '0.9' ? '1' : '0.9'; }, 250)),
                 document.hidden + ':' + window.shareSeen + ':' + devicePixelRatio + ':' + innerWidth + 'x' + innerHeight)
                """, in: .page)) as? String) ?? ""
        }
        // A visibility change reaches a page after the browser's own state: read it a moment later.
        func sharedPageSettled() async throws -> String {
            try await Task.sleep(nanoseconds: 700_000_000)
            return await sharedPage()
        }
        func cleanUp() async throws {
            model.closeTab(tab.id)
            model.closeTab(other.id)
            try await wait("the sharing tabs closed") { store.tab(withID: tab.id) == nil && store.tab(withID: other.id) == nil }
            if let previous { model.selectTab(previous) }
        }

        // 1. No gesture: the page is refused before anything reaches the shell.
        let events = ChromiumScreenShareChannel.events
        _ = try await engine.evaluate("ask(), true", in: .page)
        try await waitAsync("the request without a gesture ends", timeout: 10) { await state() != "pending" }
        let ungestured = await state()
        try check(ungestured.hasPrefix("error:") && prompts.screenShare == nil && ChromiumScreenShareChannel.events == events,
                  "without a gesture: \(ungestured), sheet \(prompts.screenShare != nil), "
                      + "\(ChromiumScreenShareChannel.events - events) event(s)")

        _ = await bringToFront(window, for: "screen sharing")
        let button = try await cssCenter(of: "#go", in: engine)
        func askByClick() async -> Bool {
            for _ in 0 ..< 3 {
                focus(window)
                click(window, engine: engine, at: button)
                if await eventually(timeout: 3, { prompts.screenShare != nil }) { return true }
            }
            return false
        }
        guard await askByClick() else {
            log("NOTE screen sharing: the synthesized click produced no request (app active \(NSApp.isActive), key \(window.isKeyWindow), "
                + "page \(await state())); the sheet, the share and Stop are not exercised in this run")
            return try await cleanUp()
        }

        // 2. The sheet: who asks, what is offered, which tabs, nothing picked. Cancel refuses the page.
        var sheet = try XUnwrap(prompts.screenShare, "the screen sharing sheet")
        let request = sheet.request
        let offered = sheet.candidates
        let own = offered.first
        let otherRow = offered.first { $0.tabID == other.id }
        try check(request.site == site && request.wantsAudio && request.allowsCurrentTab && request.tabAudio,
                  "request: site \(request.site) (expected \(site)), sound \(request.wantsAudio), own tab \(request.allowsCurrentTab)")
        try check(own?.isCurrent == true && own?.tabID == tab.id && own?.engineTabID == engine.tabID && otherRow?.engineTabID == otherEngine.tabID,
                  "tabs offered: \(offered.map { "\($0.engineTabID)\($0.isCurrent ? "*" : "")" }) (asking \(engine.tabID), other \(otherEngine.tabID))")
        try check(prompts.screenShareSheetShown && prompts.screenShareSelection == nil && prompts.screenShareAnswer == nil && prompts.screenShareKind == .tab,
                  "the sheet opened with selection \(String(describing: prompts.screenShareSelection)) kind \(prompts.screenShareKind)")
        // macOS 15 and later: a window or the screen goes to the system picker and needs no Screen Recording permission.
        if #available(macOS 15, *) {
            try check(request.offersWindow && request.offersScreen && request.usesSystemPicker && request.screenRecording == .notNeeded,
                      "window \(request.offersWindow) screen \(request.offersScreen) system picker \(request.usesSystemPicker) "
                          + "screen recording \(request.screenRecording.rawValue)")
        }
        // An answer the engine cannot take leaves the request open.
        let unknown = ChromiumScreenShareChannel.respond(sheet.id, .tab(UInt64.max - 1, audio: false))
        try check(unknown != .rearcOK && prompts.screenShare?.id == sheet.id, "a tab that does not exist: \(unknown.rearcName)")
        // The engine shares pages only, whatever it is asked (SS-02): the other tab's DevTools
        // frontend is a tab of the same profile, shows that page's storage and network data,
        // and is refused. The sheet never lists it.
        var devTools = "no DevTools in this engine"
        if runtime.capabilities.devTools {
            try check(model.openDevTools(for: other.id) == nil, "Developer Tools refused for the other tab")
            try await wait("the other tab's DevTools frontend", timeout: 20) {
                ((model.devToolsEngine(for: other.id) as? ChromiumEngine)?.tabID ?? 0) != 0
            }
            let frontend = try XUnwrap(model.devToolsEngine(for: other.id) as? ChromiumEngine, "the frontend engine")
            try check(frontend.engineProfileID == otherEngine.engineProfileID && !offered.contains { $0.engineTabID == frontend.tabID },
                      "frontend \(frontend.tabID) profile \(frontend.engineProfileID), offered \(offered.map(\.engineTabID))")
            let refused = ChromiumScreenShareChannel.respond(sheet.id, .tab(frontend.tabID, audio: false))
            try check(refused == ReArcStatus(REARC_INVALID_ARGUMENT) && prompts.screenShare?.id == sheet.id
                          && !engine.mediaCapture.isCapturingDisplay,
                      "a DevTools frontend as the tab to share: \(refused.rearcName) (expected invalid_argument), "
                          + "request kept \(prompts.screenShare?.id == sheet.id)")
            let frontendTab = frontend.tabID
            model.closeDevTools(for: other.id)
            try await wait("the frontend closed", timeout: 10) { !runtime.devToolsFrontends.contains(frontendTab) }
            devTools = "DevTools frontend \(frontendTab) -> \(refused.rearcName)"
        }
        prompts.answerScreenShare(.cancel)
        try await waitAsync("the cancelled request ends", timeout: 10) { await state() != "pending" }
        let cancelled = await state()
        try check(cancelled == "error:NotAllowedError" && prompts.screenShare == nil && !engine.mediaCapture.isCapturingDisplay,
                  "after Cancel: \(cancelled)")
        let late = ChromiumScreenShareChannel.respond(sheet.id, .cancel)
        try check(late != .rearcOK, "an answer to a request that is over: \(late.rearcName)")

        // 3. Share the other tab, with its sound: a live stream, the bars, the record; Darni's Stop ends it.
        // That tab has never been shown: its page is hidden and has no size yet (the share of 1323
        // ended after ten seconds for want of a first frame).
        let neverShown = await sharedPage()
        try check(neverShown.hasPrefix("true:0:") && otherEngine.attachmentID == nil,
                  "the tab to share before the share: \(neverShown), lease \(String(describing: otherEngine.attachmentID))")
        guard await askByClick() else { throw Failure(description: "the second click opened no sheet (page \(await state()))") }
        sheet = try XUnwrap(prompts.screenShare, "the second sheet")
        prompts.screenShareSelection = otherEngine.tabID
        let answer = try XUnwrap(prompts.screenShareAnswer, "the answer for the other tab")
        try check(answer == .tab(otherEngine.tabID, audio: true), "answer \(answer.logName)")
        // Share right after the row was picked is ignored (SS-01): nothing goes to the engine.
        let repliesBefore = ChromiumScreenShareChannel.replies
        prompts.answerScreenShare(answer)
        try check(ChromiumScreenShareChannel.replies == repliesBefore && prompts.screenShareSheetShown && !prompts.screenShareInputAllowed,
                  "Share at once after picking a row: \(ChromiumScreenShareChannel.replies - repliesBefore) answer(s) sent, "
                      + "sheet shown \(prompts.screenShareSheetShown)")
        try await wait("Share takes input once the sheet is still", timeout: 5) { prompts.screenShareInputAllowed && prompts.screenShareInputEnabled }
        prompts.answerScreenShare(answer)
        try check(ChromiumScreenShareChannel.replies == repliesBefore + 1, "Share after the wait sent no answer")
        try await waitAsync("the other tab shared", timeout: 15) { await state().hasPrefix("live:") }
        let live = await state()
        try check(live == "live:browser:1", "the page's stream: \(live)")
        try await wait("the engine reports the share", timeout: 10) { engine.mediaCapture.isCapturingDisplay && prompts.isSharingScreen }
        try await wait("the model records the share", timeout: 10) { model.screenShares.isSharing(tab.id) }
        // The bar over the page in the call names no other tab (a screen share would show it).
        let line = prompts.sharingLine ?? ""
        try check(line == "Sharing a tab with \(site)", "the bar over the sharing tab: \(line)")
        try check(otherEngine.pagePrompts.sharedBy == [ScreenShareViewer(capturer: tab.id, site: site)],
                  "the bar over the shared tab: \(otherEngine.pagePrompts.sharedBy)")
        try check(model.screenShareCards(in: model.store.keyWindowID).isEmpty, "a card for the tab on screen")
        try await waitAsync("frames of the shared tab", timeout: 15) { await frames() > 0 }
        let shownFrames = await frames()
        // Shared, the page is painted (it has a size now) and is still hidden to its own scripts.
        let neverShownShared = try await sharedPageSettled()
        let scale = { (page: String) in page.split(separator: ":").dropFirst(2).first.map(String.init) ?? "" }
        try check(neverShownShared.hasPrefix("true:0:") && !neverShownShared.hasSuffix(":0x0") && otherEngine.attachmentID == nil
                      && scale(neverShownShared) == scale(neverShown),
                  "the shared tab's page while it is shared: \(neverShownShared) (before \(neverShown))")
        let stops = ChromiumScreenShareChannel.stops
        prompts.stopScreenShare()
        try await waitAsync("Stop Sharing ends the page's track", timeout: 10) { await state() == "ended" }
        try await wait("the engine reports the share over", timeout: 10) { !engine.mediaCapture.isCapturingDisplay && !prompts.isSharingScreen }
        try check(ChromiumScreenShareChannel.stops == stops + 1 && prompts.sharingLine == nil
                      && otherEngine.pagePrompts.sharedBy.isEmpty && model.screenShares.isEmpty,
                  "after Stop Sharing: bar \(prompts.sharingLine ?? "none"), shared tab's bar \(otherEngine.pagePrompts.sharedBy), "
                      + "record empty \(model.screenShares.isEmpty)")
        try check(!engine.stopScreenShare(), "a second Stop found something to stop")
        let neverShownAfter = try await sharedPageSettled()
        try check(neverShownAfter == neverShownShared, "the shared tab's page after the share: \(neverShownAfter) (shared \(neverShownShared))")

        // 3b. The same tab once it has been on screen and is in the background again, without its
        // sound: live with frames, and its page hears nothing of the share from start to end.
        model.selectTab(other.id)
        try await waitAsync("the other tab on screen", timeout: 15) {
            let page = await sharedPage()
            return otherEngine.attachmentID != nil && page.hasPrefix("false:")
        }
        model.selectTab(tab.id)
        try await waitAsync("the other tab in the background again", timeout: 15) {
            let page = await sharedPage()
            return engine.attachmentID != nil && otherEngine.attachmentID == nil && page.hasPrefix("true:")
        }
        let background = try await sharedPageSettled()
        guard await askByClick() else { throw Failure(description: "the click for the tab in the background opened no sheet (page \(await state()))") }
        prompts.screenShareSelection = otherEngine.tabID
        prompts.screenShareAudio = false
        try await wait("Share takes input for the tab in the background", timeout: 5) { prompts.screenShareInputAllowed && prompts.screenShareInputEnabled }
        prompts.answerScreenShare(try XUnwrap(prompts.screenShareAnswer, "the answer for the tab in the background"))
        try await waitAsync("the tab in the background shared", timeout: 15) { await state().hasPrefix("live:") }
        let backgroundLive = await state()
        try check(backgroundLive == "live:browser:0", "the tab in the background without sound: \(backgroundLive)")
        try await waitAsync("frames of the tab in the background", timeout: 15) { await frames() > 0 }
        let backgroundShared = try await sharedPageSettled()
        try check(background.hasPrefix("true:") && backgroundShared == background,
                  "the page of the tab in the background while it is shared: \(backgroundShared) (before \(background))")
        prompts.stopScreenShare()
        try await waitAsync("Stop Sharing ends the second share", timeout: 10) { await state() == "ended" }
        try await wait("the engine reports the second share over", timeout: 10) {
            !engine.mediaCapture.isCapturingDisplay && !prompts.isSharingScreen && model.screenShares.isEmpty
        }
        let backgroundAfter = try await sharedPageSettled()
        try check(backgroundAfter == background, "the page of the tab in the background after the share: \(backgroundAfter) (before \(background))")

        // 4. Share its own tab; the page stops it itself.
        guard await askByClick() else { throw Failure(description: "the third click opened no sheet (page \(await state()))") }
        prompts.screenShareSelection = engine.tabID
        prompts.screenShareAudio = false
        try await wait("Share takes input for its own tab", timeout: 5) { prompts.screenShareInputAllowed }
        prompts.answerScreenShare(try XUnwrap(prompts.screenShareAnswer, "the answer for its own tab"))
        try await waitAsync("its own tab shared", timeout: 15) { await state().hasPrefix("live:") }
        let ownLive = await state()
        try check(ownLive == "live:browser:0", "its own tab without sound: \(ownLive)")
        try await wait("the bar for its own tab", timeout: 10) { prompts.sharingLine == "Sharing this tab with \(site)" }
        _ = try await engine.evaluate("window.shareStream.getTracks().forEach(function (t) { t.stop(); }), true", in: .page)
        try await wait("the page's own stop clears the bar", timeout: 10) {
            !engine.mediaCapture.isCapturingDisplay && !prompts.isSharingScreen && model.screenShares.isEmpty
        }

        // 5. A page that navigates away takes its sheet with it; nothing is answered for it.
        guard await askByClick() else { throw Failure(description: "the fourth click opened no sheet (page \(await state()))") }
        let answered = prompts.answered["screen_share"] ?? 0
        engine.load(otherURL)
        try await wait("the sheet goes with the page", timeout: 15) { prompts.screenShare == nil }
        try check((prompts.answered["screen_share"] ?? 0) == answered && !engine.mediaCapture.isCapturingDisplay,
                  "a withdrawn request was answered")

        try await cleanUp()
        log("PASS screen sharing (ABI 1.70): no gesture -> \(ungestured), no event; click -> sheet for \(site) offering tabs "
            + "\(offered.map(\.engineTabID)), window \(request.offersWindow), screen \(request.offersScreen) (system picker "
            + "\(request.usesSystemPicker), screen recording \(request.screenRecording.rawValue)); unknown tab -> \(unknown.rearcName), "
            + "\(devTools), request kept; Cancel -> \(cancelled); Share at once after picking a row ignored, taken after "
            + "\(Int(PagePromptCenter.screenShareInputDelay * 1000)) ms; other tab (never shown: \(neverShown)) with sound -> \(live), "
            + "\(shownFrames) frame(s), bars on both tabs, its page shared \(neverShownShared) and after \(neverShownAfter), "
            + "Stop Sharing -> ended; the same tab back in the background (\(background)) without sound -> \(backgroundLive), "
            + "its page shared \(backgroundShared) and after \(backgroundAfter); "
            + "own tab -> \(ownLive), page stop clears the bar; navigation withdraws the sheet; "
            + "last outcome \(ChromiumScreenShareChannel.lastOutcome)")
    }

    /// Screen sharing switched off (`ChromiumScreenShareChannel.isEnabled`): the shell installs no
    /// display-capture callback, so a page that asks right after a click is refused by the engine
    /// at once with NotSupportedError, as in 1255, and nothing of Darni's sharing UI appears.
    @MainActor private func screenShareOffChecks(model: BrowserViewModel, store: SidebarStore, window: NSWindow, base: String) async throws {
        try check(ChromiumScreenShareChannel.calls == nil, "screen sharing is off but the channel is registered")
        let previous = store.selectedTab?.id
        let shareURL = URL(string: "\(base)/share")!
        let tab = store.addTab(kind: .today, title: "Share", url: shareURL)
        _ = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        let engine = try shellEngine(model, tab)
        model.selectTab(tab.id)
        engine.load(shareURL)
        try await wait("share fixture", timeout: 20) { engine.pageTitle == "share-ready" && !engine.isLoading && engine.attachmentID != nil }
        func state() async -> String { ((try? await engine.evaluate("window.shareState", in: .page)) as? String) ?? "" }
        let prompts = engine.pagePrompts
        let events = ChromiumScreenShareChannel.events
        _ = await bringToFront(window, for: "screen sharing (off)")
        let button = try await cssCenter(of: "#go", in: engine)
        var outcome = "idle"
        for _ in 0 ..< 3 {
            focus(window)
            click(window, engine: engine, at: button)
            if await eventuallyAsync(timeout: 5, { await state().hasPrefix("error:") }) { outcome = await state(); break }
            outcome = await state()
        }
        try check(outcome == "error:NotSupportedError" && prompts.screenShare == nil && !prompts.screenShareSheetShown
                      && ChromiumScreenShareChannel.events == events && !engine.mediaCapture.isCapturingDisplay
                      && prompts.sharingLine == nil && model.screenShares.isEmpty,
                  "screen sharing off: a clicked request -> \(outcome), sheet \(prompts.screenShare != nil), "
                      + "\(ChromiumScreenShareChannel.events - events) event(s)")
        model.closeTab(tab.id)
        try await wait("the sharing tab closed") { store.tab(withID: tab.id) == nil }
        if let previous { model.selectTab(previous) }
        log("PASS screen sharing off: a clicked request -> \(outcome) at once; no sheet, no bar, no event reached the shell")
    }

    // MARK: Passkey requests from a tab that is not shown (ABI 1.68, security review PK-10)

    /// Chromium refuses to create a passkey for a tab that is not visible and
    /// has no such rule for signing in; the engine refuses a sign-in from a
    /// page nobody sees when it starts, and tells the shell, which logs it
    /// (security review AH-02). The same request from the tab once it is
    /// shown opens the sheet, which says the first result is the rule's and
    /// not another refusal.
    @MainActor
    private func passkeyHiddenTabChecks(model: BrowserViewModel, store: SidebarStore, base: String) async throws {
        guard ChromiumPasskeyChannel.calls != nil else {
            return log("ABI-GAP webauthn_prompts not advertised: a passkey request shows no sheet")
        }
        // An IP address is no relying party: the page is on localhost.
        let url = URL(string: base.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "/a")!
        let previous = store.selectedTab?.id
        let tab = store.addTab(kind: .today, title: "Passkey", url: url)
        _ = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
        let engine = try shellEngine(model, tab)
        engine.load(url)
        try await wait("background passkey tab loaded", timeout: 20) { engine.pageTitle == Self.titleA && !engine.isLoading }

        // Chromium raises a page's timeout to minutes, so an end within seconds is not the timeout.
        let ask = """
        (window.passkeyResult = 'pending',
         navigator.credentials.get({publicKey: {challenge: new Uint8Array(32), timeout: 5000}})
           .then(() => { window.passkeyResult = 'resolved' }, error => { window.passkeyResult = error.name }),
         document.visibilityState)
        """
        func result() async -> String { ((try? await engine.evaluate("window.passkeyResult", in: .page)) as? String) ?? "" }

        let events = ChromiumPasskeyChannel.events
        let refusals = ChromiumPasskeyChannel.refusals
        let hidden = try await engine.evaluate(ask, in: .page) as? String
        try check(hidden == "hidden" && engine.attachmentID == nil, "the background tab is \(hidden ?? "nil"), lease \(String(describing: engine.attachmentID))")
        var sheet = false
        let asked = Date()
        try await waitAsync("the hidden tab's passkey request ends", timeout: 10) {
            sheet = sheet || engine.pagePrompts.passkey != nil
            return await result() != "pending"
        }
        let hiddenResult = await result()
        let took = Int(Date().timeIntervalSince(asked) * 1000)
        try check(hiddenResult == "NotAllowedError" && !sheet && engine.pagePrompts.passkey == nil && ChromiumPasskeyChannel.events == events,
                  "hidden tab: result \(hiddenResult), sheet state \(sheet), step events \(ChromiumPasskeyChannel.events - events)")
        let refusal = ChromiumPasskeyChannel.lastRefusal
        try check(ChromiumPasskeyChannel.refusals == refusals + 1 && refusal.contains("of tab \(engine.tabID) refused") && refusal.contains("(hidden)"),
                  "hidden tab: \(ChromiumPasskeyChannel.refusals - refusals) refusal line(s) from the engine, the last \"\(refusal)\" "
                      + "(none: an engine older than tab/097's refusal at the start)")

        model.selectTab(tab.id)
        try await waitAsync("the passkey tab shown", timeout: 15) {
            guard engine.attachmentID != nil else { return false }
            return ((try? await engine.evaluate("document.visibilityState", in: .page)) as? String) == "visible"
        }
        _ = try await engine.evaluate(ask, in: .page)
        try await wait("the shown tab's passkey sheet", timeout: 15) { engine.pagePrompts.passkey != nil }
        let step = try XUnwrap(engine.pagePrompts.passkey?.step, "passkey step")
        try check(step.requestLine == "Sign in to localhost" && step.showsSheet, "shown tab: \(step.kind) \"\(step.requestLine)\"")
        engine.pagePrompts.answerPasskey(.cancel)
        try await waitAsync("the cancelled passkey request ends", timeout: 10) { await result() != "pending" }
        let shownResult = await result()
        try check(shownResult == "NotAllowedError" && engine.pagePrompts.passkey == nil, "shown tab after Cancel: \(shownResult)")
        // The close asks the page first and then loads the tab it leaves selected: the next step waits for that.
        model.closeTab(tab.id)
        try await wait("the passkey tab closed") { store.tab(withID: tab.id) == nil }
        if let previous { model.selectTab(previous) }
        log("PASS passkey request from a hidden tab (PK-10): navigator.credentials.get in background tab \(engine.tabID) -> "
            + "\(hiddenResult) after \(took) ms, no step event and no sheet state, logged \"\(refusal)\"; the same request with the tab shown -> "
            + "step \(step.kind) \"\(step.requestLine)\" (page \(step.pageVisibility)), Cancel -> \(shownResult)")
    }

    /// A sheet that is open stays when its tab goes to the back, so a touch of
    /// a security key meant for the tab in front could answer the older
    /// request. When a request with UI starts in a visible page, the engine
    /// cancels every open request whose page is not visible (tab/097; security
    /// review of 2026.1118.1027, addendum 2): the first tab's request ends
    /// with NotAllowedError, its sheet goes, and the log says why.
    @MainActor
    private func passkeyStaleSheetChecks(model: BrowserViewModel, store: SidebarStore, base: String) async throws {
        guard ChromiumPasskeyChannel.calls != nil else { return }
        let url = URL(string: base.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "/a")!
        let previous = store.selectedTab?.id
        let ask = """
        (window.passkeyResult = 'pending',
         navigator.credentials.get({publicKey: {challenge: new Uint8Array(32), timeout: 5000}})
           .then(() => { window.passkeyResult = 'resolved' }, error => { window.passkeyResult = error.name }),
         document.visibilityState)
        """
        func open(_ title: String) async throws -> (tab: Tab, engine: ChromiumEngine) {
            let tab = store.addTab(kind: .today, title: title, url: url)
            _ = model.engineHost.engine(for: tab, profileID: model.profileID(for: tab))
            let engine = try shellEngine(model, tab)
            engine.load(url)
            try await wait("\(title) loaded", timeout: 20) { engine.pageTitle == Self.titleA && !engine.isLoading }
            return (tab, engine)
        }
        func state(_ engine: ChromiumEngine, _ script: String) async -> String {
            ((try? await engine.evaluate(script, in: .page)) as? String) ?? ""
        }
        func show(_ tab: Tab, _ engine: ChromiumEngine, _ label: String) async throws {
            model.selectTab(tab.id)
            try await waitAsync("\(label) shown", timeout: 15) {
                guard engine.attachmentID != nil else { return false }
                return await state(engine, "document.visibilityState") == "visible"
            }
        }

        // The first tab asks while it is shown: its sheet opens.
        let first = try await open("Passkey first")
        try await show(first.tab, first.engine, "the first passkey tab")
        _ = try await first.engine.evaluate(ask, in: .page)
        try await wait("the first tab's passkey sheet", timeout: 15) { first.engine.pagePrompts.passkey != nil }
        let firstRequest = try XUnwrap(first.engine.pagePrompts.passkey?.id, "the first tab's request")

        // It goes to the back: the request and its sheet stay.
        let second = try await open("Passkey second")
        try await show(second.tab, second.engine, "the second passkey tab")
        try await waitAsync("the first passkey tab hidden", timeout: 15) { await state(first.engine, "document.visibilityState") == "hidden" }
        let kept = await state(first.engine, "window.passkeyResult")
        try check(kept == "pending" && first.engine.pagePrompts.passkey?.id == firstRequest,
                  "the first tab behind: result \(kept), sheet of request \(String(describing: first.engine.pagePrompts.passkey?.id)) (a sheet that is open stays)")

        // The second asks while it is shown: its sheet opens, and the first's request is cancelled.
        let refusals = ChromiumPasskeyChannel.refusals
        _ = try await second.engine.evaluate(ask, in: .page)
        try await wait("the second tab's passkey sheet", timeout: 15) { second.engine.pagePrompts.passkey != nil }
        try await waitAsync("the first tab's passkey request ends", timeout: 10) { await state(first.engine, "window.passkeyResult") != "pending" }
        let firstResult = await state(first.engine, "window.passkeyResult")
        try await wait("the first tab's passkey sheet gone") { first.engine.pagePrompts.passkey == nil }
        let cancel = ChromiumPasskeyChannel.lastRefusal
        try check(firstResult == "NotAllowedError", "the first tab's request after the second tab asked: \(firstResult)")
        try check(ChromiumPasskeyChannel.refusals == refusals + 1
                      && cancel.contains("request \(firstRequest) of tab \(first.engine.tabID) cancelled")
                      && cancel.contains("(hidden)") && cancel.contains("tab \(second.engine.tabID), which is visible, asked"),
                  "the cancel of the first tab's request: \(ChromiumPasskeyChannel.refusals - refusals) event(s), the last \"\(cancel)\" "
                      + "(none: an engine older than tab/097's cancel of requests nobody sees)")
        let step = try XUnwrap(second.engine.pagePrompts.passkey?.step, "the second tab's passkey step")
        let secondPending = await state(second.engine, "window.passkeyResult")
        try check(step.showsSheet && step.pageVisibility == "visible" && secondPending == "pending",
                  "the second tab: \(step.kind), page \(step.pageVisibility), result \(secondPending)")

        second.engine.pagePrompts.answerPasskey(.cancel)
        try await waitAsync("the second tab's cancelled passkey request ends", timeout: 10) {
            await state(second.engine, "window.passkeyResult") != "pending"
        }
        let secondResult = await state(second.engine, "window.passkeyResult")
        try check(secondResult == "NotAllowedError" && second.engine.pagePrompts.passkey == nil, "the second tab after Cancel: \(secondResult)")
        let tabs = "tab \(first.engine.tabID) and tab \(second.engine.tabID)"
        for tab in [second.tab, first.tab] {
            model.closeTab(tab.id)
            try await wait("a passkey tab closed") { store.tab(withID: tab.id) == nil }
        }
        if let previous { model.selectTab(previous) }
        log("PASS passkey request of a tab that went to the back is cancelled when the tab in front asks: \(tabs); the first's sheet "
            + "stayed while it was hidden, then its request -> \(firstResult), logged \"\(cancel)\"; the second's step \(step.kind), Cancel -> \(secondResult)")
    }

    /// The same rule for a window nobody sees (security review AH-02): a
    /// Little ReArc window that is ordered out. Its page holds a lease, unlike
    /// a background tab's, so only the window's state makes it hidden. Signing
    /// in and creating are both refused and logged; with the window back, the
    /// same sign-in opens the sheet.
    @MainActor
    private func passkeyHiddenLittleArcChecks(model: BrowserViewModel, shell: ChromiumShell, store: SidebarStore,
                                              base: String) async throws {
        guard ChromiumPasskeyChannel.calls != nil else { return }
        let url = URL(string: base.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "/a")!
        let record = model.openLittleArc(url: url)
        guard let window = shell.window(forLittleArc: record.id),
              let little = model.littleArcEngine(for: record.id) as? ChromiumEngine else {
            throw Failure(description: "passkeys: Little ReArc opened no window/engine")
        }
        func visibility() async -> String { ((try? await little.evaluate("document.visibilityState", in: .page)) as? String) ?? "" }
        func result() async -> String { ((try? await little.evaluate("window.passkeyResult", in: .page)) as? String) ?? "" }
        try await waitAsync("the passkey Little ReArc loaded and visible", timeout: 20) {
            guard little.attachmentID != nil, little.pageTitle == Self.titleA, !little.isLoading else { return false }
            return await visibility() == "visible"
        }
        window.orderOut(nil)
        try await waitAsync("the ordered-out Little ReArc's page hidden", timeout: 15) { await visibility() == "hidden" }
        try check(little.attachmentID != nil && !window.isVisible, "the hidden Little ReArc: lease \(String(describing: little.attachmentID)), window visible \(window.isVisible)")

        let settle = ".then(() => { window.passkeyResult = 'resolved' }, error => { window.passkeyResult = error.name })"
        let get = "(window.passkeyResult = 'pending', navigator.credentials.get({publicKey: {challenge: new Uint8Array(32), timeout: 5000}})"
            + settle + ", document.visibilityState)"
        let create = """
        (window.passkeyResult = 'pending',
         navigator.credentials.create({publicKey: {challenge: new Uint8Array(32), rp: {name: 'ReArc self-test'},
           user: {id: new Uint8Array(16), name: 'selftest', displayName: 'Self-test'},
           pubKeyCredParams: [{type: 'public-key', alg: -7}], timeout: 5000}})
        """ + settle + ", document.visibilityState)"
        var lines: [String] = []
        let written = ChromiumPasskeyChannel.refusalLines
        for (name, ask) in [("get", get), ("create", create)] {
            let events = ChromiumPasskeyChannel.events
            let refusals = ChromiumPasskeyChannel.refusals
            _ = try await little.evaluate(ask, in: .page)
            var sheet = false
            try await waitAsync("the hidden Little ReArc's passkey \(name) ends", timeout: 10) {
                sheet = sheet || little.pagePrompts.passkey != nil
                return await result() != "pending"
            }
            let answer = await result()
            let refusal = ChromiumPasskeyChannel.lastRefusal
            try check(answer == "NotAllowedError" && !sheet && ChromiumPasskeyChannel.events == events
                          && ChromiumPasskeyChannel.refusals == refusals + 1
                          && refusal.contains("of tab \(little.tabID) refused") && refusal.contains("(hidden)"),
                      "hidden Little ReArc \(name): result \(answer), sheet state \(sheet), step events \(ChromiumPasskeyChannel.events - events), "
                          + "\(ChromiumPasskeyChannel.refusals - refusals) refusal line(s), the last \"\(refusal)\"")
            lines.append("\(name) -> \(answer), \"\(refusal)\"")
        }
        // A page can ask in a loop: the tab's first refusal has its line, the second is counted.
        try check(ChromiumPasskeyChannel.refusalLines == written + 1,
                  "hidden Little ReArc: \(ChromiumPasskeyChannel.refusalLines - written) log line(s) for its two refusals, 1 expected")

        window.orderFront(nil)
        try await waitAsync("the Little ReArc's page visible again", timeout: 15) { await visibility() == "visible" }
        _ = try await little.evaluate(get, in: .page)
        try await wait("the shown Little ReArc's passkey sheet", timeout: 15) { little.pagePrompts.passkey != nil }
        let step = try XUnwrap(little.pagePrompts.passkey?.step, "Little ReArc passkey step")
        try check(step.showsSheet && step.pageVisibility == "visible", "shown Little ReArc: \(step.kind), page \(step.pageVisibility)")
        little.pagePrompts.answerPasskey(.cancel)
        try await waitAsync("the Little ReArc's cancelled passkey request ends", timeout: 10) { await result() != "pending" }
        shell.dismissLittleArcWindow(record.id)
        try await wait("the passkey Little ReArc closed") {
            shell.window(forLittleArc: record.id) == nil && store.littleArcWindow(withID: record.id) == nil
        }
        log("PASS passkey request from a hidden Little ReArc window (AH-02): tab \(little.tabID), window ordered out, page hidden: "
            + lines.joined(separator: "; ") + " (one log line, then counted); window back -> step \(step.kind), page \(step.pageVisibility)")
    }

    // MARK: Wave 23: HTML fullscreen (ABI 1.27)

    @MainActor
    private func enterPageFullscreen(_ model: BrowserViewModel, window: NSWindow, engine: ChromiumEngine, button: CGPoint) async throws -> Bool {
        for _ in 0..<3 {
            focus(window)
            click(window, engine: engine, at: button)
            if await eventually(timeout: 3, { engine.isPageFullscreen && model.htmlFullscreen != nil }) { return true }
        }
        return false
    }

    /// The page asks for fullscreen from a click; the shell window goes
    /// native fullscreen without its sidebar. Leaving by the page's own
    /// exitFullscreen(), by Escape and by the window (⌃⌘F) each restore it.
    @MainActor
    private func fullscreenChecks(model: BrowserViewModel, shell: ChromiumShell, window: NSWindow, tab: Tab, engine: ChromiumEngine, base: String) async throws {
        model.selectTab(tab.id)
        engine.load(URL(string: "\(base)/fullscreen")!)
        try await wait("fullscreen fixture", timeout: 15) { engine.pageTitle == "fs-ready" && !engine.isLoading && engine.attachmentID != nil }
        _ = await bringToFront(window, for: "HTML fullscreen")
        let button = try await cssCenter(of: "#go", in: engine)
        let sidebarBefore = model.isSidebarVisible(in: model.store.keyWindowID)
        guard try await enterPageFullscreen(model, window: window, engine: engine, button: button) else {
            log("NOTE HTML fullscreen: the synthesized click produced no fullscreen request (app active \(NSApp.isActive), "
                + "key \(window.isKeyWindow)); fullscreen is not exercised in this run")
            return
        }
        try check(model.htmlFullscreenTabID == tab.id && shell.htmlFullscreenWindow === window, "fullscreen session \(String(describing: model.htmlFullscreen))")
        try await wait("window native fullscreen", timeout: 10) { window.styleMask.contains(.fullScreen) && shell.isNativeFullscreenSettled }
        try check(engine.queryFullscreenState() == true, "engine does not report fullscreen")

        // 1. The page leaves.
        _ = try await engine.evaluate("document.exitFullscreen().then(function () { return true; })", in: .page)
        do {
            try await wait("page exit restores the window", timeout: 10) {
                model.htmlFullscreen == nil && !window.styleMask.contains(.fullScreen) && engine.pageTitle == "fs-off"
                    && shell.isNativeFullscreenSettled
            }
        } catch {
            throw Failure(description: "page exit: session \(String(describing: model.htmlFullscreen)) window fullscreen "
                + "\(window.styleMask.contains(.fullScreen)) title \(engine.pageTitle ?? "-")")
        }
        try check(model.isSidebarVisible(in: model.store.keyWindowID) == sidebarBefore && engine.queryFullscreenState() == false, "state after the page's exit")
        var paths = ["page exitFullscreen()"]

        // 2. Escape (the engine exits, reason 2).
        try await Task.sleep(nanoseconds: 300_000_000)
        if try await enterPageFullscreen(model, window: window, engine: engine, button: button) {
            try await wait("window native fullscreen again", timeout: 10) { window.styleMask.contains(.fullScreen) && shell.isNativeFullscreenSettled }
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
                    window.sendEvent(event)
                }
            }
            if await eventually(timeout: 5, { model.htmlFullscreen == nil }) {
                try await wait("Escape restores the window", timeout: 10) {
                    !window.styleMask.contains(.fullScreen) && shell.isNativeFullscreenSettled
                }
                paths.append("Escape")
            } else {
                log("NOTE HTML fullscreen: the synthesized Escape did not reach the page; leaving through the page instead")
                _ = try await engine.evaluate("document.exitFullscreen().then(function () { return true; })", in: .page)
                try await wait("page exit after the Escape attempt", timeout: 10) {
                    model.htmlFullscreen == nil && !window.styleMask.contains(.fullScreen)
                }
            }
        }

        // 3. The user leaves native fullscreen; the page follows (reason 1, host).
        try await Task.sleep(nanoseconds: 300_000_000)
        if try await enterPageFullscreen(model, window: window, engine: engine, button: button) {
            try await wait("window native fullscreen a third time", timeout: 10) {
                window.styleMask.contains(.fullScreen) && shell.isNativeFullscreenSettled
            }
            // As the green button or ⌃⌘F would, once the window has settled.
            try await Task.sleep(nanoseconds: 200_000_000)
            window.toggleFullScreen(nil)
            try await wait("leaving native fullscreen ends the page's", timeout: 10) {
                model.htmlFullscreen == nil && !window.styleMask.contains(.fullScreen) && engine.pageTitle == "fs-off"
                    && engine.queryFullscreenState() == false
            }
            paths.append("window (⌃⌘F)")
        }
        try check(model.isSidebarVisible(in: model.store.keyWindowID) == sidebarBefore, "the sidebar did not come back")
        engine.load(URL(string: "\(base)/a")!)
        try await wait("tab A back on /a", timeout: 15) { engine.pageTitle == Self.titleA && !engine.isLoading }
        log("PASS HTML fullscreen (ABI 1.27): click -> requestFullscreen -> window native fullscreen, sidebar hidden; "
            + "left by \(paths.joined(separator: ", ")); window and sidebar restored each time")
    }

    /// The sidebar's back/forward/reload/stop and lock state act on the
    /// selected tab's engine through BrowserViewModel (the menu and command-bar
    /// paths call the same methods), and the engine's favicon reaches the
    /// sidebar's favicon cache.
    @MainActor
    private func sidebarNavigationChecks(
        model: BrowserViewModel,
        store: SidebarStore,
        tab: Tab,
        engine: ChromiumEngine,
        base: String
    ) async throws {
        model.selectTab(tab.id)
        try check(model.navigationEngine === engine, "navigation commands do not target the selected tab's engine")
        if ReArcEngineHasFeature("favicon") {
            try await wait("tab A favicon in the sidebar cache", timeout: 15) {
                store.tab(withID: tab.id).map { model.favicon(for: $0) != nil } ?? false
            }
            log("PASS sidebar favicon: tab A row icon from ReArcFaviconGet (\(engine.faviconData?.count ?? 0) bytes) via FaviconStore")
        }
        if ReArcEngineHasFeature("security_state") {
            try await wait("security_state event for tab A", timeout: 10) { engine.securityLevel != 4 }
            log("PASS security_state for \(engine.currentURL?.absoluteString ?? "") -> level \(engine.securityLevel) "
                + "(\(engine.securityState)) shown by the sidebar URL field")
        }

        func title() -> String { engine.pageTitle ?? "" }
        func loadCount() -> Int { Int(title().split(separator: ":").last ?? "") ?? 0 }
        engine.load(URL(string: "\(base)/nav")!)
        try await wait("navigation fixture loaded", timeout: 15) { title().hasPrefix("nav:navigate:") && !engine.isLoading }
        model.goBack()
        try await wait("sidebar Back -> /a", timeout: 15) { engine.currentURL?.path == "/a" && !engine.isLoading }
        try await wait("canGoForward after Back") { engine.canGoForward }
        model.goForward()
        try await wait("sidebar Forward -> /nav", timeout: 15) {
            engine.currentURL?.path == "/nav" && !engine.isLoading && title().hasPrefix("nav:")
        }
        let before = loadCount()
        model.reload()
        try await wait("sidebar Reload", timeout: 15) { title() == "nav:reload:\(before + 1)" && !engine.isLoading }
        model.reload(ignoringCache: true)
        try await wait("Reload Ignoring Cache", timeout: 15) { title() == "nav:reload:\(before + 2)" && !engine.isLoading }
        log("PASS sidebar navigation: Back/Forward between /a and /nav, Reload -> '\(before + 1)', Reload Ignoring Cache -> '\(title())'")

        engine.load(URL(string: "\(base)/slow")!)
        try await wait("slow load in flight", timeout: 10) { engine.isLoading }
        let started = Date()
        model.reloadOrStop()
        try await wait("Stop ended the load before the fixture answered", timeout: LoopbackFixtureServer.slowResponseDelay - 2) {
            !engine.isLoading
        }
        try check(title() != "slow-loaded", "the stopped page still loaded")
        log(String(format: "PASS Stop (ReArcTabStop) ended the in-flight load after %.2f s; page stays '%@'",
                   Date().timeIntervalSince(started), title()))
        // Back to page A so the checks that follow see the state they expect.
        engine.load(URL(string: "\(base)/a")!)
        try await wait("tab A restored after navigation checks", timeout: 15) {
            engine.currentURL?.path == "/a" && engine.pageTitle == Self.titleA && !engine.isLoading
        }
    }

    // MARK: Wave 26 sidebar activity

    /// Pinned collapse, Copy URL formats, the loading ring, a crashed page's
    /// recovery and the unread dot, on the shell's own model and tab A.
    @MainActor
    private func wave26SidebarChecks(model: BrowserViewModel, store: SidebarStore, tab: Tab, engine: ChromiumEngine, base: String,
                                     window: NSWindow) async throws {
        model.selectTab(tab.id)
        // Earlier input-driven steps can leave tab A elsewhere when the app is inactive.
        if engine.currentURL?.path != "/a" || engine.pageTitle != Self.titleA {
            loadShellTab(model, store.tab(withID: tab.id) ?? tab, engine, URL(string: "\(base)/a")!)
            try await wait("tab A on /a for the wave 26 checks", timeout: 15) {
                engine.currentURL?.path == "/a" && engine.pageTitle == Self.titleA && !engine.isLoading
            }
        }
        let space = store.activeSpaceID
        let pinned = store.addTab(kind: .pinned, title: "Pinned P", url: URL(string: "\(base)/a")!)
        ShellMenus.sidebarItems(model).flatMap { $0 }.first { $0.title == "Collapse Pinned Section" }?.action()
        let keyWindow = store.keyWindowID
        try check(model.isPinnedSectionCollapsed(spaceID: space, in: keyWindow), "Collapse Pinned Section left it expanded")
        let collapsedRows = PinnedSectionCollapseState.visibleEntries(
            store.content(for: space).pinned, isCollapsed: true, selectedID: store.selectedItemID(inSpace: space))
        try check(collapsedRows.isEmpty, "a collapsed section with a Today selection shows \(collapsedRows.count) rows")
        _ = model.executeCommand(.expandPinnedSection, commandID: nil)
        try check(!model.isPinnedSectionCollapsed(spaceID: space, in: keyWindow), "Expand Pinned Section left it collapsed")
        log("PASS pinned section: Collapse (menu) hides the pinned rows in the key window, Expand (command) shows them")

        // Copy URL formats, on a private pasteboard; Quote reads the page's selection.
        let realPasteboard = model.linkPasteboard
        model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-selftest-\(UUID().uuidString)"))
        defer { model.linkPasteboard = realPasteboard }
        model.copyURL(format: .markdown)
        let markdown = "[\(Self.titleA)](\(base)/a)"
        try check(model.linkPasteboard.string(forType: .string) == markdown && model.toast?.message == "Copied Current URL",
                  "Copy URL as Markdown wrote '\(model.linkPasteboard.string(forType: .string) ?? "")'")
        _ = try await engine.evaluate("(getSelection().selectAllChildren(document.body), String(getSelection()))", in: .page)
        model.copyURL(format: .quote)
        try await wait("Copy as Quote with the page selection") { model.lastCopiedLinkText?.hasPrefix("> ") == true && model.lastCopiedLinkText != "> \(markdown)" }
        let quote = model.lastCopiedLinkText ?? ""
        try check(quote.hasSuffix("> — \(markdown)"), "quote '\(quote)' has no source link")
        _ = try await engine.evaluate("(getSelection().removeAllRanges(), true)", in: .page)
        log("PASS Copy URL as Markdown '\(markdown)' and Copy as Quote (\(quote.split(separator: "\n").count) lines, page selection "
            + "read in the editor world) with the toast")

        // The loading ring: a held-back load is in flight, then stopped.
        engine.load(URL(string: "\(base)/slow")!)
        try await wait("tab A row shows loading", timeout: 10) { model.tabActivity(tab.id).isLoading }
        let progress = engine.loadProgress
        model.stopLoading()
        try await wait("tab A row idle after Stop") { model.tabActivity(tab.id) == .idle }
        log(String(format: "PASS loading indicator: row and content bar loading (load_progress %.2f) while /slow is held, idle after Stop", progress))

        // A crashed renderer (engine `is_crashed`, as PrimaryMainFrameRenderProcessGone reports it).
        var raw = ReArcTabEvent()
        raw.kind = ChromiumTabEvent.Kind.updated.rawValue
        raw.profile_id = engine.engineProfileID
        raw.tab_id = engine.tabID
        raw.content_generation = engine.contentGeneration
        raw.changes = ChromiumTabEvent.Changes.crashed.rawValue
        raw.is_crashed = true
        guard let crashed = withUnsafePointer(to: &raw, { ChromiumTabEvent($0) }) else { throw Failure(description: "crash event") }
        engine.handle(crashed)
        try check(model.tabActivity(tab.id) == .crashed, "an is_crashed event left the tab \(model.tabActivity(tab.id))")
        engine.load(URL(string: "\(base)/a")!)
        model.reloadCrashedTab(tab.id)
        try await wait("crashed tab recovered by Reload", timeout: 15) {
            model.tabActivity(tab.id) == .idle && engine.pageTitle == Self.titleA && engine.currentURL?.path == "/a"
        }
        log("PASS crashed tab: is_crashed shows the sad tab with Reload; the next commit clears it")

        // Unread: a background pinned tab's title changes after its load settled.
        model.selectTab(pinned.id)
        let pinnedEngine = try shellEngine(model, pinned)
        try await wait("pinned tab P loaded", timeout: 20) { pinnedEngine.pageTitle == Self.titleA && !pinnedEngine.isLoading }
        model.selectTab(tab.id)
        model.lastNavigationAt[pinned.id] = Date(timeIntervalSinceNow: -UnreadActivityPolicy.settleInterval - 1)
        try check(store.tab(withID: pinned.id)?.isUnread == false, "P is unread before any activity")
        _ = try await pinnedEngine.evaluate("(document.title = '(1) ' + document.title, document.title)", in: .page)
        try await wait("background title change marks P unread") { store.tab(withID: pinned.id)?.isUnread == true }
        try check(store.tab(withID: pinned.id)?.title == "(1) \(Self.titleA)", "P's row title did not follow the page")
        model.selectTab(pinned.id)
        try check(store.tab(withID: pinned.id)?.isUnread == false, "selecting P left it unread")
        model.selectTab(tab.id)
        model.deleteTab(pinned.id)
        log("PASS unread dot: a background title change on pinned P set isUnread (row title follows); selecting P cleared it")

        // Command bar ⌘↩ opens the fixture page in a new tab (tab A stays); Ctrl+Tab goes back.
        model.focusLocation()
        model.commandBarText = "\(base)/a?routed=1"
        model.submitCommandBar(route: .newTab)
        guard let routed = store.selectedTab, routed.id != tab.id else { throw Failure(description: "⌘↩ opened no new tab") }
        let routedEngine = try shellEngine(model, routed)
        try await wait("⌘↩ new tab loaded", timeout: 20) { routedEngine.pageTitle == Self.titleA && !routedEngine.isLoading }
        try check(store.tab(withID: tab.id)?.url.path == "/a" && engine.currentURL?.query == nil, "⌘↩ navigated tab A")
        func key(_ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                             characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48)
        }
        guard let ctrlTab = key(.control), let release = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 59) else { throw Failure(description: "key events") }
        try check(model.handleTabSwitcherEvent(ctrlTab) && model.tabSwitcher?.highlighted.id == tab.id,
                  "Ctrl+Tab highlights \(model.tabSwitcher?.highlighted.title ?? "nothing"), not tab A")
        _ = model.handleTabSwitcherEvent(release)
        try await wait("Ctrl+Tab release selects tab A and re-attaches it", timeout: 20) {
            store.selectedTabID == tab.id && model.tabSwitcher == nil && engine.attachmentID != nil
        }
        model.deleteTab(routed.id)
        model.selectTab(tab.id)
        log("PASS command bar ⌘↩ opened \(routedEngine.currentURL?.absoluteString ?? "") in a new tab; Ctrl+Tab (MRU switcher) "
            + "highlighted tab A and releasing Control selected it")
        try await optionCommandClickChecks(model: model, store: store, tab: tab, engine: engine, base: base, window: window)

        // Air Traffic Control: a rule sends a link from another app to a Little Arc in the profile.
        let savedRouting = model.linkRouting
        let savedDestination = model.externalLinkDestination
        defer {
            model.linkRouting = savedRouting
            model.externalLinkDestination = savedDestination
        }
        model.externalLinkDestination = .activeSpace
        model.linkRouting = LinkRoutingState(rules: [
            LinkRoutingRule(matchType: .contains, pattern: "/a?atc=", destination: .littleArc(store.activeProfileID)),
        ])
        let tabsBefore = store.displayTabs().count
        ExternalLinkRouter.shared.receive(URL(string: "\(base)/a?atc=1")!)
        guard let routed = store.littleArcLiveWindows.last, routed.url.query == "atc=1",
              let routedEngine = model.littleArcEngine(for: routed.id) as? ChromiumEngine else {
            throw Failure(description: "Air Traffic Control sent the link nowhere (\(store.displayTabs().count - tabsBefore) new tabs)")
        }
        try await wait("Air Traffic Control Little ReArc loaded", timeout: 20) {
            routedEngine.pageTitle == Self.titleA && !routedEngine.isLoading && routedEngine.attachmentID != nil
        }
        try check(store.displayTabs().count == tabsBefore, "the routed link also opened a tab")
        model.windowPresenter?.dismissLittleArcWindow(routed.id)
        try await wait("Air Traffic Control Little ReArc closed") { store.littleArcWindow(withID: routed.id) == nil }
        log("PASS Air Traffic Control: a 'URL contains' rule sent a GetURL link to a Little ReArc (tab \(routedEngine.tabID)) "
            + "instead of the default (current space)")

        // Site Control Center on tab A: the panel's zoom acts on this page; site data lives in Chromium's Site Settings.
        guard let site = SiteControlCenter.site(for: engine.currentURL) else { throw Failure(description: "tab A has no site") }
        model.zoom(.zoomIn, engine: engine)
        try await wait("Site Control Center zoom in") { !PageZoom.isDefault(engine.zoomFactor) }
        model.zoom(.reset, engine: engine)
        try await wait("Site Control Center zoom reset") { PageZoom.isDefault(engine.zoomFactor) }
        try check((engine as AnyObject) is SiteDataManaging == false && model.sitePermissionsLiveInEngine,
                  "Chromium site data should open Site Settings")
        // Arc's panel: the ⋯ menu ends with Chromium's pages; the footer has no certificate to show.
        let menu = model.siteControlsMenu(for: engine, site: site)
        try check(menu.last == [.cookiesAndSiteData, .siteSettings], "⋯ menu \(menu)")
        let rows = model.siteControlSettingRows(for: engine, site: site)
        // The content blocking row (an engine with ABI 1.66) has its own actions; the
        // content blocking checks below test it.
        let settingRows = rows.filter { $0.kind != .contentBlocking }
        try check(settingRows.last?.kind == .autoPictureInPicture
                  && settingRows.dropLast().allSatisfy { $0.actions == [.openSiteSettings] }, "settings rows \(rows.map(\.title))")
        let footer = model.siteControlsFooter(for: engine)
        try check(footer.action == .openSiteSettings, "footer \(footer)")
        log("PASS Site Control Center for \(site.host): panel zoom in and reset on tab A (zoom events); cookies and site data "
            + "-> chrome://settings/content/siteDetails; Arc's panel: \(rows.count) settings rows, ⋯ menu \(menu.count) sections, "
            + "footer '\(footer.title)'")
    }

    /// ⌥⌘-click on a link in tab A: Chromium makes a background tab, which the
    /// shell adopts as a Little Arc (the click's keys, as the app monitor notes them).
    @MainActor
    private func optionCommandClickChecks(model: BrowserViewModel, store: SidebarStore, tab: Tab, engine: ChromiumEngine, base: String,
                                          window: NSWindow) async throws {
        guard inputDeliverable(window) else {
            log("NOTE ⌥⌘-click: synthesized input is not deliverable (app active \(NSApp.isActive)); not exercised in this run")
            return
        }
        loadShellTab(model, store.tab(withID: tab.id) ?? tab, engine, URL(string: "\(base)/links")!)
        try await wait("tab A on the link fixture", timeout: 15) { engine.pageTitle == "links" && !engine.isLoading }
        let link = try await cssCenter(of: "#blank", in: engine)
        let adoptionsBefore = model.littleArcAdoptions
        let tabsBefore = store.displayTabs().count
        var opened = false
        var modifiedClick = false
        // The engine drops a ⌘-modified target=_blank click (no created event), so the last try is
        // a plain click with ⌥⌘ recorded: it still drives the shell's Little Arc adoption end to end.
        for attempt in 0..<3 where !opened {
            focus(window)
            model.noteMouseDown(modifiers: [.command, .option])
            modifiedClick = attempt < 2
            click(window, engine: engine, at: link, modifiers: modifiedClick ? [.command, .option] : [])
            opened = await eventually(timeout: 2) { model.littleArcAdoptions > adoptionsBefore }
        }
        if opened, let record = store.littleArcLiveWindows.last,
           let little = model.littleArcEngine(for: record.id) as? ChromiumEngine {
            try await wait("⌥⌘-clicked link loaded in Little ReArc", timeout: 20) {
                little.currentURL?.path == "/a" && little.pageTitle == Self.titleA && !little.isLoading
            }
            try check(little.role == .littleArc && store.displayTabs().count == tabsBefore && engine.pageTitle == "links",
                      "⌥⌘-click: role \(little.role), tabs \(tabsBefore) -> \(store.displayTabs().count), tab A '\(engine.pageTitle ?? "")'")
            model.windowPresenter?.dismissLittleArcWindow(record.id)
            try await wait("⌥⌘-click Little ReArc closed") { store.littleArcWindow(withID: record.id) == nil }
            let path = modifiedClick ? "modified click"
                : "ENGINE-GAP: modified clicks open no contents, so a plain click with ⌥⌘ recorded"
            log("PASS ⌥⌘-click: Chromium's new contents for the target=_blank link became Little ReArc tab \(little.tabID) on /a; "
                + "no sidebar tab; tab A stayed on its page (\(path))")
        } else {
            log("NOTE ⌥⌘-click: the synthesized click opened no tab (app active \(NSApp.isActive), key \(window.isKeyWindow)); not exercised")
        }
        loadShellTab(model, store.tab(withID: tab.id) ?? tab, engine, URL(string: "\(base)/a")!)
        try await wait("tab A back on /a", timeout: 15) { engine.currentURL?.path == "/a" && engine.pageTitle == Self.titleA && !engine.isLoading }
    }

    /// Loads a shell tab's page and its sidebar URL together, so a window
    /// becoming key (`loadSelectedIfNeeded`) does not send it back.
    @MainActor
    private func loadShellTab(_ model: BrowserViewModel, _ tab: Tab, _ engine: ChromiumEngine, _ url: URL) {
        model.store.updateTab(tab.id, url: url)
        engine.load(url)
    }

    /// A new Today tab on a fixture page, selected and loading, for a step
    /// that needs a page of its own.
    @MainActor
    private func openFixtureTab(_ model: BrowserViewModel, _ store: SidebarStore, title: String,
                                path: String) throws -> (tab: Tab, engine: ChromiumEngine) {
        let url = URL(string: "\(serverBase)\(path)")!
        let tab = store.addTab(kind: .today, title: title, url: url)
        model.selectTab(tab.id)
        let engine = try shellEngine(model, tab)
        loadShellTab(model, tab, engine, url)
        return (tab, engine)
    }

    /// Runs `body` on a fixture page in a tab of its own (`openFixtureTab`),
    /// then closes the tab and selects the one shown before.
    @MainActor
    private func withFixtureTab(_ model: BrowserViewModel, _ store: SidebarStore, title: String, path: String,
                                _ body: @MainActor (Tab, ChromiumEngine) async throws -> Void) async throws {
        let previous = store.selectedTab?.id
        let (tab, engine) = try openFixtureTab(model, store, title: title, path: path)
        defer {
            model.closeTab(tab.id)
            if let previous { model.selectTab(previous) }
        }
        try await body(tab, engine)
    }

    /// The page's renderer still answers a script and the engine reports no crash.
    @MainActor
    private func checkRendererAlive(_ engine: ChromiumEngine, after what: String) async throws {
        let alive = (try? await engine.evaluate("1 + 1", in: .page)) as? NSNumber
        try check(alive?.intValue == 2 && !engine.isCrashed, "renderer after \(what): crashed \(engine.isCrashed)")
    }

    // MARK: Trusted navigation

    @MainActor
    /// Two-finger swipe back and forward. The owner lost it on YouTube and GitHub in 1152:
    /// the edge probe gave up on any custom element, so every swipe there went to the page.
    private func historySwipeChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        engine.load(URL(string: "\(base)/swipe-edges")!)
        try await wait("swipe edges fixture") { engine.pageTitle == "swipe-edges-ready" && !engine.isLoading }
        @MainActor func probe(_ x: Double, _ y: Double) async throws -> (back: Bool, forward: Bool) {
            let result = try await engine.evaluate(HistorySwipeEdgeScript.source(x: x, y: y), in: .editor) as? [String: Any]
            return (result?["back"] as? Bool == true, result?["forward"] as? Bool == true)
        }
        let cells: [(name: String, x: Double, y: Double, back: Bool, forward: Bool)] = [
            ("plain text", 0.125, 0.25, true, true),
            ("custom element with a shadow root", 0.375, 0.25, true, true),
            ("scroller at its start inside a shadow root", 0.625, 0.25, true, false),
            ("scroller in its middle", 0.875, 0.25, false, false),
            ("overscroll-behavior contain, no scroller", 0.125, 0.75, true, true),
            ("scroller at its start with overscroll-behavior contain", 0.375, 0.75, false, false),
            ("iframe", 0.625, 0.75, false, false),
            ("scroller at its end", 0.875, 0.75, false, true),
        ]
        for cell in cells {
            let edges = try await probe(cell.x, cell.y)
            try check(edges.back == cell.back && edges.forward == cell.forward,
                      "history swipe probe over \(cell.name): back \(edges.back) forward \(edges.forward), "
                      + "expected back \(cell.back) forward \(cell.forward)")
        }
        log("PASS history swipe probe: \(cells.count) cells (custom elements, shadow roots, scrollers, contain, iframe)")
        _ = try await engine.evaluate("document.documentElement.style.overscrollBehaviorX = 'none'", in: .page)
        let rootNone = try await probe(0.125, 0.25)
        try check(!rootNone.back && !rootNone.forward, "history swipe probe ignored overscroll-behavior-x: none on the root")
        _ = try await engine.evaluate("document.documentElement.style.overscrollBehaviorX = ''", in: .page)
        log("PASS history swipe probe: overscroll-behavior-x: none on the root stops the swipe")

        // The real path: phased trackpad events through NSApp, the local monitor, the
        // probe and the swipe machine, with a first event more vertical than sideways
        // (real fingers, 2026-11-18). Back from B to A, then forward to B.
        guard let host = window.contentView?.firstDescendant(ofType: ChromiumHostView.self) else {
            throw Failure(description: "history swipe: no page view in the window")
        }
        window.makeKeyAndOrderFront(nil)
        engine.load(URL(string: "\(base)/swipe-a")!)
        try await wait("swipe page A") { engine.pageTitle == "swipe-a" && !engine.isLoading }
        engine.load(URL(string: "\(base)/swipe-b")!)
        try await wait("swipe page B") { engine.pageTitle == "swipe-b" && !engine.isLoading && engine.canGoBack }
        try await swipe(window: window, host: host, dx: 18)
        try await wait("swipe back to page A", timeout: 10) { engine.pageTitle == "swipe-a" && !engine.isLoading }
        log("PASS history swipe: a swipe over custom elements goes back")
        try await wait("forward history after the swipe") { engine.canGoForward }
        try await swipe(window: window, host: host, dx: -18)
        try await wait("swipe forward to page B", timeout: 10) { engine.pageTitle == "swipe-b" && !engine.isLoading }
        log("PASS history swipe: a swipe over custom elements goes forward")
    }

    /// One trackpad swipe over the middle of `host`: may-begin, a jittery began, 14 changes,
    /// ended, handed to the page's swipe handler as its local monitor hands them. AppKit drops
    /// the position of a synthesized scroll event that names a window, so it goes alongside.
    @MainActor
    private func swipe(window: NSWindow, host: ChromiumHostView, dx: Int32) async throws {
        guard let handler = host.historySwipe else { throw Failure(description: "history swipe: the page has no swipe handler") }
        let mid = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        var taken = 0
        @MainActor func send(_ dx: Int32, _ dy: Int32, phase: Int64) async throws {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
                throw Failure(description: "history swipe: no scroll event")
            }
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
            cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(dy))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: Double(dx))
            // 51: the event's window number (kCGSEventWindowIDField); NSEvent reads its window from it.
            if let windowField = CGEventField(rawValue: 51) {
                cg.setIntegerValueField(windowField, value: Int64(window.windowNumber))
            }
            guard let event = NSEvent(cgEvent: cg), event.window === window, event.hasPreciseScrollingDeltas else {
                throw Failure(description: "history swipe: the synthesized scroll event is not a trackpad event for the test window")
            }
            if handler.handleForSelfTest(event, locationInWindow: mid) { taken += 1 }
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        try await send(0, 0, phase: 128)
        let first = dx > 0 ? Int32(1) : Int32(-1)
        try await send(first, 2, phase: 1)
        for _ in 0..<14 { try await send(dx, 0, phase: 2) }
        try await send(0, 0, phase: 4)
        try check(taken >= 15, "history swipe took \(taken) of 17 events; the page got the rest")
    }

    @MainActor
    private func trustedNavigationChecks(engine: ChromiumEngine, base: String) async throws {
        let viewSource = NavigationURLPolicy.viewSourceURL(for: URL(string: "\(base)/a")!, engine: .chromium)!
        let viewSourceStatus = engine.navigateNow(viewSource)
        try check(viewSourceStatus == .rearcOK, "view-source rejected: \(viewSourceStatus.rearcName)")
        try await wait("view-source commit") { engine.currentURL?.scheme == "view-source" && !engine.isLoading }
        log("PASS view-source committed: \(engine.currentURL?.absoluteString ?? "")")

        let versionStatus = engine.navigateNow(BrowserInternalPage.version.url)
        try check(versionStatus == .rearcOK, "chrome://version rejected: \(versionStatus.rearcName)")
        try await wait("chrome://version commit", timeout: 20) {
            engine.currentURL?.absoluteString.hasPrefix("chrome://version") == true && !engine.isLoading
        }
        log("PASS chrome://version committed, title '\(engine.pageTitle ?? "")'")
        if runtime.capabilities.scriptEvaluation {
            let webUIError = try await expectEvaluationError("evaluation on WebUI") {
                try await engine.evaluate("document.title", in: .page)
            }
            let unsupported = ChromiumStatusCode.unsupported
            try check(webUIError == .rejected(unsupported) || {
                if case .failed(let status, _) = webUIError { return status == unsupported }
                return false
            }(), "evaluation on chrome://version reported \(webUIError)")
            log("PASS evaluation on WebUI refused: \(webUIError)")
        }

        let settingsStatus = engine.navigateNow(BrowserInternalPage.settings.url)
        try check(settingsStatus == .rearcOK, "chrome://settings rejected: \(settingsStatus.rearcName)")
        try await wait("chrome://settings commit", timeout: 25) {
            engine.currentURL?.host() == "settings" && engine.currentURL?.scheme == "chrome" && !engine.isLoading
        }
        log("PASS chrome://settings committed (the shell's Settings entry point), title '\(engine.pageTitle ?? "")'")
        try await importDataChecks(engine: engine)

        if runtime.capabilities.webUIDailyPages {
            var committed: [String] = []
            for page in [BrowserInternalPage.history, .downloads, .passwords, .extensions] {
                let status = engine.navigateNow(page.url)
                try check(status == .rearcOK, "\(page.url) rejected: \(status.rearcName)")
                let host = page.url.host()
                try await wait("\(page.url) commit", timeout: 25) {
                    engine.currentURL?.scheme == "chrome" && engine.currentURL?.host() == host && !engine.isLoading
                }
                committed.append("\(engine.currentURL?.absoluteString ?? "") '\(engine.pageTitle ?? "")'")
            }
            log("PASS daily WebUI committed (webui_daily_pages): \(committed.joined(separator: ", "))")
        } else {
            log("ABI-GAP webui_daily_pages not advertised: History, Downloads, Passwords and Extensions stay hidden")
        }

        var rejected: [String] = []
        for bad in ["javascript:void(0)", "chrome://flags", "view-source:view-source:\(base)/a"] {
            let status = engine.navigateNow(URL(string: bad)!)
            try check(status == ReArcStatus(REARC_INVALID_URL), "\(bad) returned \(status.rearcName)")
            rejected.append(bad)
        }
        log("PASS still rejected with invalid_url: \(rejected.joined(separator: ", "))")
    }

    /// ABI 1.13: an existing directory opens in place; the startup one returns
    /// the startup ID; bad syntax rejects synchronously, a missing one async.
    @MainActor
    private func profileDirectoryChecks() async throws {
        func open(_ token: String) async -> (ReArcStatus, UInt64) {
            await withCheckedContinuation { continuation in
                runtime.openDirectory(token) { status, id, _ in continuation.resume(returning: (status, id)) }
            }
        }
        let (defaultStatus, defaultID) = await open("Default")
        try check(defaultStatus == .rearcOK && defaultID == runtime.defaultProfileID,
                  "OpenDirectory(Default) -> \(defaultStatus.rearcName) id \(defaultID), startup \(runtime.defaultProfileID)")
        let (missingStatus, missingID) = await open("rearc-selftest-missing")
        try check(missingStatus != .rearcOK && missingID == 0, "missing directory -> \(missingStatus.rearcName) id \(missingID)")
        let (traversalStatus, _) = await open("../Default")
        try check(traversalStatus == ReArcStatus(REARC_INVALID_ARGUMENT), "../Default -> \(traversalStatus.rearcName)")
        try check(runtime.liveProfileContexts == 0, "\(runtime.liveProfileContexts) directory request context(s) never released")
        log("PASS OpenDirectory: Default -> startup profile \(defaultID); missing -> \(missingStatus.rearcName); "
            + "../Default -> \(traversalStatus.rearcName); contexts released")
    }

    @MainActor
    private func shutdown() {
        log("requesting orderly shutdown")
        let status = runtime.requestShutdown(force: true) { [self] status, cancelled in
            shutdownStatus = cancelled ? ReArcStatus(REARC_CANCELLED) : status
            log("shutdown completion: \(status.rearcName) cancelled=\(cancelled) attached=\(engine?.attachmentID != nil)")
            if status != .rearcOK {
                // Rejected after waiting for closes in flight: Run will not return.
                failures.append("ReArcEngineShutdown rejected: \(status.rearcName)")
                log("FAIL ReArcEngineShutdown rejected: \(status.rearcName)")
                fflush(stdout)
                _exit(1)
            }
        }
        if status != .rearcOK {
            failures.append("ReArcEngineShutdown rejected: \(status.rearcName)")
            log("FAIL ReArcEngineShutdown rejected: \(status.rearcName)")
            fflush(stdout)
            _exit(1)
        }
    }
}

/// The self-test asks the list mirror for nothing (security CB-08): a fresh
/// profile counts as a new install, which has blocking on and would fetch
/// `latest.json` from the live site. A list that changed under the page
/// checks would also change what they see.
private struct SelfTestNoMirror: BlocklistFetching {
    func data(from url: URL, limit: Int) async throws -> Data {
        throw URLError(.notConnectedToInternet)
    }
}

/// The cold launch's mirror for a list update (security CB-02, the takeover
/// step): `latest.json` and the archive the self-test wrote into `folder`,
/// for the mirror's own addresses only. Nothing goes over the network.
private struct SelfTestFileMirror: BlocklistFetching {
    let folder: URL

    func data(from url: URL, limit: Int) async throws -> Data {
        guard url == BlocklistMirror.latestURL || BlocklistMirror.isMirrorURL(url, for: BlocklistMirror.latestURL) else {
            throw URLError(.unsupportedURL)
        }
        let data = try Data(contentsOf: folder.appendingPathComponent(url.lastPathComponent))
        guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return data
    }
}

// MARK: - Host prompt channels (ABI 1.18–1.22)

/// Answers file panels for the self-test: records each request and replies
/// with `reply` (nil cancels) unless `hold` keeps the panel open.
private final class SelfTestFilePanels: FilePanelPresenting {
    final class Handle: FilePanelHandle {
        var closed = false
        func close() { closed = true }
    }

    var requests: [FileChooserRequest] = []
    var handles: [Handle] = []
    var reply: [URL]?
    var hold = false

    func present(_ request: FileChooserRequest, in window: NSWindow?, completion: @escaping ([URL]?) -> Void) -> FilePanelHandle? {
        requests.append(request)
        let handle = Handle()
        handles.append(handle)
        if !hold {
            let reply = self.reply
            DispatchQueue.main.async { completion(reply) }
        }
        return handle
    }
}

/// Stands in for the NSMenu (whose tracking loop would block the run): records each plan.
private final class SelfTestMenus: PageContextMenuPresenting {
    var plans: [PageContextMenuPlan] = []
    var choice: PageContextMenuItem?
    var hold = false

    func present(_ plan: PageContextMenuPlan, at point: CGPoint, in view: NSView?, completion: @escaping (PageContextMenuItem?) -> Void) {
        plans.append(plan)
        guard !hold else { return }
        let choice = self.choice
        DispatchQueue.main.async { completion(choice) }
    }
}

extension ChromiumSelfTest {
    /// Synthesized input reaches the renderer only while the app is active and the window key and visible.
    @MainActor
    private func inputDeliverable(_ window: NSWindow) -> Bool {
        ShellInput.deliverable(window)
    }

    @MainActor
    private func cssCenter(of selector: String, in engine: ChromiumEngine) async throws -> CGPoint {
        let point = try await engine.evaluate(
            "(function(){ var r = document.querySelector('\(selector)').getBoundingClientRect(); "
                + "return { x: r.left + Math.min(30, r.width / 2), y: r.top + r.height / 2 }; })()",
            in: .page
        ) as? [String: Double]
        guard let x = point?["x"], let y = point?["y"] else { throw Failure(description: "no \(selector) on the page") }
        return CGPoint(x: x, y: y)
    }

    /// Brings the window forward and gives the page the keyboard.
    @MainActor
    private func focus(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let host = window.contentView?.firstDescendant(ofType: ChromiumHostView.self), let page = host.subviews.first {
            window.makeFirstResponder(page)
        }
    }

    /// Sends a synthesized (right) click to the page at a CSS point.
    @MainActor
    /// `host` is the page's view when several are in the window (a Peek over a tab); else the first one.
    private func click(_ window: NSWindow, engine: ChromiumEngine, at css: CGPoint, right: Bool = false, control: Bool = false,
                       modifiers: NSEvent.ModifierFlags = [], host: ChromiumHostView? = nil) {
        guard let host = host ?? window.contentView?.firstDescendant(ofType: ChromiumHostView.self) else { return }
        window.makeKeyAndOrderFront(nil)
        let viewPoint = PageZoom.viewPoint(fromCSSPoint: css, zoom: engine.zoomFactor)
        let local = NSPoint(x: viewPoint.x, y: host.isFlipped ? viewPoint.y : host.bounds.height - viewPoint.y)
        let location = host.convert(local, to: nil)
        let types: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: control ? [.control] : modifiers,
                                              timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
    }

    /// What a click at `css` on `engine`'s page would land on, and every page view in the window.
    @MainActor
    private func hitReport(_ window: NSWindow, engine: ChromiumEngine, at css: CGPoint) -> (hitsPage: Bool, text: String) {
        guard let content = window.contentView, let host = engine.leaseHolder else { return (false, "the page has no view") }
        let viewPoint = PageZoom.viewPoint(fromCSSPoint: css, zoom: engine.zoomFactor)
        let local = NSPoint(x: viewPoint.x, y: host.isFlipped ? viewPoint.y : host.bounds.height - viewPoint.y)
        let point = content.convert(host.convert(local, to: nil), from: nil)
        var chain: [String] = []
        var view = content.hitTest(point)
        var hitHost: ChromiumHostView?
        while let current = view {
            chain.append(String(describing: Swift.type(of: current)))
            if let found = current as? ChromiumHostView { hitHost = found; break }
            view = current.superview
        }
        var hosts: [String] = []
        func collect(_ view: NSView) {
            if let found = view as? ChromiumHostView {
                hosts.append("tab \(found.engine.tabID) lease \(found.leaseAttachmentID ?? 0) frame \(found.convert(found.bounds, to: nil))"
                             + (found.isHiddenOrHasHiddenAncestor ? " hidden" : ""))
            }
            if NSStringFromClass(Swift.type(of: view)).contains("RenderWidgetHostViewCocoa") {
                hosts.append("renderer view frame \(view.convert(view.bounds, to: nil))" + (view.isHidden ? " hidden" : ""))
            }
            view.subviews.forEach(collect)
        }
        collect(host)
        // The click reaches the page only through its renderer view, the hit chain's first link.
        let reachesRenderer = hitHost === host && chain.first?.contains("RenderWidgetHostViewCocoa") == true
        return (reachesRenderer, "hit \(chain.prefix(6).joined(separator: " < ")) (tab \(hitHost?.engine.tabID ?? 0)); page view: "
                + hosts.joined(separator: "; "))
    }

    @MainActor
    private func rightClickUntil(_ window: NSWindow, engine: ChromiumEngine, at css: CGPoint, _ label: String, _ condition: () -> Bool) async throws {
        for attempt in 0..<3 {
            focus(window)
            click(window, engine: engine, at: css, right: attempt < 2, control: attempt == 2)
            if await eventually(timeout: 1.5, condition) { return }
        }
        throw Failure(description: "timed out waiting for \(label) after three right-clicks")
    }

    @MainActor
    private func type(_ text: String, in window: NSWindow) {
        for character in text {
            let string = String(character)
            for kind in [NSEvent.EventType.keyDown, .keyUp] {
                if let event = NSEvent.keyEvent(with: kind, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: string,
                                                charactersIgnoringModifiers: string, isARepeat: false,
                                                keyCode: string == "\r" ? 36 : 0) {
                    window.sendEvent(event)
                }
            }
        }
    }

    /// Waits for `condition`; false (no failure) when it never came, for input-driven steps.
    @MainActor
    private func eventually(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    @MainActor
    private func promptChannelChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        _ = await bringToFront(window, for: "prompt channel")
        let capabilities = runtime.capabilities
        let minor = capabilities.abiMinorVersion.map(String.init) ?? "absent"
        log("prompt channels: javascript_dialogs=\(capabilities.javascriptDialogs ? 1 : 0) file_chooser=\(capabilities.fileChooser ? 1 : 0) "
            + "permission_prompts=\(capabilities.permissionPrompts ? 1 : 0) context_menu=\(capabilities.contextMenu ? 1 : 0) "
            + "password_prompts=\(capabilities.passwordPrompts ? 1 : 0) (Inspect \(capabilities.canInspect ? "opens the shell's DevTools" : "disabled: no DevTools frontend")); "
            + "synthesized input \(inputDeliverable(window) ? "deliverable" : "not deliverable (app inactive or window not key)")")
        let prompts = engine.pagePrompts
        try check(prompts.anchorView?.window === window, "the page prompt overlay is not in the tab's window")
        // Input-driven channels first, while the app is most likely still active.
        if capabilities.fileChooser {
            try await fileInputChecks(engine: engine, base: base, window: window)
        } else {
            log("ABI-GAP file_chooser not advertised (ABI minor \(minor) < 19): file inputs are cancelled")
        }
        if capabilities.contextMenu {
            try await contextMenuChecks(engine: engine, base: base, window: window)
        } else {
            log("ABI-GAP context_menu not advertised (ABI minor \(minor) < 21): no page menu on Chromium")
        }
        if capabilities.passwordPrompts {
            try await passwordChecks(engine: engine, base: base, window: window)
        } else {
            log("ABI-GAP password_prompts not advertised (ABI minor \(minor) < 22): no save-password offers")
        }
        if capabilities.javascriptDialogs {
            try await beforeUnloadChecks(engine: engine, base: base, window: window)
            try await dialogChecks(engine: engine, base: base, window: window)
        } else {
            log("ABI-GAP javascript_dialogs not advertised (ABI minor \(minor) < 18): pages get Chromium's no-host cancel")
        }
        if capabilities.permissionPrompts {
            try await permissionChecks(engine: engine, base: base)
        } else {
            log("ABI-GAP permission_prompts not advertised (ABI minor \(minor) < 20): requests are dismissed")
        }
        engine.load(URL(string: "\(base)/a")!)
        try await wait("page A after the prompt channels") { engine.pageTitle == Self.titleA && !engine.isLoading }
        try check(!prompts.hasPendingPrompt, "a prompt is still pending after the channel checks")
    }

    // MARK: JavaScript dialogs (ABI 1.18)

    @MainActor
    private func dialogChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let prompts = engine.pagePrompts
        engine.load(URL(string: "\(base)/dialogs")!)
        try await wait("dialogs fixture") { engine.pageTitle == "dialogs" && !engine.isLoading }
        func run(_ kind: String) async throws { _ = try await engine.evaluate("run('\(kind)')", in: .page) }
        func shown(_ kind: JavaScriptDialogKind) async throws -> JavaScriptDialogRequest {
            try await wait("\(kind) dialog request") { prompts.dialog?.request.kind == kind }
            return prompts.dialog!.request
        }

        try await run("alert")
        let alert = try await shown(.alert)
        try check(alert.message == "hello from ReArc" && alert.title.hasPrefix("http://127.0.0.1") && alert.origin.hasPrefix("http://127.0.0.1"),
                  "alert '\(alert.message)' title '\(alert.title)' origin '\(alert.origin)'")
        try check(prompts.dialog?.offersSuppression == false, "the first dialog offered the dialog limit")
        prompts.answerDialog(accept: true)
        try await wait("alert answered") { engine.pageTitle == "alert:done" }

        try await run("confirm")
        _ = try await shown(.confirm)
        try check(prompts.dialog?.offersSuppression == true, "the second dialog did not offer the dialog limit")
        prompts.answerDialog(accept: false)
        try await wait("confirm cancelled") { engine.pageTitle == "confirm:false" }

        try await run("prompt")
        _ = try await shown(.prompt)
        try check(prompts.dialogText == "default name", "prompt default text '\(prompts.dialogText)'")
        prompts.dialogText = "ReArc ✓"
        prompts.answerDialog(accept: true)
        try await wait("prompt answered") { engine.pageTitle == "prompt:ReArc ✓" }

        // "Don't allow this page to create more dialogs": later dialogs are answered without UI.
        try await run("confirm")
        _ = try await shown(.confirm)
        prompts.suppressDialogs = true
        prompts.answerDialog(accept: true)
        try await wait("confirm accepted") { engine.pageTitle == "confirm:true" }
        let eventsBefore = runtime.promptEvents["dialog"] ?? 0
        try await run("confirm")
        try await wait("suppressed confirm") { engine.pageTitle == "confirm:false" }
        try check(prompts.dialog == nil && (runtime.promptEvents["dialog"] ?? 0) == eventsBefore + 1,
                  "a suppressed dialog was shown (events \(eventsBefore) -> \(runtime.promptEvents["dialog"] ?? 0))")

        // A new document may show dialogs again; navigating away withdraws a pending one.
        engine.load(URL(string: "\(base)/dialogs")!)
        try await wait("dialogs fixture reloaded") { engine.pageTitle == "dialogs" && !engine.isLoading }
        try await run("alert")
        let pending = try await shown(.alert)
        let cancelledBefore = prompts.cancelled["dialog"] ?? 0
        engine.load(URL(string: "\(base)/a")!)
        try await wait("navigation withdraws the alert") { prompts.dialog == nil && (prompts.cancelled["dialog"] ?? 0) == cancelledBefore + 1 }
        try await wait("page A after the withdrawn alert") { engine.pageTitle == Self.titleA && !engine.isLoading }
        let late = runtime.respondDialog(pending.id, JavaScriptDialogReply(accept: true))
        try check(late == ReArcStatus(REARC_NOT_FOUND), "a reply to the withdrawn alert returned \(late.rearcName)")
        log("PASS JavaScript dialogs (ABI 1.18, PagePromptCenter): alert '\(alert.title)' accepted, confirm -> false, "
            + "prompt default 'default name' -> 'ReArc ✓', the second dialog offered the limit and a suppressed confirm "
            + "answered false without UI, navigation withdrew a pending alert (late reply -> \(late.rearcName))")
    }

    /// Leave site?: needs the page's sticky user activation, so a synthesized click first.
    @MainActor
    private func beforeUnloadChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let prompts = engine.pagePrompts
        engine.load(URL(string: "\(base)/leave")!)
        try await wait("leave fixture") { engine.pageTitle == "leave" && !engine.isLoading }
        func activate() async throws -> Bool {
            for _ in 0..<3 {
                focus(window)
                click(window, engine: engine, at: CGPoint(x: 200, y: 200))
                if await waitActivation(engine) { return true }
            }
            return false
        }
        guard try await activate() else {
            log("NOTE beforeunload: synthesized input did not activate the page (app active \(NSApp.isActive), key \(window.isKeyWindow)); "
                + "Leave site? needs sticky user activation, so its veto and accept paths are not exercised in this run")
            return
        }
        // Navigation: Stay keeps the page.
        engine.load(URL(string: "\(base)/a")!)
        let leave = try await waitDialog(prompts, .beforeUnload, "beforeunload on navigation")
        try check(leave.title == "Leave site?", "beforeunload title '\(leave.title)'")
        prompts.answerDialog(accept: false)
        try await Task.sleep(nanoseconds: 800_000_000)
        try check(engine.currentURL?.path == "/leave", "Stay still navigated to \(engine.currentURL?.path ?? "nil")")
        // Normal close: Stay vetoes it (ReArcTabClose OK, cancelled).
        var closes: [Bool] = []
        _ = try await activate()
        try check(engine.requestPageClose { closes.append($0) }, "a normal close was not started")
        _ = try await waitDialog(prompts, .beforeUnload, "beforeunload on close")
        prompts.answerDialog(accept: false)
        try await wait("close vetoed") { closes == [false] }
        try check(engine.tabID != 0 && engine.currentURL?.path == "/leave", "the vetoed close still closed the tab")
        // Leave continues the navigation.
        _ = try await activate()
        engine.load(URL(string: "\(base)/a")!)
        _ = try await waitDialog(prompts, .beforeUnload, "beforeunload before leaving")
        prompts.answerDialog(accept: true)
        try await wait("left the page") { engine.pageTitle == Self.titleA && !engine.isLoading }
        log("PASS beforeunload (ABI 1.18): 'Leave site?' on navigation -> Stay kept /leave; on a normal close -> Stay vetoed "
            + "(tab \(engine.tabID) kept); Leave continued to /a")
    }

    /// A non-forced quit with "Leave site?" up, answered Stay: the quit undoes
    /// itself (`ChromiumQuit`), and a page made meanwhile is Chromium and gets
    /// its tab once the runtime is active again.
    @MainActor
    private func vetoedQuitChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let prompts = engine.pagePrompts
        engine.load(URL(string: "\(base)/leave")!)
        try await wait("leave fixture for the vetoed quit") { engine.pageTitle == "leave" && !engine.isLoading }
        var activated = false
        for _ in 0..<3 where !activated {
            focus(window)
            click(window, engine: engine, at: CGPoint(x: 200, y: 200))
            activated = await waitActivation(engine)
        }
        // Without the page's activation there is no Leave site?, and the quit would end the self-test.
        guard activated else {
            log("NOTE vetoed quit: synthesized input did not activate the page; the quit is not exercised in this run")
            return
        }
        var undone = 0
        let shellCancel = runtime.onTerminateCancelled
        runtime.onTerminateCancelled = { undone += 1; shellCancel?() }
        defer { runtime.onTerminateCancelled = shellCancel }
        var outcome: (status: ReArcStatus, cancelled: Bool)?
        let status = runtime.requestShutdown(force: false) { outcome = ($0, $1) }
        try check(status == .rearcOK, "the non-forced quit was rejected: \(status.rearcName)")
        try check(runtime.stage == .quitting, "a quit in progress is \(runtime.stage)")
        let during = ChromiumEngine(runtime: runtime, context: EngineProfileContext(profileID: UUID()), role: .tab, shellID: UUID())
        try check(during.tabID == 0, "a tab was created during the quit")
        _ = try await waitDialog(prompts, .beforeUnload, "beforeunload during the quit")
        prompts.answerDialog(accept: false)
        try await wait("quit vetoed") { outcome != nil }
        try check(outcome?.cancelled == true, "the quit was not vetoed: \(outcome?.status.rearcName ?? "nil")")
        try check(!runtime.isStopping && ChromiumRuntime.active != nil && undone == 1,
                  "after the veto: stopping \(runtime.isStopping), stage \(runtime.stage), undone \(undone)")
        try check(engine.tabID != 0, "the vetoed quit closed the vetoing tab")
        try check(await during.waitForTab(), "the page made during the quit got no tab (\(during.lastError ?? "no error"))")
        log("PASS vetoed quit: Stay kept tab \(engine.tabID), the runtime is active again, "
            + "and the page made during the quit got Chromium tab \(during.tabID)")
    }

    @MainActor
    private func waitActivation(_ engine: ChromiumEngine) async -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline {
            if (try? await engine.evaluate("navigator.userActivation.hasBeenActive", in: .page)) as? Bool == true { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    @MainActor
    private func waitDialog(_ prompts: PagePromptCenter, _ kind: JavaScriptDialogKind, _ label: String) async throws -> JavaScriptDialogRequest {
        try await wait(label, timeout: 10) { prompts.dialog?.request.kind == kind }
        return prompts.dialog!.request
    }

    // MARK: Permissions (ABI 1.20)

    @MainActor
    private func permissionChecks(engine: ChromiumEngine, base: String) async throws {
        let prompts = engine.pagePrompts
        let sites = SitePermissionsController(fileURL: nil)
        prompts.sitePermissions = sites
        prompts.profileID = UUID()
        engine.load(URL(string: "\(base)/permissions")!)
        try await wait("permissions fixture") { engine.pageTitle == "permissions" && !engine.isLoading }
        func waitRequest(_ key: String) async throws -> PermissionPromptRequest {
            try await wait("\(key) permission request", timeout: 10) { prompts.permission?.request.types.map(\.key) == [key] }
            try await wait("permission interaction delay") { prompts.permissionInteractionAllowed }
            return prompts.permission!.request
        }
        func reset() async throws { _ = try await engine.evaluate("(document.title = 'permissions', true)", in: .page) }

        // This time only: the next request prompts again.
        _ = try await engine.evaluate("notify()", in: .page)
        let notify = try await waitRequest("notifications")
        try check(notify.origin.hasPrefix("http://127.0.0.1") && notify.phrases == ["Show notifications"], "request \(notify)")
        prompts.rememberPermission = false
        prompts.answerPermission(.allow)
        try await wait("granted this time") { engine.pageTitle == "notify:granted" }
        try await reset()
        _ = try await engine.evaluate("notify()", in: .page)
        _ = try await waitRequest("notifications")
        // Remembered: Chromium stores the block, and the next request gets no prompt.
        prompts.rememberPermission = true
        prompts.answerPermission(.deny)
        try await wait("denied and remembered") { engine.pageTitle == "notify:denied" }
        try await reset()
        let eventsBefore = runtime.promptEvents["permission"] ?? 0
        _ = try await engine.evaluate("notify()", in: .page)
        try await wait("remembered block answers without a prompt") { engine.pageTitle == "notify:denied" }
        try check(prompts.permission == nil && (runtime.promptEvents["permission"] ?? 0) == eventsBefore,
                  "a remembered block prompted again")

        // Dismiss stores nothing; the page sees PERMISSION_DENIED.
        _ = try await engine.evaluate("geo()", in: .page)
        let geo = try await waitRequest("geolocation")
        try check(geo.needsSystemAuthorization, "geolocation should note macOS authorization")
        prompts.answerPermission(.dismiss)
        try await wait("geolocation dismissed") { engine.pageTitle == "geo:1" }

        // Navigation withdraws a pending request.
        try await reset()
        _ = try await engine.evaluate("geo()", in: .page)
        let pending = try await waitRequest("geolocation")
        let cancelledBefore = prompts.cancelled["permission"] ?? 0
        engine.load(URL(string: "\(base)/a")!)
        try await wait("navigation withdraws the permission prompt") {
            prompts.permission == nil && (prompts.cancelled["permission"] ?? 0) == cancelledBefore + 1
        }
        let late = runtime.respondPermission(pending.id, .allow, persist: true)
        try check(late == ReArcStatus(REARC_NOT_FOUND), "a reply to the withdrawn request returned \(late.rearcName)")
        let recorded = sites.entries(origin: notify.origin, scope: prompts.permissionScope)
        try check(recorded.map(\.type.key) == ["notifications"] && recorded.first?.entry.decision == .deny && recorded.first?.entry.remembered == true,
                  "site record \(recorded.map { "\($0.type.key)=\($0.entry.decision)" })")
        try await wait("page A after permissions") { engine.pageTitle == Self.titleA && !engine.isLoading }
        log("PASS permission prompts (ABI 1.20): notifications allowed this time (prompted again), then blocked and remembered "
            + "(the next request answered without a prompt), geolocation dismissed -> PERMISSION_DENIED, navigation withdrew a "
            + "pending request (late reply -> \(late.rearcName)); site record: notifications blocked (remembered)")
    }

    // MARK: File inputs (ABI 1.19)

    @MainActor
    private func fileInputChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let prompts = engine.pagePrompts
        let panels = SelfTestFilePanels()
        prompts.filePanels = panels
        defer { prompts.filePanels = SystemFilePanelPresenter() }
        let fixtures = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-upload-\(UUID().uuidString)", isDirectory: true)
        let folder = fixtures.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        for name in ["a.txt", "b.txt", "folder/c.txt", "folder/d.txt"] {
            try Data("rearc \(name)\n".utf8).write(to: fixtures.appendingPathComponent(name))
        }
        // A symlink out of the folder is not uploaded (the engine skips symlinks).
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape.txt"), withDestinationURL: fixtures.appendingPathComponent("a.txt"))

        let invalid = ReArcFileChooserRespond(UInt64.max, true, nil, 0)
        try check(invalid == ReArcStatus(REARC_NOT_FOUND), "a reply to an unknown chooser returned \(invalid.rearcName)")
        engine.load(URL(string: "\(base)/upload")!)
        try await wait("upload fixture") { engine.pageTitle == "upload" && !engine.isLoading }
        panels.reply = [fixtures.appendingPathComponent("a.txt"), fixtures.appendingPathComponent("b.txt")]
        var opened = false
        for _ in 0..<3 where !opened {
            focus(window)
            click(window, engine: engine, at: CGPoint(x: 200, y: 200))
            opened = await eventually(timeout: 1.5) { !panels.requests.isEmpty }
        }
        guard opened else {
            log("NOTE file input: the synthesized click opened no chooser (app active \(NSApp.isActive), key \(window.isKeyWindow)); "
                + "input.click() needs user activation, so <input type=file> is not exercised in this run (save panels are, "
                + "through Ask where to save); unknown request -> \(invalid.rearcName)")
            return
        }
        let multiple = panels.requests[0]
        try check(multiple.mode == .openMultiple && multiple.filter.extensions == ["txt"] && multiple.filter.mimeTypes == ["text/plain"],
                  "chooser mode \(multiple.mode) accept \(multiple.acceptTypes)")
        try await wait("files reached the page") { engine.pageTitle == "files:a.txt,b.txt" }

        _ = try await engine.evaluate("folder()", in: .page)
        panels.reply = [folder]
        click(window, engine: engine, at: CGPoint(x: 200, y: 200))
        try await wait("folder chooser", timeout: 5) { panels.requests.count == 2 }
        try check(panels.requests[1].mode == .uploadFolder, "folder chooser mode \(panels.requests[1].mode)")
        try await wait("folder files reached the page") { engine.pageTitle == "folder:2" }

        // The engine withdraws an open chooser when the page navigates; the panel closes.
        panels.hold = true
        click(window, engine: engine, at: CGPoint(x: 200, y: 200))
        try await wait("held chooser", timeout: 5) { panels.requests.count == 3 }
        engine.load(URL(string: "\(base)/a")!)
        try await wait("navigation closes the chooser") { panels.handles.last?.closed == true && prompts.fileChooserRequest == nil }
        try await wait("page A after the chooser") { engine.pageTitle == Self.titleA && !engine.isLoading }
        log("PASS file chooser (ABI 1.19): <input multiple accept=.txt,text/plain> -> open-multiple with filter [txt] [text/plain], "
            + "2 files reached the page; webkitdirectory -> upload folder, 2 files (symlink skipped); navigation closed a held panel; "
            + "unknown request -> \(invalid.rearcName)")
    }

    /// Ask where to save (policy prompt 1): the save path comes from the file chooser channel.
    @MainActor
    private func askWhereToSaveChecks(
        engine: ChromiumEngine,
        base: String,
        controller: DownloadsController,
        backend: ChromiumDownloadBackend,
        directory: URL
    ) async throws -> String {
        let panels = SelfTestFilePanels()
        engine.pagePrompts.filePanels = panels
        backend.filePanels = panels
        defer {
            engine.pagePrompts.filePanels = SystemFilePanelPresenter()
            backend.filePanels = SystemFilePanelPresenter()
        }
        let chosen = directory.appendingPathComponent("chosen", isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let target = chosen.appendingPathComponent("renamed-by-panel.bin")
        panels.reply = [target]
        controller.askWhereToSave = true
        defer { controller.askWhereToSave = false }
        try check(runtime.asksWhereToSaveDownloads, "Ask where to save did not reach the policy")
        func row(_ name: String) -> DownloadRecord? { controller.records.first { $0.url.hasSuffix("/\(name)") } }

        try check(engine.navigateNow(URL(string: "\(base)/download/rearc-asked.bin")!) == .rearcOK, "asked download rejected")
        try await wait("save panel request", timeout: 20) { panels.requests.count == 1 }
        let request = panels.requests[0]
        try check(request.mode == .save && request.defaultPath.hasSuffix("rearc-asked.bin"), "save request \(request.mode) '\(request.defaultPath)'")
        try await wait("asked download complete", timeout: 20) { row("rearc-asked.bin")?.state == .complete }
        let saved = try XUnwrap(row("rearc-asked.bin"))
        let size = (try? FileManager.default.attributesOfItem(atPath: target.path))?[.size] as? Int ?? -1
        try check(saved.targetPath == target.path && size == LoopbackFixtureServer.smallDownloadSize,
                  "saved to '\(saved.targetPath)' (\(size) bytes), chose '\(target.path)'")
        controller.perform(.remove, on: saved.id)
        try await wait("asked row removed") { row("rearc-asked.bin") == nil }

        // Cancel in the panel cancels the download.
        panels.reply = nil
        try check(engine.navigateNow(URL(string: "\(base)/download/rearc-declined.bin")!) == .rearcOK, "declined download rejected")
        try await wait("second save panel request", timeout: 20) { panels.requests.count == 2 }
        try await wait("declined download cancelled", timeout: 20) {
            guard let record = row("rearc-declined.bin") else { return false }
            return record.state == .cancelled
        }
        if let declined = row("rearc-declined.bin") {
            controller.perform(.remove, on: declined.id)
            try await wait("declined row removed") { row("rearc-declined.bin") == nil }
        }
        try await wait("tab still on page A after the asked downloads", timeout: 5) { engine.currentURL?.path == "/a" }
        return "Ask where to save: save request '\((request.defaultPath as NSString).lastPathComponent)' saved to the chosen "
            + "\(target.lastPathComponent) (\(size) B), panel cancel -> download cancelled"
    }

    // MARK: Page context menu (ABI 1.21)

    @MainActor
    private func contextMenuChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let prompts = engine.pagePrompts
        let menus = SelfTestMenus()
        prompts.contextMenus = menus
        defer { prompts.contextMenus = NSMenuContextMenuPresenter() }
        let unknown = runtime.contextCommand(UInt64.max, .dismiss)
        try check(unknown == ReArcStatus(REARC_NOT_FOUND), "a command for an unknown menu returned \(unknown.rearcName)")
        engine.load(URL(string: "\(base)/dialogs")!)
        try await wait("context menu fixture") { engine.pageTitle == "dialogs" && !engine.isLoading }
        let link = try await cssCenter(of: "#link", in: engine)
        let repliesBefore = runtime.promptReplies["context"] ?? 0
        var delivered = false
        for attempt in 0..<3 where !delivered {
            focus(window)
            // A fresh page can drop its first input; the last try is a control-click.
            click(window, engine: engine, at: link, right: attempt < 2, control: attempt == 2)
            delivered = await eventually(timeout: 1.5) { !menus.plans.isEmpty }
        }
        guard delivered else {
            log("NOTE context menu: the synthesized right-click produced no menu request (app active \(NSApp.isActive), "
                + "key \(window.isKeyWindow)); the menu is not exercised in this run; unknown request -> \(unknown.rearcName)")
            return
        }
        let linkPlan = menus.plans[0]
        // Split needs a sidebar tab; this engine is not one.
        try check(linkPlan.items.prefix(2) == [.openLinkInNewTab, .openLinkInNewWindow] && linkPlan.items.contains(.openLinkInLittleArc)
                  && linkPlan.items.contains(.copyLink) && linkPlan.items.contains(.openLinkInNewSplit) == (prompts.ownerTabID != nil)
                  && linkPlan.items.contains(.saveLinkAs) == ReArcEngineHasFeature("context_menu_save_link"),
                  "link menu \(linkPlan.items.map(\.title))")
        try check(linkPlan.entry(.inspect)?.isEnabled == runtime.capabilities.canInspect,
                  "Inspect enabled=\(String(describing: linkPlan.entry(.inspect)?.isEnabled)) with devtools=\(runtime.capabilities.devTools)")
        try await wait("dismissed link menu") { engine.contextMenuRequestID == nil && (runtime.promptReplies["context"] ?? 0) > repliesBefore }
        // A retried click can land late as a second menu; let it finish first.
        try await Task.sleep(nanoseconds: 400_000_000)

        // Copy Link Address on a link with trackers: the shell copies it, clean, to a private
        // pasteboard and dismisses the engine's request (whose own copy would be the link as it is).
        if let model = prompts.router as? BrowserViewModel, model.copiesCleanLinks {
            let realPasteboard = model.linkPasteboard
            model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-selftest-link-\(UUID().uuidString)"))
            defer { model.linkPasteboard = realPasteboard }
            _ = try await engine.evaluate("(document.getElementById('link').href = '/a?utm_source=news&id=7&fbclid=x#top', true)", in: .page)
            menus.choice = .copyLink
            let trackedBase = menus.plans.count
            try await rightClickUntil(window, engine: engine, at: link, "tracked link menu") { menus.plans.count > trackedBase }
            let clean = "\(base)/a?id=7#top"
            try await wait("Copy Link Address copied the clean link") { model.linkPasteboard.string(forType: .string) == clean }
            try await wait("the clean copy dismissed the engine's menu") { engine.contextMenuRequestID == nil }
            menus.choice = nil
            _ = try await engine.evaluate("(document.getElementById('link').href = '/a', true)", in: .page)
            // A retried click can land late as a second menu; let it finish before the pasteboard goes back.
            try await Task.sleep(nanoseconds: 400_000_000)
            log("PASS Copy Link Address: a link with trackers is copied without them (\(clean)), by the shell")
        } else {
            log("NOTE Copy Link Address: this page's menu has no browser model (or clean links are off); the clean copy is not exercised")
        }

        // Page menu: Reload runs in the engine.
        _ = try await engine.evaluate("(window.rearcMarker = 1, true)", in: .page)
        menus.choice = .reload
        let plain = try await cssCenter(of: "#plain", in: engine)
        let pageBase = menus.plans.count
        try await rightClickUntil(window, engine: engine, at: plain, "page menu") { menus.plans.count > pageBase }
        let pagePlan = menus.plans[pageBase]
        try check(pagePlan.items.contains(.reload) && pagePlan.items.contains(.back) && !pagePlan.items.contains(.copyLink),
                  "page menu \(pagePlan.items.map(\.title))")
        try await waitAsync("reload from the page menu") {
            guard !engine.isLoading else { return false }
            let marker = (try? await engine.evaluate("typeof window.rearcMarker", in: .page)) as? String
            return marker == "undefined"
        }

        // The engine command Inspect stays refused (unsupported) and the request is dismissed instead;
        // with `devtools` the menu's Inspect is the shell's own (wave 28 DevTools step).
        try await Task.sleep(nanoseconds: 400_000_000)
        menus.hold = true
        let heldBase = menus.plans.count
        try await rightClickUntil(window, engine: engine, at: plain, "held menu") {
            menus.plans.count > heldBase && engine.contextMenuRequestID != nil
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let held = try XUnwrap(engine.contextMenuRequestID)
        let inspect = engine.finishContextMenu(held, item: .inspect)
        let expected = ReArcStatus(REARC_UNSUPPORTED)
        try check(inspect == expected, "Inspect returned \(inspect.rearcName)")
        let again = runtime.contextCommand(held, .dismiss)
        try check(again == ReArcStatus(REARC_NOT_FOUND), "the dismissed menu still accepted a command (\(again.rearcName))")
        log("PASS page context menu (ABI 1.21): link menu \(linkPlan.items.map(\.title)) dismissed; page menu Reload ran in the engine; "
            + "Inspect -> \(inspect.rearcName) then dismissed (repeat -> \(again.rearcName)); unknown request -> \(unknown.rearcName)")
        try await saveLinkedImageChecks(engine: engine, base: base, window: window, menus: menus)
    }

    /// tenor's page (2026-11-13): Save Image As on a GIF from another origin
    /// inside a link. The engine's SaveFrameWithHeaders asks for the path
    /// through the file chooser channel (a fake panel answers with a temp
    /// path) and the GIF's bytes land there.
    @MainActor
    private func saveLinkedImageChecks(engine: ChromiumEngine, base: String, window: NSWindow, menus: SelfTestMenus) async throws {
        let prompts = engine.pagePrompts
        let panels = SelfTestFilePanels()
        prompts.filePanels = panels
        defer { prompts.filePanels = SystemFilePanelPresenter() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-save-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("saved-tenor.gif")
        panels.reply = [target]

        engine.load(URL(string: "\(base)/linked-image")!)
        try await wait("linked image fixture") { engine.pageTitle == "linked-image" && !engine.isLoading }
        let loaded = "(function(){ var g = document.getElementById('gif'); return g.complete && g.naturalWidth > 0 ? g.src : ''; })()"
        var source = ""
        try await waitAsync("the linked GIF loaded") {
            source = (try? await engine.evaluate(loaded, in: .page)) as? String ?? ""
            return !source.isEmpty
        }
        menus.hold = false
        menus.choice = .saveImage
        let gif = try await cssCenter(of: "#gif", in: engine)
        let before = menus.plans.count
        try await rightClickUntil(window, engine: engine, at: gif, "linked image menu") { menus.plans.count > before }
        let plan = menus.plans[before]
        try check(plan.items.first == .openLinkInNewTab && plan.entry(.saveImage)?.isEnabled == true && plan.items.contains(.copyImageAddress),
                  "linked image menu \(plan.items.map(\.title))")
        try await wait("Save Image As asked for a path", timeout: 20) { !panels.requests.isEmpty }
        let request = panels.requests[0]
        try check(request.mode == .save && (request.defaultPath as NSString).lastPathComponent == "tenor.gif",
                  "save request \(request.mode) '\(request.defaultPath)'")
        try await wait("the GIF saved at the chosen path", timeout: 20) {
            (try? Data(contentsOf: target)) == LoopbackFixtureServer.linkedGIF
        }
        menus.choice = nil
        log("PASS Save Image As (linked GIF from \(URL(string: source)?.host() ?? "?")): menu \(plan.items.map(\.title)); save request "
            + "'\((request.defaultPath as NSString).lastPathComponent)' answered with \(target.lastPathComponent); "
            + "\(LoopbackFixtureServer.linkedGIF.count) B, the GIF's bytes")
    }

    // MARK: Password offers (ABI 1.22)

    /// Clicks the field until the page reports it focused, types `text`, and
    /// waits until the field holds exactly that (retyping after a lost key).
    @MainActor
    private func typeIntoField(_ id: String, _ text: String, engine: ChromiumEngine, window: NSWindow) async -> Bool {
        func read(_ script: String) async -> String? { (try? await engine.evaluate(script, in: .page)) as? String }
        func until(_ timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if await condition() { return true }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return false
        }
        let focusedScript = "String(document.activeElement && document.activeElement.id)"
        let valueScript = "String(document.getElementById('\(id)').value)"
        // Without an active app and key window the clicks cannot arrive; one try, then the NOTE.
        let attempts = inputDeliverable(window) ? 4 : 1
        for attempt in 0..<attempts {
            focus(window)
            guard let center = try? await cssCenter(of: "#\(id)", in: engine) else { return false }
            click(window, engine: engine, at: center)
            guard await until(1.5, { await read(focusedScript) == id }) else {
                log("password offer: click \(attempt + 1) did not focus #\(id); retrying")
                continue
            }
            if attempt > 0, await read(valueScript) != "" {
                // A partial value from a lost key: select it so typing replaces it.
                _ = try? await engine.evaluate("(document.getElementById('\(id)').select(), true)", in: .page)
            }
            type(text, in: window)
            if await until(2, { await read(valueScript) == text }) { return true }
            log("password offer: #\(id) holds '\(await read(valueScript) ?? "?")' after typing; retrying")
        }
        return false
    }

    @MainActor
    private func passwordChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        let prompts = engine.pagePrompts
        let unknown = runtime.respondPassword(UInt64.max, .notNow)
        try check(unknown == ReArcStatus(REARC_NOT_FOUND), "a reply to an unknown offer returned \(unknown.rearcName)")
        engine.load(URL(string: "\(base)/login")!)
        try await wait("login fixture") { engine.pageTitle == "login" && !engine.isLoading }
        // Chromium detects submissions from trusted typing only (script-set values do not count).
        // Input reaches the renderer asynchronously and a fresh page can drop its first click, so
        // each field is typed only once the page reports it focused, and checked before submitting.
        let password = "s3cret-pass-\(Int.random(in: 1000...9999))"
        let userTyped = await typeIntoField("user", "rearc-user", engine: engine, window: window)
        let passTyped = await typeIntoField("pass", password, engine: engine, window: window)
        if userTyped, passTyped {
            click(window, engine: engine, at: try await cssCenter(of: "#go", in: engine))
        }
        guard userTyped, passTyped, await eventually(timeout: 10, { prompts.password != nil }) else {
            let typed = (try? await engine.evaluate("document.getElementById('user') ? document.getElementById('user').value : '(left)'", in: .page)) as? String
            log("NOTE password offer: no save offer after synthesized typing (fields verified: user \(userTyped), pass \(passTyped); "
                + "app active \(NSApp.isActive), key \(window.isKeyWindow), "
                + "username field '\(typed ?? "?")', page '\(engine.pageTitle ?? "")'); offers need trusted input, so the prompt is "
                + "not exercised in this run; unknown offer -> \(unknown.rearcName)")
            return
        }
        let offer = prompts.password!.prompt
        try check(offer.username == "rearc-user" && !offer.isUpdate && offer.origin.hasPrefix("http://127.0.0.1"), "offer \(offer)")
        prompts.answerPassword(.notNow)
        let late = runtime.respondPassword(offer.id, .save)
        try check(late == ReArcStatus(REARC_NOT_FOUND), "a second reply to the offer returned \(late.rearcName)")
        log("PASS password offer (ABI 1.22): '\(offer.title)' for \(offer.username) -> Not Now (dismiss; nothing stored), "
            + "second reply -> \(late.rearcName); unknown offer -> \(unknown.rearcName)")
    }
}

// MARK: - Wave 25: iCloud sync gate

extension ChromiumSelfTest {
    /// The running bundle's signature decides sync. Unentitled (ad-hoc or
    /// Apple Development without REARC_ICLOUD_CONTAINER) it must be the inert
    /// engine and say so; entitled, the container must be the one configured.
    @MainActor
    fileprivate func syncGateChecks() throws {
        switch CloudKitSyncAvailability.current {
        case .unavailable(let reason):
            let engine = CloudKitSyncAvailability.makeEngine(stateFileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("rearc-selftest-sync-\(UUID().uuidString).json"))
            try check(engine is UnavailableSyncEngine, "an unentitled bundle built a live sync engine")
            try check(reason.hasPrefix(CloudKitSyncAvailability.unavailableMessage), "unexpected sync gate reason: \(reason)")
            log("PASS iCloud sync gated off in this bundle: \(reason)")
        case .available(let container):
            let configured = Bundle.main.object(forInfoDictionaryKey: CloudKitSyncAvailability.infoPlistKey) as? String
            try check(configured == container, "entitled container \(container) is not the configured \(configured ?? "none")")
            log("PASS iCloud sync available for \(container) (not exercised against iCloud by the self-test)")
        }
    }
}

// MARK: - Wave 24: printing, drops into pages, Picture in Picture (ABI 1.28–1.30)

/// Records print operations instead of opening the print panel; `finish` ends them.
private final class SelfTestPrintRunner: PrintOperationRunning {
    var operations: [NSPrintOperation] = []
    var windows: [NSWindow?] = []
    private var completions: [(Bool) -> Void] = []

    func run(_ operation: NSPrintOperation, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        operations.append(operation)
        windows.append(window)
        completions.append(completion)
    }

    func finishAll() {
        let pending = completions
        completions = []
        pending.forEach { $0(false) }
    }
}

/// Answers Export as PDF… with a fixed file instead of a save panel.
private struct SelfTestPDFDestination: PDFDestinationChoosing {
    let url: URL

    func chooseDestination(suggestedName: String, in window: NSWindow?, completion: @escaping (URL?) -> Void) {
        DispatchQueue.main.async { completion(url) }
    }
}

/// A synthetic NSDraggingInfo over a private pasteboard, for Chromium's real
/// NSDraggingDestination (WebContentsViewCocoa), as engine/tests/c_abi_drops_host.mm
/// does. It never touches the general or the drag pasteboard.
private final class SelfTestDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingLocation: NSPoint
    private weak var window: NSWindow?
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(pasteboard: NSPasteboard, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingLocation = location
        self.window = window
    }

    var draggingDestinationWindow: NSWindow? { window }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .link, .generic] }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 24 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}

extension ChromiumSelfTest {
    /// Brings ReArc to the front for input-driven steps: activation, then one
    /// retry. A run from a terminal often cannot take focus (cooperative
    /// activation, a locked screen); the caller then logs a NOTE.
    @MainActor
    private func bringToFront(_ window: NSWindow, for label: String) async -> Bool {
        if inputDeliverable(window) { return true }
        for attempt in 1 ... 2 {
            NSApp.unhide(nil)
            if #available(macOS 14.0, *) { NSApp.activate() }
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            if await eventually(timeout: attempt == 1 ? 2 : 4, { self.inputDeliverable(window) }) {
                log("front: ReArc active with the \(label) window key (attempt \(attempt))")
                return true
            }
        }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = (session?["CGSSessionScreenIsLocked"] as? Bool) ?? false
        log("NOTE front: ReArc could not become the active app for \(label) after a retry (active \(NSApp.isActive), "
            + "key \(window.isKeyWindow), screen locked \(locked), frontmost "
            + "'\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-")')")
        return false
    }

    // MARK: Printing (ABI 1.28)

    /// PDF bytes and pages, page ranges, the page's window.print() through the
    /// shell's printer (recorded, no real panel), one job per page, Cmd+P and Export as PDF.
    @MainActor
    private func printingChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        engine.load(URL(string: "\(base)/print")!)
        try await wait("print fixture", timeout: 15) { engine.pageTitle == "print-ready" && !engine.isLoading }
        let (status, pdf) = await engine.printToPDF(paper: .letter)
        let data = pdf ?? Data()
        let pages = PDFDocument(data: data)?.pageCount ?? 0
        try check(status == .rearcOK && PDFSignature.isPDF(data) && pages == 3,
                  "print to PDF: \(status.rearcName), \(data.count) bytes, %PDF \(PDFSignature.isPDF(data)), \(pages) page(s)")
        let (rangeStatus, rangePDF) = await engine.printToPDF(paper: PrintPaperSetup(widthInches: 8.27, heightInches: 11.69, landscape: true), pageRanges: "2")
        let rangePages = rangePDF.flatMap { PDFDocument(data: $0) }
        let landscape = rangePages?.page(at: 0).map { $0.bounds(for: .mediaBox).width > $0.bounds(for: .mediaBox).height } ?? false
        try check(rangeStatus == .rearcOK && rangePages?.pageCount == 1 && landscape,
                  "page range 2 (A4 landscape): \(rangeStatus.rearcName), \(rangePages?.pageCount ?? 0) page(s), landscape \(landscape)")
        let (badStatus, badPDF) = await engine.printToPDF(paper: nil, pageRanges: "9")
        try check(badStatus == ReArcStatus(REARC_INVALID_ARGUMENT) && badPDF == nil, "out-of-range pages: \(badStatus.rearcName)")

        let printer = PagePrinter.shared
        let recorder = SelfTestPrintRunner()
        let savedRunner = printer.runner, savedChooser = printer.destinationChooser
        var errors: [Error] = []
        printer.runner = recorder
        printer.onError = { errors.append($0) }
        defer {
            recorder.finishAll()
            printer.runner = savedRunner
            printer.destinationChooser = savedChooser
            printer.onError = nil
        }
        // window.print(): the page's request completes at once (beforeprint, afterprint), the shell prints the PDF.
        let requestsBefore = engine.printRequestCount
        _ = try await engine.evaluate("(window.print(), true)", in: .page)
        try await wait("print request and recorded print operation", timeout: 15) {
            engine.printRequestCount == requestsBefore + 1 && recorder.operations.count == 1 || !errors.isEmpty
        }
        try check(errors.isEmpty, "print failed: \(errors)")
        try await wait("beforeprint+afterprint", timeout: 5) { engine.pageTitle == "beforeprint+afterprint" }
        let operation = recorder.operations[0]
        try check(recorder.windows[0] === window && operation.printInfo.topMargin == 0,
                  "print operation: sheet window \(String(describing: recorder.windows[0])), top margin \(operation.printInfo.topMargin)")
        // While its panel is open, another print of the same page is dropped (Cmd+P included).
        let dropped = printer.droppedRequests
        printer.print(engine)
        try check(printer.droppedRequests == dropped + 1 && recorder.operations.count == 1, "a second print while the panel is open was not dropped")
        recorder.finishAll()
        printer.print(engine)
        try await wait("Cmd+P print operation", timeout: 15) { recorder.operations.count == 2 || !errors.isEmpty }
        try check(errors.isEmpty, "Cmd+P failed: \(errors)")
        recorder.finishAll()

        // Export as PDF… to a temporary file (the save panel is answered with it).
        let exportURL = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-export-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: exportURL) }
        printer.destinationChooser = SelfTestPDFDestination(url: exportURL)
        var exported: Result<URL, Error>?
        printer.exportPDF(engine) { exported = $0 }
        try await wait("Export as PDF", timeout: 15) { exported != nil }
        let file = (try? Data(contentsOf: exportURL)) ?? Data()
        let filePages = PDFDocument(url: exportURL)?.pageCount ?? 0
        try check(PDFSignature.isPDF(file) && filePages >= 1, "exported PDF: \(String(describing: exported)), \(file.count) bytes, \(filePages) page(s)")
        try check(runtime.livePrintContexts == 0, "\(runtime.livePrintContexts) print-to-PDF context(s) never released")
        log("PASS printing (ABI 1.28): ReArcTabPrintToPDF -> %PDF \(data.count) bytes, \(pages) pages; page range 2 on A4 "
            + "landscape -> 1 landscape page; range 9 -> invalid_argument; window.print() -> print request (source 0), "
            + "'beforeprint+afterprint', print operation from the PDF as a sheet on the tab's window (recorded, no panel); "
            + "a second print while it is open dropped; Cmd+P -> print operation; Export as PDF -> \(file.count)-byte PDF, "
            + "\(filePages) page(s); contexts released")
    }

    // MARK: Drops into pages (ABI 1.29)

    private static func findView(named className: String, in view: NSView) -> NSView? {
        if NSStringFromClass(Swift.type(of: view)) == className { return view }
        for subview in view.subviews {
            if let found = findView(named: className, in: subview) { return found }
        }
        return nil
    }

    /// Enter, two updates, drop; then the page's event log.
    @MainActor
    private func drag(_ pasteboard: NSPasteboard, onto destination: NSView, host: NSView, window: NSWindow,
                      engine: ChromiumEngine) async throws -> (enter: NSDragOperation, performed: Bool, log: String) {
        let location = host.convert(NSPoint(x: host.bounds.midX, y: host.bounds.midY), to: nil)
        let info = SelfTestDrag(pasteboard: pasteboard, location: location, window: window)
        let enter = destination.draggingEntered(info)
        for _ in 0 ..< 2 {
            try await Task.sleep(nanoseconds: 300_000_000)
            _ = destination.draggingUpdated(info)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let performed = destination.performDragOperation(info)
        try await Task.sleep(nanoseconds: 800_000_000)
        let log = try await engine.evaluate("log.splice(0).join('\\n')", in: .page) as? String ?? "?"
        return (enter, performed, log)
    }

    private func pasteboard(_ write: (NSPasteboard) -> Void) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("com.rearc.selftest.drag.\(UUID().uuidString)"))
        board.clearContents()
        write(board)
        return board
    }

    /// Text and a file reach the page's drop handler; a sidebar drag (the
    /// shell's private type) never reaches it at all.
    @MainActor
    private func pageDropChecks(engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        try check(runtime.dropPolicy == .shell, "drop policy at ready: \(String(describing: runtime.dropPolicy))")
        let provider = SidebarDragPayload.itemProvider(for: UUID())
        try check(provider.registeredTypeIdentifiers.contains(SidebarDragType.identifier),
                  "sidebar drags do not carry \(SidebarDragType.identifier): \(provider.registeredTypeIdentifiers)")
        engine.load(URL(string: "\(base)/drop")!)
        try await wait("drop fixture", timeout: 15) { engine.pageTitle == "drop-ready" && !engine.isLoading && engine.attachmentID != nil }
        guard let host = engine.leaseHolder, let destination = Self.findView(named: "WebContentsViewCocoa", in: host) else {
            throw Failure(description: "no WebContentsViewCocoa under the tab's host view")
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let text = try await drag(pasteboard { $0.setString("rearc dropped text", forType: .string) },
                                  onto: destination, host: host, window: window, engine: engine)
        try check(text.enter != [] && text.performed && text.log.contains("drop|text=rearc dropped text"),
                  "text drop: enter \(text.enter.rawValue) performed \(text.performed) log '\(text.log)'")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("rearc-drop.txt")
        try Data("dropped file".utf8).write(to: fileURL)
        let file = try await drag(pasteboard { _ = $0.writeObjects([fileURL as NSURL]) },
                                  onto: destination, host: host, window: window, engine: engine)
        try check(file.enter != [] && file.log.contains("files=rearc-drop.txt:12") && file.log.contains("content=dropped file"),
                  "file drop: enter \(file.enter.rawValue) performed \(file.performed) log '\(file.log)'")

        let id = UUID().uuidString
        let sidebar = try await drag(pasteboard {
            $0.declareTypes([SidebarDragPayload.pasteboardType, .string], owner: nil)
            $0.setData(Data(id.utf8), forType: SidebarDragPayload.pasteboardType)
            $0.setString(id, forType: .string)
        }, onto: destination, host: host, window: window, engine: engine)
        try check(sidebar.enter == [] && !sidebar.performed && sidebar.log.isEmpty,
                  "sidebar drag reached the page: enter \(sidebar.enter.rawValue) performed \(sidebar.performed) log '\(sidebar.log)'")
        try check(engine.currentURL?.path == "/drop", "a drop navigated the tab to \(engine.currentURL?.absoluteString ?? "nil")")
        log("PASS drops into pages (ABI 1.29): policy files+text+urls+images, blocked \(SidebarDragType.identifier); "
            + "through WebContentsViewCocoa: text -> page drop handler; a Finder file -> File 'rearc-drop.txt' (12 bytes, "
            + "contents read); a sidebar drag (private type + UUID text) -> no operation and no page event; tab stayed on /drop")
    }

    // MARK: Picture in Picture (ABI 1.30)

    private func pictureInPictureOverlay() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && NSStringFromClass(Swift.type(of: $0)).hasPrefix("NativeWidgetMac") }
    }

    /// Chromium's overlay hides its controls until the pointer is over it;
    /// back to tab is 24 px, 28 px from the right, 5 px from the top (c_abi_pip_host.mm).
    @MainActor
    private func clickBackToTab(in overlay: NSWindow) async {
        guard let content = overlay.contentView else { return }
        let center = NSPoint(x: content.bounds.midX, y: content.bounds.midY)
        let now = ProcessInfo.processInfo.systemUptime
        if let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: center, modifierFlags: [], timestamp: now,
                                                windowNumber: overlay.windowNumber, context: nil, eventNumber: 0,
                                                trackingNumber: 0, userData: nil) {
            content.mouseEntered(with: entered)
        }
        if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: center, modifierFlags: [], timestamp: now,
                                          windowNumber: overlay.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            content.mouseMoved(with: moved)
        }
        try? await Task.sleep(nanoseconds: 700_000_000)
        let button = NSPoint(x: content.bounds.width - 40, y: content.bounds.height - 17)
        for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: button, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overlay.windowNumber,
                                                 context: nil, eventNumber: 1, clickCount: type == .mouseMoved ? 0 : 1,
                                                 pressure: type == .leftMouseDown ? 1 : 0) else { continue }
            switch type {
            case .mouseMoved: content.mouseMoved(with: event)
            case .leftMouseDown: content.mouseDown(with: event)
            default: content.mouseUp(with: event)
            }
        }
    }

    /// The command enters and leaves PiP (sidebar badge, the page's PiP
    /// events), switching away from the playing tab enters it automatically and
    /// coming back leaves it, and the overlay's back-to-tab shows the tab.
    @MainActor
    private func pictureInPictureChecks(model: BrowserViewModel, tab: Tab, engine: ChromiumEngine, other: Tab) async throws {
        // Off until step 2: the locked test session counts as fully occluded, and
        // the occlusion trigger would put the video in PiP as soon as it plays.
        let automatic = model.automaticPictureInPicture
        model.automaticPictureInPicture = false
        defer { model.automaticPictureInPicture = automatic }
        model.selectTab(tab.id)
        engine.load(URL(string: "\(serverBase)/pip")!)
        try await wait("PiP fixture playing", timeout: 25) {
            engine.pageTitle == "pip-playing" || engine.pageTitle?.hasPrefix("pip-err") == true
        }
        try check(engine.pageTitle == "pip-playing", "PiP fixture: '\(engine.pageTitle ?? "")'")
        try await wait("pip_available media event", timeout: 15) { model.mediaState(for: tab.id).canPictureInPicture }
        try check(model.store.selectedTabID == tab.id, "the PiP tab is not selected")

        // 1. The command (menu item, command bar) enters PiP; the sidebar row shows the badge.
        let eventsBefore = runtime.pictureInPictureEvents.count
        model.togglePictureInPicture()
        try await wait("PiP entered through the command", timeout: 10) {
            model.isPictureInPicture(tab.id) && engine.isPictureInPicture && engine.pageTitle == "pip-in"
        }
        // Wave 32 (pip_embedded): the video renders into ReArc's view, not Chromium's window.
        let embedded = runtime.capabilities.pipEmbedded
        let overlayName: String
        if embedded {
            try await wait("embedded PiP overlay shown", timeout: 10) { engine.videoOverlay != nil }
            try check(pictureInPictureOverlay() == nil, "Chromium's PiP window opened although the shell hosts the video")
            overlayName = NSStringFromClass(Swift.type(of: engine.videoOverlay!.view))
        } else {
            let overlay = pictureInPictureOverlay()
            try check(overlay != nil, "no Chromium PiP overlay window")
            overlayName = NSStringFromClass(Swift.type(of: overlay!))
        }
        model.togglePictureInPicture()
        try await wait("PiP left through the command", timeout: 10) {
            !model.isPictureInPicture(tab.id) && !engine.isPictureInPicture && engine.pageTitle == "pip-out"
        }

        // 2. Automatic PiP: switching to another tab puts the playing video in PiP; coming back ends it.
        model.automaticPictureInPicture = true
        model.selectTab(other.id)
        try await wait("automatic PiP on switching away", timeout: 10) {
            model.isPictureInPicture(tab.id) && model.autoPiPEnteredTabIDs.contains(tab.id) && engine.pageTitle == "pip-in"
        }
        model.selectTab(tab.id)
        try await wait("automatic PiP ends when the tab is shown again", timeout: 10) {
            !model.isPictureInPicture(tab.id) && !model.autoPiPEnteredTabIDs.contains(tab.id) && engine.pageTitle == "pip-out"
        }
        var paths = ["command in and out", "automatic on switching away, back on return"]

        // 3. Back to tab (phase 2) from the overlay's button shows the tab again.
        model.selectTab(other.id)
        try await wait("automatic PiP for back-to-tab", timeout: 10) { model.isPictureInPicture(tab.id) }
        if embedded, let video = engine.videoOverlay {
            // The live player's back-to-tab is the engine action, so no synthesized input is needed.
            video.perform(.backToTab)
            try await wait("embedded back to tab: phase 2 and the tab shown", timeout: 10) {
                runtime.pictureInPictureEvents.contains { $0.tabID == engine.tabID && $0.phase == .backToTab }
                    && model.store.selectedTabID == tab.id && !model.isPictureInPicture(tab.id)
            }
            paths.append("back to tab (embedded overlay action) selects the tab")
        } else if let overlay = pictureInPictureOverlay() {
            await clickBackToTab(in: overlay)
            if await eventually(timeout: 4, { runtime.pictureInPictureEvents.contains { $0.tabID == engine.tabID && $0.phase == .backToTab } }) {
                try await wait("back to tab shows the tab", timeout: 10) {
                    model.store.selectedTabID == tab.id && !model.isPictureInPicture(tab.id)
                }
                paths.append("back to tab (overlay button) selects the tab")
            } else {
                log("NOTE PiP back to tab: the synthesized click on the overlay produced no back-to-tab event; leaving through the command")
            }
        }
        if model.isPictureInPicture(tab.id) { model.setPictureInPicture(false, tabID: tab.id) }
        try await wait("PiP closed", timeout: 10) { !model.isPictureInPicture(tab.id) }
        model.selectTab(tab.id)
        let phases = runtime.pictureInPictureEvents.dropFirst(eventsBefore).filter { $0.tabID == engine.tabID }.map { "\($0.phase)" }
        loadShellTab(model, tab, engine, URL(string: "\(serverBase)/a")!)
        try await wait("tab A back on /a after PiP", timeout: 15) { engine.pageTitle == Self.titleA && !engine.isLoading }
        log("PASS Picture in Picture (ABI 1.30): MediaRecorder WebM with audio -> pip_available; \(paths.joined(separator: "; ")); "
            + "sidebar badge followed pip_active; overlay \(overlayName); events \(phases.joined(separator: ","))")
    }

    /// Prerender activation (security AA-01, RC-811 AD-02): the engine runs
    /// with LazyBrowserInterfaceBroker off, which changes how an activated
    /// prerender gets its interface broker. A page prerenders a second one by
    /// speculation rule, a link click goes there, and the tab must show it
    /// with the renderer up. An embedding that never prerenders logs a gap.
    @MainActor
    private func prerenderChecks(model: BrowserViewModel, store: SidebarStore) async throws {
        try await withFixtureTab(model, store, title: "Prerender", path: "/prerender-from") { _, engine in
            try await wait("prerender source page loaded", timeout: 15) { engine.pageTitle == "prerender-from" && !engine.isLoading }
            // Time for the speculation rule to start and finish the prerender.
            try await Task.sleep(for: .seconds(2))
            _ = try await engine.evaluate("document.getElementById('go').click(), true", in: .page)
            try await wait("prerender target shown", timeout: 15) {
                engine.pageTitle == "prerender-activated" || engine.pageTitle == "prerender-loaded-normally"
            }
            try check(engine.currentURL?.path == "/prerender-to", "after the click the tab shows \(engine.currentURL?.absoluteString ?? "nil")")
            try await checkRendererAlive(engine, after: "the prerender navigation")
            if engine.pageTitle == "prerender-activated" {
                log("PASS prerender: a speculation rule prerendered /prerender-to and the link click activated it; renderer alive")
            } else {
                log("ABI-GAP prerender: not prerendered (ReArcTabDelegate keeps IsPrerender2Supported's default, unsupported); the target loaded normally, renderer fine")
            }
        }
    }

    // MARK: Reader view

    /// The reader view on the engine (docs/FEATURE-SPECS/READER-VIEW.md §10), on the
    /// reader fixture's pages (`SelfTestReaderFixture`), each through the model's own commands:
    ///
    /// - On the article the address field's button shows, and View > Show Reader is on.
    /// - The reader opens with the article's title, byline, site, text and its picture.
    ///   Readability ran in the reader's isolated world: the page's own world has no trace of it.
    /// - Leaving the reader shows the page as it was left, with no history entry added.
    /// - A link from the reader loads in the tab; an address that is not a web address does nothing.
    /// - On a page that is no article there is no button.
    /// - The hostile article (script in its body, on-attributes, javascript: links, SVG,
    ///   frames): its payloads are live in the page itself, which is the control, and from
    ///   the reader not one beacon reaches the fixture server.
    @MainActor
    private func readerViewChecks(model: BrowserViewModel, store: SidebarStore) async throws {
        typealias Fixture = SelfTestReaderFixture
        guard runtime.capabilities.scriptEvaluation else {
            log("ABI-GAP script_evaluation not advertised: the reader view has no button and its menu item is off")
            return
        }
        @MainActor func readerText(_ tab: Tab) async throws -> (text: String, names: Set<String>) {
            guard let session = model.reader.session(for: tab.id) else { throw Failure(description: "reader: no reader is open") }
            try await wait("the reader's page") { !session.page.webView.isLoading }
            let json = try await ReaderWebKitEvaluation.evaluate(
                "JSON.stringify({text: document.body.innerText, names: Array.prototype.map.call(document.querySelectorAll('article *'), "
                    + "function (e) { return (e.namespaceURI === 'http://www.w3.org/1999/xhtml' ? '' : 'foreign ') + e.localName; })})",
                in: session.page.webView)
            let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            return (object?["text"] as? String ?? "", Set(object?["names"] as? [String] ?? []))
        }
        let menuItem = ShellMenus.reader(model).flatMap { $0 }.first
        try check(menuItem?.appKitKeyEquivalent.key == "r" && menuItem?.appKitKeyEquivalent.mask == [.command, .option],
                  "reader: the menu item's key is not ⌥⌘R")

        try await withFixtureTab(model, store, title: "Reader", path: Fixture.articlePath) { tab, engine in
            try await wait("the reader fixture's article") { engine.pageTitle?.contains(Fixture.articleTitle) == true && !engine.isLoading }
            try check(model.readerButtonState(for: tab, engine: engine) != .showing, "reader: a reader is open before it was asked for")
            model.detectReaderArticle(for: tab, engine: engine)
            try await wait("the reader button on an article") { model.readerButtonState(for: tab, engine: engine) == .available }
            try check(menuItem?.shownTitle == "Show Reader" && menuItem?.isEnabledNow == true,
                      "reader: View > Show Reader is \(menuItem?.shownTitle ?? "missing"), enabled \(menuItem?.isEnabledNow ?? false)")
            try check(model.readerImageMode(for: tab, engine: engine) == .loadedByPage, "reader: an ordinary tab's reader has pictures off")
            _ = try await engine.evaluate("(function () { window.rearcReaderKept = 'kept'; window.scrollTo(0, 30); return 1; })()", in: .page)
            let before = try await engine.evaluate("document.documentElement.outerHTML.length", in: .page) as? NSNumber

            model.toggleReader(tabID: tab.id)
            try await wait("the reader to open") { model.reader.isShowing(tab.id) }
            guard let article = model.reader.session(for: tab.id)?.article else { throw Failure(description: "reader: no article") }
            try check(article.title == Fixture.articleTitle && article.byline == Fixture.articleByline && article.siteName == Fixture.articleSite,
                      "reader: title [\(article.title)] byline [\(article.byline ?? "none")] site [\(article.siteName)]")
            try check(article.imagesShown == 1 && article.imagesWithheld == 0,
                      "reader: \(article.imagesShown) pictures shown, \(article.imagesWithheld) withheld; the page had loaded its one picture")
            let shown = try await readerText(tab)
            try check(shown.text.contains(Fixture.articleTitle) && shown.text.contains("\(Fixture.articleByline) · \(article.readingMinutes) min read")
                        && shown.text.contains("someone has added the single word"),
                      "reader: the page does not show the article: \(shown.text.prefix(300))")
            try check(shown.names.isSubset(of: Set(ReaderTag.allCases.map(\.rawValue))), "reader: elements outside the allowlist: \(shown.names.sorted())")
            try check(menuItem?.shownTitle == "Hide Reader", "reader: the menu item still says \(menuItem?.shownTitle ?? "nothing") with the reader open")
            try check(model.readerButtonState(for: tab, engine: engine) == .showing, "reader: the button does not show the reader as open")
            let leaked = try await engine.evaluate("typeof Readability + '/' + typeof isProbablyReaderable + '/' + typeof walk", in: .page) as? String
            try check(leaked == "undefined/undefined/undefined", "reader: the scripts left names in the page's own world: \(leaked ?? "?")")
            log("PASS reader: the button shows on an article; the reader opens with its title, byline, site, \(article.readingMinutes) min, "
                + "\(article.wordCount) words and 1 picture; Readability ran in an isolated world (page world: \(leaked ?? "?"))")

            model.toggleReader(tabID: tab.id)
            try check(!model.reader.isShowing(tab.id), "reader: it did not close")
            let kept = try await engine.evaluate("window.rearcReaderKept + '|' + location.pathname", in: .page) as? String
            let after = try await engine.evaluate("document.documentElement.outerHTML.length", in: .page) as? NSNumber
            try check(kept == "kept|\(Fixture.articlePath)" && before == after && !engine.canGoBack,
                      "reader: the page is not as it was left (state \(kept ?? "?"), length \(String(describing: before)) -> \(String(describing: after)), can go back \(engine.canGoBack))")
            log("PASS reader: leaving it shows the page as it was left (its state kept, its document unchanged, no history entry)")

            // Links: only a web address, and only as a page link in the tab.
            model.toggleReader(tabID: tab.id)
            try await wait("the reader to open again") { model.reader.isShowing(tab.id) }
            for refused in ["javascript:document.title='reader-link-ran'", "chrome://settings", "file:///etc/hosts", "data:text/html,x"] {
                model.openReaderLink(URL(string: refused)!, fromTab: tab.id, inNewTab: false)
            }
            try await Task.sleep(nanoseconds: 400_000_000)
            try check(model.reader.isShowing(tab.id) && engine.currentURL?.path == Fixture.articlePath && engine.pageTitle != "reader-link-ran",
                      "reader: an address that is not a web address was followed (\(engine.currentURL?.absoluteString ?? "?"))")
            let plain = URL(string: "\(serverBase)\(Fixture.plainPath)")!
            model.store.updateTab(tab.id, url: plain)
            model.openReaderLink(plain, fromTab: tab.id, inNewTab: false)
            try await wait("the reader's link to load in the tab") { engine.currentURL?.path == Fixture.plainPath && engine.pageTitle == "About" && !engine.isLoading }
            try check(!model.reader.isShowing(tab.id), "reader: it stayed open over another page")
            model.detectReaderArticle(for: tab, engine: engine)
            try await wait("the page that is no article to be judged", timeout: 10) {
                model.reader.availability(for: tab.id, url: engine.currentURL) == .notArticle
            }
            try check(model.readerButtonState(for: tab, engine: engine) == .hidden, "reader: the button shows on a page that is no article")
            log("PASS reader: a link loads in the tab and closes the reader; javascript:, chrome:, file: and data: addresses do nothing; no button on a page that is no article")

            // The hostile article. First the control: in the page itself its payloads run.
            Fixture.resetBeacons()
            loadShellTab(model, tab, engine, URL(string: "\(serverBase)\(Fixture.hostilePath)")!)
            try await wait("the hostile article") { engine.pageTitle == Fixture.hostileTitle && !engine.isLoading }
            try await wait("the hostile page's own beacons (the control)") {
                let counts = Fixture.beaconCounts
                return (counts["body-script"] ?? 0) > 0 && (counts["img-onerror"] ?? 0) > 0 && (counts["body-onload"] ?? 0) > 0
            }
            try await Task.sleep(nanoseconds: 1_500_000_000)
            // The page itself stays alive under the reader, and its autofocus field pings again
            // whenever the page gets the keyboard back: that one id is the page's, so it is left
            // out. (The reader has no field: its elements are checked below.)
            @MainActor func counts() -> [String: Int] { Fixture.beaconCounts.filter { $0.key != "input-autofocus" } }
            let control = counts()
            model.toggleReader(tabID: tab.id)
            try await wait("the reader on the hostile article") { model.reader.isShowing(tab.id) }
            let hostile = try await readerText(tab)
            try check(hostile.text.contains(Fixture.hostileMarker) && hostile.text.contains(Fixture.hostileTitle),
                      "reader: the hostile article's text is not shown: \(hostile.text.prefix(300))")
            try check(hostile.names.isSubset(of: Set(ReaderTag.allCases.map(\.rawValue))) && !hostile.names.contains("a"),
                      "reader: the hostile article brought elements across: \(hostile.names.sorted())")
            if let page = model.reader.session(for: tab.id)?.page {
                _ = try await ReaderWebKitEvaluation.evaluate(
                    "Array.prototype.forEach.call(document.querySelectorAll('article *'), function (e) { if (typeof e.click === 'function') e.click(); }); 'clicked'",
                    in: page.webView)
            }
            try await Task.sleep(nanoseconds: 2_500_000_000)
            let afterReader = counts()
            try check(afterReader == control, "reader: a beacon arrived while the reader showed the hostile article: before \(control), after \(afterReader)")
            log("PASS reader: nothing from the hostile article ran in the reader: \(control.values.reduce(0, +)) beacons from the page itself "
                + "(\(control.keys.sorted().joined(separator: ", "))), none more with the reader open and every element clicked")
            model.closeReader(tabID: tab.id)
        }
    }

    /// Built-in ad and tracker blocking (CONTENT-BLOCKING.md §8 "Self-test",
    /// security CB-02). An engine without `content_blocking` (before ABI
    /// 1.66, patch `tab/095-content-blocker-component`) logs the gap, and
    /// the only check is that nothing of blocking shows.
    ///
    /// With it, the blocking fixture (`SelfTestBlockingFixture`) is loaded in
    /// a tab of its own: a page that asks a tracker's host and an ad server's
    /// host for a script each. Both hosts are in the built-in lists, both
    /// resolve to the fixture server, and the server counts what it is asked
    /// for. The steps, each through the model's own commands:
    ///
    /// - Ads and trackers: neither is fetched, the engine counts 2, and the
    ///   site controls row says "2 blocked on this page".
    /// - Trackers only: the ad loads, the tracker does not, the count is 1.
    /// - A site exception (the row's own command): both load, nothing counted.
    /// - The exception removed: neither is fetched again.
    /// - Off: both load. On again: neither.
    ///
    /// A change of settings reaches the engine's rules a moment after the
    /// call returns, so each step loads the page until it shows the wanted
    /// state and fails when it never does.
    @MainActor
    private func contentBlockingChecks(model: BrowserViewModel, store: SidebarStore) async throws {
        guard model.contentBlocking.isAvailable else {
            log("ABI-GAP content_blocking not advertised (ABI minor \(runtime.capabilities.abiMinorVersion.map(String.init) ?? "absent") < 66): "
                + "Block ads and trackers is hidden in Settings and the site controls, and no install is offered it")
            try check(!model.contentBlocking.showsOffer, "the blocking offer is up without an engine that can block")
            try check(model.contentBlocking.bundle == nil, "a blocklist bundle was loaded without an engine that can block")
            return
        }
        try check(store.contentBlockingRollout.isDecided, "an engine with blocking attached and the install was not counted as new or existing")
        try await wait("the blocklist bundles to be checked") { model.contentBlocking.didLoadLists }
        guard let bundle = model.contentBlocking.bundle else {
            throw Failure(description: "content blocking: the engine can block and no blocklist bundle verified "
                + "(\(model.contentBlockingEvents.suffix(3).joined(separator: "; "))): nothing is blocked")
        }
        let unfit = SelfTestBlockingFixture.problems(in: bundle)
        try check(unfit.isEmpty, "the blocking fixture does not fit the lists (\(unfit.joined(separator: "; "))): "
            + "choose other hosts in SelfTestBlockingFixture")

        try await withFixtureTab(model, store, title: "Blocking", path: "\(SelfTestBlockingFixture.pagePath)?run=0") { tab, engine in
            let profileID = model.profileID(for: tab)
            let saved = store.contentBlocking(for: profileID)
            defer {
                store.setContentBlocking(saved, for: profileID)
                model.contentBlockingSettingsChanged()
            }
            // The tab's first load (run 0) ends before any numbered load starts: its commit
            // arriving after load 1 began put run 0 back in the sidebar, and a selection
            // change then reloaded it over load 1.
            _ = try await blockingFixtureLoad(0, engine)
            @MainActor func settings() -> ContentBlockingSettings { store.contentBlocking(for: profileID) }
            @MainActor func count() -> Int? { model.contentBlocking.blockedCount?(engine) }
            @MainActor func row() throws -> SiteControlCenter.SettingRow {
                guard let site = SiteControlCenter.site(for: engine.currentURL),
                      let row = model.contentBlockingRow(for: engine, site: site) else {
                    throw Failure(description: "the site controls have no blocking row for \(engine.currentURL?.absoluteString ?? "nil")")
                }
                return row
            }
            /// The engine's count for the page reaches `expected` and stays there.
            @MainActor func expectCount(_ expected: Int, _ label: String) async throws {
                try await wait("\(label): the engine's count of blocked requests to be \(expected) (now \(count().map(String.init) ?? "nil"))", timeout: 10) {
                    count() == expected
                }
                try await Task.sleep(for: .milliseconds(400))
                try check(count() == expected, "\(label): the count went on to \(count().map(String.init) ?? "nil"), not \(expected)")
            }

            // 1. Ads and trackers, with no exception and no own rule in the way.
            model.setContentBlockingEnabled(true, for: profileID)
            model.setContentBlockingStrength(.adsAndTrackers, for: profileID)
            for host in settings().exceptions { model.removeContentBlockingException(host, for: profileID) }
            model.setContentBlockingOwnRules("", for: profileID)
            try check(settings().level == .adsAndTrackers && settings().exceptions.isEmpty, "blocking settings before the page checks: \(settings())")
            let revision = model.contentBlocking.blockedCountRevision
            // The first use of a bundle copies and indexes its 18,000 rules.
            let firstLoads = try await waitForBlocking("at Ads and trackers", model, tab, engine, tracker: true, ad: true, timeout: 90)
            try await expectCount(2, "at Ads and trackers")
            try await wait("the engine's count callback to reach the shell", timeout: 5) { model.contentBlocking.blockedCountRevision != revision }
            let onRow = try row()
            try check(onRow.state == "2 blocked on this page" && !onRow.isBlocked, "the site controls row at Ads and trackers: \(onRow)")
            log("PASS content blocking at Ads and trackers (bundle \(bundle.version), \(bundle.source)): the page's requests to "
                + "\(SelfTestBlockingFixture.trackerHost) and \(SelfTestBlockingFixture.adHost) never reached the fixture server "
                + "(load \(firstLoads)); the engine counts 2 and the site controls row says '\(onRow.state)'")

            // 2. Trackers only: EasyList goes off, EasyPrivacy stays.
            model.setContentBlockingStrength(.trackersOnly, for: profileID)
            let trackerLoads = try await waitForBlocking("at Trackers only", model, tab, engine, tracker: true, ad: false)
            try await expectCount(1, "at Trackers only")
            let trackersRow = try row()
            try check(trackersRow.state == "1 blocked on this page", "the site controls row at Trackers only: \(trackersRow)")
            model.setContentBlockingStrength(.adsAndTrackers, for: profileID)
            let backLoads = try await waitForBlocking("back at Ads and trackers", model, tab, engine, tracker: true, ad: true)
            log("PASS content blocking levels: at Trackers only the ad loaded and the tracker did not (load \(trackerLoads)), count 1; "
                + "back at Ads and trackers neither loaded (load \(backLoads))")

            // 3. A site exception, by the site controls' own command, which reloads the tab.
            guard let site = SiteControlCenter.site(for: engine.currentURL) else { throw Failure(description: "the blocking fixture's page has no site") }
            let runBefore = blockingRun
            model.setContentBlocking(false, forSiteOf: engine, site: site)
            try check(settings().exception(covering: engine.currentURL) != nil, "Turn Off for This Site added no exception: \(settings().exceptions)")
            // That reload is of the same page load number: the server sees its requests, if they come.
            let ownReloadLoaded = await eventually(timeout: 5) { LoopbackFixtureServer.blockingFetches(run: runBefore).tracker > 0 }
            let exceptionLoads = try await waitForBlocking("with a site exception", model, tab, engine, tracker: false, ad: false)
            try await expectCount(0, "with a site exception")
            let exceptedRow = try row()
            try check(exceptedRow.state == "Off for this site" && exceptedRow.isBlocked, "the site controls row with an exception: \(exceptedRow)")
            if ownReloadLoaded {
                log("PASS content blocking site exception (\(settings().exceptions.joined(separator: ","))): the tab's own reload already loaded "
                    + "both requests; nothing counted; the row says 'Off for this site'")
            } else {
                log("PASS content blocking site exception (\(settings().exceptions.joined(separator: ","))): both requests load (load "
                    + "\(exceptionLoads) after the change); nothing counted; the row says 'Off for this site'")
                log("NOTE content blocking: the reload that Turn Off for This Site makes itself was still blocked: it ran before the "
                    + "engine had set the exception (dynamic rules are set after the call returns). The person sees the page blocked "
                    + "until they reload again; the engine needs to report the change done before the shell reloads (security CB-06)")
            }

            // 4. The exception removed.
            model.setContentBlocking(true, forSiteOf: engine, site: site)
            try check(settings().exceptions.isEmpty, "Turn On for This Site left \(settings().exceptions)")
            let againLoads = try await waitForBlocking("with the exception removed", model, tab, engine, tracker: true, ad: true)
            try await expectCount(2, "with the exception removed")

            // 5. Off for the profile, and on again.
            model.setContentBlockingEnabled(false, for: profileID)
            let offLoads = try await waitForBlocking("at Off", model, tab, engine, tracker: false, ad: false)
            try await expectCount(0, "at Off")
            let offRow = try row()
            try check(offRow.state == "Off in Settings", "the site controls row at Off: \(offRow)")
            model.setContentBlockingEnabled(true, for: profileID)
            let onLoads = try await waitForBlocking("switched on again", model, tab, engine, tracker: true, ad: true, timeout: 60)
            try await expectCount(2, "switched on again")
            log("PASS content blocking exception removed and Off: without the exception neither request loaded (load \(againLoads)); at Off "
                + "both loaded (load \(offLoads)), nothing counted, the row says 'Off in Settings'; on again neither loaded (load \(onLoads)), count 2")
        }
    }

    /// "Blocked on this page" (CONTENT-BLOCKING.md §3, patch `tab/098`, ABI
    /// 1.69): the list behind the site controls row's count, and what the
    /// security pre-review asks a run to show (security/PRE-blocked-list.md,
    /// BL-09). An engine without `content_blocking_hosts` logs the gap.
    ///
    /// On the blocking fixture (a tracker's host and an ad server's host):
    ///
    /// 1. The list has two lines, the two registrable domains, 1 each,
    ///    tagged Tracker and Ad, and the row offers it.
    /// 2. A navigation inside the document leaves the list as it is.
    /// 3. Allow (the list's own command) writes exactly one own rule, for
    ///    the site the engine names as the page's; the ad's request then
    ///    reaches the fixture server and only the tracker is counted and
    ///    listed. Remove deletes the line, and both are blocked and listed
    ///    again. Asked for a site the tab is not on, Allow writes nothing
    ///    (security BL-10).
    ///
    /// On the list page (`SelfTestBlockingFixture.listPageHTML`):
    ///
    /// 4. A single-label name and a public suffix are listed, the first once
    ///    with 3 and both tags, and neither can be allowed.
    /// 5. More sites than a list holds give a full list and the rest as "more".
    /// 6. A navigation to a page that asks for nothing empties the list.
    /// 7. A private window's tab has a list and no Allow; once it is closed
    ///    the engine has nothing for it.
    /// 8. None of the made-up sites of step 5 is in a file of the engine's
    ///    or the shell's data folders: the list was in memory only. (The
    ///    security review repeats this after ReArc has quit.)
    ///
    /// The cold launch's list update checks the list once more, after
    /// blocking has moved to the second blocker (`contentBlockingColdLaunch`).
    /// No line this step logs names a made-up site.
    @MainActor
    private func contentBlockingBlockedListChecks(model: BrowserViewModel, store: SidebarStore, shell: ChromiumShell) async throws {
        // Without blocking the gap is already logged (contentBlockingChecks).
        guard model.contentBlocking.isAvailable else { return }
        guard model.contentBlocking.blockedHosts != nil, let call = ChromiumBlockedHostsCall.resolve() else {
            log("ABI-GAP content_blocking_hosts not advertised (ABI minor \(runtime.capabilities.abiMinorVersion.map(String.init) ?? "absent") < 69): "
                + "the site controls row shows how many requests were blocked and cannot list their sites")
            return
        }
        guard let bundle = model.contentBlocking.bundle else {
            throw Failure(description: "blocked list: no blocklist bundle verified")
        }
        let unfit = SelfTestBlockingFixture.problems(in: bundle) + SelfTestBlockingFixture.listProblems(in: bundle)
            + SelfTestBlockingFixture.frameProblems(in: bundle)
        try check(unfit.isEmpty, "the blocked list's pages do not fit the lists (\(unfit.joined(separator: "; "))): "
            + "choose other hosts or paths in SelfTestBlockingFixture")
        typealias Entry = ContentBlockingBlockedList.Entry
        let tracker = SelfTestBlockingFixture.trackerHost, ad = SelfTestBlockingFixture.adHost
        let marker = SelfTestBlockingFixture.listCapMarker
        /// A list for a log or a failure: made-up sites are counted, never named.
        func describe(_ list: ContentBlockingBlockedList?) -> String {
            guard let list else { return "no list" }
            let named = list.entries.filter { !$0.host.hasPrefix(marker) }
            let lines = named.map { "\($0.host) \($0.count) \($0.tagText)\($0.canBeAllowed ? "" : " (no Allow)")" }
            let madeUp = list.entries.count - named.count
            return "[" + (lines + (madeUp > 0 ? ["\(madeUp) made-up site(s)"] : [])).joined(separator: "; ") + "], \(list.uncounted) more"
        }

        blockingRun += 1
        let firstRun = blockingRun
        try await withFixtureTab(model, store, title: "Blocked list", path: "\(SelfTestBlockingFixture.pagePath)?run=\(firstRun)") { tab, engine in
            let profileID = model.profileID(for: tab)
            let saved = store.contentBlocking(for: profileID)
            defer {
                store.setContentBlocking(saved, for: profileID)
                model.contentBlockingSettingsChanged()
            }
            // The tab's first load ends before any other starts (as in contentBlockingChecks).
            try await wait("the blocking fixture's page load \(firstRun) (title '\(engine.pageTitle ?? "nil")')", timeout: 20) {
                SelfTestBlockingFixture.Verdict(title: engine.pageTitle)?.run == firstRun
            }
            guard let site = SiteControlCenter.site(for: engine.currentURL) else { throw Failure(description: "the blocking fixture's page has no site") }
            @MainActor func settings() -> ContentBlockingSettings { store.contentBlocking(for: profileID) }
            @MainActor func count(_ page: ChromiumEngine? = nil) -> Int? { model.contentBlocking.blockedCount?(page ?? engine) }
            @MainActor func list(_ page: ChromiumEngine? = nil) -> ContentBlockingBlockedList? { model.blockedList(for: page ?? engine) }
            /// The lines alone; the page's own site is checked where it matters.
            @MainActor func shows(_ wanted: [Entry], _ page: ChromiumEngine? = nil) -> Bool {
                list(page).map { $0.entries == wanted && $0.uncounted == 0 } ?? false
            }
            @MainActor func expectList(_ wanted: [Entry], _ label: String) async throws {
                try await wait("\(label): the blocked list to be \(describe(.init(entries: wanted))) (now \(describe(list())))", timeout: 10) {
                    shows(wanted) && count() == wanted.reduce(0) { $0 + $1.count }
                }
            }
            /// One load of the list page in `engine`; returns when the page's requests have ended.
            @MainActor func loadList(_ mode: SelfTestBlockingFixture.ListMode) async throws -> SelfTestBlockingFixture.ListVerdict {
                blockingRun += 1
                let run = blockingRun
                loadShellTab(model, tab, engine, SelfTestBlockingFixture.listPageURL(base: serverBase, run: run, mode: mode))
                return try await blockedListLoad(run, engine)
            }

            // 1. Ads and trackers, with no exception and no own rule in the way: two sites, two lists.
            model.setContentBlockingEnabled(true, for: profileID)
            model.setContentBlockingStrength(.adsAndTrackers, for: profileID)
            for excepted in settings().exceptions { model.removeContentBlockingException(excepted, for: profileID) }
            model.setContentBlockingOwnRules("", for: profileID)
            let both = [Entry(host: tracker, count: 1, kinds: [.tracker]), Entry(host: ad, count: 1, kinds: [.ad])]
            _ = try await waitForBlocking("at Ads and trackers, for the list", model, tab, engine, tracker: true, ad: true, timeout: 90)
            try await expectList(both, "at Ads and trackers")
            guard let row = model.contentBlockingRow(for: engine, site: site) else { throw Failure(description: "the site controls have no blocking row") }
            try check(row.hasBlockedList && row.state == "2 blocked on this page", "the row does not offer its list: \(row)")
            // The site Allow writes for is the engine's name for the page: here an address, which is itself.
            guard let shown = list(), let pageSite = shown.allowSite, model.canAllowBlockedHosts(for: engine, on: shown) else {
                throw Failure(description: "a line of the list cannot be allowed on \(site.host): the engine names the page's site "
                    + "'\(list()?.pageSite ?? "nil")', one site: \(list()?.pageSiteIsOneSite ?? false)")
            }
            // `site.host` is the display host, with the fixture server's port; a site name has none.
            let pageHost = engine.currentURL.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.host }?.lowercased()
            try check(pageSite == pageHost, "the engine names the page's site '\(pageSite)', and the page is on \(pageHost ?? "nil") (\(site.host))")
            // A page that loaded is no error page (bridge 0.80.0 says which; 0.79.0 does not say and reads as none).
            try check(!shown.pageIsError, "the engine calls the fixture's loaded page an error page")
            log("PASS blocked list: \(describe(list())) for a page that asked a tracker's host and an ad server's host; "
                + "the engine counts 2 and the row offers the list")

            // 2. A navigation inside the document is the same page: the list stays.
            let hash = try await engine.evaluate("history.pushState(null, '', location.pathname + location.search + '#same'), location.hash", in: .page) as? String
            try check(hash == "#same", "the fixture did not navigate inside its document: location.hash is \(hash ?? "nil")")
            try await Task.sleep(for: .milliseconds(600))
            try check(shows(both) && count() == 2,
                      "after a navigation inside the document the list is \(describe(list())) and the count \(count().map(String.init) ?? "nil")")

            // 3. Allow, by the list's own command, which reloads the tab.
            guard let line = ContentBlockingSiteAllow.rule(host: ad, site: pageSite) else {
                throw Failure(description: "no Allow rule can be written for \(ad) on \(pageSite)")
            }
            // For a site the tab is not on (the list of a page it has left): nothing.
            model.setBlockedHost(ad, allowed: true, on: "elsewhere.test", of: engine)
            try check(settings().ownRules.isEmpty, "Allow for a site the tab is not on wrote '\(settings().ownRules)'")
            model.setBlockedHost(ad, allowed: true, on: pageSite, of: engine)
            try check(settings().ownRules == line + "\n", "Allow wrote '\(settings().ownRules)' into the own rules, not the one line '\(line)'")
            try check(model.allowedBlockedHosts(for: engine, pageSite: pageSite) == [ad],
                      "allowed on this site: \(model.allowedBlockedHosts(for: engine, pageSite: pageSite))")
            // The server's word for it: waitForBlocking fails a load whose page and server disagree.
            let allowedLoads = try await waitForBlocking("with \(ad) allowed", model, tab, engine, tracker: true, ad: false)
            try await expectList([both[0]], "with \(ad) allowed")
            model.setBlockedHost(ad, allowed: false, on: pageSite, of: engine)
            try check(settings().ownRules.isEmpty, "Remove left '\(settings().ownRules)' in the own rules")
            let againLoads = try await waitForBlocking("with the allow removed", model, tab, engine, tracker: true, ad: true)
            try await expectList(both, "with the allow removed")
            log("PASS blocked list allow: asked for a site the tab is not on, Allow wrote nothing; '\(line)' is the one line it wrote for "
                + "the page's own site (it is the own rules' text in Settings); the ad's request "
                + "then reached the fixture server (load \(allowedLoads)) and only \(tracker) was counted and listed; removed, both are "
                + "blocked and listed again (load \(againLoads))")

            // 3b. An allowed site also gets what its own frame asks for (Darni 2026.1120.1105:
            // a site allowed on a real page stayed in the list with a count).
            typealias FrameVerdict = SelfTestBlockingFixture.FrameVerdict
            /// Loads the frame's page until it shows `wanted`; returns the loads it took and the last load's number.
            @MainActor func frameLoads(until wanted: FrameVerdict, _ what: String, base: String? = nil,
                                       timeout: TimeInterval = 40) async throws -> (loads: Int, run: Int) {
                let deadline = Date().addingTimeInterval(timeout)
                var loads = 0
                while true {
                    blockingRun += 1
                    let run = blockingRun
                    loadShellTab(model, tab, engine, SelfTestBlockingFixture.framePageURL(base: base ?? serverBase, run: run))
                    try await wait("the frame page's load \(run) (title '\(engine.pageTitle ?? "nil")')", timeout: 20) {
                        FrameVerdict(title: engine.pageTitle, run: run) != nil
                    }
                    loads += 1
                    let verdict = FrameVerdict(title: engine.pageTitle, run: run)
                    // The server's word against the page's: the frame's script arrives there only when it loaded.
                    let fetched = LoopbackFixtureServer.blockingFetches(run: run).tracker
                    try check((verdict == .innerLoaded) == (fetched > 0),
                              "frame page load \(run): the page saw \(verdict?.rawValue ?? "nothing"), and the server was asked for the frame's script \(fetched) time(s)")
                    if verdict == wanted { return (loads, run) }
                    guard Date() < deadline else {
                        throw Failure(description: "blocked list frame \(what): after \(loads) load(s) in \(Int(timeout)) s the page still has "
                            + "\(verdict?.rawValue ?? "nothing"), not \(wanted.rawValue); the list is \(describe(list()))")
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }
            let trackerLine = [both[0]]
            _ = try await frameLoads(until: .frameBlocked, "with nothing allowed")
            try await expectList(trackerLine, "the frame's page with nothing allowed")
            // The state that was seen: the frame is let in, and what it asks of its own host is not. An exception
            // for third-party requests alone leaves exactly that, by either of its two rules.
            model.setContentBlockingOwnRules("@@||\(tracker)^$domain=\(pageSite),third-party\n", for: profileID)
            _ = try await frameLoads(until: .innerBlocked, "with the frame let in and its own requests not")
            try await expectList(trackerLine, "the frame's page with the frame let in and its own requests not")
            model.setContentBlockingOwnRules("", for: profileID)
            _ = try await frameLoads(until: .frameBlocked, "with that rule gone")
            // Allow, as the list's command writes it.
            model.setBlockedHost(tracker, allowed: true, on: pageSite, of: engine)
            guard let trackerRule = ContentBlockingSiteAllow.rule(host: tracker, site: pageSite) else {
                throw Failure(description: "no Allow rule can be written for \(tracker) on \(pageSite)")
            }
            try check(settings().ownRules == trackerRule + "\n", "Allow wrote '\(settings().ownRules)' into the own rules, not the one line '\(trackerRule)'")
            let frameAllowed = try await frameLoads(until: .innerLoaded, "with \(tracker) allowed")
            try await expectList([], "the frame's page with \(tracker) allowed")
            try check(list()?.stillBlockedNote(allowed: model.allowedBlockedHosts(for: engine, pageSite: pageSite)) == nil,
                      "with \(tracker) allowed and nothing blocked the list has a note")
            // The other direction (security addendum 14, remark 2): the line is for pages of this site. The same
            // page from another site, with the line in place, must have the frame blocked at its first load.
            // This is the check that fails if an engine ever stops honouring the rule's page condition.
            let otherSite = SelfTestBlockingFixture.siteHost
            let otherBase = serverBase.replacingOccurrences(of: "127.0.0.1", with: otherSite)
            try check(otherBase != serverBase, "the fixture server's address '\(serverBase)' has no 127.0.0.1 to put \(otherSite) in for")
            let elsewhere = try await frameLoads(until: .frameBlocked, "on \(otherSite), with \(tracker) allowed on \(pageSite) alone", base: otherBase)
            try check(elsewhere.loads == 1, "with \(tracker) allowed on \(pageSite) alone, the frame's page on \(otherSite) had its frame let in "
                + "for \(elsewhere.loads - 1) load(s)")
            try await expectList(trackerLine, "the frame's page on \(otherSite)")
            try check(settings().ownRules == trackerRule + "\n", "the load from \(otherSite) changed the own rules to '\(settings().ownRules)'")
            // Back on the page's own site, where Remove is.
            _ = try await frameLoads(until: .innerLoaded, "back on \(pageSite) with \(tracker) allowed")
            model.setBlockedHost(tracker, allowed: false, on: pageSite, of: engine)
            try check(settings().ownRules.isEmpty, "Remove left '\(settings().ownRules)' in the own rules")
            _ = try await frameLoads(until: .frameBlocked, "with the allow removed")
            try await expectList(trackerLine, "the frame's page with the allow removed")
            log("PASS blocked list allow in a frame: a frame on \(tracker) that asks its own host is blocked with nothing allowed; with an "
                + "exception for third-party requests alone the frame loads and its own request stays blocked and listed; with '\(trackerRule)', "
                + "the line Allow writes, the frame's request reached the fixture server (load \(frameAllowed.loads)) and nothing was counted "
                + "or listed; the same page on \(otherSite) had the frame blocked at its first load; removed, the frame is blocked and listed again")

            // 4. Names that are not one site: listed, and never allowed.
            _ = try await loadList(.sites)
            let names = [Entry(host: SelfTestBlockingFixture.listHost, count: SelfTestBlockingFixture.listHostRequests, kinds: [.ad, .tracker], canBeAllowed: false),
                         Entry(host: SelfTestBlockingFixture.listSuffixHost, count: 1, kinds: [.tracker], canBeAllowed: false)]
            try await expectList(names, "a single-label name and a public suffix")
            for name in names.map(\.host) {
                model.setBlockedHost(name, allowed: true, on: pageSite, of: engine)
                try check(settings().ownRules.isEmpty, "\(name) is not one site and Allow wrote '\(settings().ownRules)'")
            }
            log("PASS blocked list names: \(describe(list())); neither line can be allowed")

            // 5. More sites than a list holds.
            _ = try await loadList(.cap)
            let sites = SelfTestBlockingFixture.listCapSites, held = ContentBlockingBlockedList.maxEntries
            try await wait("the engine's count to be \(sites) (now \(count().map(String.init) ?? "nil"))", timeout: 20) { count() == sites }
            let capped = list()
            try check(capped?.entries.count == held && capped?.uncounted == sites - held
                        && capped?.entries.allSatisfy { $0.count == 1 && $0.host.hasPrefix(marker) && $0.kinds == [.tracker] && $0.canBeAllowed } == true,
                      "\(sites) blocked sites gave \(describe(capped)), not \(held) lines and \(sites - held) more")
            log("PASS blocked list cap: \(sites) blocked sites are \(held) lines and \(sites - held) more")

            // 6. A navigation to another document starts the list again, as it does the count.
            _ = try await loadList(.quiet)
            try await expectList([], "after a navigation to a page that asks for nothing")
            let quietRow = model.contentBlockingRow(for: engine, site: site)
            try check(quietRow?.hasBlockedList == false, "the row still offers a list on a page with nothing blocked: \(String(describing: quietRow))")
            log("PASS blocked list cleared: a navigation inside the document kept the list; a navigation to another document emptied it, count 0")

            // 7. A private window: a list, no Allow, and nothing once it is closed.
            blockingRun += 1
            let privateRun = blockingRun
            let privateWindow = model.openPrivateWindow(url: SelfTestBlockingFixture.listPageURL(base: serverBase, run: privateRun))
            guard let privateEngine = privateWindow.engine as? ChromiumEngine else { throw Failure(description: "private window engine is not Chromium") }
            _ = try await blockedListLoad(privateRun, privateEngine)
            try await wait("the private tab's blocked list to be \(describe(.init(entries: names))) (now \(describe(list(privateEngine))))", timeout: 10) {
                shows(names, privateEngine) && count(privateEngine) == SelfTestBlockingFixture.listRequests
            }
            try check(list(privateEngine).map { !model.canAllowBlockedHosts(for: privateEngine, on: $0) } == true, "a private window's list offers Allow")
            model.setBlockedHost(ad, allowed: true, on: pageSite, of: privateEngine)
            try check(settings().ownRules.isEmpty, "Allow from a private window wrote '\(settings().ownRules)'")
            let privateTab = privateEngine.tabID, privateKey = privateEngine.profileKey
            guard let privateNSWindow = privateWindow.hostWindow else { throw Failure(description: "private window has no NSWindow") }
            shell.closeWindow(privateNSWindow)
            try await wait("the private session to close", timeout: 20) { model.privateWindows.isEmpty && runtime.engineProfileID(for: privateKey) == nil }
            // The engine tears the tab down after the shell lets go of the session, so the
            // answer may take a moment to empty; it must, and the time it took is logged.
            @MainActor func privateAnswer() -> (ReArcStatus, ContentBlockingBlockedList?) {
                // The adapter's own read of the reply, with its length bound.
                let (status, json) = call.reply(tab: privateTab)
                return (status, json.flatMap { ContentBlockingBlockedList.decode($0, lists: model.contentBlockingListRows) })
            }
            let closedAt = Date()
            do {
                try await wait("the engine to answer nothing for the closed private tab", timeout: 15) {
                    let (status, left) = privateAnswer()
                    return status == .rearcOK && left?.isEmpty == true
                }
            } catch {
                let (status, left) = privateAnswer()
                throw Failure(description: "15 s after the private window closed the engine answers \(status.rearcName) with \(describe(left)) for its tab")
            }
            log("NOTE blocked list private window: the engine's answer for the closed tab emptied \(String(format: "%.2f", Date().timeIntervalSince(closedAt))) s after the session closed")
            log("PASS blocked list private window: its tab had \(describe(.init(entries: names))) and no Allow; closed, the engine has nothing for it")

            // 8. Memory only: no made-up site of step 5 is in a file. Last, so that what it finds is the only thing it fails.
            // Every file the app could have written it to is read: the engine's profile folder and the folder of the
            // shell's own files (the sidebar file's, where the model keeps the rest). Both are the app's alone. A folder
            // other programs write to as well is not read: that is a fault of the test's setup, and it fails as one.
            model.persistence.flush()
            let folders = [runtime.userDataDir, model.persistence.fileURL.deletingLastPathComponent()].compactMap { $0 }
            let shared = SelfTestDiskScan.sharedFolders(among: folders)
            try check(shared.isEmpty, "blocked list in memory only: \(shared.joined(separator: " and ")) is not a folder of the app's own "
                + "(the temporary folder, the home folder or one above them), so its files were not read; give the run a profile "
                + "folder and a shell data folder of their own")
            let found = await Task.detached { SelfTestDiskScan.files(containing: marker, in: folders) }.value
            try check(found.isEmpty, "the blocked sites of a page were written to disk: '\(marker)…' is in \(found.prefix(5).joined(separator: ", "))"
                + (found.count > 5 ? " and \(found.count - 5) more file(s)" : ""))
            log("PASS blocked list in memory only: none of the \(sites) made-up sites is in a file under \(folders.map(\.path).joined(separator: " or "))")
        }
    }

    /// The engine names sites by Chromium's public suffix list (CONTENT-BLOCKING.md
    /// §9, patch `tab/098`, ABI 1.69 `host_sites`), through the shell's one
    /// place to ask (`SiteNames.shared`). An engine without it logs the gap.
    /// What must hold: a host is named by its registrable domain, private
    /// registries included; a public suffix is said to be one and a name
    /// with no suffix is not; and a name the engine would read as another
    /// (`1.2` is an address to it) gets no answer at all (security BL-12).
    /// A table lookup: nothing here loads a page or asks the network.
    @MainActor
    private func hostSitesChecks() throws {
        guard runtime.capabilities.hostSites, let names = SiteNames.shared else {
            log("ABI-GAP host_sites not advertised (ABI minor \(runtime.capabilities.abiMinorVersion.map(String.init) ?? "absent") < 69): "
                + "the shell names a site by its own rules (the page's exact host for a blocking exception, its guess elsewhere)")
            return
        }
        let wanted: [(String, SiteName?)] = [
            ("www.example.co.uk", SiteName(name: "example.co.uk", isOneSite: true)),
            ("a.someone.web.app", SiteName(name: "someone.web.app", isOneSite: true)),
            ("someone.github.io", SiteName(name: "someone.github.io", isOneSite: true)),
            ("school.edu.au", SiteName(name: "school.edu.au", isOneSite: true)),
            ("WWW.Example.COM.", SiteName(name: "example.com", isOneSite: true)),
            ("203.0.113.7", SiteName(name: "203.0.113.7", isOneSite: true)),
            ("name.test", SiteName(name: "name.test", isOneSite: true)),
            ("web.app", SiteName(name: "web.app", isOneSite: false, isSuffix: true)),
            ("co.uk", SiteName(name: "co.uk", isOneSite: false, isSuffix: true)),
            ("edu.au", SiteName(name: "edu.au", isOneSite: false, isSuffix: true)),
            ("com", SiteName(name: "com", isOneSite: false, isSuffix: true)),
            ("localhost", SiteName(name: "localhost", isOneSite: false, isSuffix: false)),
            ("1.2", nil), ("0x7f.1", nil), ("123", nil), ("example.com:443", nil), ("https://example.com", nil), ("[::1]", nil), ("", nil),
        ]
        let wrong = wanted.compactMap { host, site -> String? in
            let answer = names.site(of: host)
            return answer == site ? nil : "'\(host)' is \(answer.map { "\($0)" } ?? "no answer"), not \(site.map { "\($0)" } ?? "no answer")"
        }
        try check(wrong.isEmpty, "the engine's site names: \(wrong.joined(separator: "; "))")
        // The engine itself refuses a name it reads as another one; the shell's check is a second hold.
        if let copy = ChromiumHostSites.resolve() {
            let refused = ["1.2", "0x7f.1", "123", "a b", "example.com/x"].filter { ChromiumHostSites.reply(copy, $0) != nil }
            try check(refused.isEmpty, "the engine answered for \(refused), which are not plain names of themselves")
        }
        log("PASS host sites: \(wanted.count) names, registrable domains by Chromium's suffix list (someone.web.app and school.edu.au are sites; "
            + "web.app, co.uk and com are suffixes; localhost is neither), and no answer for a name the engine reads as another")
    }

    /// The four users of the engine's site names (CONTENT-BLOCKING.md §9;
    /// security CB-12, BO-01, AG-05), on a page under a private suffix: the
    /// blocking fixture loaded from `rearc_selftest.azurewebsites.net`, which
    /// the shell's old guess took for a page of all of `azurewebsites.net`.
    /// Needs the blocked list's call and `host_sites`; the gaps are logged by
    /// the steps before. What must hold:
    ///
    /// - The engine names the page's site as the one tenant.
    /// - "Turn Off Blocking for This Site" stores that tenant, and the
    ///   fixture's two requests then load.
    /// - A stored exception for the whole suffix (what builds 1027 to 1049
    ///   wrote) is marked on the row, and "This Site Only" swaps it for the
    ///   tenant. The suffix typed into Settings is refused.
    /// - A new boost on the page is for the tenant; a scope of the suffix is
    ///   refused and matches nothing.
    /// - A long host under the suffix keeps its own label when shortened.
    @MainActor
    private func siteNamesUsersChecks(model: BrowserViewModel, store: SidebarStore) async throws {
        guard model.contentBlocking.isAvailable, model.contentBlocking.blockedHosts != nil, runtime.capabilities.hostSites,
              SiteNames.shared != nil, model.contentBlocking.bundle != nil else { return }
        let host = SelfTestBlockingFixture.siteHost, suffix = SelfTestBlockingFixture.siteSuffix
        // The fixture server by the site's name: the same port, another host.
        let siteBase = serverBase.replacingOccurrences(of: "127.0.0.1", with: host)
        try check(siteBase != serverBase, "the fixture server's address '\(serverBase)' has no 127.0.0.1 to put \(host) in for")

        blockingRun += 1
        try await withFixtureTab(model, store, title: "Site names", path: "\(SelfTestBlockingFixture.listPagePath)?run=\(blockingRun)&quiet=1") { tab, engine in
            let profileID = model.profileID(for: tab)
            let saved = store.contentBlocking(for: profileID)
            defer {
                store.setContentBlocking(saved, for: profileID)
                model.contentBlockingSettingsChanged()
            }
            _ = try await blockedListLoad(blockingRun, engine)
            @MainActor func settings() -> ContentBlockingSettings { store.contentBlocking(for: profileID) }
            /// Loads the fixture from the site's name until the page shows the wanted state.
            @MainActor func loadUntil(tracker: Bool, ad: Bool, _ what: String, timeout: TimeInterval = 30) async throws {
                let deadline = Date().addingTimeInterval(timeout)
                while true {
                    blockingRun += 1
                    let run = blockingRun
                    loadShellTab(model, tab, engine, SelfTestBlockingFixture.pageURL(base: siteBase, run: run))
                    let load = try await blockingFixtureLoad(run, engine)
                    if load.verdict.trackerBlocked == tracker && load.verdict.adBlocked == ad { return }
                    guard Date() < deadline else {
                        throw Failure(description: "site names \(what): after \(Int(timeout)) s the page on \(host) still has \(load.verdict.text)")
                    }
                    try await Task.sleep(for: .milliseconds(250))
                }
            }

            model.setContentBlockingEnabled(true, for: profileID)
            model.setContentBlockingStrength(.adsAndTrackers, for: profileID)
            for excepted in settings().exceptions { model.removeContentBlockingException(excepted, for: profileID) }
            model.setContentBlockingOwnRules("", for: profileID)

            // 1. The page under the suffix, blocked; the engine names its site as the tenant.
            try await loadUntil(tracker: true, ad: true, "at Ads and trackers", timeout: 60)
            guard let site = SiteControlCenter.site(for: engine.currentURL), let pageURL = engine.currentURL else {
                throw Failure(description: "the page on \(host) has no site")
            }
            let named = model.blockedList(for: engine)
            try check(named?.pageSite == host && named?.pageSiteIsOneSite == true,
                      "the engine names the page's site '\(named?.pageSite ?? "nil")' (one site: \(named?.pageSiteIsOneSite ?? false)), not \(host)")

            // 2. Turn Off Blocking for This Site: the tenant, not the suffix.
            model.setContentBlocking(false, forSiteOf: engine, site: site)
            try check(settings().exceptions == [host], "Turn Off for This Site stored \(settings().exceptions), not [\(host)]")
            try await loadUntil(tracker: false, ad: false, "with the site's exception")

            // 3. What an older build stored: the whole suffix. Marked, narrowed, and refused when typed.
            store.updateContentBlocking(for: profileID) { $0.setExceptions([suffix]) }
            model.contentBlockingSettingsChanged()
            guard let marked = model.contentBlockingRow(for: engine, site: site) else { throw Failure(description: "the site controls have no blocking row") }
            try check(marked.state == SiteControlCenter.suffixExceptionText(suffix) && marked.actions.contains(.turnOffBlockingForSiteOnly),
                      "the row for a stored '\(suffix)' exception: \(marked)")
            model.performSiteSetting(.turnOffBlockingForSiteOnly, on: marked, engine: engine, site: site)
            try check(settings().exceptions == [host], "This Site Only left \(settings().exceptions), not [\(host)]")
            try check(!model.addContentBlockingException(suffix, for: profileID) && settings().exceptions == [host],
                      "'\(suffix)' typed into Settings was taken: \(settings().exceptions)")
            model.setContentBlocking(true, forSiteOf: engine, site: site)
            try check(settings().exceptions.isEmpty, "Turn On for This Site left \(settings().exceptions)")
            try await loadUntil(tracker: true, ad: true, "with the exception removed")

            // 4. Boost scopes.
            let scope = BoostScopeMatcher.defaultRule(forPage: pageURL)
            try check(scope?.host == host && scope?.hostMatch == .registrable, "a new boost on \(host) is scoped to \(String(describing: scope))")
            let wide = BoostHostRule(host: suffix, schemes: ["http"])
            try check(!BoostScopeMatcher.validateRule(wide) && !BoostScopeMatcher.validateRule(BoostHostRule(host: suffix, hostMatch: .exact)),
                      "a boost scoped to \(suffix) is accepted")
            try check(!BoostScopeMatcher.matches(rule: wide, url: pageURL) && (scope.map { BoostScopeMatcher.matches(rule: $0, url: pageURL) } ?? false),
                      "a boost scoped to \(suffix) matches the page on \(host), or one scoped to \(host) does not")

            // 5. The shortened host.
            let long = "login.\(String(repeating: "a", count: 30)).\(suffix)"
            let short = PageOrigin.shortenedHost(long)
            try check(short == "…" + long.dropFirst("login.".count), "'\(long)' is shortened to '\(short)'")

            log("PASS site names in use: on \(host) the engine names the tenant as the site; Turn Off for This Site stores it and the "
                + "page's requests load; a stored '\(suffix)' is marked on the row and narrowed to the tenant, and refused when typed; a new "
                + "boost is for the tenant and a scope of '\(suffix)' is refused and matches nothing; a long host keeps its own label")
        }
    }

    /// Waits for load `run` of the blocked list page to end and reads it.
    @MainActor
    private func blockedListLoad(_ run: Int, _ engine: ChromiumEngine, timeout: TimeInterval = 20) async throws -> SelfTestBlockingFixture.ListVerdict {
        try await wait("the blocked list page's load \(run) (title '\(engine.pageTitle ?? "nil")')", timeout: timeout) {
            SelfTestBlockingFixture.ListVerdict(title: engine.pageTitle)?.run == run
        }
        guard let verdict = SelfTestBlockingFixture.ListVerdict(title: engine.pageTitle) else {
            throw Failure(description: "the blocked list page's title changed under the test: '\(engine.pageTitle ?? "nil")'")
        }
        return verdict
    }

    /// One load of the blocking fixture in `tab`, as a page load with a
    /// number of its own: what the page saw of its two requests, and what
    /// the fixture server was asked for in that load. The two must agree: a
    /// request the page saw fail and the server answered, or the other way
    /// round, is a broken fixture and fails here.
    @MainActor
    private func loadBlockingFixture(_ model: BrowserViewModel, _ tab: Tab, _ engine: ChromiumEngine) async throws
        -> (verdict: SelfTestBlockingFixture.Verdict, fetched: (tracker: Int, ad: Int)) {
        blockingRun += 1
        let run = blockingRun
        loadShellTab(model, tab, engine, SelfTestBlockingFixture.pageURL(base: serverBase, run: run))
        return try await blockingFixtureLoad(run, engine)
    }

    /// Waits for page load `run` of the blocking fixture to end and reads it.
    @MainActor
    private func blockingFixtureLoad(_ run: Int, _ engine: ChromiumEngine, timeout: TimeInterval = 20) async throws
        -> (verdict: SelfTestBlockingFixture.Verdict, fetched: (tracker: Int, ad: Int)) {
        try await wait("the blocking fixture's page load \(run) (title '\(engine.pageTitle ?? "nil")')", timeout: timeout) {
            SelfTestBlockingFixture.Verdict(title: engine.pageTitle)?.run == run
        }
        guard let verdict = SelfTestBlockingFixture.Verdict(title: engine.pageTitle) else {
            throw Failure(description: "the blocking fixture's title changed under the test: '\(engine.pageTitle ?? "nil")'")
        }
        let fetched = LoopbackFixtureServer.blockingFetches(run: run)
        try check(verdict.trackerBlocked == (fetched.tracker == 0) && verdict.adBlocked == (fetched.ad == 0),
                  "blocking fixture load \(run): the page saw \(verdict.text), and the server was asked for the tracker "
                    + "\(fetched.tracker) time(s) and the ad \(fetched.ad) time(s)")
        return (verdict, fetched)
    }

    /// Loads the blocking fixture until the page shows the wanted state, and
    /// returns how many loads that took (1: the first load after the change
    /// already had it). Fails with the last state after `timeout`.
    @MainActor
    private func waitForBlocking(_ what: String, _ model: BrowserViewModel, _ tab: Tab, _ engine: ChromiumEngine,
                                 tracker: Bool, ad: Bool, timeout: TimeInterval = 30) async throws -> Int {
        let wanted = SelfTestBlockingFixture.Verdict(run: 0, trackerBlocked: tracker, adBlocked: ad)
        let deadline = Date().addingTimeInterval(timeout)
        var loads = 0
        while true {
            let load = try await loadBlockingFixture(model, tab, engine)
            loads += 1
            if load.verdict.trackerBlocked == tracker && load.verdict.adBlocked == ad { return loads }
            guard Date() < deadline else {
                throw Failure(description: "content blocking \(what): after \(loads) load(s) in \(Int(timeout)) s the page still has "
                    + "\(load.verdict.text), not \(wanted.text); last events: \(model.contentBlockingEvents.suffix(3).joined(separator: "; "))")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    // MARK: Blocking at a cold launch (security CB-02)

    /// Security CB-02: the engine keeps nothing of blocking between launches
    /// but what Chromium keeps of the blocker, and a restored tab starts
    /// loading when its profile opens. If the lists come on later than that,
    /// the tab's trackers are fetched at every such launch. The engine loads
    /// again the blocker that was ready in the last session, so Chromium
    /// brings its lists up with it, and holds a profile's first navigations
    /// while a blocker loads fresh (tab/095).
    ///
    /// Each case starts ReArc again, as a process of its own with a profile
    /// of its own, whose tab and Little ReArc window are restored on the
    /// blocking fixture (`contentBlockingColdLaunch`). A launch passes when
    /// its fixture server was never asked for the tracker or the ad:
    ///
    /// 1. A new profile: the first launch copies and indexes the rules.
    /// 2. The same profile again: the everyday launch.
    /// 3. An existing profile whose blocker has no state: a launch with
    ///    blocking off (both pages fetch both, and no rules are copied into the
    ///    user data folder), then a launch with blocking on.
    /// 4. A list update: on profile 1, a newer bundle signed with a key made
    ///    for this run arrives and takes over (the engine's marker moves to
    ///    the second blocker), and the launch after it, with that bundle,
    ///    loads the second blocker again (the marker stays where it is).
    ///
    /// After each launch the engine's marker of the blocker that was last
    /// ready is read from the profile's preferences. A bundle release.sh is
    /// verifying takes only a new, empty profile (RC-0.1.0-602 F-03): there it
    /// is case 1 alone, which also switches blocking off to see the page
    /// fetch both.
    @MainActor
    private func contentBlockingColdLaunchChecks() async throws {
        // Without the feature the gap is already logged (contentBlockingChecks).
        guard runtime.capabilities.contentBlocking, ChromiumContentBlockingCalls.resolve() != nil else { return }
        guard let executable = Bundle.main.executableURL else { throw Failure(description: "no executable to start the cold launch with") }
        guard let builtIn = ContentBlockingController.builtInListsURL,
              let builtInVersion = Self.bundleVersion(in: builtIn) else {
            throw Failure(description: "content blocking cold launch: the app has no built-in bundle to read the version of")
        }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-cold-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let release = ShippedBuild.isRelease(infoDictionary: Bundle.main.infoDictionary)

        /// One cold launch; its `COLD-BLOCKING PASS` summary.
        @MainActor func launch(_ label: String, profile: URL, step: SelfTestBlockingFixture.ColdStep, lists: URL? = nil,
                               update: URL? = nil, key: Data? = nil, checkOff: Bool = false) async throws -> String {
            // Longer than the launch's own waits together (45 s for each page, 45 s for a later
            // blocked load, 30 s for an update), so a failing launch ends by itself and says why.
            var arguments = SelfTestBlockingFixture.coldLaunchArguments(
                from: CommandLine.arguments, userDataDir: profile.path, step: step, lists: lists?.path, update: update?.path, listsKey: key)
            if checkOff { arguments.append(SelfTestBlockingFixture.coldCheckOffFlag) }
            let child = try await runColdLaunch(executable: executable, arguments: arguments, timeout: 150)
            let lines = child.output.split(whereSeparator: \.isNewline).map(String.init)
            let told = lines.filter { $0.contains("COLD-BLOCKING") || $0.contains("ReArc Blocker") }
            for line in told { log("cold launch, \(label): \(line)") }
            guard child.status == 0, let passed = told.last(where: { $0.contains("COLD-BLOCKING PASS") }) else {
                // The launch's own account of blocking (bundles, list checks, what the engine was
                // told), which is otherwise only in its log; the log itself stays for the reader.
                for line in lines.filter({ $0.contains("content blocking:") }).suffix(40) { log("cold launch, \(label): \(line)") }
                let failed = lines.filter { $0.contains("FAIL") }.suffix(4).joined(separator: " | ")
                throw Failure(description: "content blocking cold launch, \(label), ended with status \(child.status) (its log: \(child.log.path)): "
                    + (failed.isEmpty ? String(child.output.suffix(600)) : failed))
            }
            try? FileManager.default.removeItem(at: child.log)
            return "\(label): " + (passed.components(separatedBy: "COLD-BLOCKING PASS").last?.trimmingCharacters(in: .whitespaces) ?? "")
        }
        /// The engine's markers after a launch, slot 0 first, against what they must be.
        @MainActor func expectMarkers(_ profile: URL, _ wanted: [String?], _ label: String, _ why: String) throws {
            // One engine profile for every launch on this folder: a second one means the launch did
            // not meet the blocker of the launches before it, and its markers would be read beside theirs.
            let folders = (try? FileManager.default.contentsOfDirectory(atPath: profile.path)) ?? []
            let named = SelfTestBlockingFixture.namedProfileFolders(in: folders)
            try check(named.isEmpty, "content blocking cold launch, \(label): the launch ran in an engine profile of its own "
                + "(\(named.joined(separator: ", "))) instead of the folder's first one")
            let found = Self.readyMarkers(userDataDir: profile)
            try check(found == wanted, "content blocking cold launch, \(label): the engine's ready-blocker markers are "
                + "\(found.map { $0 ?? "none" }), not \(wanted.map { $0 ?? "none" }): \(why)")
        }

        let first = scratch.appendingPathComponent("profile-1", isDirectory: true)
        var summaries = [try await launch("new profile", profile: first, step: .restore, checkOff: release)]
        if release {
            log("PASS content blocking at a cold launch: a restored tab and a restored Little ReArc window on the blocking fixture "
                + "fetched neither the tracker nor the ad (\(summaries[0])); one launch, on a new profile: a release bundle under "
                + "verification takes no used profile")
            log("NOTE content blocking cold launch: an existing profile without blocker state and the launch after a list update "
                + "need a used profile, which only a development build's self-test runs")
            return
        }
        let v0 = builtInVersion.description
        try expectMarkers(first, [v0, nil], "new profile", "the first blocker was not ready before the launch ended, or its marker was not kept")
        summaries.append(try await launch("the same profile again", profile: first, step: .restore))
        try expectMarkers(first, [v0, nil], "the same profile again", "the blocker of the last session was not the one loaded")

        // 3. An existing profile whose blocker has no state.
        let existing = scratch.appendingPathComponent("profile-2", isDirectory: true)
        summaries.append(try await launch("blocking off", profile: existing, step: .off))
        try expectMarkers(existing, [nil, nil], "blocking off", "a profile with blocking off got a blocker")
        let copies = existing.appendingPathComponent("ReArc Blocker")
        try check(!FileManager.default.fileExists(atPath: copies.path),
                  "content blocking cold launch, blocking off: the engine copied the rules into \(copies.path) with blocking off in every profile")
        summaries.append(try await launch("an existing profile whose blocker has no state", profile: existing, step: .restore))
        try expectMarkers(existing, [v0, nil], "an existing profile whose blocker has no state", "the fresh blocker did not get ready")

        // 4. A list update's takeover on profile 1, and the launch after it.
        let signer = Curve25519.Signing.PrivateKey()
        let key = signer.publicKey.rawRepresentation
        let update = scratch.appendingPathComponent("update", isDirectory: true)
        let lists = scratch.appendingPathComponent("lists", isDirectory: true)
        try FileManager.default.createDirectory(at: lists, withIntermediateDirectories: true)
        let v1 = try Self.makeNewerBundle(from: builtIn, signer: signer, in: update)
        summaries.append(try await launch("a list update (\(v0) to \(v1))", profile: first, step: .takeover, lists: lists, update: update, key: key))
        try expectMarkers(first, [nil, v1], "a list update", "the second blocker did not take over from the first")
        summaries.append(try await launch("the launch after the list update", profile: first, step: .restore, lists: lists, key: key))
        try expectMarkers(first, [nil, v1], "the launch after the list update",
                          "the engine loaded the first blocker fresh instead of the second, which holds the last session's lists")
        log("PASS content blocking at a cold launch: restored tabs and Little ReArc windows on the blocking fixture fetched neither the "
            + "tracker nor the ad (\(summaries.joined(separator: "; "))); the engine's markers followed the ready blocker: "
            + "\(v0) in slot 0, then \(v1) in slot 1 after the update and the launch after it")
    }

    /// The `version` of the bundle in `directory`'s manifest.
    private static func bundleVersion(in directory: URL) -> BlocklistVersion? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(BlocklistManifest.fileName)),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (manifest["version"] as? String).flatMap(BlocklistVersion.init)
    }

    /// The engine's ready-blocker markers in the profiles of `userDataDir`.
    private static func readyMarkers(userDataDir: URL) -> [String?] {
        let profiles = (try? FileManager.default.contentsOfDirectory(at: userDataDir, includingPropertiesForKeys: nil)) ?? []
        let files = profiles.flatMap { profile in
            ["Secure Preferences", "Preferences"].compactMap { try? Data(contentsOf: profile.appendingPathComponent($0)) }
        }
        return SelfTestBlockingFixture.readyMarkers(inPreferences: files)
    }

    /// The takeover step's update: the built-in bundle as a newer version,
    /// signed by `signer` (a key made for this run, which only its cold
    /// launches trust), packed as the mirror packs it, with the
    /// `latest.json` that names it. Written into `folder`; returns the version.
    private static func makeNewerBundle(from source: URL, signer: Curve25519.Signing.PrivateKey, in folder: URL) throws -> String {
        let manifestData = try Data(contentsOf: source.appendingPathComponent(BlocklistManifest.fileName))
        guard var manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let current = (manifest["version"] as? String).flatMap(BlocklistVersion.init), let date = current.date else {
            throw Failure(description: "the built-in bundle's manifest has no version to make a newer one from")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmm"
        let version = formatter.string(from: date.addingTimeInterval(3600))
        guard let newer = BlocklistVersion(version), newer > current else { throw Failure(description: "no version after \(current)") }
        manifest["version"] = version
        let name = "blocklists-\(version)"
        let bundle = folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: bundle)
        let signed = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try signed.write(to: bundle.appendingPathComponent(BlocklistManifest.fileName))
        try Data(signer.signature(for: signed).base64EncodedString().utf8)
            .write(to: bundle.appendingPathComponent(BlocklistManifest.signatureFileName))
        if case .failure(let rejection) = BlocklistVerifier.verify(directory: bundle, source: .downloaded,
                                                                     publicKeys: [signer.publicKey.rawRepresentation], engine: nil) {
            throw Failure(description: "the self-test's newer bundle does not verify: \(rejection.text)")
        }
        // Plain ustar, as the pipeline's archives: BlocklistArchive refuses pax headers and macOS metadata.
        let archive = folder.appendingPathComponent("\(name).tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["--format", "ustar", "--no-mac-metadata", "--no-xattrs", "-czf", archive.path, "-C", folder.path, name]
        tar.environment = ["COPYFILE_DISABLE": "1"]
        try tar.run()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else { throw Failure(description: "tar ended with status \(tar.terminationStatus) packing the newer bundle") }
        try FileManager.default.removeItem(at: bundle)
        let packed = try Data(contentsOf: archive)
        let check = folder.appendingPathComponent("check", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: check) }
        try BlocklistArchive.extract(packed, to: check)
        let url = BlocklistMirror.latestURL.deletingLastPathComponent().appendingPathComponent(archive.lastPathComponent)
        let latest: [String: Any] = ["version": version, "url": url.absoluteString, "sha256": BlocklistVerifier.sha256(of: packed)]
        try JSONSerialization.data(withJSONObject: latest).write(to: folder.appendingPathComponent(BlocklistMirror.latestURL.lastPathComponent))
        return version
    }

    /// Runs this executable again as the cold launch for blocking and waits
    /// for it to end. Its output goes to a file, so a full pipe cannot stall
    /// it. The file (`log`) is the caller's to delete: a launch that failed
    /// leaves it, and the failure names it.
    @MainActor
    private func runColdLaunch(executable: URL, arguments: [String], timeout: TimeInterval) async throws
        -> (status: Int32, output: String, log: URL) {
        let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-cold-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: logFile.path, contents: nil) else {
            throw Failure(description: "could not create the cold launch's log \(logFile.path)")
        }
        let output = try FileHandle(forWritingTo: logFile)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                let tail = String(decoding: (try? Data(contentsOf: logFile)) ?? Data(), as: UTF8.self).suffix(600)
                throw Failure(description: "the cold launch for blocking was still running after \(Int(timeout)) s "
                    + "(its log: \(logFile.path)): \(tail)")
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return (process.terminationStatus, String(decoding: (try? Data(contentsOf: logFile)) ?? Data(), as: UTF8.self), logFile)
    }

    /// The cold launch itself (`--rearc-selftest-cold-blocking`), in place
    /// of every other step: the shell starts as it does for a person, with a
    /// sidebar whose selected tab is the blocking fixture and a Little ReArc
    /// window on it too, in a new install's state (blocking on at Ads and
    /// trackers) unless the step is `off`. Nothing waits for the lists. The
    /// fixture server then says whether those first loads fetched the
    /// tracker or the ad. The step (`SelfTestBlockingFixture.ColdStep`) says
    /// what follows.
    ///
    /// Prints `COLD-BLOCKING PASS …` and exits 0 when the step passed. When a
    /// page with blocking on fetched one, it is loaded again until it is
    /// blocked, so the failure says how long after the start the lists came on.
    @MainActor
    private func contentBlockingColdLaunch() async throws {
        log("COLD-BLOCKING launch: engine ABI \(ReArcEngineABIVersion()), Chromium \(String(cString: ReArcEngineVersion())), "
            + "user data \(runtime.userDataDir?.path ?? "-")")
        try check(runtime.capabilities.contentBlocking && ChromiumContentBlockingCalls.resolve() != nil,
                  "COLD-BLOCKING FAIL: this engine has no content_blocking")
        let arguments = CommandLine.arguments
        guard let step = SelfTestBlockingFixture.coldStep(arguments) else {
            throw Failure(description: "COLD-BLOCKING FAIL: unknown step in \(arguments.filter { $0.hasPrefix(SelfTestBlockingFixture.coldStepFlag) })")
        }
        let server = try LoopbackFixtureServer()
        self.server = server
        let port = try await server.start()
        serverBase = "http://127.0.0.1:\(port)"
        // Its own folder: the sidebar file's sibling `Blocklists` is then this launch's alone,
        // or the one the self-test keeps from launch to launch.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-cold-shell-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // The kept folder is moved in and, at the end, back out: a real folder, as a person's is.
        // Through a link the store cannot list its own downloads (`contentsOfDirectory(at:)` does
        // not open a link to a folder), so a bundle it had just put in place "did not verify in place".
        let kept = SelfTestBlockingFixture.value(of: SelfTestBlockingFixture.coldListsFlag, in: arguments)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        let downloads = scratch.appendingPathComponent(BlocklistStore.folderName, isDirectory: true)
        if let kept { try FileManager.default.moveItem(at: kept, to: downloads) }
        defer {
            if let kept { try? FileManager.default.moveItem(at: downloads, to: kept) }
            try? FileManager.default.removeItem(at: scratch)
        }
        // The key this run's self-test made, beside the compiled-in ones, for the takeover's bundle.
        runtime.selfTestListsKey = SelfTestBlockingFixture.coldListsKey(arguments)

        // The same shell profile at every launch, so the same engine profile on a used user data folder.
        let store = SidebarStore(defaultProfileID: SelfTestBlockingFixture.coldProfileID)
        let tab = store.addTab(kind: .today, title: "Blocking", url: SelfTestBlockingFixture.pageURL(base: serverBase, run: 1))
        store.selectTab(tab.id)
        let owner = store.profiles.first?.id
        let little = store.createLittleArcWindow(url: SelfTestBlockingFixture.pageURL(base: serverBase, run: 2), title: "Blocking", profileID: owner)
        blockingRun = 2
        if step == .off {
            // Settled before the model loads, as an existing install: its profiles stay Off. Setting
            // `.off` on a profile with no settings changes nothing (no settings already read as Off),
            // and the model's rollout then counted a new install and gave it Ads and trackers.
            store.beginContentBlockingRollout(isNewInstall: false)
        }
        // As ChromiumShell.makeModel does: the owner is named before the model loads the tab.
        runtime.legacyDefaultOwner = owner
        let model = BrowserViewModel(
            store: store,
            persistence: SidebarFilePersistence(fileURL: scratch.appendingPathComponent("sidebar.json")),
            syncEngine: LocalSyncEngine(),
            faviconStore: FaviconStore(directory: nil)
        )
        let shell = ChromiumShell(runtime: runtime, autosavesFrames: false, sessionFile: scratch.appendingPathComponent("window-session.json"))
        let shellStarted = Date()
        shell.start(model: model)
        model.contentBlocking.fetcher = SelfTestNoMirror()
        func sinceStart() -> Int { Int(Date().timeIntervalSince(shellStarted) * 1000) }
        try check(model.contentBlocking.isAvailable, "COLD-BLOCKING FAIL: blocking did not attach to the model")
        let engine = try shellEngine(model, tab)
        self.engine = engine
        let profileID = model.profileID(for: tab)
        let level = store.contentBlocking(for: profileID).level
        let wantedLevel: ContentBlockingLevel = step == .off ? .off : .adsAndTrackers
        try check(level == wantedLevel, "COLD-BLOCKING FAIL: the launch's profile is at \(level.title), not \(wantedLevel.title) "
            + "(rollout \(String(describing: store.contentBlockingRollout.install)), step \(step.rawValue))")

        // The restored pages' own loads. Their first renderers start cold.
        try await wait("the restored tab's page (title '\(engine.pageTitle ?? "nil")')", timeout: 45) {
            SelfTestBlockingFixture.Verdict(title: engine.pageTitle)?.run == 1
        }
        let loaded = sinceStart()
        try await wait("the restored Little ReArc window", timeout: 45) { shell.window(forLittleArc: little.id) != nil }
        guard let littleEngine = model.littleArcEngine(for: little.id) as? ChromiumEngine else {
            throw Failure(description: "COLD-BLOCKING FAIL: the restored Little ReArc window has no ChromiumEngine")
        }
        try await wait("the restored Little ReArc window's page (title '\(littleEngine.pageTitle ?? "nil")')", timeout: 45) {
            SelfTestBlockingFixture.Verdict(title: littleEngine.pageTitle)?.run == 2
        }
        let littleLoaded = sinceStart()
        guard let verdict = SelfTestBlockingFixture.Verdict(title: engine.pageTitle),
              let littleVerdict = SelfTestBlockingFixture.Verdict(title: littleEngine.pageTitle) else {
            throw Failure(description: "COLD-BLOCKING FAIL: a restored page's title changed under the test")
        }
        let fetched = LoopbackFixtureServer.blockingFetches(run: 1)
        let littleFetched = LoopbackFixtureServer.blockingFetches(run: 2)
        let bundle = model.contentBlocking.bundle.map { "\($0.version) (\($0.source))" } ?? "none yet"
        log("COLD-BLOCKING first loads (step \(step.rawValue)): the tab \(verdict.text) \(loaded) ms after the shell started, the "
            + "Little ReArc window \(littleVerdict.text) at \(littleLoaded) ms; the fixture server was asked for the tracker "
            + "\(fetched.tracker)+\(littleFetched.tracker) time(s) and the ad \(fetched.ad)+\(littleFetched.ad) time(s); bundle \(bundle)")

        if step == .off {
            try check(fetched.tracker > 0 && fetched.ad > 0 && littleFetched.tracker > 0 && littleFetched.ad > 0
                        && !verdict.trackerBlocked && !verdict.adBlocked && !littleVerdict.trackerBlocked && !littleVerdict.adBlocked,
                      "COLD-BLOCKING FAIL: with blocking off the restored pages did not fetch both (tab \(verdict.text), Little ReArc "
                        + "\(littleVerdict.text)): the fixture cannot show blocking")
            log("COLD-BLOCKING PASS blocking off: both restored pages fetched the tracker and the ad")
            return
        }
        guard fetched.tracker == 0, fetched.ad == 0, littleFetched.tracker == 0, littleFetched.ad == 0 else {
            // Fetched before the lists were on. When do they come on?
            let loads = try await waitForBlocking("after the cold launch", model, tab, engine, tracker: true, ad: true, timeout: 45)
            throw Failure(description: "COLD-BLOCKING FAIL (security CB-02): the restored pages fetched the tracker "
                + "\(fetched.tracker)+\(littleFetched.tracker) time(s) and the ad \(fetched.ad)+\(littleFetched.ad) time(s) "
                + "(tab at \(loaded) ms, Little ReArc window at \(littleLoaded) ms after the shell started), before the lists were on; "
                + "a later load (the \(loads + 1). of the page) was blocked at \(sinceStart()) ms. The first navigations must wait "
                + "for the blocker's lists")
        }
        try check(verdict.trackerBlocked && verdict.adBlocked && littleVerdict.trackerBlocked && littleVerdict.adBlocked,
                  "COLD-BLOCKING FAIL: the server was asked for nothing and the pages saw \(verdict.text) and \(littleVerdict.text)")
        var summary = "neither fetched on the restored pages' first loads (tab \(loaded) ms, Little ReArc window \(littleLoaded) ms "
            + "after the shell started, bundle \(bundle))"

        if step == .takeover {
            // A list update: a newer bundle arrives while the first blocker blocks.
            guard let update = SelfTestBlockingFixture.value(of: SelfTestBlockingFixture.coldUpdateFlag, in: arguments) else {
                throw Failure(description: "COLD-BLOCKING FAIL: the takeover step has no update folder")
            }
            let before = model.contentBlocking.bundle?.version
            let inUse = before.map(String.init(describing:)) ?? "none"
            // The launch's own check (no mirror) ends first: one check runs at a time.
            try await wait("the launch's list check to end", timeout: 15) { !model.contentBlocking.isCheckingLists }
            model.contentBlocking.fetcher = SelfTestFileMirror(folder: URL(fileURLWithPath: update, isDirectory: true))
            model.checkBlocklists()
            try check(model.contentBlocking.isCheckingLists, "COLD-BLOCKING FAIL: the list check did not start (blocking on somewhere: "
                + "\(store.isContentBlockingOnAnywhere), lists \(model.contentBlocking.lists == nil ? "none" : "attached"), bundle \(inUse))")
            try await wait("the list check with the update's mirror to end (bundle \(inUse))", timeout: 30) { !model.contentBlocking.isCheckingLists }
            // One check, and what it ended with: unreachable, rejected and why, or updated.
            let outcome = model.contentBlocking.lastCheck.map { "\($0)" } ?? "nothing"
            let refused = await model.contentBlocking.lists?.rejections ?? []
            log("COLD-BLOCKING list check: \(outcome); bundle \(model.contentBlocking.bundle.map { "\($0.version) (\($0.source))" } ?? "none")"
                + (refused.isEmpty ? "" : "; refused: \(refused.suffix(4).joined(separator: "; "))"))
            guard case .updated? = model.contentBlocking.lastCheck, model.contentBlocking.bundle?.version != before else {
                throw Failure(description: "COLD-BLOCKING FAIL: the list check did not bring the newer bundle: it ended with \(outcome), "
                    + "bundle \(inUse) still in use" + (refused.isEmpty ? "" : "; refused: \(refused.suffix(4).joined(separator: "; "))")
                    + "; last events: \(model.contentBlockingEvents.suffix(4).joined(separator: "; "))")
            }
            let after = model.contentBlocking.bundle.map { "\($0.version) (\($0.source))" } ?? "none"
            // Through the takeover the old blocker blocks until the new one's lists are on.
            let loads = try await waitForBlocking("during the list update", model, tab, engine, tracker: true, ad: true, timeout: 10)
            try check(loads == 1, "COLD-BLOCKING FAIL: during the list update \(loads - 1) load(s) of the page were not blocked")
            summary += "; the list check brought \(after) and the next load was blocked"
        }
        if arguments.contains(SelfTestBlockingFixture.coldCheckOffFlag) {
            // Not fetched means blocked only if the page can fetch them at all: with blocking off it must.
            // This removes the blocker, so the self-test asks for it only on a profile's last launch.
            model.setContentBlockingEnabled(false, for: profileID)
            let offLoads = try await waitForBlocking("the cold launch's fixture with blocking off", model, tab, engine, tracker: false, ad: false)
            summary += "; with blocking off both load, \(offLoads) load(s) later"
        } else {
            // The engine marks the blocker that is ready, for the next launch, when its lists are on
            // (a takeover: the new one's, after indexing). That is not visible from here: time for it.
            try await Task.sleep(for: .seconds(step == .takeover ? 10 : 4))
            if step == .takeover, model.contentBlocking.blockedHosts != nil {
                // By now blocking has moved to the second blocker: the list must still be the page's
                // (security BL-09; the next launch reads which blocker was left ready).
                _ = try await waitForBlocking("after the list update", model, tab, engine, tracker: true, ad: true, timeout: 10)
                let wanted = [SelfTestBlockingFixture.trackerHost, SelfTestBlockingFixture.adHost]
                try await wait("the blocked list after the list update", timeout: 10) { model.blockedList(for: engine)?.entries.map(\.host) == wanted }
                summary += "; after the update the blocked list still has both sites"
            }
        }
        log("COLD-BLOCKING PASS \(summary)")
    }

    /// Window › Task Manager (docs/briefs/2026-11-17-chrome-features.md).
    /// Opening it twice shows one window. Its reading lists ReArc first, the
    /// GPU process and a page of this step as "Tab: <title>" in a process
    /// of its own; the next reading has CPU figures; the segments and the
    /// search narrow the rows as Chrome's do. Closing the window stops the
    /// readings. End task on the page's renderer leaves the tab crashed, as
    /// in Chrome, and takes the process off the list. An engine without
    /// `task_manager` logs what the rows lack.
    @MainActor
    private func taskManagerChecks(model: BrowserViewModel, store: SidebarStore, window: NSWindow) async throws {
        let pageTitle = "search results"
        let previous = store.selectedTab?.id
        let (tab, engine) = try openFixtureTab(model, store, title: "Task manager page", path: "/search")
        let manager = model.taskManager
        let saved = (category: manager.category, search: manager.search, sort: manager.sort)
        defer {
            model.taskManagerWindow?.close()
            manager.category = saved.category
            manager.search = saved.search
            manager.sort = saved.sort
            manager.selection = []
            model.closeTab(tab.id)
            if let previous { model.selectTab(previous) }
            window.makeKeyAndOrderFront(nil)
        }
        try await wait("task manager page loaded", timeout: 15) { engine.pageTitle == pageTitle && !engine.isLoading }

        try check(!manager.isPolling, "the Task Manager reads the engine before its window is shown")
        model.showTaskManager()
        model.showTaskManager()
        // Its own windows only: a browser window can carry a page's title.
        let shown = NSApp.windows.filter { $0.isVisible && $0.windowController is TaskManagerWindowController }
        try check(shown.count == 1 && manager.isPolling, "Task Manager opened twice: \(shown.count) windows, reading \(manager.isPolling)")
        manager.category = .all
        manager.search = ""
        manager.sort = nil
        func rows() -> String { manager.rows.map { "\($0.pid) \($0.title)" }.joined(separator: " | ") }
        // By its engine tab, not its title: another page of this run may be called the same.
        func pageRow() -> TaskManagerRow? { manager.rows.first { $0.icon == .tab(engine.tabID) } }
        try await wait("the Task Manager's reading with the page", timeout: 10) { pageRow()?.title == "Tab: \(pageTitle)" }
        guard let row = pageRow(), let group = manager.groups.first(where: { $0.pid == row.pid }) else {
            throw Failure(description: "no row for the page: \(rows())")
        }
        try check(manager.rows.filter { $0.icon == .tab(engine.tabID) }.count == 1, "a page of one frame has more than one row: \(rows())")
        try check(manager.rows.first?.title == "Browser" && manager.rows.first?.pid == getpid() && manager.rows.first?.isKillable == false,
                  "All tasks starts with ReArc itself: \(rows())")
        try check(manager.rows.contains { $0.title == "GPU Process" }, "All tasks has no GPU process: \(rows())")
        try check(row.pid != getpid() && row.isKillable && row.memoryFootprint > 0,
                  "the page's row: pid \(row.pid) killable \(row.isKillable) memory \(row.memoryFootprint)")
        try await wait("CPU figures from the second reading", timeout: 10) {
            manager.rows.first?.usage.cpuPercent != nil && manager.groups.first { $0.pid == row.pid }?.usage.cpuPercent != nil
        }

        manager.category = .tabsAndExtensions
        try check(manager.rows.contains { $0.id == row.id } && !manager.rows.contains { $0.title == "Browser" || $0.title == "GPU Process" },
                  "Tabs and extensions: \(rows())")
        manager.category = .browser
        try check(manager.rows.first?.title == "Browser" && !manager.rows.contains { $0.title.hasPrefix("Tab: ") }, "Browser: \(rows())")
        manager.category = .all
        manager.search = "SEARCH res"
        try check(manager.rows.contains { $0.id == row.id } && !manager.rows.contains { $0.title == "Browser" || $0.title == "GPU Process" },
                  "search for the page's title: \(rows())")
        manager.search = ""

        if runtime.capabilities.taskManager {
            try await wait("network figures", timeout: 10) { manager.rows.first?.usage.networkBytesPerSecond != nil }
            try check(manager.rows.contains { $0.title.hasPrefix("Utility: ") }, "no utility process is named: \(rows())")
        } else {
            try check(manager.rows.first?.text(for: .network) == "–", "Network without task_manager shows \(manager.rows.first?.text(for: .network) ?? "nil")")
            log("ABI-GAP task_manager not advertised (ABI minor \(runtime.capabilities.abiMinorVersion.map(String.init) ?? "absent") < 65): "
                + "the Task Manager's Network column shows –, a tab is listed in every process with one of its frames, "
                + "and extensions and the spare renderer have no names")
        }

        // Closed, the window reads nothing; opened again, it reads again.
        model.taskManagerWindow?.close()
        try check(!manager.isPolling, "the Task Manager still reads the engine after its window closed")
        model.showTaskManager()
        try check(manager.isPolling, "the Task Manager does not read after its window opened again")

        // End task, only when the page has its renderer to itself: the other
        // pages of this run must stay up.
        guard group.tabTitles == [pageTitle] else {
            log("NOTE task manager: the page shares process \(row.pid) with \(group.tabTitles); End task not exercised")
            log("PASS task manager: one window, ReArc first, GPU process, the page's row with memory and CPU, segments, search, no reading while closed")
            return
        }
        try await wait("the page's process listed again", timeout: 10) { manager.groups.contains { $0.pid == row.pid } }
        manager.selection = [getpid()]
        try check(!manager.canEndSelection, "End task is on for ReArc itself")
        manager.selection = [row.pid]
        try check(manager.canEndSelection, "End task is off for the page's process")
        var asked = false
        manager.endSelection { _, answer in
            asked = true
            answer(false)
        }
        try check(!asked, "End task asked before ending a process with one tab")
        try await wait("the page crashed after End task", timeout: 10) { engine.isCrashed }
        try await wait("the ended process off the list", timeout: 10) { !manager.groups.contains { $0.pid == row.pid } }
        try check(manager.selection.isEmpty, "the ended process is still selected")
        log("PASS task manager: one window, ReArc first, GPU process, the page's row with memory and CPU, segments, search, "
            + "no reading while closed, End task left the tab crashed and took process \(row.pid) off the list")
    }

    /// H.264/AAC (media/001, security RC-811 AD-02): a clip the page records
    /// itself plays with src= and through MediaSource, and a damaged copy
    /// neither hangs nor takes the renderer down. An engine without
    /// proprietary codecs is a gap in a dev build and a failure in a release.
    @MainActor
    private func codecChecks(model: BrowserViewModel, store: SidebarStore) async throws {
        try await withFixtureTab(model, store, title: "Codecs", path: "/codecs") { _, engine in
            try await wait("codecs fixture finished", timeout: 40) {
                engine.pageTitle == "codecs-done" || engine.pageTitle?.hasPrefix("codecs-err") == true
            }
            if engine.pageTitle == "codecs-err:no-mp4-recorder" {
                let release = ShippedBuild.isRelease(infoDictionary: Bundle.main.infoDictionary)
                try check(!release, "release engine has no H.264 MediaRecorder (proprietary codecs off?)")
                log("ABI-GAP codecs: this engine records no H.264 MP4 (built without proprietary codecs)")
                return
            }
            let json = (try? await engine.evaluate("JSON.stringify(window.codecs)", in: .page)) as? String ?? "{}"
            let result = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            let src = result["src"] as? String, mse = result["mse"] as? String, damaged = result["damaged"] as? String ?? ""
            try check(src == "ok", "H.264 src= playback: \(src ?? "nil") (\(json))")
            try check(mse == "ok", "H.264 MediaSource playback: \(mse ?? "nil") (\(json))")
            try check(damaged == "ok" || damaged.hasPrefix("error:") || damaged.hasPrefix("timeout:"),
                      "damaged clip: \(damaged)")
            try await checkRendererAlive(engine, after: "the damaged clip")
            log("PASS codecs: \(result["mime"] as? String ?? "?") \(result["bytes"] ?? "?") bytes, audio \(result["audio"] ?? "?"); "
                + "src= \(src ?? ""), MediaSource \(mse ?? ""), damaged copy \(damaged), renderer alive")
        }
    }

    /// Wave 32 (ABI 1.43): switching away from a playing video shows its strip
    /// and the live video in the sidebar, the video keeps presenting frames
    /// while its tab is hidden, pause and play work through the strip, the
    /// same view moves to the floating panel, minimizes into the strip and
    /// comes back, and closing the tab removes both. No synthesized input.
    /// The card and the panel must show the video on screen, read from the
    /// screen (the compositor's own copy changed while the owner saw black).
    @MainActor
    private func liveVideoChecks(model: BrowserViewModel, store: SidebarStore, home: Tab, homeEngine: ChromiumEngine, other: Tab, window: NSWindow,
                                 path: String = "/pip") async throws {
        let embeds = model.embedsVideoInSidebar, automatic = model.automaticPictureInPicture
        model.embedsVideoInSidebar = true
        // Video in Sidebar alone enters PiP on the switch away; no occlusion trigger.
        model.automaticPictureInPicture = false
        defer {
            model.embedsVideoInSidebar = embeds
            model.automaticPictureInPicture = automatic
        }
        let (tab, engine) = try openFixtureTab(model, store, title: "Live video \(path)", path: path)
        try await wait("live video fixture playing", timeout: 25) {
            engine.pageTitle == "pip-playing" || engine.pageTitle?.hasPrefix("pip-err") == true
        }
        try check(engine.pageTitle == "pip-playing", "live video fixture \(path): '\(engine.pageTitle ?? "")'")
        let decoding = ((try? await engine.evaluate("window.hw", in: .page)) as? String) ?? "software (VP8 blob)"
        try await wait("pip_available for the live video tab", timeout: 15) { model.mediaState(for: tab.id).canPictureInPicture }
        try check(!model.mediaStrips(in: nil).contains(tab.id), "a strip showed while its tab is on screen")

        // 1. Switch away: the strip and the live video in the sidebar.
        model.selectTab(other.id)
        try await wait("live video in the sidebar after switching away", timeout: 10) {
            model.sidebarLiveVideoTabID(in: nil) == tab.id && engine.videoOverlay?.view.window === window
        }
        guard let video = engine.videoOverlay else { throw Failure(description: "no overlay for the live video tab") }
        try check(model.mediaStrips(in: nil).contains(tab.id), "no strip for the hidden playing tab")
        let info = model.mediaStripInfo(for: tab.id)
        try check(info?.isPlaying == true && info?.canPreviousTrack == false && info?.canNextTrack == false,
                  "strip state: playing \(String(describing: info?.isPlaying)), previous \(String(describing: info?.canPreviousTrack)), next \(String(describing: info?.canNextTrack))")
        let size = video.view.bounds.size
        try check(abs(size.width - (model.sidebarWidth - 16)) < 1.5, "the live video is \(size.width) pt wide, not the sidebar's width less 16")
        let firstFrame = await eventually(timeout: 5) { video.hasFirstFrame }

        // 2. Frames keep coming at the video's rate while the tab is hidden: the page's
        // requestVideoFrameCallback count, and pixels read back from the view's own
        // composited output (the fixture's colour changes every 50 ms).
        func rvfc() async -> Double { ((try? await engine.evaluate("window.rvfc", in: .page)) as? NSNumber)?.doubleValue ?? -1 }
        func pixel() async -> UInt32? {
            await withCheckedContinuation { continuation in video.readPixel { continuation.resume(returning: $0) } }
        }
        let rvfc1 = await rvfc(), start = Date()
        var pixels: [UInt32?] = []
        for _ in 0 ..< 4 {
            pixels.append(await pixel())
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let rvfc2 = await rvfc(), seconds = Date().timeIntervalSince(start)
        let videoRate = (rvfc2 - rvfc1) / seconds
        let read = pixels.compactMap { $0 }
        let pixelsChanged = Set(read).count > 1
        // Not black: the video, not the letterbox or an empty surface.
        let showsVideo = read.contains { ($0 >> 8) & 0xFFFFFF > 0x101010 }
        liveFramesAdvancing = rvfc2 > rvfc1 && pixelsChanged && showsVideo
        let hex = pixels.map { $0.map { String(format: "%08X", $0) } ?? "none" }.joined(separator: ",")
        log(String(format: "live video frames: requestVideoFrameCallback %.0f -> %.0f (%.1f fps), view pixels %@, first CALayer update %@",
                   rvfc1, rvfc2, videoRate, hex, firstFrame ? "yes" : "no"))
        try check(rvfc2 > rvfc1, "the hidden tab's video presented no frames (requestVideoFrameCallback \(rvfc1) -> \(rvfc2))")
        try check(read.count == pixels.count, "the view's output could not be read back: \(hex)")
        try check(showsVideo && pixelsChanged, "the view's pixels did not advance with the video: \(hex)")
        let cardScreen = try await onScreenVideo(video.view, label: "the sidebar card (\(path), \(decoding))")
        try check(!model.blankLiveVideos.contains(tab.id), "the shell judged the sidebar card blank though it shows the video")

        // 3. Pause and play through the strip; the paused strip stays.
        model.mediaTogglePlayPause(tab.id)
        try await wait("paused from the strip", timeout: 10) { !video.isPlaying && model.mediaState(for: tab.id).isPaused }
        try check(model.mediaStrips(in: nil).contains(tab.id) && model.sidebarLiveVideoTabID(in: nil) == tab.id,
                  "pausing removed the strip or the live video")
        model.mediaTogglePlayPause(tab.id)
        try await wait("playing again from the strip", timeout: 10) { video.isPlaying && model.mediaState(for: tab.id).isPlaying }

        // 4. Pop out to the panel, minimize into the strip, Open Picture in Picture, dock.
        let overlayID = video.overlayID, eventsBefore = runtime.videoOverlayEvents.count
        model.popOutLiveVideo(tab.id)
        try await wait("popped out to the floating panel", timeout: 5) {
            model.livePanel.isShowing && video.view.window === model.livePanel.window
        }
        try check(model.mediaStrips(in: nil).contains(tab.id), "no strip beside the floating panel")
        let panelScreen = try await onScreenVideo(video.view, label: "the floating panel (\(path), \(decoding))")
        model.minimizeLiveVideo(tab.id)
        try await wait("minimized into the strip", timeout: 5) {
            !model.livePanel.isShowing && model.mediaStrips(in: nil).contains(tab.id)
        }
        try check(model.mediaStripInfo(for: tab.id)?.offersPictureInPicture == true, "the minimized strip offers no Open Picture in Picture")
        model.openPictureInPicture(tab.id)
        try await wait("Open Picture in Picture brought the panel back", timeout: 5) { model.livePanel.isShowing }
        model.dockLiveVideo(tab.id)
        try await wait("docked back in the sidebar", timeout: 5) { video.view.window === window && !model.livePanel.isShowing }
        let moves = runtime.videoOverlayEvents.dropFirst(eventsBefore).filter { $0.overlayID == overlayID }
        try check(engine.videoOverlay?.overlayID == overlayID && !moves.contains { $0.kind == .hidden || $0.kind == .closed },
                  "moving the video ended its session: \(moves.map { "\($0.kind)" })")

        // 5. Closing the tab removes the live video and the strip.
        let engineTabID = engine.tabID
        model.closeTab(tab.id)
        try await wait("closing the tab removed the live video", timeout: 10) {
            !runtime.videoOverlays.values.contains { $0.tabID == engineTabID }
                && model.sidebarLiveVideoTabID(in: nil) == nil && !model.mediaStrips(in: nil).contains(tab.id)
        }
        // Closing selected a neighbour; the later checks expect tab A.
        model.selectTab(home.id)
        try await wait("tab A shown after the live video checks") {
            homeEngine.leaseHolder?.window === window && homeEngine.attachmentID != nil
        }
        log("PASS live video and media strip (ABI 1.43, \(path), \(decoding) decoding): switch away -> strip + sidebar video \(Int(size.width))x\(Int(size.height)); "
            + "on screen: card \(cardScreen), panel \(panelScreen); "
            + String(format: "hidden tab at %.1f fps (rVFC) with the view's pixels changing (%@); ", videoRate, hex)
            + "strip pause/play kept the strip; pop-out, minimize, Open Picture in Picture and dock kept overlay \(overlayID); "
            + "tab close removed it; frames_advancing=\(liveFramesAdvancing ? "yes" : "no")")
    }
}

extension ChromiumSelfTest {
    /// The live video as it is on screen: a 3 x 3 grid inside `view`, read
    /// twice 400 ms apart from a ScreenCaptureKit picture of its window. The
    /// overlay's read-back (`readPixel`) is the compositor's own copy, which
    /// changed while the owner's panel was black; this reads what is shown.
    /// Throws when the screen cannot be read: a black player must not pass.
    @MainActor
    private func onScreenVideo(_ view: NSView, label: String) async throws -> String {
        // The release bundle has no Screen Recording grant and the gate must not ask for one:
        // without it the screen goes unchecked, said plainly in the log (the compositor's copy
        // alone passed on black in 677, so the release notes for a build say when this was skipped).
        guard CGPreflightScreenCaptureAccess() else {
            log("SCREEN NOT CHECKED: \(label): no Screen Recording access, so only the compositor's copy was read")
            return "screen not checked"
        }
        guard let window = view.window else { throw Failure(description: "\(label): the video view is in no window") }
        func capture() async throws -> [UInt32] {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw Failure(description: "\(label): its window is not on screen")
            }
            let scale = window.backingScaleFactor
            let config = SCStreamConfiguration()
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
                                                                   configuration: config)
            let width = image.width, height = image.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            // The view's rect in the picture: window points, top-left origin, scaled.
            let rect = view.convert(view.bounds, to: nil)
            let sx = Double(width) / window.frame.width, sy = Double(height) / window.frame.height
            var grid: [UInt32] = []
            for fx in [0.3, 0.5, 0.7] {
                for fy in [0.3, 0.5, 0.7] {
                    let x = Int((rect.minX + rect.width * fx) * sx)
                    let y = Int((window.frame.height - (rect.minY + rect.height * fy)) * sy)
                    guard (0 ..< width).contains(x), (0 ..< height).contains(y) else { continue }
                    let i = (y * width + x) * 4
                    grid.append(UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | 0xFF)
                }
            }
            return grid
        }
        let first = try await capture()
        try await Task.sleep(nanoseconds: 400_000_000)
        let second = try await capture()
        let hex = (first + second).map { String(format: "%08X", $0) }.joined(separator: ",")
        let black = !first.isEmpty && (first + second).allSatisfy(LiveVideoDrawing.isBlack)
        try check(!first.isEmpty, "\(label): the video view lies outside its window's picture")
        try check(!black, "\(label) is black on screen (\(hex)) while the compositor's copy shows the video: "
                  + "the engine's CALayer presentation of the frames fails, not their decoding")
        try check(first != second, "\(label) is frozen on screen (\(hex))")
        return "\(first.count) points changing"
    }
}

// MARK: - Wave 27: extensions, autofill, leak check, HTTP auth (ABI 1.31–1.38)

/// Local unpacked MV3 fixtures for `--load-extension` (as engine/tests
/// run_c_abi.py "act" and "click"): never a Web Store install.
enum SelfTestExtensionFixture {
    static let popupName = "ReArc selftest popup"
    static let popupTitle = "ReArc selftest action"
    static let clickName = "ReArc selftest click"
    static let frontName = "ReArc selftest front"
    /// How long the front fixture runs after a click on its action.
    static let frontRun: TimeInterval = 15
    static let floodName = "ReArc selftest flood"
    /// How many tabs the flood fixture asks for at once: over `ExtensionTabRate.limit`.
    static let floodBurst = ExtensionTabRate.limit + 5
    static let popupSize = CGSize(width: 320, height: 180)

    /// Writes the fixtures into a fresh temp directory; their paths for `--load-extension`.
    /// The name is random and the directory owner-only, so it cannot be prepared or found
    /// by its name in advance (security RC-0.1.0-544 F-03); the profile they load into is
    /// always a new one in a release build (`ReleaseVerificationDataDir`).
    static func write() -> [URL] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-selftest-extensions-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let popup = root.appendingPathComponent("popup"), click = root.appendingPathComponent("click")
        let front = root.appendingPathComponent("front"), flood = root.appendingPathComponent("flood")
        func file(_ dir: URL, _ name: String, _ text: String) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: dir.appendingPathComponent(name))
        }
        file(popup, "manifest.json", """
        {"name":"\(popupName)","version":"1.0","manifest_version":3,"background":{"service_worker":"bg.js"},
         "action":{"default_title":"\(popupTitle)","default_popup":"popup.html","default_icon":{"16":"icon16.png","32":"icon32.png"}}}
        """)
        file(popup, "bg.js", """
        const badge = () => { chrome.action.setBadgeText({text: '7'}); chrome.action.setBadgeBackgroundColor({color: '#ff0000'}); };
        chrome.runtime.onInstalled.addListener(badge); chrome.runtime.onStartup.addListener(badge); badge();
        """)
        // 320x180 of content; it reports its view type and closes itself (window.close()).
        file(popup, "popup.html", """
        <!doctype html><title>popup</title><body style="margin:0"><div style="width:\(Int(popupSize.width))px;height:\(Int(popupSize.height))px;background:#2a6">popup</div>
        <script src="popup.js"></script>
        """)
        file(popup, "popup.js", "document.title = 'popup:' + chrome.extension.getViews({type: 'popup'}).length; setTimeout(() => window.close(), 3000);")
        for size in [16, 32] { try? png(size).write(to: popup.appendingPathComponent("icon\(size).png")) }
        file(click, "manifest.json", """
        {"name":"\(clickName)","version":"1.0","manifest_version":3,"background":{"service_worker":"bg.js"},"action":{"default_title":"\(clickName)"}}
        """)
        // First click: tabs.create with what Chromium sees as the active tab and window;
        // later clicks: uninstallSelf with its confirmation (the host's prompt; the self-test cancels).
        file(click, "bg.js", """
        let clicks = 0;
        chrome.action.onClicked.addListener(async (tab) => {
          clicks += 1;
          if (clicks > 1) { chrome.management.uninstallSelf({showConfirmDialog: true}).catch(() => {}); return; }
          const [cur] = await chrome.tabs.query({active: true, currentWindow: true});
          const win = await chrome.windows.getCurrent();
          const info = {cur: cur ? cur.id : null, clicked: tab.id, win: win.id, winTab: tab.windowId};
          chrome.tabs.create({url: chrome.runtime.getURL('page.html') + '#' + encodeURIComponent(JSON.stringify(info))});
        });
        """)
        file(click, "page.html", "<!doctype html><title>ext-page</title><script src=\"page.js\"></script>")
        file(click, "page.js", "document.title = 'ext-page' + decodeURIComponent(location.hash.slice(1));")
        file(front, "manifest.json", """
        {"name":"\(frontName)","version":"1.0","manifest_version":3,"background":{"service_worker":"bg.js"},"action":{"default_title":"\(frontName)"}}
        """)
        // Wants its tab in front, as an automation extension does for a tab its client asked for
        // (owner's report 2026-11-22): for `frontRun` seconds after a click on its action, whenever
        // no window of its profile is focused it opens a blank tab in its window and makes it the
        // active one. Loaded into every profile, as an extension installed in two profiles is.
        file(front, "bg.js", """
        let timer = null, left = 0, busy = false;
        async function tick() {
          if (--left <= 0) { clearInterval(timer); timer = null; }
          if (busy) return;
          busy = true;
          try {
            const wins = await chrome.windows.getAll();
            if (!wins.some((w) => w.focused)) {
              const win = await chrome.windows.getLastFocused({windowTypes: ['normal']});
              const tab = await chrome.tabs.create({windowId: win.id, url: 'chrome://newtab', active: false});
              await chrome.tabs.update(tab.id, {active: true});
            }
          } catch (e) {}
          busy = false;
        }
        chrome.action.onClicked.addListener(() => {
          if (timer) return;
          left = \(Int(frontRun * 4));
          timer = setInterval(tick, 250);
        });
        """)
        file(flood, "manifest.json", """
        {"name":"\(floodName)","version":"1.0","manifest_version":3,"background":{"service_worker":"bg.js"},"permissions":["tabs"],
         "action":{"default_title":"\(floodName)"}}
        """)
        // A client that asks by itself (security RC-2026.1122.1231 FX-01, FX-02). Its badge says what
        // it did last, and so what the next click does: the first three clicks each ask for a window of
        // the clicked tab's site (`w1` made, `w0` failed), every later one asks for `floodBurst` tabs
        // with an address at once and shows how many were made and how many failed (`10/5`).
        file(flood, "bg.js", """
        chrome.action.onClicked.addListener(async (tab) => {
          const done = await chrome.action.getBadgeText({});
          let base;
          try { base = new URL(tab.url).origin; } catch (e) { chrome.action.setBadgeText({text: 'nourl'}); return; }
          if (!done.startsWith('w') || done.length < 6) {
            let made = '0';
            try { await chrome.windows.create({url: base + '/a?flood=window' + done.length}); made = '1'; } catch (e) {}
            chrome.action.setBadgeText({text: done + 'w' + made});
            return;
          }
          const asked = [];
          for (let i = 0; i < \(floodBurst); i++) asked.push(chrome.tabs.create({url: base + '/a?flood=' + i, active: false}));
          const answers = await Promise.allSettled(asked);
          const made = answers.filter((answer) => answer.status === 'fulfilled').length;
          chrome.action.setBadgeText({text: made + '/' + (answers.length - made)});
        });
        """)
        return [popup, click, front, flood]
    }

    private static func png(_ size: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 0.82, green: 0.19, blue: 0.19, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}

/// Records extension prompts and cancels each (nothing is removed or installed).
final class SelfTestExtensionPrompts: ExtensionPromptPresenting {
    final class Handle: ExtensionPromptHandle {
        var closed = false
        func close() { closed = true }
    }

    private(set) var requests: [ExtensionPromptRequest] = []

    func present(_ request: ExtensionPromptRequest, in window: NSWindow?,
                 completion: @escaping (ExtensionPromptAction) -> Void) -> ExtensionPromptHandle? {
        requests.append(request)
        DispatchQueue.main.async { completion(.cancel) }
        return Handle()
    }
}

extension ChromiumSelfTest {
    private var minorText: String { runtime.capabilities.abiMinorVersion.map(String.init) ?? "absent" }

    /// ABI 1.35: default on, round trip, then off for every self-test profile.
    @MainActor
    fileprivate func leakDetectionChecks() throws {
        guard runtime.capabilities.passwordLeakDetection else {
            log("ABI-GAP password_leak_detection not advertised (ABI minor \(minorText) < 35): no Check Passwords for Leaks toggle")
            return
        }
        let profile = runtime.defaultProfileID
        let initial = runtime.passwordLeakDetection(profile: profile)
        try check(initial.status == .rearcOK && initial.enabled && !initial.managed,
                  "leak detection default: \(initial.status.rearcName) enabled \(initial.enabled) managed \(initial.managed)")
        try check(runtime.setPasswordLeakDetection(profile: profile, enabled: false) == .rearcOK, "turning the leak check off failed")
        let off = runtime.passwordLeakDetection(profile: profile)
        try check(off.status == .rearcOK && !off.enabled, "leak detection after set off: \(off.enabled)")
        // In memory only (never the user's defaults): profiles opened later get it off too.
        runtime.leakDetectionPreference.explicitChoice = false
        runtime.openPersistentEngineProfiles.forEach(runtime.applyLeakDetectionPreference(profile:))
        let invalid = runtime.passwordLeakDetection(profile: 0).status
        try check(invalid != .rearcOK, "leak detection on profile 0 returned ok")
        log("PASS password leak check (ABI 1.35): default on (not managed), set off -> off, profile 0 -> \(invalid.rearcName); "
            + "off for all \(runtime.openPersistentEngineProfiles.count) open self-test profile(s) and those opened later")
    }

    @MainActor
    fileprivate func wave27ShellChecks(model: BrowserViewModel, store: SidebarStore, shell: ChromiumShell, tab: Tab,
                                       engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        if runtime.capabilities.passwordLeakDetection {
            // Wave 35: the switch moved from the ReArc menu to Settings › Advanced.
            let leakCheck = shell.settingsCapabilities().passwordLeakCheck
            try check(leakCheck != nil, "Settings › Advanced has no password leak switch")
            try check(leakCheck?.wrappedValue == false, "the switch does not show the self-test's off value")
            log("PASS Settings › Advanced password leak switch reads the profile's value (off in the self-test)")
        }
        try await extensionChecks(model: model, store: store, shell: shell, tab: tab, engine: engine)
        try await extensionFocusChecks(model: model, store: store, shell: shell, tab: tab, engine: engine, base: base)
        try await autofillChecks(model: model, store: store, tab: tab, engine: engine, base: base, window: window)
        try await httpAuthChecks(model: model, tab: tab, engine: engine, base: base)
        try await linkOpenChecks(model: model, store: store, tab: tab, engine: engine, base: base, window: window)
        model.selectTab(tab.id)
        loadShellTab(model, tab, engine, URL(string: "\(base)/a")!)
        try await wait("tab A after the wave 27 checks") { engine.pageTitle == Self.titleA && !engine.isLoading }
    }

    // MARK: P3.14: sidebar on the right

    /// Settings › General › Sidebar position: on the right the sidebar's list
    /// sits at the window's right edge and the page beside it on the left;
    /// back on the left, as before.
    @MainActor
    fileprivate func sidebarSideChecks(model: BrowserViewModel, engine: ChromiumEngine, window: NSWindow) async throws {
        let original = model.sidebarSide
        guard let content = window.contentView else { throw Failure(description: "no content view") }
        func sidebarTables() -> [CGRect] {
            func tables(in view: NSView) -> [NSTableView] {
                ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables(in:))
            }
            return tables(in: content).filter { !$0.isHiddenOrHasHiddenAncestor }
                .map { $0.enclosingScrollView ?? $0 }
                .map { $0.convert($0.bounds, to: nil) }
                .filter { $0.width > 0 && $0.intersects(content.bounds) }
        }
        let width = content.bounds.width
        let sidebar = model.sidebarWidth(in: model.store.keyWindowID)
        for side in [SidebarSide.right, .left] {
            model.setSidebarSide(side)
            try await wait("the sidebar moved \(side.rawValue)", timeout: 5) { model.sidebarSide == side && model.sidebarFlipOpacity == 1 }
            try await Task.sleep(nanoseconds: 400_000_000)
            let frames = sidebarTables()
            try check(!frames.isEmpty, "no sidebar list on screen with the sidebar on the \(side.rawValue)")
            let page = engine.leaseHolder.map { $0.convert($0.bounds, to: nil) } ?? .zero
            switch side {
            case .right:
                try check(frames.allSatisfy { $0.minX >= width - sidebar - 1 }, "the sidebar's list is at \(frames), not the right \(sidebar) pt")
                try check(page.maxX <= width - sidebar + 1 && page.minX < sidebar, "the page is at \(page), not left of the sidebar")
            case .left:
                try check(frames.allSatisfy { $0.maxX <= sidebar + 1 }, "the sidebar's list is at \(frames), not the left \(sidebar) pt")
                try check(page.minX >= sidebar - 1, "the page is at \(page), not right of the sidebar")
            }
        }
        model.setSidebarSide(original)
        try await wait("the sidebar back on the \(original.rawValue)", timeout: 5) { model.sidebarSide == original && model.sidebarFlipOpacity == 1 }
        log("PASS sidebar position: Right puts the sidebar's list at the window's right edge and the page left of it; Left puts them back")
    }

    // MARK: Wave 28: Library, themes, Boosts v2, capture

    @MainActor
    fileprivate func wave28ShellChecks(model: BrowserViewModel, store: SidebarStore, tab: Tab,
                                       engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        model.selectTab(tab.id)
        let key = store.keyWindowID

        // Library: View > View Media turns the key window's sidebar into the Library, with the
        // page still beside it; Spaces is the rail alone; showing the tab again leaves.
        let viewTitles = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items.map(\.title) ?? []
        try check(viewTitles.contains("View Library") && viewTitles.contains("View Easels & Notes"), "View menu: \(viewTitles)")
        let restingWidth = model.sidebarWidth(in: key)
        ShellMenus.library(model).flatMap { $0 }.first { $0.title == "View Media" }?.action()
        try check(model.librarySection(in: key) == .media, "View Media showed \(String(describing: model.librarySection(in: key)))")
        try check(model.sidebarWidth(in: key) >= CGFloat(LibrarySidebarLayout.railWidth + LibrarySidebarLayout.columnWidth),
                  "the Library sidebar is \(model.sidebarWidth(in: key)) pt wide")
        try check(model.selectedTab(in: key)?.id == tab.id, "the page left the main frame")
        ShellMenus.library(model).flatMap { $0 }.first { $0.title == "View Spaces" }?.action()
        try check(model.sidebarWidth(in: key) == CGFloat(LibrarySidebarLayout.railWidth), "Spaces kept the column")
        model.selectTab(tab.id)
        try check(model.librarySection(in: key) == nil, "a sidebar click left the Library open")
        try check(model.sidebarWidth(in: key) == restingWidth, "the sidebar stayed \(model.sidebarWidth(in: key)) pt wide")
        log("PASS Library: View > View Media opens the Library in the key window's sidebar beside the page; Spaces is the rail; selecting the tab closes it")

        try await sidebarSideChecks(model: model, engine: engine, window: window)

        // Gradient theme with Dark appearance: the window turns dark; back to the plain theme, it follows the Mac.
        let space = store.activeSpaceID
        let original = store.activeSpace.theme
        var dark = SpaceTheme.gradientPresets[1]
        dark.noise = 0.3
        dark.appearance = .dark
        store.setSpaceTheme(space, theme: dark)
        try await wait("the window takes the space's Dark appearance", timeout: 5) { window.appearance?.name == .darkAqua }
        let records = SidebarSyncProjection.extract(store.makeSnapshot())
        try check(records[SyncRecordKind.spaceStyle.recordName(for: space)] != nil, "no style record for the gradient space")
        store.setSpaceTheme(space, theme: original)
        try await wait("the window follows the Mac again", timeout: 5) { window.appearance == nil }
        log("PASS gradient theme: Dark appearance sets the window's (darkAqua), the style syncs in its own record, Automatic clears it")

        // Boosts v2: a visual boost (dark mode, a zap, bigger text) compiled to CSS applies on Chromium.
        loadShellTab(model, tab, engine, URL(string: "\(base)/a")!)
        try await wait("tab A for the Boosts v2 check") { engine.pageTitle == Self.titleA && !engine.isLoading }
        var visual = BoostVisualStyle(darkMode: true, textScale: 1.25)
        visual.appendZap("p")
        let visualBoost = BoostPackage.newStyle(
            name: "Selftest visual",
            hostScope: [BoostHostRule(host: "127.0.0.1", hostMatch: .exact, pathPrefix: "/a", schemes: ["http"])],
            css: BoostVisualStyle.compose(visual, customCSS: "")
        )
        // Each check runs on the reloaded document: one made before the reload
        // committed passed on the old page and left the removal racing the
        // reload (rc562). The marker lives only in the old document.
        func reloadAfterInstall(_ label: String, since installs: Int) async throws {
            try await wait("\(label) acknowledged", timeout: 10) { engine.boostInstallCount > installs }
            _ = try await engine.evaluate("window.rearcBeforeReload = true", in: .page)
            engine.reload(ignoringCache: false)
            try await waitAsync("page A reloaded after \(label)", timeout: 15) {
                let fresh = (try? await engine.evaluate("window.rearcBeforeReload !== true", in: .page) as? Bool) ?? false
                return fresh && engine.pageTitle == Self.titleA && !engine.isLoading
            }
        }
        let addInstalls = engine.boostInstallCount
        try check(store.addBoost(visualBoost) == nil, "the visual boost was refused")
        model.syncAllTabBoosts()
        try await reloadAfterInstall("the visual boost install", since: addInstalls)
        var applied = ""
        try await waitAsync("the visual boost on page A", timeout: 15) {
            applied = (try? await engine.evaluate(
                "getComputedStyle(document.querySelector('p')).display + '|' + getComputedStyle(document.documentElement).filter",
                in: .page) as? String) ?? ""
            return applied.hasPrefix("none|") && applied.contains("invert")
        }
        let removeInstalls = engine.boostInstallCount
        store.removeBoost(packageID: visualBoost.manifest.id)
        model.syncAllTabBoosts()
        try await reloadAfterInstall("the visual boost removal", since: removeInstalls)
        try await waitAsync("page A without the visual boost", timeout: 15) {
            let display = (try? await engine.evaluate("getComputedStyle(document.querySelector('p')).display", in: .page) as? String) ?? ""
            return display == "block" && engine.pageTitle == Self.titleA
        }
        // The rc562 race on purpose: the removal replaces the plan while a
        // reload is navigating. The engine may refuse it then; the shell
        // retries once the tab settles, so the boost still goes.
        let raceInstalls = engine.boostInstallCount
        try check(store.addBoost(visualBoost) == nil, "the visual boost was refused the second time")
        model.syncAllTabBoosts()
        try await wait("the re-added visual boost acknowledged", timeout: 10) { engine.boostInstallCount > raceInstalls }
        engine.reload(ignoringCache: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        let racing = engine.boostInstallCount
        store.removeBoost(packageID: visualBoost.manifest.id)
        model.syncAllTabBoosts()
        try await reloadAfterInstall("the removal during a reload", since: racing)
        try await waitAsync("page A without the visual boost after the race", timeout: 15) {
            let display = (try? await engine.evaluate("getComputedStyle(document.querySelector('p')).display", in: .page) as? String) ?? ""
            return display == "block" && engine.pageTitle == Self.titleA
        }
        log("PASS Boosts v2: dark mode, a zap and text size compiled into the stylesheet apply on Chromium ('\(applied)'), and go with the boost")

        // Capture: the overlay needs a page; a region and the clicked element crop the viewport snapshot; portrait frames it.
        model.isCapturePreviewPresented = false
        try check(model.beginPageCapture() == nil && model.pageCaptureSession?.tabID == tab.id, "Capture did not start over tab A")
        model.cancelPageCapture()
        let viewport = try await engine.captureSnapshot(scope: .visible)
        let full = try XCTUnwrapImage(viewport, "viewport snapshot")
        let region = try XCTUnwrapImage(CaptureImaging.crop(viewport, to: CaptureRect(x: 0, y: 0, width: 0.5, height: 0.5)), "region crop")
        try check(abs(region.width * 2 - full.width) <= 2 && abs(region.height * 2 - full.height) <= 2,
                  "region \(region.width)x\(region.height) of \(full.width)x\(full.height)")
        let center = try await engine.evaluate(
            "(function(){ var r = document.querySelector('h1').getBoundingClientRect(); "
                + "return [(r.x + 10) / innerWidth, (r.y + r.height / 2) / innerHeight]; })()", in: .page) as? [NSNumber]
        let point = try XCTUnwrapValue(center?.map(\.doubleValue), "the heading's centre")
        let heading = await engine.captureElementBounds(atFractionX: point[0], y: point[1])
        let fraction = try XCTUnwrapValue(heading?.fraction, "the element under the pointer")
        let element = try XCTUnwrapImage(CaptureImaging.crop(viewport, to: fraction), "element crop")
        try check(element.height < full.height / 3 && element.width > full.width / 2, "element \(element.width)x\(element.height)")
        let palette = SpaceThemePalette(theme: store.activeSpace.theme, darkAppearance: false)
        let portrait = try XCTUnwrapImage(CaptureImaging.portrait(viewport, palette: palette, watermark: true), "portrait")
        try check(portrait.width > full.width && portrait.height > full.height, "portrait \(portrait.width)x\(portrait.height)")
        log("PASS capture: region \(region.width)x\(region.height) of the \(full.width)x\(full.height) viewport snapshot, "
            + "clicked element <h1> \(element.width)x\(element.height) measured in the editor world, portrait \(portrait.width)x\(portrait.height)")
    }

    // MARK: DevTools (ABI 1.40) and client certificates (ABI 1.41)

    @MainActor
    private func devToolsChecks(model: BrowserViewModel, store: SidebarStore, shell: ChromiumShell, tab: Tab,
                                engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        guard runtime.capabilities.devTools else {
            log("ABI-GAP devtools not advertised (ABI minor \(minorText) < 40): Inspect and ⌥⌘I stay off")
            return
        }
        let viewMenu = NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu
        let developer = viewMenu?.items.first { $0.title == "Developer" }?.submenu?.items.first { $0.title == "Developer Tools" }
        try check(developer?.keyEquivalent == "i" && developer?.keyEquivalentModifierMask == [.command, .option],
                  "View > Developer > Developer Tools (⌥⌘I) missing")
        model.selectTab(tab.id)
        try check(model.toggleDevTools() == nil, "⌥⌘I refused on tab A")
        try await wait("the docked DevTools frontend attached", timeout: 20) {
            (model.devToolsEngine(for: tab.id) as? ChromiumEngine)?.attachmentID != nil
        }
        let frontend = try XCTUnwrapValue(model.devToolsEngine(for: tab.id) as? ChromiumEngine, "the frontend engine")
        try await wait("the bundled frontend loaded", timeout: 20) {
            frontend.currentURL?.scheme == "devtools" && !frontend.isLoading
        }
        try check(frontend.engineProfileID == engine.engineProfileID && frontend.leaseHolder?.window === window,
                  "frontend profile \(frontend.engineProfileID) window \(String(describing: frontend.leaseHolder?.window))")
        try check(!store.displayTabs().contains { $0.url.scheme == "devtools" }, "the frontend became a sidebar tab")
        var placement = "it moves to its own window and back"
        if model.devToolsDockable {
            // ABI 1.54: the frontend docks itself (its ⋮ menu); the shell follows its reports.
            try await wait("the frontend reported its Dock side", timeout: 20) {
                model.devTools.session(for: tab.id)?.layout?.pageBounds != nil
            }
            let layout = try XCTUnwrapValue(model.devTools.session(for: tab.id)?.layout, "the dock layout")
            try check(layout.side == .undocked || frontend.leaseHolder?.window === window, "docked frontend outside the window")
            placement = "it reported Dock side \(layout.side) with the page at \(layout.pageBounds.map { "\($0)" } ?? "-")"
        } else {
            model.setDevToolsPlacement(.window)
            try await wait("DevTools in their own window", timeout: 10) {
                guard let own = shell.window(forDevTools: tab.id) else { return false }
                return frontend.leaseHolder?.window === own
            }
            model.setDevToolsPlacement(.docked)
            try await wait("DevTools docked again", timeout: 10) {
                shell.window(forDevTools: tab.id) == nil && frontend.leaseHolder?.window === window
            }
        }
        let frontendTab = frontend.tabID
        model.toggleDevTools()
        try await wait("⌥⌘I closed the frontend tab", timeout: 10) { !runtime.devToolsFrontends.contains(frontendTab) }
        try check(model.devTools.session(for: tab.id) == nil && engine.tabID != 0, "the page went with its DevTools")
        log("PASS DevTools (ABI 1.40): ⌥⌘I opens the bundled frontend docked beside tab A (same engine profile, not a sidebar tab), "
            + "\(placement), and ⌥⌘I closes it while the page stays")

        // Inspect from the page menu on another tab; closing that page closes its frontend.
        let target = model.openInNewTab(URL(string: "\(base)/a")!)
        let targetEngine = try XCTUnwrapValue(model.engineHost.engine(forTabID: target.id, profileID: model.profileID(for: target)) as? ChromiumEngine,
                                              "the second tab's engine")
        try await wait("the second tab loaded", timeout: 15) { targetEngine.pageTitle == Self.titleA && !targetEngine.isLoading }
        runtime.onInspectRequested?(targetEngine)
        try await wait("Inspect's frontend", timeout: 20) { model.devToolsEngine(for: target.id) != nil }
        let inspected = (model.devToolsEngine(for: target.id) as? ChromiumEngine)?.tabID ?? 0
        runtime.forceCloseTab(targetEngine.tabID)
        try await wait("the engine closed the frontend with its page", timeout: 15) {
            !runtime.devToolsFrontends.contains(inspected) && model.devTools.session(for: target.id) == nil
        }
        model.closeTab(target.id)
        model.selectTab(tab.id)
        log("PASS DevTools: the page menu's Inspect opened a frontend for another tab (frontend \(inspected)); "
            + "closing that page closed its frontend in the engine and in the shell")
    }

    @MainActor
    private func clientCertificateChecks(model: BrowserViewModel, store: SidebarStore) async throws {
        guard runtime.capabilities.clientCertificates else {
            log("ABI-GAP client_certificates not advertised (ABI minor \(minorText) < 41): sites asking for one fail")
            return
        }
        guard let mtls = SelfTestMutualTLS.shared else {
            log("NOTE client certificates: step skipped (\(mutualTLSNote))")
            return
        }
        let tab = model.openInNewTab(mtls.url("/select"))
        let engine = try XCTUnwrapValue(model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab)) as? ChromiumEngine,
                                        "the mTLS tab's engine")
        let prompts = engine.pagePrompts
        try await wait("the certificate sheet", timeout: 20) { prompts.clientCertificate != nil }
        let request = try XCTUnwrapValue(prompts.clientCertificate?.request, "the request")
        let subjects = request.identities.map(\.subject)
        try check(request.identities.count == 2 && subjects.contains { $0.contains("Client Cert A") }
                  && subjects.contains { $0.contains("Client Cert D") }
                  && request.identities.allSatisfy { ClientCertificateIdentity.isValidFingerprint($0.fingerprint) }
                  && request.origin == "https://127.0.0.1:\(mtls.port)",
                  "request \(request.origin) \(subjects)")
        prompts.answerClientCertificate(nil)
        try await wait("Cancel leaves the page without a certificate", timeout: 15) { !engine.isLoading && prompts.clientCertificate == nil }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try check(prompts.clientCertificate == nil && engine.pageTitle?.hasPrefix("mtls:") != true, "Cancel was asked again or loaded")
        engine.reload(ignoringCache: false)
        try await wait("the sheet again after a reload", timeout: 20) { prompts.clientCertificate != nil }
        let chosen = try XCTUnwrapValue(prompts.clientCertificate?.request.identities.first { $0.subject.contains("Client Cert D") }, "Client Cert D")
        prompts.selectedCertificate = chosen.fingerprint
        prompts.answerClientCertificate(prompts.selectedCertificate)
        try await wait("the server saw Client Cert D", timeout: 20) { engine.pageTitle == "mtls:Client Cert D:/select" }
        loadShellTab(model, tab, engine, mtls.url("/cached"))
        try await wait("Chromium reused the choice", timeout: 20) { engine.pageTitle == "mtls:Client Cert D:/cached" }
        try check(prompts.clientCertificate == nil, "asked again for the same host and port")
        model.closeTab(tab.id)
        log("PASS client certificates (ABI 1.41): the per-tab sheet listed Client Cert A and D (subject, issuer, expiry) for "
            + "\(request.origin); Cancel loaded nothing and did not ask again; selecting D reached the server and was reused")
    }

    private func XCTUnwrapImage(_ png: Data?, _ label: String) throws -> CGImage {
        guard let png, let image = CaptureImaging.cgImage(png) else { throw Failure(description: "\(label): no image") }
        return image
    }

    private func XCTUnwrapValue<T>(_ value: T?, _ label: String) throws -> T {
        guard let value else { throw Failure(description: "\(label): none") }
        return value
    }

    /// Wave 28: File > Import from Another Browser opens chrome://settings/importData. WebUI
    /// refuses both script and snapshots, so the dialog itself cannot be observed; the step checks
    /// that the route commits and stays (Settings closes the dialog by leaving it). Nothing is
    /// imported (that would read this Mac's real Safari, Chrome or Firefox data).
    @MainActor
    private func importDataChecks(engine: ChromiumEngine) async throws {
        let status = engine.navigateNow(BrowserInternalPage.importData.url)
        try check(status == .rearcOK, "chrome://settings/importData rejected: \(status.rearcName)")
        try await wait("chrome://settings/importData commit", timeout: 25) {
            engine.currentURL?.host() == "settings" && engine.currentURL?.path == "/importData" && !engine.isLoading
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let route = engine.currentURL?.path ?? ""
        let snapshot: String
        do {
            _ = try await engine.captureSnapshot(scope: .visible)
            snapshot = "a snapshot was allowed"
        } catch {
            snapshot = "snapshots of WebUI are refused (\(error))"
        }
        try check(route == "/importData", "the import route did not stay: '\(route)'")
        log("PASS import: chrome://settings/importData committed in the settings tab and kept its route for 1.5 s, title "
            + "'\(engine.pageTitle ?? "")'; the dialog is not observable (script on WebUI is refused, \(snapshot)); no import run")
    }

    // MARK: Extensions (ABI 1.31–1.33, 1.36)

    @MainActor
    private func extensionChecks(model: BrowserViewModel, store: SidebarStore, shell: ChromiumShell, tab: Tab, engine: ChromiumEngine) async throws {
        let capabilities = runtime.capabilities
        guard capabilities.extensionActions, let host = shell.extensionHost else {
            log("ABI-GAP extension_actions not advertised (ABI minor \(minorText) < 33): no extensions toolbar on Chromium")
            return
        }
        let controller = model.extensions
        controller.defaults = UserDefaults(suiteName: "rearc-selftest-extensions-\(UUID().uuidString)")!
        let prompts = SelfTestExtensionPrompts()
        host.prompts = prompts
        try check(controller.isAvailable, "the extensions toolbar is not available")
        var actions: [ExtensionActionItem] = []
        try await waitAsync("the fixture extensions' actions", timeout: 20) {
            controller.refresh(engine, scale: 2)
            try? await Task.sleep(nanoseconds: 300_000_000)
            actions = controller.actions(for: engine)
            let popup = actions.first { $0.name == SelfTestExtensionFixture.popupName }
            return popup?.displayBadge == "7" && actions.contains { $0.name == SelfTestExtensionFixture.clickName }
        }
        let popupAction = actions.first { $0.name == SelfTestExtensionFixture.popupName }!
        let clickAction = actions.first { $0.name == SelfTestExtensionFixture.clickName }!
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        try check(popupAction.title == SelfTestExtensionFixture.popupTitle && popupAction.hasPopup && popupAction.isEnabled,
                  "popup action \(popupAction)")
        try check(popupAction.badgeBackgroundColor?.red == 1 && popupAction.badgeBackgroundColor?.green == 0, "badge color \(String(describing: popupAction.badgeBackgroundColor))")
        try check(popupAction.iconPNG.map { Array($0.prefix(4)) == png } == true, "action icon is not a PNG")
        try check(!clickAction.hasPopup, "the click fixture has a popup")
        controller.togglePin(popupAction.id)
        try check(controller.pinnedActions(for: engine).map(\.id) == [popupAction.id], "pinning did not put the action in the toolbar")
        log("PASS extension actions (ABI 1.33): \(actions.count) local unpacked fixtures; '\(popupAction.title)' badge '7' red, "
            + "popup, \(popupAction.iconPNG?.count ?? 0)-byte icon; pinned to the toolbar, the rest in the extensions menu")

        // Popup: a registry tab in the popup panel, sized by the renderer, closed by window.close().
        let tabsBefore = store.displayTabs().count
        var popupEngine: ChromiumEngine!
        for attempt in 1...2 {
            controller.run(popupAction.id, for: engine, anchor: nil)
            try await wait("the extension popup adopted", timeout: 10) { host.popups.engine != nil }
            popupEngine = host.popups.engine!
            try await wait("the popup attached in its panel") { popupEngine.attachmentID != nil && popupEngine.leaseHolder?.window === host.popups.window }
            let ready = await eventually(timeout: 10) {
                host.popups.size == SelfTestExtensionFixture.popupSize && popupEngine.pageTitle?.hasPrefix("popup:") == true
            }
            if ready { break }
            // Seen once in a real-Keychain run: the popup committed but its script never ran (no title, no resize).
            try check(attempt == 1, "the popup never resized to its content or set its title (size \(host.popups.size), "
                      + "title \(popupEngine.pageTitle ?? "-"), resizes \(host.popups.resizes)) after a retry")
            log("NOTE extension popup: tab \(popupEngine.tabID) loaded without running its script within 10 s "
                + "(size \(host.popups.size), title '\(popupEngine.pageTitle ?? "")'); closing it and clicking again")
            host.popups.dismiss()
            try await wait("the popup closed before the retry") { host.popups.engine == nil }
        }
        let popupTab = popupEngine.tabID
        let panelSize = host.popups.window?.frame.size
        try check(popupEngine.pageTitle == "popup:1", "popup title \(popupEngine.pageTitle ?? "-") (getViews popup count)")
        try check(panelSize == SelfTestExtensionFixture.popupSize, "popup panel size \(String(describing: panelSize))")
        try check(controller.openPopupExtensionID == popupAction.id, "the toolbar does not show the open popup")
        try check(store.displayTabs().count == tabsBefore, "the popup became a sidebar tab")
        try await wait("the popup closed by its window.close()", timeout: 10) { host.popups.engine == nil }
        try check(controller.openPopupExtensionID == nil, "the toolbar still shows a popup")
        log("PASS extension popup (ABI 1.33): popup tab \(popupTab) attached in the popup panel, resized to "
            + "\(Int(SelfTestExtensionFixture.popupSize.width))x\(Int(SelfTestExtensionFixture.popupSize.height)) by \(host.popups.resizes) event(s), "
            + "'popup:1', no sidebar tab; window.close() dismissed it")

        // Escape closes a popup the page did not close.
        controller.run(popupAction.id, for: engine, anchor: nil)
        try await wait("the popup again", timeout: 10) { host.popups.engine?.attachmentID != nil }
        host.popups.dismiss()
        try check(host.popups.engine == nil && host.popups.window == nil, "dismiss left the popup")
        log("PASS extension popup dismissed by the shell (focus loss, Escape, tab switch, second click share this path)")

        // tabs.create from the click fixture, through the host's tab request (ABI 1.36).
        guard capabilities.extensionWindows else {
            log("ABI-GAP extension_windows not advertised (ABI minor \(minorText) < 36): extension tabs.create fails")
            controller.togglePin(popupAction.id)
            return
        }
        host.reconcileWindows()
        let spaceWindow = host.windowID(forSpace: store.activeSpaceID)
        let (stateStatus, state) = runtime.extensionState(tab: engine.tabID)
        try check(stateStatus == .rearcOK && state.window_id == spaceWindow && state.active, "tab A's extension state \(stateStatus.rearcName) \(state)")
        let before = Set(store.displayTabs().map(\.id))
        let requestsBefore = runtime.extensionTabRequests.count
        controller.run(clickAction.id, for: engine, anchor: nil)
        try await wait("the extension's tab in the sidebar", timeout: 15) { store.displayTabs().contains { !before.contains($0.id) } }
        let created = store.displayTabs().first { !before.contains($0.id) }!
        let createdEngine = try shellEngine(model, created)
        try await wait("the extension page loaded", timeout: 15) { createdEngine.pageTitle?.hasPrefix("ext-page{") == true }
        let json = String((createdEngine.pageTitle ?? "").dropFirst("ext-page".count))
        let info = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let request = runtime.extensionTabRequests.dropFirst(requestsBefore).first
        try check(request?.kind == .createTab && request?.url.hasPrefix("chrome-extension://") == true, "tab request \(String(describing: request))")
        try check(info["cur"] as? Int == Int(state.tab_id) && info["clicked"] as? Int == Int(state.tab_id),
                  "the extension saw active \(info["cur"] ?? "-") / clicked \(info["clicked"] ?? "-"), tab A is \(state.tab_id)")
        try check(info["win"] as? Int == Int(spaceWindow) && info["winTab"] as? Int == Int(spaceWindow), "window ids \(info)")
        try check(store.spaceContaining(tabID: created.id) == store.activeSpaceID, "the extension's tab is not in the current space")
        host.reconcileWindows()
        let createdState = runtime.extensionState(tab: createdEngine.tabID).1
        try check(createdState.window_id == spaceWindow && createdState.active, "the new tab's extension state \(createdState)")
        log("PASS extension tabs.create (ABI 1.36): request \(request?.id ?? 0) -> a today tab in the current space, loaded "
            + "\(request?.url.split(separator: "#").first ?? ""); the extension saw tab A (\(state.tab_id)) active in window \(spaceWindow) "
            + "(the space), and the new tab became active there")

        // Uninstall confirmation through the host (ABI 1.32); the self-test cancels it.
        controller.run(clickAction.id, for: engine, anchor: nil)
        if await eventually(timeout: 8, { prompts.requests.contains { $0.kind == .uninstall } }) {
            let prompt = prompts.requests.first { $0.kind == .uninstall }!
            try check(prompt.name == SelfTestExtensionFixture.clickName, "uninstall prompt for \(prompt.name)")
            try await waitAsync("the click fixture still installed", timeout: 5) {
                controller.refresh(engine, scale: 2)
                try? await Task.sleep(nanoseconds: 300_000_000)
                return controller.actions(for: engine).contains { $0.id == clickAction.id }
            }
            log("PASS extension uninstall prompt (ABI 1.32): '\(prompt.displayTitle)' / '\(prompt.displayAcceptLabel)' as a host sheet; "
                + "cancelled, the extension stays")
        } else {
            log("NOTE extension uninstall prompt: management.uninstallSelf({showConfirmDialog}) sent no host prompt within 8 s "
                + "(prompt events: \(runtime.extensionPromptEvents.map { "\($0.phase)/\($0.request.kind)" }))")
        }
        model.deleteTab(created.id)
        model.selectTab(tab.id)
        controller.togglePin(popupAction.id)
    }

    // MARK: Extensions in two profiles do not pass the window between them

    /// Owner's report 2026-11-22: the same extension in two profiles, each
    /// copy bringing its own tab forward when it saw no focused window, made
    /// the window switch between the two profiles' spaces for as long as it
    /// ran and left two blank tabs behind at each switch. Here the front
    /// fixture runs in two profiles for `frontRun` seconds with nobody at the
    /// keyboard: the space on screen must not change, the copy that is not on
    /// screen gets its tab as its own window's active tab and no more than
    /// `ExtensionBlankTabs.limit` blank tabs, and the copy on screen opens none.
    /// Then the user's own switch to the other space, and the same the other
    /// way round.
    @MainActor
    private func extensionFocusChecks(model: BrowserViewModel, store: SidebarStore, shell: ChromiumShell, tab: Tab,
                                      engine: ChromiumEngine, base: String) async throws {
        let capabilities = runtime.capabilities
        guard capabilities.extensionActions, capabilities.extensionWindows, capabilities.profiles, let host = shell.extensionHost else {
            log("ABI-GAP extension_windows or profiles not advertised (ABI minor \(minorText)): extensions in two profiles are not exercised")
            return
        }
        let controller = model.extensions
        let frontName = SelfTestExtensionFixture.frontName
        func frontAction(_ engine: ChromiumEngine, timeout: TimeInterval) async -> ExtensionActionItem? {
            var found: ExtensionActionItem?
            _ = await eventuallyAsync(timeout: timeout) {
                controller.refresh(engine, scale: 2)
                try? await Task.sleep(nanoseconds: 300_000_000)
                found = controller.actions(for: engine).first { $0.name == frontName }
                return found != nil
            }
            return found
        }
        model.selectTab(tab.id)
        let homeSpace = store.activeSpace
        guard let homeFront = await frontAction(engine, timeout: 20) else {
            throw Failure(description: "extension focus: the front fixture has no action in the first profile")
        }

        // A second profile with one space and one open page: a copy needs a window with an active tab.
        let other = store.addProfile(name: "Extension Focus Other")
        let otherSpace = try XUnwrap(store.spaces(in: other.id).first, "the second profile's space")
        let otherTab = store.addTab(kind: .today, title: "other", url: try XUnwrap(URL(string: "\(base)/a?focus=1"), "address"), in: otherSpace.id)
        model.selectSpace(otherSpace.id)
        model.selectTab(otherTab.id)
        let otherEngine = try shellEngine(model, otherTab)
        try await wait("extension focus: the second profile's page", timeout: 25) { otherEngine.pageTitle == Self.titleA && !otherEngine.isLoading }
        let otherFront = await frontAction(otherEngine, timeout: 15)

        let before = Set((store.displayTabs(in: homeSpace.id) + store.displayTabs(in: otherSpace.id)).map(\.id))
        func added(_ space: Space.ID) -> [Tab] { store.displayTabs(in: space).filter { !before.contains($0.id) } }
        func watch(_ seconds: TimeInterval, on space: Space, _ label: String) async throws {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                try check(store.activeSpaceID == space.id, "extension focus: \(label): the space on screen changed by itself to "
                          + "'\(store.activeSpace.name)' (\(added(homeSpace.id).count) + \(added(otherSpace.id).count) new tabs)")
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        /// The copy whose space is not on screen: its tab is its own window's active tab, in the engine too, and the window is not focused.
        func checkHiddenCopy(_ space: Space, _ label: String) throws -> Int {
            let tabs = added(space.id)
            try check(!tabs.isEmpty && tabs.count <= ExtensionBlankTabs.limit && tabs.allSatisfy { $0.url.absoluteString == "about:blank" },
                      "extension focus: \(label): \(tabs.count) new tabs in '\(space.name)' (at most \(ExtensionBlankTabs.limit) blank ones expected)")
            guard let selected = store.selectedTab(inSpace: space.id), tabs.contains(where: { $0.id == selected.id }) else {
                throw Failure(description: "extension focus: \(label): the extension's tab is not its own space's selected tab")
            }
            host.reconcileWindows()
            let (status, state) = runtime.extensionState(tab: try shellEngine(model, selected).tabID)
            try check(status == .rearcOK && state.active && !state.focused && state.window_id == host.windowID(forSpace: space.id),
                      "extension focus: \(label): the engine has the tab as \(status.rearcName) \(state)")
            return tabs.count
        }

        // Nobody at the keyboard: an earlier step's synthesized click must not count for this one.
        model.extensionFocusGate = ExtensionFocusGate()
        let logged = model.extensionFocusLog.count
        let armed = Date()
        controller.run(homeFront.id, for: engine, anchor: nil)
        if let otherFront { controller.run(otherFront.id, for: otherEngine, anchor: nil) }

        // The second profile's space is on screen: the first profile's copy sees no focused window.
        try await wait("extension focus: the first profile's copy opened its tab", timeout: 10) { !added(homeSpace.id).isEmpty }
        try await watch(4, on: otherSpace, "first profile's copy running")
        let homeCount = try checkHiddenCopy(homeSpace, "first profile's copy")
        try check(added(otherSpace.id).isEmpty, "extension focus: the copy on screen opened \(added(otherSpace.id).count) tab(s) though its window is focused")

        // The user's own switch; now the second profile's copy is the one that sees no focused window.
        model.selectSpace(homeSpace.id)
        try check(store.activeSpaceID == homeSpace.id, "extension focus: the user's own switch did not happen")
        var otherCount = 0
        if otherFront != nil {
            try await wait("extension focus: the second profile's copy opened its tab", timeout: 8) { !added(otherSpace.id).isEmpty }
            try await watch(3, on: homeSpace, "second profile's copy running")
            otherCount = try checkHiddenCopy(otherSpace, "second profile's copy")
        } else {
            try await watch(3, on: homeSpace, "after the user's switch")
        }

        // Until both copies have stopped, and a moment more: nothing moves and nothing piles up.
        let remaining = SelfTestExtensionFixture.frontRun + 1.5 - Date().timeIntervalSince(armed)
        if remaining > 0 { try await watch(remaining, on: homeSpace, "to the end of the run") }
        let finalHome = added(homeSpace.id).count, finalOther = added(otherSpace.id).count
        try await watch(1, on: homeSpace, "after the run")
        try check(added(homeSpace.id).count == finalHome && added(otherSpace.id).count == finalOther
                  && finalHome <= ExtensionBlankTabs.limit && finalOther <= ExtensionBlankTabs.limit,
                  "extension focus: tabs kept arriving (\(homeCount) -> \(added(homeSpace.id).count), \(otherCount) -> \(added(otherSpace.id).count))")
        try check(model.extensionFocusLog.count == logged, "extension focus: the loop breaker had to step in: \(model.extensionFocusLog.suffix(1))")

        for created in added(homeSpace.id) { model.deleteTab(created.id) }
        try check(model.deleteProfile(other.id, deletingSpaces: true) == nil, "extension focus: the extra profile could not be deleted")
        model.selectTab(tab.id)
        try await wait("extension focus: the first tab shown again", timeout: 15) { store.selectedTab?.id == tab.id && store.activeSpaceID == homeSpace.id }
        log("PASS extensions in two profiles (owner's report 2026-11-22): the front fixture ran \(Int(SelfTestExtensionFixture.frontRun)) s in "
            + (otherFront == nil ? "the first profile only (NOTE: --load-extension did not load it into the second)" : "both profiles")
            + " with no input; the space on screen never changed by itself; the copy not on screen got its tab as its window's active "
            + "tab (not focused) and \(finalHome) blank tab(s) in the first profile, \(finalOther) in the second (limit "
            + "\(ExtensionBlankTabs.limit)); the copy on screen opened none; the user's own switch worked; loop breaker not needed")
        try await extensionFloodChecks(model: model, store: store, shell: shell, host: host, tab: tab, engine: engine, base: base)
    }

    /// Security RC-2026.1122.1231 FX-02 and FX-01, with the flood fixture and
    /// nobody at the keyboard. `windows.create`: the Little Darni window is
    /// made and is on screen, but behind the window in front, neither key nor
    /// main nor focused to the engine, and a notice with Show says so and
    /// stays; after a key or click of the user's the next one comes to the
    /// front and is not counted. Show brings the first forward and the notice
    /// goes; a third, opened behind, takes its notice with it when it closes. Then
    /// `floodBurst` `tabs.create` calls at once, each with an address on the
    /// fixture server: `ExtensionTabRate.limit` tabs open, the rest of the
    /// calls fail in the extension, and one toast names the extension.
    @MainActor
    private func extensionFloodChecks(model: BrowserViewModel, store: SidebarStore, shell: ChromiumShell, host: ChromiumExtensionHost,
                                      tab: Tab, engine: ChromiumEngine, base: String) async throws {
        let controller = model.extensions
        let floodName = SelfTestExtensionFixture.floodName
        func floodAction() -> ExtensionActionItem? { controller.actions(for: engine).first { $0.name == floodName } }
        /// Runs the fixture's action and waits for the badge that says it has finished. The
        /// toasts shown meanwhile are kept: one may be gone again before a slow page has loaded.
        var toasts: [ShellToast] = []
        func click(_ label: String, until finished: @escaping (String) -> Bool) async throws -> String {
            guard let action = floodAction() else { throw Failure(description: "extension flood: \(label): the fixture's action is gone") }
            toasts = []
            controller.run(action.id, for: engine, anchor: nil)
            var badge = ""
            try await waitAsync("extension flood: \(label): the fixture's answer in its badge", timeout: 30) {
                for _ in 0..<6 {
                    if let toast = model.toast, !toasts.contains(where: { $0.id == toast.id }) { toasts.append(toast) }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                controller.refresh(engine, scale: 2)
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let toast = model.toast, !toasts.contains(where: { $0.id == toast.id }) { toasts.append(toast) }
                badge = floodAction()?.badgeText ?? ""
                return finished(badge)
            }
            return badge
        }
        func order(_ window: NSWindow) -> Int { NSApp.orderedWindows.firstIndex { $0 === window } ?? -1 }

        // The fixture reads its site from the clicked tab.
        model.selectTab(tab.id)
        loadShellTab(model, tab, engine, try XUnwrap(URL(string: "\(base)/a"), "address"))
        try await wait("extension flood: tab A", timeout: 20) { engine.pageTitle == Self.titleA && !engine.isLoading }
        let space = store.activeSpace
        // The page view can still be on its way back into the window after the previous
        // step's profile switch (RC run 2026-11-22 23:21 read it at once and found none).
        try await wait("extension flood: tab A's page in a window", timeout: 15) { engine.leaseHolder?.window != nil }
        guard let browserWindow = engine.leaseHolder?.window else { throw Failure(description: "extension flood: tab A is in no window") }
        try await waitAsync("extension flood: the flood fixture's action", timeout: 20) {
            controller.refresh(engine, scale: 2)
            try? await Task.sleep(nanoseconds: 300_000_000)
            return floodAction() != nil
        }

        // 1. windows.create by itself. An earlier step's synthesized click must not count.
        model.extensionFocusGate = ExtensionFocusGate()
        model.extensionTabRate = ExtensionTabRate()
        let focusLogged = model.extensionFocusLog.count
        let littleBefore = Set(store.littleArcLiveWindows.map(\.id))
        func newLittle() -> [LittleArcWindow] { store.littleArcLiveWindows.filter { !littleBefore.contains($0.id) } }
        // The window it must stay behind. With none on screen (every window minimised) only the keyboard is checked.
        let front = LittleArcWindowOrdering.frontWindow(among: NSApp.orderedWindows)
        let key = NSApp.keyWindow, main = NSApp.mainWindow, keyLittle = model.keyLittleArcID
        let first = try await click("windows.create with no input") { $0.count >= 2 }
        try check(first == "w1", "extension flood: windows.create with no input failed in the extension (badge '\(first)')")
        let behind = try XUnwrap(newLittle().first, "the Little Darni window an extension made")
        func noticeText() -> String { model.extensionWindowNotice.map { "'\($0.message)' for \($0.windows.count)" } ?? "none" }
        try check(model.extensionWindowNotice?.message == "\(floodName) opened a window behind this one"
                  && model.extensionWindowNotice?.windows == [behind.id] && model.extensionWindowNotice?.toast.action == .show,
                  "extension flood: no notice with Show for the window behind (notice \(noticeText()), toasts \(toasts.map(\.message)))")
        try check(!toasts.contains { $0.action == .show }, "extension flood: the window behind was said in a toast, which goes by itself")
        guard let behindWindow = shell.window(forLittleArc: behind.id),
              let behindEngine = model.littleArcEngine(for: behind.id) as? ChromiumEngine else {
            throw Failure(description: "extension flood: windows.create opened no window or engine")
        }
        // Loaded and settled: a window that takes the keyboard does so when it opens or when its page has it.
        try await wait("extension flood: the window's page", timeout: 20) {
            behindEngine.currentURL?.query == "flood=window0" && !behindEngine.isLoading
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        try check(behindWindow.isVisible, "extension flood: the window an extension made is not on screen at all")
        try check(!behindWindow.isKeyWindow && !behindWindow.isMainWindow && model.keyLittleArcID == keyLittle
                  && NSApp.keyWindow === key && NSApp.mainWindow === main,
                  "extension flood: a window an extension made by itself took the keyboard (key \(behindWindow.isKeyWindow), main "
                  + "\(behindWindow.isMainWindow), key Little Darni \(String(describing: model.keyLittleArcID)), app key window "
                  + "'\(NSApp.keyWindow?.title ?? "none")')")
        if let front {
            try check(LittleArcWindowOrdering.frontWindow(among: NSApp.orderedWindows) === front && order(behindWindow) > order(front),
                      "extension flood: a window an extension made by itself is in front (its place \(order(behindWindow)), the front "
                      + "window's \(order(front)) of \(NSApp.orderedWindows.count))")
        } else {
            log("NOTE extension flood: no window was on screen for the new one to stay behind; only the keyboard was checked")
        }
        host.reconcileWindows()
        let (status, state) = runtime.extensionState(tab: behindEngine.tabID)
        try check(status == .rearcOK && state.active && !state.focused, "extension flood: the engine has the window's tab as \(status.rearcName) \(state)")

        // 2. The same after a key or click of the user's: that window comes to the front.
        model.noteUserInput()
        let second = try await click("windows.create after input") { $0.count >= 4 }
        try check(second == "w1w1", "extension flood: windows.create after input failed in the extension (badge '\(second)')")
        let shown = try XUnwrap(newLittle().first { $0.id != behind.id }, "the second Little Darni window")
        // The first is still behind and still said: its notice outlives the page load and the second window.
        try check(model.extensionWindowNotice?.windows == [behind.id],
                  "extension flood: after a window the user's input started, the notice is \(noticeText()); it must count the first window only")
        let shownWindow = try XUnwrap(shell.window(forLittleArc: shown.id), "the second Little Darni's window")
        try check(shownWindow.isVisible && LittleArcWindowOrdering.frontWindow(among: NSApp.orderedWindows) === shownWindow,
                  "extension flood: a window the user's input started did not come to the front (its place \(order(shownWindow)))")
        // Key only while the app is active; the order above holds either way.
        let tookKey = shownWindow.isKeyWindow
        try check(model.extensionFocusLog.count == focusLogged, "extension flood: the loop breaker stepped in: \(model.extensionFocusLog.suffix(1))")

        // 2a. The notice's Show: the window behind comes to the front, and the notice goes.
        model.showExtensionWindowsBehind()
        try await wait("extension flood: Show brought the window behind to the front", timeout: 10) {
            LittleArcWindowOrdering.frontWindow(among: NSApp.orderedWindows) === behindWindow
        }
        try check(model.extensionWindowNotice == nil, "extension flood: the notice stayed after Show (\(noticeText()))")

        // 2b. One more by itself (the input above is spent), closed while it is behind: its notice goes with it.
        model.extensionFocusGate = ExtensionFocusGate()
        let third = try await click("windows.create with no input, again") { $0.count >= 6 }
        try check(third == "w1w1w1", "extension flood: the third windows.create failed in the extension (badge '\(third)')")
        let closing = try XUnwrap(newLittle().first { $0.id != behind.id && $0.id != shown.id }, "the third Little Darni window")
        try check(model.extensionWindowNotice?.windows == [closing.id],
                  "extension flood: the notice for a second window behind is \(noticeText())")
        for record in [behind, shown, closing] { shell.dismissLittleArcWindow(record.id) }
        try await wait("extension flood: the fixture's windows closed", timeout: 15) {
            [behind, shown, closing].allSatisfy { shell.window(forLittleArc: $0.id) == nil && store.littleArcWindow(withID: $0.id) == nil }
        }
        try check(model.extensionWindowNotice == nil, "extension flood: the notice outlived its window (\(noticeText()))")
        browserWindow.makeKeyAndOrderFront(nil)
        model.selectTab(tab.id)

        // 3. A burst of tabs.create with an address, over the cap.
        model.extensionFocusGate = ExtensionFocusGate()
        model.extensionTabRate = ExtensionTabRate()
        let rateLogged = model.extensionTabRateLog.count
        let before = Set(store.displayTabs(in: space.id).map(\.id))
        func added() -> [Tab] { store.displayTabs(in: space.id).filter { !before.contains($0.id) } }
        let limit = ExtensionTabRate.limit, burst = SelfTestExtensionFixture.floodBurst
        let answer = try await click("a burst of tabs.create") { $0.contains("/") }
        try check(answer == "\(limit)/\(burst - limit)",
                  "extension flood: of \(burst) tabs.create calls at once the extension saw made/failed '\(answer)', expected \(limit)/\(burst - limit)")
        try check(toasts.filter { $0.message == "\(floodName) tried to open many tabs; Darni stopped it" }.count == 1,
                  "extension flood: not exactly one toast naming the extension (toasts \(toasts.map(\.message)))")
        try await wait("extension flood: the burst's tabs on their pages", timeout: 30) {
            added().count >= limit && added().allSatisfy { $0.url.query?.hasPrefix("flood=") == true }
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        try check(added().count == limit, "extension flood: \(added().count) tabs opened for \(burst) requests (cap \(limit))")
        try check(store.activeSpaceID == space.id && store.selectedTab?.id == tab.id, "extension flood: the burst changed what is on screen")
        try check(model.extensionTabRateLog.count == rateLogged + 1,
                  "extension flood: the rate cap logged \(model.extensionTabRateLog.count - rateLogged) bursts for one")

        for created in added() { model.deleteTab(created.id) }
        model.selectTab(tab.id)
        try await wait("extension flood: the first tab shown again", timeout: 15) { store.selectedTab?.id == tab.id && added().isEmpty }
        log("PASS extension windows and tab bursts (security FX-01, FX-02): windows.create with no input made a Little Darni window "
            + "behind the window in front (not key, not main, not focused to the engine) with a notice and Show that stayed; after the "
            + "user's input the next one came to the front (key: \(tookKey), app active \(NSApp.isActive)); Show brought the first "
            + "forward and cleared the notice; a third closed behind took its notice with it; of \(burst) tabs.create calls at once with "
            + "an address \(limit) opened and \(burst - limit) failed in the extension, with one toast naming it")
    }

    // MARK: Autofill suggestions (ABI 1.34) and save offers (1.37)

    @MainActor
    private func autofillChecks(model: BrowserViewModel, store: SidebarStore, tab: Tab, engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        guard runtime.capabilities.autofillSuggestions else {
            log("ABI-GAP autofill_suggestions not advertised (ABI minor \(minorText) < 34): no suggestions UI on Chromium")
            return
        }
        let unknown = runtime.acceptAutofill(UInt64.max, index: 0)
        try check(unknown == ReArcStatus(REARC_NOT_FOUND), "accept on an unknown list returned \(unknown.rearcName)")
        model.selectTab(tab.id)
        loadShellTab(model, tab, engine, URL(string: "\(base)/autofill")!)
        try await wait("the autofill fixture") { engine.pageTitle == "autofill" && !engine.isLoading }
        let prompts = engine.pagePrompts
        _ = await bringToFront(window, for: "autofill")
        func clickField(_ id: String) async -> Bool {
            for _ in 0..<3 {
                focus(window)
                guard let center = try? await cssCenter(of: "#\(id)", in: engine) else { return false }
                click(window, engine: engine, at: center)
                if await eventually(timeout: 2, { prompts.autofill != nil }) { return true }
            }
            return false
        }
        guard await clickField("dl") else {
            log("NOTE autofill: the synthesized click on a datalist field produced no suggestions (app active \(NSApp.isActive), "
                + "key \(window.isKeyWindow)); the dropdown is not exercised in this run; unknown list -> \(unknown.rearcName)")
            return
        }
        let popup = prompts.autofill!
        let row = popup.rows.first { $0.value == "rearc-option-one" }
        try check(popup.product == .datalist && row != nil, "suggestions product \(popup.product.rawValue) rows \(popup.rows.map(\.value))")
        let panel = (prompts.autofillPanels as? AutofillPanelPresenter)?.visiblePanel
        try check(panel != nil && panel?.isKeyWindow == false, "the suggestion panel is not on screen (or took the keyboard)")
        if let panel, let anchor = prompts.anchorView, let anchorWindow = anchor.window {
            let view = anchorWindow.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let fieldBottom = view.maxY - popup.field.maxY
            try check(abs(panel.frame.maxY - (fieldBottom - AutofillPopupLayout.gap)) < 1 || panel.frame.minY > fieldBottom,
                      "panel \(panel.frame) not at the field (bottom \(fieldBottom))")
        }
        // Down in the field: Chromium moves the selection and reports it (phase 2).
        if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
                                       charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125) {
            window.sendEvent(down)
        }
        let selected = await eventually(timeout: 2) { prompts.autofill?.selected != nil }
        while prompts.autofillShownFor < AutofillAcceptPolicy.earlyAcceptGuard { try await Task.sleep(nanoseconds: 50_000_000) }
        prompts.acceptAutofillRow(row!.id)
        try await waitAsync("the datalist value filled", timeout: 5) {
            (try? await engine.evaluate("document.getElementById('dl').value", in: .page)) as? String == "rearc-option-one"
        }
        try await wait("the suggestions hidden after accept") { prompts.autofill == nil && panel?.isVisible != true }
        log("PASS autofill dropdown (ABI 1.34): datalist product, rows \(popup.rows.map { popup.primaryText(of: $0) }), "
            + "panel under the field without taking the keyboard; Down -> \(selected ? "selection reported" : "no selection event (NOTE)"); "
            + "click accepted 'rearc-option-one'; unknown list -> \(unknown.rearcName)")
        if await clickField("dl") {
            let request = prompts.autofill!.requestID
            let tabs = Set(store.displayTabs().map(\.id))
            let status = runtime.manageAutofill(request)
            let opened = await eventually(timeout: 3) { store.displayTabs().contains { !tabs.contains($0.id) && $0.url.scheme == "chrome" } }
            if let settings = store.displayTabs().first(where: { !tabs.contains($0.id) && $0.url.scheme == "chrome" }) {
                log("PASS autofill Manage… (ABI 1.34): ReArcAutofillManage -> \(status.rearcName), opened \(settings.url.absoluteString) as a tab")
                model.deleteTab(settings.id)
                model.selectTab(tab.id)
            } else {
                log("NOTE autofill Manage…: \(status.rearcName), no settings page for the datalist product (opened \(opened))")
                prompts.dismissAutofill()
            }
        }
        try await addressSaveChecks(model: model, tab: tab, engine: engine, base: base, window: window)
    }

    @MainActor
    private func addressSaveChecks(model: BrowserViewModel, tab: Tab, engine: ChromiumEngine, base: String, window: NSWindow) async throws {
        guard runtime.capabilities.autofillSavePrompts else {
            log("ABI-GAP autofill_save_prompts not advertised (ABI minor \(minorText) < 37): no card or address save offers")
            return
        }
        let unknown = runtime.respondAutofillSave(UInt64.max, .ignore)
        try check(unknown == ReArcStatus(REARC_NOT_FOUND), "a reply to an unknown save offer returned \(unknown.rearcName)")
        let prompts = engine.pagePrompts
        let fields = [("name", "Rearc Tester"), ("street", "1 Test Way"), ("city", "Testville"), ("state", "CA"), ("zip", "94043")]
        var typed = true
        for (id, value) in fields where typed {
            typed = await typeIntoField(id, value, engine: engine, window: window)
        }
        if typed { click(window, engine: engine, at: try await cssCenter(of: "#save", in: engine)) }
        guard typed, await eventually(timeout: 10, { prompts.autofillSave != nil }) else {
            log("NOTE address save offer: no offer after synthesized typing (typed \(typed), app active \(NSApp.isActive), key \(window.isKeyWindow)); "
                + "Chromium imports typed forms only, so the offer is not exercised in this run; unknown offer -> \(unknown.rearcName)")
            return
        }
        let offer = prompts.autofillSave!.offer
        try check(offer.kind == .address && offer.summary.contains("1 Test Way"), "save offer \(offer)")
        prompts.answerAutofillSave(.decline)
        let late = runtime.respondAutofillSave(offer.id, .accept)
        try check(late == ReArcStatus(REARC_NOT_FOUND), "a second reply to the offer returned \(late.rearcName)")
        log("PASS address save offer (ABI 1.37): '\(offer.title)' \(offer.summaryLines) -> No Thanks (declined; nothing stored), "
            + "second reply -> \(late.rearcName)")
    }

    /// Arc's Peek chrome: a click outside the card (here on the sidebar)
    /// closes it without reaching the sidebar, Esc closes it, and Expand and
    /// Split View move the live page into a tab: the same Chromium tab, its
    /// script state and history intact, so nothing reloads.
    @MainActor
    private func peekChromeChecks(model: BrowserViewModel, store: SidebarStore, base: String, window: NSWindow,
                                  tabA: Tab, engineA: ChromiumEngine) async throws {
        func openPeek(from source: Tab?, path: String = "/a", title: String = Self.titleA) async throws
            -> (BrowserViewModel.PeekSession, ChromiumEngine) {
            model.showPeek(url: URL(string: "\(base)\(path)")!, sourceTabID: source?.id)
            guard let session = model.peekSession,
                  let peek = model.engineHost.ephemeralEngine(withID: session.engineID, profileID: session.profileID) as? ChromiumEngine else {
                throw Failure(description: "Peek created no Chromium engine")
            }
            try await wait("peek page shown in its card", timeout: 20) {
                peek.attachmentID != nil && peek.pageTitle == title && !peek.isLoading && peek.leaseHolder?.window === window
            }
            return (session, peek)
        }
        /// Follows the /links page's ordinary link to /a with a click on the
        /// Peek's own page: a user's navigation, so it is a back entry.
        /// (A script's pushState is not: without user activation Chromium's
        /// history-manipulation intervention skips the entry it leaves, and
        /// CanGoBack stays false.)
        func navigateInPeek(_ peek: ChromiumEngine) async throws {
            guard let host = peek.leaseHolder else { throw Failure(description: "the Peek's page has no view") }
            let center = try await cssCenter(of: "#plain", in: peek)
            click(window, engine: peek, at: center, host: host)
            try await wait("a click in the Peek follows its link", timeout: 15) {
                peek.currentURL?.path == "/a" && peek.pageTitle == Self.titleA && !peek.isLoading && peek.canGoBack
            }
        }

        model.selectTab(tabA.id)
        var (_, peek) = try await openPeek(from: tabA)
        guard let content = window.contentView else { throw Failure(description: "browser window has no content view") }
        /// A click in the middle of the sidebar as it is now (full or the mini column).
        /// A click at a window point (top-left), posted to the app's event
        /// queue like real input, so the app's mouse-down monitor sees it.
        func post(_ point: CGPoint, _ modifiers: NSEvent.ModifierFlags = [], right: Bool = false) {
            let local = NSPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
            let types: [NSEvent.EventType] = right ? [.rightMouseDown, .rightMouseUp] : [.leftMouseDown, .leftMouseUp]
            for type in types {
                if let event = NSEvent.mouseEvent(with: type, location: content.convert(local, to: nil), modifierFlags: modifiers,
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
        }
        func clickSidebar(_ modifiers: NSEvent.ModifierFlags = []) {
            post(CGPoint(x: model.sidebarWidth(in: store.keyWindowID) / 2, y: content.bounds.height / 2), modifiers)
        }
        let selectedBefore = store.selectedItemID
        clickSidebar()
        try await wait("a click on the sidebar closes the Peek") {
            model.peekSession == nil && runtime.liveLeaseCount(forTab: peek.tabID) == 0
        }
        try check(store.selectedItemID == selectedBefore, "the click that closed the Peek also reached the sidebar")

        (_, peek) = try await openPeek(from: tabA)
        press("\u{1b}", keyCode: 53, [], in: window, model: model, delivery: .direct)
        try await wait("Esc closes the Peek") { model.peekSession == nil && runtime.liveLeaseCount(forTab: peek.tabID) == 0 }

        // The washed page beside the card, left- and right-clicked: the Peek
        // closes from the mouse-down and the page under it gets nothing.
        for right in [false, true] {
            (_, peek) = try await openPeek(from: tabA)
            let layout = model.peekLayout(in: store.keyWindowID, windowSize: content.bounds.size)
            let pageBefore = engineA.currentURL
            post(CGPoint(x: (layout.region.minX + layout.card.minX) / 2, y: layout.card.midY), right: right)
            try await wait("a \(right ? "right-" : "")click on the washed page closes the Peek") {
                model.peekSession == nil && runtime.liveLeaseCount(forTab: peek.tabID) == 0
            }
            try check(engineA.currentURL == pageBefore && model.peekSwallowsMouseUp == nil,
                      "the \(right ? "right-" : "")click that closed the Peek reached the page or kept its mouse-up")
        }
        // A click on the card itself (its address line) leaves it open.
        (_, peek) = try await openPeek(from: tabA)
        let cardLayout = model.peekLayout(in: store.keyWindowID, windowSize: content.bounds.size)
        post(CGPoint(x: cardLayout.card.midX, y: cardLayout.card.minY + PeekLayout.addressLineHeight / 2))
        try await Task.sleep(nanoseconds: 400_000_000)
        try check(model.peekSession != nil, "a click on the Peek's address line closed it")
        press("\u{1b}", keyCode: 53, [], in: window, model: model, delivery: .direct)
        try await wait("Esc closes the Peek after the card click") { model.peekSession == nil }

        // With a ⌘-click selection, in the full and the mini sidebar: a ⇧- or
        // ⌘-click on the sidebar only closes the Peek (the selection stays as
        // it was), and Esc closes the Peek before it clears the selection.
        guard let key = store.keyWindowID else { throw Failure(description: "no key browser window") }
        let spare = store.addTab(kind: .today, title: "Peek selection", url: URL(string: "\(base)/b")!,
                                 in: store.spaceContaining(tabID: tabA.id))
        try check(model.handleSelectionClick(on: spare.id, in: key, modifiers: .command), "⌘-click did not select a second row")
        let selection = store.multiSelectedIDs(in: key)
        try check(selection?.count == 2, "the selection is \(selection?.count ?? 0) rows")
        for mini in [false, true] {
            if mini {
                model.sidebarModes.set(.mini, in: key)
                try await Task.sleep(nanoseconds: 400_000_000)
                try check(model.sidebarWidth(in: key) == CGFloat(MiniSidebarLayout.width), "the mini sidebar is \(model.sidebarWidth(in: key)) pt")
            }
            for modifiers in [NSEvent.ModifierFlags.shift, .command] {
                (_, peek) = try await openPeek(from: tabA)
                clickSidebar(modifiers)
                try await wait("a \(modifiers == .shift ? "⇧" : "⌘")-click on the \(mini ? "mini " : "")sidebar closes the Peek") {
                    model.peekSession == nil && runtime.liveLeaseCount(forTab: peek.tabID) == 0
                }
                try check(store.multiSelectedIDs(in: key) == selection && store.selectedItemID == selectedBefore,
                          "the click that closed the Peek changed the \(mini ? "mini " : "")sidebar's selection")
            }
            (_, peek) = try await openPeek(from: tabA)
            press("\u{1b}", keyCode: 53, [], in: window, model: model, delivery: .direct)
            try await wait("Esc closes the Peek over a selection") { model.peekSession == nil }
            try check(store.multiSelectedIDs(in: key) == selection, "Esc cleared the selection along with the Peek")
        }
        model.sidebarModes.set(.full, in: key)
        model.clearSelection(in: key)
        model.closeTab(spare.id)
        model.selectTab(tabA.id)
        try await wait("the full sidebar is back") { model.sidebarWidth(in: key) == model.sidebarWidth }

        let mark = "(function(){ window.__rearcPeekMark = 'kept'; return 1; })()"
        let readMark = "typeof window.__rearcPeekMark === 'string' ? window.__rearcPeekMark : 'reloaded'"
        var (session, expanding) = try await openPeek(from: tabA, path: "/links", title: "links")
        try await navigateInPeek(expanding)
        _ = try await expanding.evaluate(mark, in: .page)
        let chromiumTab = expanding.tabID
        try check(model.performPeekAction(.expandToTab), "Expand did nothing")
        guard let expanded = store.selectedTab, expanded.id == session.engineID,
              model.engineHost.engine(forTabID: expanded.id, profileID: session.profileID) === expanding else {
            throw Failure(description: "Expand did not move the Peek's engine into the selected tab")
        }
        try await wait("expanded tab attached in the window", timeout: 20) {
            expanding.attachmentID != nil && expanding.leaseHolder?.window === window
        }
        let kept = try await expanding.evaluate(readMark, in: .page) as? String
        try check(expanding.role == .tab && expanding.tabID == chromiumTab && kept == "kept" && expanding.canGoBack
                      && expanding.currentURL?.path == "/a" && expanded.url.path == "/a",
                  "expanded Peek: role \(expanding.role) tab \(expanding.tabID) vs \(chromiumTab), mark \(kept ?? "-"), "
                      + "back \(expanding.canGoBack), url \(expanding.currentURL?.absoluteString ?? "-")")
        // The back entry is the Peek's: Back in the tab returns to the page the Peek opened on.
        model.goBack()
        try await wait("Back in the expanded tab returns to the Peek's first page", timeout: 15) {
            expanding.currentURL?.path == "/links" && expanding.pageTitle == "links" && !expanding.isLoading
        }
        model.closeTab(expanded.id)
        model.selectTab(tabA.id)

        (session, expanding) = try await openPeek(from: tabA)
        _ = try await expanding.evaluate(mark, in: .page)
        try check(model.peekSplitAnchor == tabA.id, "tab A cannot take the Peek as a split pane")
        try check(model.performPeekAction(.openInSplitView), "Open in Split View did nothing")
        guard let split = store.splitContaining(tabID: tabA.id)?.split, split.tabs.map(\.id) == [tabA.id, session.engineID],
              model.engineHost.engine(forTabID: session.engineID, profileID: session.profileID) === expanding else {
            throw Failure(description: "Open in Split View made no split of tab A and the Peek's page")
        }
        try await wait("split panes attached", timeout: 20) { engineA.attachmentID != nil && expanding.attachmentID != nil }
        let splitKept = try await expanding.evaluate(readMark, in: .page) as? String
        try check(splitKept == "kept", "the split pane reloaded the Peek's page")
        model.closeTab(session.engineID)
        model.selectTab(tabA.id)
        try await wait("tab A alone after the Peek's pane closed") {
            store.splitContaining(tabID: tabA.id) == nil && engineA.attachmentID != nil
        }
        log("PASS Peek chrome: sidebar, washed-page left and right clicks (from the mouse-down) and Esc close it, a card click "
            + "does not (the click stays out of the sidebar and its ⇧/⌘ selection, "
            + "full and mini; Esc leaves the selection); Expand and Split View "
            + "keep Chromium tab \(chromiumTab)'s page, script state and history")
    }

    @MainActor
    private func automaticPeekChecks(model: BrowserViewModel, store: SidebarStore, base: String, window: NSWindow) async throws {
        let previous = model.automaticPeekEnabled
        model.automaticPeekEnabled = true
        defer { model.automaticPeekEnabled = previous; model.dismissPeek() }
        let source = URL(string: "\(base)/links")!
        let offSite = URL(string: base.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "/a")!
        for kind in [Tab.Kind.pinned, .favorite] {
            let tab = store.addTab(kind: kind, title: "Auto Peek", url: source)
            model.selectTab(tab.id)
            let engine = try shellEngine(model, tab)
            do {
                try await wait("auto Peek source loaded", timeout: 20) {
                    engine.attachmentID != nil && engine.pageTitle == "links" && !engine.isLoading
                }
            } catch {
                throw Failure(description: "the \(kind) auto Peek source never showed: " + shellReport(model, store, tab: tab, engine: engine))
            }
            try await wait("auto Peek script configured") { !engine.automaticPeekUpdating }
            let href = String(data: try JSONEncoder().encode(offSite.absoluteString), encoding: .utf8)!
            _ = try await engine.evaluate("document.querySelector('#plain').href = \(href)", in: .page)
            let center = try await cssCenter(of: "#plain", in: engine)
            click(window, engine: engine, at: center)
            try await wait("off-site \(kind) link opens Peek", timeout: 15) { model.peekSession?.url == offSite }
            let preview = try XCTUnwrapSelfTest(model.peekSession, "automatic Peek session")
            let previewEngine = model.engineHost.ephemeralEngine(withID: preview.engineID, profileID: preview.profileID) as? ChromiumEngine
            try await wait("automatic Peek attached and loaded", timeout: 20) {
                previewEngine?.attachmentID != nil && previewEngine?.pageTitle == Self.titleA && previewEngine?.isLoading == false
            }
            try check(engine.currentURL == source, "auto Peek navigated the source \(kind) tab")
            try check(model.peekSession?.profileID == model.profileID(for: tab), "auto Peek used the wrong profile")
            model.dismissPeek()
            model.automaticPeekEnabled = false
            try await wait("auto Peek disabled in the current document") { !engine.automaticPeekUpdating }
            // Nothing of the closed Peek may still take the page's clicks.
            let closedAt = Date()
            do {
                try await wait("the closed Peek leaves the source page clickable", timeout: 5) {
                    hitReport(window, engine: engine, at: center).hitsPage
                }
            } catch {
                throw Failure(description: "after the \(kind) Peek closed its source page takes no clicks: "
                              + hitReport(window, engine: engine, at: center).text)
            }
            log("auto Peek \(kind) closed: the page takes clicks after \(Int(Date().timeIntervalSince(closedAt) * 1000)) ms; "
                + hitReport(window, engine: engine, at: center).text)
            click(window, engine: engine, at: center, host: engine.leaseHolder)
            try await wait("disabled auto Peek follows link", timeout: 15) { engine.currentURL == offSite && !engine.isLoading }
            try check(model.peekSession == nil, "disabled auto Peek still opened a preview")
            model.deleteTab(tab.id)
            model.automaticPeekEnabled = true
        }
        log("PASS automatic Peek: off-site links from pinned tabs and favorites preserve the source and profile; toggle off navigates normally")
    }

    // MARK: Modified link opens (ABI 1.39)

    /// ⌘-click: a background tab; ⇧⌘-click: a selected tab; ⌥⌘-click: Little
    /// Arc. All on an ordinary link, which wave 26 could not open on Chromium.
    @MainActor
    private func linkOpenChecks(model: BrowserViewModel, store: SidebarStore, tab: Tab, engine: ChromiumEngine, base: String,
                                window: NSWindow) async throws {
        guard runtime.capabilities.linkOpenRequests else {
            log("ABI-GAP link_open_requests not advertised (ABI minor \(minorText) < 39): ⌘-click on ordinary links opens nothing")
            return
        }
        let unknown = runtime.respondLinkOpen(UInt64.max, tab: 0)
        try check(unknown == ReArcStatus(REARC_NOT_FOUND), "a reply to an unknown link open returned \(unknown.rearcName)")
        model.selectTab(tab.id)
        loadShellTab(model, store.tab(withID: tab.id) ?? tab, engine, URL(string: "\(base)/links")!)
        try await wait("tab A on the link fixture", timeout: 15) { engine.pageTitle == "links" && !engine.isLoading }
        guard await bringToFront(window, for: "modified link clicks") else {
            log("NOTE modified link clicks: synthesized input is not deliverable (app active \(NSApp.isActive)); not exercised in this run; "
                + "unknown request -> \(unknown.rearcName)")
            return
        }
        let link = try await cssCenter(of: "#plain", in: engine)
        /// Clicks with `modifiers` until a new sidebar tab (or Little Arc) appears.
        func modifiedClick(_ modifiers: NSEvent.ModifierFlags, opened: () -> Bool) async -> Bool {
            for _ in 0..<3 {
                focus(window)
                model.noteMouseDown(modifiers: modifiers)
                click(window, engine: engine, at: link, modifiers: modifiers)
                if await eventually(timeout: 3, opened) { return true }
            }
            return false
        }
        var results: [String] = []
        for (label, modifiers, selects) in [("⌘-click", NSEvent.ModifierFlags.command, false), ("⇧⌘-click", [.command, .shift], true)] {
            let before = Set(store.displayTabs().map(\.id))
            let eventsBefore = runtime.linkOpenEvents.count
            guard await modifiedClick(modifiers, opened: { store.displayTabs().contains { !before.contains($0.id) } }) else {
                results.append("\(label): NOTE no tab (app active \(NSApp.isActive), key \(window.isKeyWindow))")
                continue
            }
            let created = store.displayTabs().first { !before.contains($0.id) }!
            let createdEngine = try shellEngine(model, created)
            try await wait("\(label) link loaded", timeout: 15) { createdEngine.currentURL?.path == "/a" && createdEngine.pageTitle == Self.titleA }
            let event = runtime.linkOpenEvents.dropFirst(eventsBefore).first
            let selected = store.selectedTabID == created.id
            try check(selected == selects, "\(label): new tab selected \(selected), expected \(selects)")
            try check(engine.pageTitle == "links" && store.spaceContaining(tabID: created.id) == store.activeSpaceID,
                      "\(label): source '\(engine.pageTitle ?? "")', space of the new tab")
            results.append("\(label) -> disposition \(event?.disposition ?? 0), \(selects ? "selected" : "background") tab on /a")
            if !selects {
                // Back on a link-opened tab, with nothing behind it, closes it and returns to
                // the link's tab (owner, 2026-11-21): by swipe here, by ⌘[ on a second one.
                try await openerBackCheck(model: model, store: store, opener: tab, opened: created, engine: createdEngine,
                                          window: window, bySwipe: true)
                let again = Set(store.displayTabs().map(\.id))
                guard await modifiedClick(.command, opened: { store.displayTabs().contains { !again.contains($0.id) } }) else {
                    throw Failure(description: "a second ⌘-click opened no tab for the ⌘[ check")
                }
                let second = store.displayTabs().first { !again.contains($0.id) }!
                let secondEngine = try shellEngine(model, second)
                try await wait("second ⌘-clicked link loaded", timeout: 15) { secondEngine.currentURL?.path == "/a" && !secondEngine.isLoading }
                try await openerBackCheck(model: model, store: store, opener: tab, opened: second, engine: secondEngine,
                                          window: window, bySwipe: false)
                // A target=_blank link: Chromium makes the contents, the shell adopts them as a tab.
                let beforeBlank = Set(store.displayTabs().map(\.id))
                let blankLink = try await cssCenter(of: "#blank", in: engine)
                var blankOpened = false
                for _ in 0..<3 where !blankOpened {
                    focus(window)
                    model.noteMouseDown(modifiers: [])
                    click(window, engine: engine, at: blankLink)
                    blankOpened = await eventually(timeout: 3) { store.displayTabs().contains { !beforeBlank.contains($0.id) } }
                }
                guard blankOpened, let third = store.displayTabs().first(where: { !beforeBlank.contains($0.id) }) else {
                    throw Failure(description: "a click on the target=_blank link opened no tab")
                }
                let thirdEngine = try shellEngine(model, third)
                try await wait("target=_blank link loaded", timeout: 15) { thirdEngine.currentURL?.path == "/a" && !thirdEngine.isLoading }
                try await openerBackCheck(model: model, store: store, opener: tab, opened: third, engine: thirdEngine,
                                          window: window, bySwipe: true)
                results.append("swipe back and ⌘[ on ⌘-clicked tabs, swipe back on a target=_blank tab -> each closed, the link's tab selected")
                model.selectTab(tab.id)
                continue
            }
            model.deleteTab(created.id)
            model.selectTab(tab.id)
        }
        let littleBefore = store.littleArcLiveWindows.count
        if await modifiedClick([.command, .option], opened: { store.littleArcLiveWindows.count > littleBefore }),
           let record = store.littleArcLiveWindows.last, let little = model.littleArcEngine(for: record.id) as? ChromiumEngine {
            try await wait("⌥⌘-clicked ordinary link in Little ReArc", timeout: 15) { little.currentURL?.path == "/a" && little.pageTitle == Self.titleA }
            results.append("⌥⌘-click -> disposition \(runtime.linkOpenEvents.last?.disposition ?? 0), Little ReArc on /a")
            model.windowPresenter?.dismissLittleArcWindow(record.id)
            try await wait("the link's Little ReArc closed") { store.littleArcWindow(withID: record.id) == nil }
        } else {
            results.append("⌥⌘-click: NOTE no Little ReArc")
        }
        let passed = results.filter { !$0.contains("NOTE") }.count
        log("\(passed == results.count ? "PASS" : "NOTE") modified link opens (ABI 1.39) on an ordinary link: \(results.joined(separator: "; ")); "
            + "tab A stayed on its page; unknown request -> \(unknown.rearcName)")
    }

    /// Back on `opened`, a tab a link in `opener` opened, with no page behind it: by a swipe
    /// through the page's swipe handler, or by ⌘[ (`model.goBack`). It closes and `opener` is selected.
    @MainActor
    private func openerBackCheck(model: BrowserViewModel, store: SidebarStore, opener: Tab, opened: Tab, engine: ChromiumEngine,
                                 window: NSWindow, bySwipe: Bool) async throws {
        let how = bySwipe ? "swipe back" : "⌘["
        try check(model.tabOpeners.opener(of: opened.id) == opener.id,
                  "\(how): the link-opened tab's opener is \(String(describing: model.tabOpeners.opener(of: opened.id))), expected the link's tab")
        model.selectTab(opened.id)
        func host() -> ChromiumHostView? {
            var views: [NSView] = window.contentView.map { [$0] } ?? []
            while let view = views.popLast() {
                if let host = view as? ChromiumHostView, host.engine === engine { return host }
                views.append(contentsOf: view.subviews)
            }
            return nil
        }
        try await wait("\(how): the link-opened tab shown", timeout: 10) {
            store.selectedTabID == opened.id && host()?.leaseAttachmentID != nil
        }
        try check(!engine.canGoBack && model.canGoBack(engine),
                  "\(how): page history \(engine.canGoBack), Back enabled \(model.canGoBack(engine)); expected no history and Back enabled")
        if bySwipe {
            guard let host = host() else { throw Failure(description: "swipe back: the link-opened tab has no page view") }
            try await swipe(window: window, host: host, dx: 18)
        } else {
            model.goBack()
        }
        try await wait("\(how) on the link-opened tab closes it and selects the link's tab", timeout: 10) {
            store.tab(withID: opened.id) == nil && store.selectedTabID == opener.id
        }
        log("PASS \(how) on a link-opened tab with no history: it closed and the link's tab is selected")
    }

    // MARK: HTTP authentication (ABI 1.38)

    @MainActor
    private func httpAuthChecks(model: BrowserViewModel, tab: Tab, engine: ChromiumEngine, base: String) async throws {
        guard runtime.capabilities.httpAuth else {
            log("ABI-GAP http_auth not advertised (ABI minor \(minorText) < 38): sign-in challenges are cancelled")
            return
        }
        let unknown = runtime.respondHTTPAuth(UInt64.max, credentials: nil)
        try check(unknown == ReArcStatus(REARC_NOT_FOUND), "a reply to an unknown sign-in returned \(unknown.rearcName)")
        let prompts = engine.pagePrompts
        model.selectTab(tab.id)
        loadShellTab(model, tab, engine, URL(string: "\(base)/auth/basic")!)
        try await wait("the sign-in sheet", timeout: 10) { prompts.httpAuth != nil }
        let first = prompts.httpAuth!.challenge
        try check(first.challenger.hasPrefix("http://127.0.0.1") && first.realm == LoopbackFixtureServer.authRealm
                  && first.scheme.lowercased() == "basic" && !first.isProxy && first.isInsecure, "challenge \(first)")
        prompts.answerHTTPAuth(signIn: false)
        try await wait("the 401 page after Cancel") { engine.pageTitle == "auth-denied" && !engine.isLoading }
        engine.reload(ignoringCache: true)
        try await wait("the sign-in sheet again", timeout: 10) { prompts.httpAuth != nil }
        let second = prompts.httpAuth!.challenge
        prompts.authUsername = LoopbackFixtureServer.authCredentials.username
        prompts.authPassword = LoopbackFixtureServer.authCredentials.password
        prompts.answerHTTPAuth(signIn: true)
        try check(prompts.authPassword.isEmpty, "the sheet kept the password after answering")
        try await wait("the page after Sign In") { engine.pageTitle == "auth-ok" && !engine.isLoading }
        let late = runtime.respondHTTPAuth(second.id, credentials: nil)
        try check(late == ReArcStatus(REARC_NOT_FOUND), "a second reply returned \(late.rearcName)")
        log("PASS HTTP auth (ABI 1.38): '\(first.title)' for \(first.challenger) realm '\(first.realm)' (\(first.scheme), not private) "
            + "-> Cancel showed the 401 page; again -> Sign In loaded 'auth-ok'; second reply -> \(late.rearcName); unknown -> \(unknown.rearcName)")
    }
}

extension NSView {
    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        for child in subviews {
            if let match = child as? T ?? child.firstDescendant(ofType: type) { return match }
        }
        return nil
    }
}

// MARK: Wave 30 shortcuts

extension ChromiumSelfTest {
    /// How the shortcut step's key events travel (ShellInput, shared with the bench).
    typealias KeyDelivery = ShellInput.Delivery

    @MainActor
    private func keyEvent(_ type: NSEvent.EventType, _ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags,
                          in window: NSWindow) -> NSEvent? {
        ShellInput.keyEvent(type, characters, keyCode: keyCode, flags, in: window)
    }

    @MainActor
    private func press(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow,
                       model: BrowserViewModel, delivery: KeyDelivery) {
        ShellInput.press(characters, keyCode: keyCode, flags, in: window, model: model, delivery: delivery)
    }

    @MainActor
    private func eventuallyAsync(timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    @MainActor
    private func releaseModifiers(in window: NSWindow, model: BrowserViewModel, delivery: KeyDelivery) {
        ShellInput.releaseModifiers(in: window, model: model, delivery: delivery)
    }

    @MainActor
    private func moveMouse(to point: NSPoint, in window: NSWindow) {
        ShellInput.moveMouse(to: point, in: window)
    }

    /// Settings › Profiles' Search engine pop-up, through the model the pop-up
    /// draws from (`ProfileSearchEngineRow`) and the call its binding makes.
    /// The shell installs the engine's list at ready; each profile lists its
    /// own engines with its default; choosing one makes it that profile's
    /// default in the engine, read back with a fresh `ReArcSearchListEngines`
    /// and not from the pop-up's copy, while a second profile keeps its own;
    /// after the change the engine still offers the old default and the
    /// pop-up lists the same engines as before; the first profile's default
    /// is put back. The stock settings pages
    /// Darni has replaced (search, downloads) open from no shell route.
    @MainActor
    private func searchEngineChecks(model: BrowserViewModel, store: SidebarStore) async throws {
        // The stock settings pages Darni has replaced, asked for by address as the shell's own routes ask.
        let tabsBefore = store.displayTabs().map(\.id)
        for path in BrowserInternalPage.replacedStockSettingsPaths.sorted() {
            let replaced = try XUnwrap(URL(string: "chrome://\(BrowserInternalPage.stockSettingsHost)\(path)"), "replaced settings address")
            model.openPageInNewTab(replaced, title: "Settings")
            try check(store.displayTabs().map(\.id) == tabsBefore, "the shell opened \(replaced.absoluteString) as a tab")
        }
        try check(!BrowserInternalPage.allCases.contains { BrowserInternalPage.isReplacedStockSettings($0.url) },
                  "a shell page is a stock settings page Darni has replaced")

        guard runtime.capabilities.searchEngines else {
            try check(model.searchEngineSettings == nil, "a search engine list without search_engines")
            log("ABI-GAP search_engines not advertised: Settings › Profiles has no search engine pop-up")
            return
        }
        try check(model.searchEngineSettings is ChromiumSearchEngineSettings,
                  "the shell did not install the engine's search engine list at ready: the pop-up has no source")
        let homeSpace = store.activeSpace
        let homeTab = store.selectedTab
        let home = homeSpace.profileID
        let other = store.addProfile(name: "Search Engine Other")
        store.selectSpace(homeSpace.id)
        func row(_ profile: Profile.ID) -> ProfileSearchEngineRow? { ProfileSearchEngineRow(model: model, profileID: profile) }
        /// The engine's own list for the profile, read now, never the pop-up's copy.
        func engineList(_ profile: Profile.ID) async -> SearchEngineChoices? {
            await withCheckedContinuation { continuation in
                runtime.searchEngines(for: profile) { continuation.resume(returning: $0) }
            }
        }
        /// The engine's own answer for the profile's default, never the pop-up's copy.
        func engineDefault(_ profile: Profile.ID) async -> SearchEngineChoices.Engine? { await engineList(profile)?.current }
        try await wait("the search engine lists of both profiles", timeout: 25) {
            [home, other.id].allSatisfy { (row($0)?.options.count ?? 0) > 1 && row($0)?.selection != nil }
        }
        guard let homeRow = row(home), let otherRow = row(other.id), let original = homeRow.selection,
              let otherBefore = await engineDefault(other.id) else {
            throw Failure(description: "search engines: no list or default for one of the profiles")
        }
        try check(homeRow.isEditable && otherRow.isEditable, "search engines: the pop-up cannot change the default")
        try check(otherRow.selection == String(otherBefore.id), "search engines: the pop-up shows \(otherRow.selection ?? "-") for the second "
                  + "profile, the engine has \(otherBefore.id)")
        // An engine that is neither profile's default now, so that a change in the wrong profile would show.
        guard let pick = homeRow.options.first(where: { $0.id != original && $0.name != otherBefore.name })
            ?? homeRow.options.first(where: { $0.id != original }) else {
            throw Failure(description: "search engines: only one engine to choose (\(homeRow.options.map(\.name)))")
        }
        let provider = model.searchProvider
        // As the pop-up's binding sets it.
        model.setDefaultSearchEngine(pick.id, for: home)
        try await wait("the pop-up shows the chosen engine") { row(home)?.selection == pick.id }
        let homeAfter = await engineDefault(home)
        try check(homeAfter.map { String($0.id) } == pick.id && homeAfter?.name == pick.name,
                  "search engines: chose \(pick.name) (\(pick.id)), the engine's default is \(homeAfter?.name ?? "-") (\(homeAfter?.id ?? 0))")
        // The engine's list after the change: the old default is still offered, and the pop-up
        // lists what the engine offers, in its order (the old default left the pop-up until a
        // relaunch: Chromium's can_make_default is false for the default itself, and the shell
        // moved the default in its own copy without the flag; found on screen 2026-11-22).
        guard let listAfter = await engineList(home) else {
            throw Failure(description: "search engines: no list from the engine after the default changed")
        }
        let offeredAfter = listAfter.offered.map { String($0.id) }
        let listing = listAfter.engines.map { "\($0.name) default=\($0.isDefault) can=\($0.canMakeDefault)" }
        // Chromium lists the default plus its prepopulated engines: a custom old default (the
        // self-test's own local engine, a site search) leaves the engine's list, and the pop-up
        // keeps offering it (`SearchEngineChoices.keeping`; RC 1229's first self-test, 2026-11-22).
        let originalIsCustom = !offeredAfter.contains(original)
        if !originalIsCustom {
            try check(listAfter.engines.first { String($0.id) == original }?.canMakeDefault == true,
                      "search engines: the engine's can_make_default did not move to the old default (\(listing))")
        }
        try check(listAfter.current?.canMakeDefault == false,
                  "search engines: the new default can still be made default in the engine (\(listing))")
        try await wait("the pop-up lists the engine's choices after the change, and the old default", timeout: 10) {
            let shown = row(home)?.options.map(\.id) ?? []
            return Array(shown.prefix(offeredAfter.count)) == offeredAfter && shown.contains(original)
                && shown.count == offeredAfter.count + (originalIsCustom ? 1 : 0)
        }
        // The same engines (a custom old default moves to the end of the list).
        try check(Set(row(home)?.options.map(\.id) ?? []) == Set(homeRow.options.map(\.id)),
                  "search engines: the pop-up listed \(homeRow.options.map(\.name)) and after choosing \(pick.name) lists "
                  + "\(row(home)?.options.map(\.name) ?? []): choosing an engine changed the list")
        let otherAfter = await engineDefault(other.id)
        try check(otherAfter?.id == otherBefore.id && otherAfter?.name == otherBefore.name && row(other.id)?.selection == otherRow.selection,
                  "search engines: the second profile's default changed with the first's (\(otherBefore.name) -> \(otherAfter?.name ?? "-"))")

        // Back as it was: the steps after this one search through the first profile's default.
        model.setDefaultSearchEngine(original, for: home)
        try await waitAsync("the first profile's default search put back", timeout: 15) {
            await engineDefault(home).map { String($0.id) } == original
        }
        try await wait("the pop-up as it was, the default and the list", timeout: 10) {
            row(home)?.selection == original && Set(row(home)?.options.map(\.id) ?? []) == Set(homeRow.options.map(\.id))
        }
        if let services = model.commandBarServices as? ChromiumCommandBarServices {
            services.refreshSearchProvider(for: home)
            try await wait("the command bar's search provider as before", timeout: 10) {
                model.searchProvider.searchTemplate == provider.searchTemplate
            }
        }
        try check(model.deleteProfile(other.id, deletingSpaces: true) == nil, "search engines: the extra profile could not be deleted")
        if let homeTab {
            model.selectTab(homeTab.id)
            try await wait("search engines: the first tab shown again", timeout: 15) {
                store.selectedTab?.id == homeTab.id && store.activeSpaceID == homeSpace.id
            }
        }
        log("PASS search engine pop-up (Settings › Profiles): the engine's list installed at ready; \(homeRow.options.count) engines in the "
            + "first profile, \(otherRow.options.count) in a second; choosing \(pick.name) made it the first profile's default in the "
            + "engine (ReArcSearchListEngines), the second kept \(otherBefore.name); the old default still offered and the pop-up's list "
            + "unchanged after the change; default put back; no shell route opens Chromium's "
            + "search or download settings pages")
    }

    /// Wave 35 (ARC-RECORDING-2026-11-06 §6.4 item 9): ⌘, opens ReArc's own
    /// Settings window, not a chrome://settings tab; every pane shows under its
    /// toolbar item with its name as the title; a switch and a recorded shortcut
    /// reach the menu bar and are saved where the next launch reads them. The
    /// step writes to a throwaway defaults suite, never the user's.
    @MainActor
    private func settingsWindowChecks(model: BrowserViewModel, shell: ChromiumShell, window: NSWindow) async throws {
        let suite = "rearc-selftest-settings-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "no defaults suite for Settings") }
        let realDefaults = model.externalLinkDefaults
        let saved = (pane: model.settingsPane, warn: model.warnBeforeQuitting, overrides: model.shortcutOverrides)
        model.externalLinkDefaults = defaults
        defer {
            shell.settingsWindowForTesting?.close()
            model.shortcutOverrides = saved.overrides
            model.warnBeforeQuitting = saved.warn
            model.settingsPane = saved.pane
            model.externalLinkDefaults = realDefaults
            defaults.removePersistentDomain(forName: suite)
        }
        let tabsBefore = model.store.displayTabs().count
        guard let comma = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                                           windowNumber: window.windowNumber, context: nil, characters: ",",
                                           charactersIgnoringModifiers: ",", isARepeat: false, keyCode: 43) else {
            throw Failure(description: "no ⌘, event")
        }
        try check(NSApp.mainMenu?.performKeyEquivalent(with: comma) == true, "⌘, ran no menu item")
        try await wait("Settings window after ⌘,") { shell.settingsWindowForTesting?.isVisible == true }
        try check(model.store.displayTabs().count == tabsBefore, "⌘, opened a tab (chrome://settings) instead of the window")
        guard let settings = shell.settingsWindowForTesting else { throw Failure(description: "no Settings window") }
        let toolbar = settings.toolbar?.items.map(\.itemIdentifier.rawValue) ?? []
        try check(toolbar == SettingsPane.allCases.map(\.rawValue), "Settings toolbar \(toolbar)")
        let account = settings.toolbar?.items.first?.label
        try check(account == model.accountName, "the account item is labelled \(account ?? "nil"), not the profile's name")
        var heights: [String] = []
        for pane in SettingsPane.allCases {
            model.settingsPane = pane
            let title = pane.title(accountName: model.accountName)
            try await wait("Settings pane \(title)") {
                settings.title == title && settings.toolbar?.selectedItemIdentifier?.rawValue == pane.rawValue
            }
            settings.contentView?.layoutSubtreeIfNeeded()
            // Arc's fixed 684 × 650 for every pane; long ones scroll inside.
            try check(settings.frame.size == SettingsMetrics.windowSize, "the \(title) pane made the window \(settings.frame.size)")
            heights.append("\(title) \(Int(settings.frame.width))×\(Int(settings.frame.height))")
        }
        // A switch and a shortcut, set as the panes set them.
        model.warnBeforeQuitting.toggle()
        let chord = ShortcutChord(.character("y"), [.control, .option, .command])
        model.shortcutOverrides.set(chord, for: "newTab")
        let file = NSApp.mainMenu?.items.first { $0.title == "File" }?.submenu
        guard let newTab = file?.items.first(where: { $0.title == "New Tab" }) else { throw Failure(description: "no File > New Tab") }
        try check(newTab.keyEquivalent == "y" && newTab.keyEquivalentModifierMask == [.control, .option, .command],
                  "File > New Tab shows \(newTab.keyEquivalent) \(newTab.keyEquivalentModifierMask.rawValue), not ⌃⌥⌘Y")
        // What the next launch reads (each setting loads from these keys at model init).
        try check(QuitWarning.isEnabled(in: defaults) == model.warnBeforeQuitting, "Warn before quitting was not saved")
        try check(ShortcutOverrides.load(from: defaults).chord(for: "newTab") == chord, "the recorded shortcut was not saved")
        try check(SettingsPane.load(from: defaults) == SettingsPane.allCases.last, "the last pane was not remembered")
        model.shortcutOverrides.resetAll()
        try check(newTab.keyEquivalent == "t" && newTab.keyEquivalentModifierMask == .command, "Reset All left New Tab on \(newTab.keyEquivalent)")
        log("PASS Settings window (wave 35): ⌘, opens it with no tab, \(SettingsPane.allCases.count) panes (\(heights.joined(separator: ", "))), "
            + "Warn before quitting and a recorded ⌃⌥⌘Y for New Tab saved for the next launch and on the menu bar; Reset All restores ⌘T")
    }

    /// Wave 30: Arc's shortcuts with page content focused, as real key events
    /// through AppKit's dispatch. First the bug (routing off: ⌘S reaches the
    /// page and is dropped), then ⌘S (must pass), ⌘L, ⇧⌘C / ⌥⇧⌘C on the
    /// pasteboard, ⌘T, ⌘W, ⌃Tab, ⌘1, ⌃1/⌃2, ⌘D and ⌘R, then a page that calls
    /// preventDefault on every keydown.
    @MainActor
    private func shortcutChecks(model: BrowserViewModel, store: SidebarStore, tab: Tab, engine: ChromiumEngine, base: String,
                                window: NSWindow) async throws {
        guard runtime.capabilities.keyEquivalentEvents else {
            log("ABI-GAP key_equivalent_events not advertised (ABI minor \(runtime.capabilities.abiMinorVersion.map(String.init) ?? "absent") < 42): "
                + "only Arc-wins shortcuts work while a page has focus")
            return
        }
        let delivery: KeyDelivery = await bringToFront(window, for: "shortcuts") ? .appKit : .direct
        let mode = delivery == .appKit ? "posted to the event queue" : "direct dispatch"
        if delivery == .direct {
            log("NOTE shortcuts: no key window (app active \(NSApp.isActive), screen locked "
                + "\((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false)), so AppKit "
                + "would drop posted keys: each key goes through the app's key monitor, then the page view's own "
                + "keyEvent:wasKeyEquivalent:YES (performKeyEquivalent: past its key-window check), as AppKit orders them; the "
                + "Esc key, Control's release and the field's selection are checked the same way")
        }
        let router = model.shortcutRouter
        func press(_ characters: String, keyCode: UInt16, _ flags: NSEvent.ModifierFlags, in window: NSWindow) {
            self.press(characters, keyCode: keyCode, flags, in: window, model: model, delivery: delivery)
        }
        func releaseModifiers(in window: NSWindow) {
            self.releaseModifiers(in: window, model: model, delivery: delivery)
        }
        let realPasteboard = model.linkPasteboard
        model.linkPasteboard = NSPasteboard(name: NSPasteboard.Name("rearc-selftest-keys-\(UUID().uuidString)"))
        defer {
            model.linkPasteboard = realPasteboard
            router.isEnabled = true
        }
        func pageKeys(_ page: ChromiumEngine = engine) async -> [String] {
            let joined = (try? await page.evaluate("window.rearcKeys ? window.rearcKeys.join(',') : ''", in: .page)) as? String ?? ""
            return joined.split(separator: ",").map(String.init)
        }
        func pageFocused() -> Bool { ShortcutRouter.isWebContent(window.firstResponder) }
        func focusPage(_ page: ChromiumEngine = engine) async throws {
            if delivery == .appKit { window.makeKeyAndOrderFront(nil) }
            try check(page.focusPage(), "tab \(page.tabID) took no keyboard focus")
            try await wait("page focused") { pageFocused() }
            // First responder reaches the renderer asynchronously, and keys before
            // it never reach the page: a plain x (no shortcut) until the page sees one.
            let deadline = Date().addingTimeInterval(6)
            while !(await pageKeys(page).contains(":x")) {
                guard Date() < deadline else {
                    var widgets: [String] = []
                    var queue = page.leaseHolder.map { [$0 as NSView] } ?? []
                    while !queue.isEmpty {
                        let view = queue.removeFirst()
                        if NSStringFromClass(Swift.type(of: view)).contains("RenderWidgetHostViewCocoa") {
                            widgets.append("\(ObjectIdentifier(view).hashValue % 10000)\(view.isHidden ? " hidden" : "")"
                                + "\(view === window.firstResponder ? " first-responder" : "")\(view.isHiddenOrHasHiddenAncestor ? " (hidden ancestor)" : "")")
                        }
                        queue.append(contentsOf: view.subviews)
                    }
                    throw Failure(description: "tab \(page.tabID)'s page took no key: widgets [\(widgets.joined(separator: ", "))], "
                        + "keys \(await pageKeys(page)), url \(page.currentURL?.absoluteString ?? "")")
                }
                press("x", keyCode: 7, [], in: window)
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
        func show(_ url: String, on page: ChromiumEngine = engine, tab shown: Tab = tab) async throws {
            loadShellTab(model, store.tab(withID: shown.id) ?? shown, page, URL(string: url)!)
            try await wait("\(url) loaded", timeout: 20) {
                page.currentURL?.absoluteString == url && page.pageTitle == "keys" && !page.isLoading
                    && page.attachmentID != nil && page.leaseHolder?.window === window
            }
            // A tab switch just before (⌘W's) still detaches views, and a detaching
            // view that held focus hands it to the window: let it settle first.
            try await Task.sleep(nanoseconds: 500_000_000)
            try await focusPage(page)
        }
        func commandBarFieldFocused() -> Bool { (window.firstResponder as? NSTextView)?.isFieldEditor == true }
        func waitForCommandBarField(_ label: String) async throws {
            guard await eventually(timeout: 5, { commandBarFieldFocused() }) else {
                throw Failure(description: "\(label): the command bar's field has no focus; first responder "
                    + "\(window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none"), bar shown \(model.isCommandBarPresented)")
            }
        }
        var escapeRetries: [String] = []
        /// Esc in the bar's field, after the field settles; a second Esc is
        /// reported, never hidden.
        func pressEscape(_ label: String) async throws {
            try await Task.sleep(nanoseconds: 300_000_000)
            press("\u{1b}", keyCode: 53, [], in: window)
            if await eventually(timeout: 2, { !model.isCommandBarPresented }) { return }
            escapeRetries.append(label)
            press("\u{1b}", keyCode: 53, [], in: window)
        }
        func escapeCommandBar(_ label: String) async throws {
            try await waitForCommandBarField(label)
            try await pressEscape(label)
            try await wait("Esc closed the command bar after \(label)") { !model.isCommandBarPresented }
            try await wait("the page has focus again after \(label)'s command bar") { pageFocused() }
        }
        var results: [String] = []

        // Before the fix: with routing off, ⌘S reaches the focused page, which
        // does not take it, and RenderWidgetHostViewCocoa never hands it to the menu.
        try await show("\(base)/keys?utm_source=selftest")
        let sidebarShown = model.isSidebarVisible(in: model.store.keyWindowID)
        router.isEnabled = false
        press("s", keyCode: 1, .command, in: window)
        try await waitAsync("⌘S reached the page with routing off", timeout: 5) { await pageKeys().contains("M:s") }
        try await Task.sleep(nanoseconds: 600_000_000)
        try check(model.isSidebarVisible(in: model.store.keyWindowID) == sidebarShown, "with routing off ⌘S still toggled the sidebar: the diagnosis does not hold")
        router.isEnabled = true
        log("PASS shortcut diagnosis (\(mode)): routing off, ⌘S on a focused page reached it (keydown M:s) and was dropped (sidebar "
            + "unchanged): RenderWidgetHostViewCocoa takes every key equivalent before the main menu")

        // ⌘S (must pass): hides and shows the sidebar; the page keeps focus; the content takes the width.
        try check(model.isSidebarVisible(in: model.store.keyWindowID), "the sidebar is hidden before ⌘S")
        let shownWidth = engine.leaseHolder?.bounds.width ?? 0
        press("s", keyCode: 1, .command, in: window)
        try await wait("⌘S hid the sidebar", timeout: 5) { !model.isSidebarVisible(in: model.store.keyWindowID) }
        try await Task.sleep(nanoseconds: 700_000_000)
        try check(pageFocused(), "⌘S moved keyboard focus to \(String(describing: window.firstResponder))")
        let hiddenWidth = engine.leaseHolder?.bounds.width ?? 0
        try check(hiddenWidth > shownWidth + model.sidebarWidth(in: model.store.keyWindowID) * 0.8, "the page did not take the sidebar's width (\(shownWidth) -> \(hiddenWidth))")
        moveMouse(to: NSPoint(x: 2, y: window.frame.height / 2), in: window)
        try await wait("the window edge floats the hidden sidebar") { model.isSidebarPeeking(in: model.store.keyWindowID) }
        moveMouse(to: NSPoint(x: model.sidebarWidth(in: model.store.keyWindowID) + 120, y: window.frame.height / 2), in: window)
        try await wait("leaving the floating sidebar hides it") { !model.isSidebarPeeking(in: model.store.keyWindowID) }
        try check(abs((engine.leaseHolder?.bounds.width ?? 0) - hiddenWidth) < 1, "the floating sidebar resized the page")
        try await focusPage()
        press("s", keyCode: 1, .command, in: window)
        try await wait("⌘S showed the sidebar", timeout: 5) { model.isSidebarVisible(in: model.store.keyWindowID) }
        try await Task.sleep(nanoseconds: 700_000_000)
        try check(pageFocused(), "showing the sidebar moved keyboard focus")
        try check(abs((engine.leaseHolder?.bounds.width ?? 0) - shownWidth) < 1, "the page did not give the width back")
        let sKeys = await pageKeys().filter { $0 == "M:s" }.count
        try check(sKeys == 3, "the page saw ⌘S \(sKeys) times, not 3 (website-first keys reach it first)")
        results.append("⌘S hid (page \(Int(shownWidth)) -> \(Int(hiddenWidth)) pt, edge hover floats it over the page) and showed the "
            + "sidebar, focus stayed on the page")

        // ⌘L: the command bar with the URL selected; the page never sees ⌘L; Esc gives the page focus back.
        try await Task.sleep(nanoseconds: 200_000_000)
        press("l", keyCode: 37, .command, in: window)
        try await wait("⌘L opened the command bar") { model.isCommandBarPresented }
        let url = store.tab(withID: tab.id)?.url.absoluteString ?? ""
        try check(model.commandBarText == url, "⌘L filled '\(model.commandBarText)', not '\(url)'")
        guard await eventually(timeout: 10, {
            guard let field = window.firstResponder as? NSTextView else { return false }
            return field.string == url && field.selectedRange() == NSRange(location: 0, length: (url as NSString).length)
        }) else {
            let field = window.firstResponder as? NSTextView
            throw Failure(description: "the command bar's URL is not selected: first responder "
                + "\(window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none"), field '\(field?.string ?? "")' "
                + "selection \(field.map { NSStringFromRange($0.selectedRange()) } ?? "-"), model '\(model.commandBarText)', "
                + "bar shown \(model.isCommandBarPresented), live rows \(model.commandBarResults.count)")
        }
        try await escapeCommandBar("⌘L")
        results.append("⌘L opened the command bar on '\(url)' fully selected; Esc returned focus to the page")

        // ⇧⌘C / ⌥⇧⌘C: the pasteboard gets the link without trackers, with Arc's toast.
        press("C", keyCode: 8, [.command, .shift], in: window)
        try await wait("⇧⌘C copied the URL") { model.linkPasteboard.string(forType: .string) == "\(base)/keys" }
        try check(model.toast?.message == PageLinkCopyFormat.cleanConfirmation, "⇧⌘C toast '\(model.toast?.message ?? "")'")
        press("C", keyCode: 8, [.command, .shift, .option], in: window)
        try await wait("⌥⇧⌘C copied the Markdown link") { model.linkPasteboard.string(forType: .string) == "[keys](\(base)/keys)" }
        try check(pageFocused(), "copying moved focus")
        results.append("⇧⌘C put '\(base)/keys' on the pasteboard (utm_source stripped, toast '\(PageLinkCopyFormat.cleanConfirmation)'), "
            + "⌥⇧⌘C '[keys](\(base)/keys)'")

        // ⌘T: the command bar for a new tab, made only when a page is chosen
        // (perf-2); tab A stays selected and Esc leaves no tab behind.
        let rows = store.displayTabs().count
        press("t", keyCode: 17, .command, in: window)
        try await wait("⌘T opened the command bar for a new tab") {
            model.isCommandBarPresented && model.commandBarCreatesNewTab && model.commandBarText.isEmpty
        }
        try check(store.displayTabs().count == rows && store.selectedTabID == tab.id, "⌘T made a tab before a page was chosen")
        try await waitForCommandBarField("⌘T")
        try await pressEscape("⌘T")
        try await wait("Esc after ⌘T left no tab and kept tab A") {
            !model.isCommandBarPresented && store.displayTabs().count == rows && store.selectedTabID == tab.id
        }
        try await wait("tab A shown after ⌘T") { engine.leaseHolder?.window === window && engine.attachmentID != nil }
        try await wait("the page has focus again after ⌘T") { pageFocused() }
        results.append("⌘T opened the command bar (field focused) without making a tab; Esc left none and refocused tab A")

        // ⌘D: pin and unpin with Arc's toasts.
        press("d", keyCode: 2, .command, in: window)
        try await wait("⌘D pinned tab A") { store.kind(of: tab.id) == .pinned }
        try check(model.toast?.message.hasPrefix("Pinned Tab to “") == true, "⌘D toast '\(model.toast?.message ?? "")'")
        try await wait("tab A shown after pinning") { engine.leaseHolder?.window === window && engine.attachmentID != nil }
        if !pageFocused() { try await focusPage() }
        press("d", keyCode: 2, .command, in: window)
        try await wait("⌘D unpinned tab A") { store.kind(of: tab.id) == .today }
        try await wait("tab A shown after unpinning") { engine.leaseHolder?.window === window && engine.attachmentID != nil }
        results.append("⌘D pinned then unpinned tab A ('Pinned Tab to …' / 'Un-Pinned Tab from …')")

        // ⌘R: the page does not take it, so the menu reloads.
        try await focusPage()
        _ = try await engine.evaluate("(window.rearcMarker = 1, 1)", in: .page)
        press("r", keyCode: 15, .command, in: window)
        try await waitAsync("⌘R reloaded the page", timeout: 10) {
            let marker = try? await engine.evaluate("window.rearcMarker === 1", in: .page) as? Bool
            return marker == false && !engine.isLoading
        }
        try await focusPage()
        results.append("⌘R (page first, not taken) reloaded")

        // ⌘1: the sidebar's first row.
        if let first = store.displayEntries().first, first.id != tab.id, !(first.isFolder) {
            press("1", keyCode: 18, .command, in: window)
            try await wait("⌘1 selected the first row") { store.selectedItemID == first.id }
            model.selectTab(tab.id)
            try await wait("tab A shown after ⌘1") { engine.leaseHolder?.window === window && engine.attachmentID != nil }
            try await focusPage()
            results.append("⌘1 selected the first sidebar row")
        } else {
            press("9", keyCode: 25, .command, in: window)
            let last = store.displayEntries().last?.id
            try await wait("⌘9 selected the last row") { store.selectedItemID == last }
            model.selectTab(tab.id)
            try await wait("tab A shown after ⌘9") { engine.leaseHolder?.window === window && engine.attachmentID != nil }
            try await focusPage()
            results.append("⌘9 selected the last sidebar row (tab A is the first)")
        }

        // ⌃2 / ⌃1: Space switching from a focused page.
        var addedSpace: Space.ID?
        if store.spacesInActiveProfile.count < 2 { addedSpace = store.addSpace(name: "Shortcuts", profileID: store.activeProfileID).id }
        let firstSpace = store.activeSpaceID
        let secondSpace = store.spacesInActiveProfile.first { $0.id != firstSpace }?.id
        let secondIndex = store.spacesInActiveProfile.firstIndex { $0.id == secondSpace } ?? 1
        let firstIndex = store.spacesInActiveProfile.firstIndex { $0.id == firstSpace } ?? 0
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
        press("\(secondIndex + 1)", keyCode: digits[secondIndex], .control, in: window)
        try await wait("⌃\(secondIndex + 1) switched to the other space") { store.activeSpaceID == secondSpace }
        press("\(firstIndex + 1)", keyCode: digits[firstIndex], .control, in: window)
        try await wait("⌃\(firstIndex + 1) switched back") { store.activeSpaceID == firstSpace }
        if let addedSpace { _ = store.removeSpace(addedSpace) }
        model.selectTab(tab.id)
        try await wait("tab A shown after the space switch") { engine.leaseHolder?.window === window && engine.attachmentID != nil }
        try await focusPage()
        results.append("⌃\(secondIndex + 1) and ⌃\(firstIndex + 1) switched spaces from the focused page")

        // ⌃Tab: the switcher from a focused page; releasing Control shows the most recent other tab.
        if store.recentTabSwitcherItems().count > 1 {
            let expected = store.recentTabSwitcherItems()[1].id
            // The step has failed with a lost synthetic press (808, 2026-11-16); this
            // line tells that apart from a switcher that could not open.
            let key = NSApp.keyWindow
            log("⌃Tab precondition: key \(key.map { String(describing: Swift.type(of: $0)) } ?? "nil") is the test window \(key === window), "
                + "sheet \(key?.attachedSheet != nil), command bar \(model.isCommandBarPresented), little arc \(model.keyLittleArcID != nil), "
                + "private \(model.keyPrivateWindow != nil), recent \(store.recentTabSwitcherItems().count)")
            press("\t", keyCode: 48, .control, in: window)
            try await wait("⌃Tab opened the switcher") { model.tabSwitcher != nil }
            releaseModifiers(in: window)
            try await wait("releasing ⌃ selected the recent tab") { model.tabSwitcher == nil && store.selectedTabID == expected }
            model.selectTab(tab.id)
            try await wait("tab A shown after ⌃Tab") { engine.leaseHolder?.window === window && engine.attachmentID != nil }
            try await focusPage()
            results.append("⌃Tab switched to the most recent other tab")
        }

        // ⌘W: closes the focused tab.
        let doomed = store.addTab(kind: .today, title: "Keys W", url: URL(string: "\(base)/keys")!)
        model.selectTab(doomed.id)
        let doomedEngine = try shellEngine(model, doomed)
        try await show("\(base)/keys?w=1", on: doomedEngine, tab: doomed)
        press("w", keyCode: 13, .command, in: window)
        try await wait("⌘W closed the focused tab") { store.tab(withID: doomed.id) == nil }
        model.selectTab(tab.id)
        try await wait("tab A shown after ⌘W") { engine.leaseHolder?.window === window && engine.attachmentID != nil }
        results.append("⌘W closed the focused tab")
        let plainKeys = await pageKeys()
        for arcWins in ["M:l", "MS:c", "MAS:c", "M:t", "M:w", "C:tab"] {
            try check(!plainKeys.contains(arcWins), "the page saw the Arc-wins key \(arcWins): \(plainKeys)")
        }
        log("PASS shortcuts with the page focused (real key events, \(mode)): " + results.joined(separator: "; ")
            + "; the page saw none of ⌘L, ⇧⌘C, ⌥⇧⌘C, ⌘T, ⌘W, ⌃Tab")

        // A page that calls preventDefault on every keydown.
        try await show("\(base)/keys?block=1&utm_source=selftest")
        var blocked: [String] = []
        _ = try await engine.evaluate("(window.rearcMarker = 1, 1)", in: .page)
        try check(pageFocused(), "the blocking page lost focus before ⌘R")
        press("r", keyCode: 15, .command, in: window)
        if !(await eventuallyAsync(timeout: 5, { await pageKeys().contains("M:r") })) {
            throw Failure(description: "the blocking page never saw ⌘R: keys \(await pageKeys()), first responder "
                + "\(window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none") (page view "
                + "\(window.firstResponder === engine.leaseHolder?.pageKeyView)), router \(router.history.suffix(4)), "
                + "verdicts \(runtime.keyEquivalentEvents.suffix(4).map { "\($0.characters)/\($0.consumed)" })")
        }
        try await Task.sleep(nanoseconds: 800_000_000)
        let kept = try await engine.evaluate("window.rearcMarker === 1", in: .page) as? Bool
        try check(kept == true, "⌘R reloaded a page that took it (the website wins)")
        blocked.append("⌘R stayed with the page (website wins)")

        let visible = model.isSidebarVisible(in: model.store.keyWindowID)
        press("s", keyCode: 1, .command, in: window)
        try await wait("the page took ⌘S: Arc's prompt") { model.toast?.message == "Press ⌘S again to Show/Hide Sidebar" }
        try check(model.isSidebarVisible(in: model.store.keyWindowID) == visible, "the first ⌘S toggled the sidebar although the page took it")
        press("s", keyCode: 1, .command, in: window)
        try await wait("the second ⌘S toggled the sidebar") { model.isSidebarVisible(in: model.store.keyWindowID) != visible }
        let blockedS = await pageKeys().filter { $0 == "M:s" }.count
        try check(blockedS == 1, "the page saw ⌘S \(blockedS) times, not once")
        model.toggleSidebar()
        try await wait("sidebar restored") { model.isSidebarVisible(in: model.store.keyWindowID) == visible }
        if !pageFocused() { try await focusPage() }
        blocked.append("⌘S once: the page took it and 'Press ⌘S again to Show/Hide Sidebar' showed; twice: the sidebar toggled")

        press("l", keyCode: 37, .command, in: window)
        try await wait("⌘L opened the command bar over a blocking page") { model.isCommandBarPresented }
        try await escapeCommandBar("⌘L on the blocking page")
        press("C", keyCode: 8, [.command, .shift], in: window)
        try await wait("⇧⌘C copied over a blocking page") { model.linkPasteboard.string(forType: .string) == "\(base)/keys?block=1" }
        let tabsBefore = store.displayTabs().count
        press("t", keyCode: 17, .command, in: window)
        try await wait("⌘T over a blocking page") { model.isCommandBarPresented }
        try await waitForCommandBarField("⌘T over a blocking page")
        try await pressEscape("⌘T on the blocking page")
        try await wait("Esc after ⌘T on the blocking page") { !model.isCommandBarPresented && store.displayTabs().count == tabsBefore }
        model.selectTab(tab.id)
        try await wait("tab A shown again") { engine.leaseHolder?.window === window && engine.attachmentID != nil }
        try await focusPage()
        if store.recentTabSwitcherItems().count > 1 {
            let expected = store.recentTabSwitcherItems()[1].id
            press("\t", keyCode: 48, .control, in: window)
            try await wait("⌃Tab over a blocking page") { model.tabSwitcher != nil }
            releaseModifiers(in: window)
            try await wait("⌃Tab release over a blocking page") { model.tabSwitcher == nil && store.selectedTabID == expected }
            model.selectTab(tab.id)
            try await wait("tab A shown after ⌃Tab") { engine.leaseHolder?.window === window && engine.attachmentID != nil }
        }
        let blockedKeys = await pageKeys()
        for arcWins in ["M:l", "MS:c", "M:t", "C:tab"] {
            try check(!blockedKeys.contains(arcWins), "the blocking page saw the Arc-wins key \(arcWins): \(blockedKeys)")
        }
        blocked.append("⌘L, ⇧⌘C ('\(base)/keys?block=1'), ⌘T and ⌃Tab never reached it")
        log("PASS shortcuts over a page that calls preventDefault on every keydown (\(mode)): " + blocked.joined(separator: "; ")
            + " [router: \(router.history.suffix(6).joined(separator: " | "))]"
            + (escapeRetries.isEmpty ? "" : "; NOTE Esc needed a second press after \(escapeRetries.joined(separator: ", "))"))

        loadShellTab(model, store.tab(withID: tab.id) ?? tab, engine, URL(string: "\(base)/a")!)
        try await wait("tab A back on /a", timeout: 20) { engine.pageTitle == Self.titleA && !engine.isLoading }
    }
}

// MARK: Wave 33 UI checks (THEMES-STATUS.md §5)

extension ChromiumSelfTest {
    /// SwiftUI's virtual AccessibilityNode implements the accessibility
    /// selectors without declaring NSAccessibilityProtocol conformance. Keep
    /// those nodes as well as AppKit views when walking the public AX tree.
    private struct TestAccessibilityElement {
        let object: NSObject

        func read(_ key: String) -> Any? {
            guard object.responds(to: NSSelectorFromString(key)) else { return nil }
            return object.value(forKey: key)
        }

        func accessibilityLabel() -> String? { read("accessibilityLabel") as? String }
        func accessibilityFrame() -> NSRect { (read("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
        /// VoiceOver's press: a SwiftUI button runs its action, with no synthesized input.
        func press() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard object.responds(to: selector) else { return false }
            typealias Press = @convention(c) (NSObject, Selector) -> Bool
            return unsafeBitCast(object.method(for: selector), to: Press.self)(object, selector)
        }
        var children: [TestAccessibilityElement] {
            (read("accessibilityChildren") as? [NSObject] ?? []).map { TestAccessibilityElement(object: $0) }
        }
    }

    @MainActor
    private func accessibilityElements(under root: NSObject) -> [TestAccessibilityElement] {
        var found: [TestAccessibilityElement] = [], queue = [TestAccessibilityElement(object: root)]
        var visited = Set<ObjectIdentifier>()
        while !queue.isEmpty, found.count < 5000 {
            let element = queue.removeFirst()
            guard visited.insert(ObjectIdentifier(element.object)).inserted else { continue }
            found.append(element)
            queue.append(contentsOf: element.children)
        }
        return found
    }

    @MainActor
    private func accessibilityElement(in window: NSWindow, labelled label: String) -> TestAccessibilityElement? {
        guard let root = window.contentView else { return nil }
        return accessibilityElements(under: root).first { ($0.accessibilityLabel() ?? "").contains(label) }
    }

    /// A left click posted at a screen point in `window`.
    @MainActor
    private func click(atScreen point: NSPoint, in window: NSWindow) {
        let location = window.convertPoint(fromScreen: point)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    /// Whether this process may post input through the window server. A run
    /// started from a terminal inherits the terminal's Accessibility grant; a
    /// LaunchServices launch (`open`) is its own responsible process, and
    /// without a grant of its own macOS drops its posted clicks silently.
    private var canPostSystemInput: Bool { CGPreflightPostEventAccess() }

    private func systemInputNote(_ checks: String) -> String {
        "NOTE \(checks) skipped: this process may not post window-server input "
            + "(no Accessibility grant; run the self-test from a terminal, as bundle-chromium.sh and release.sh do)"
    }

    /// A left click through the window server at a screen point, as a mouse
    /// gives it: SwiftUI buttons ignore clicks posted to the app's queue.
    /// The pointer is moved there first and given time to settle: the first
    /// click after it jumps across the screen is dropped.
    @MainActor
    private func systemClick(atScreen point: NSPoint) async throws {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        let location = CGPoint(x: point.x, y: top - point.y)
        let source = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<2 {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    private func popoverWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && NSStringFromClass(Swift.type(of: $0)).contains("Popover") }
    }

    /// Wave 33's checks that need the screen: the traffic lights after ⌘S,
    /// a peek and full screen; where the theme popover opens; the toast's
    /// share button; the media strip around Picture in Picture.
    @MainActor
    func wave33UIChecks(model: BrowserViewModel, store: SidebarStore, tab: Tab, engine: ChromiumEngine, other: Tab, window: NSWindow) async throws {
        guard await bringToFront(window, for: "wave 33 UI checks") else {
            log("NOTE wave 33 UI checks skipped: they need the window on an unlocked screen")
            return
        }
        var results: [String] = []
        func lightsHidden() -> Bool { window.standardWindowButton(.closeButton)?.isHidden ?? true }
        func toggle(_ visible: Bool) async throws {
            guard model.isSidebarVisible(in: model.store.keyWindowID) != visible else { return }
            model.toggleSidebar()
            try await wait("sidebar \(visible ? "shown" : "hidden")", timeout: 5) { model.isSidebarVisible(in: model.store.keyWindowID) == visible && !model.isSidebarSliding(in: model.store.keyWindowID) }
        }

        // (2) Traffic lights: hidden with the sidebar, shown during a peek, back after ⌘S, also in full screen.
        try await toggle(true)
        try await wait("traffic lights shown with the sidebar", timeout: 3) { !lightsHidden() }
        try await toggle(false)
        try await wait("traffic lights hidden with the sidebar", timeout: 3) { lightsHidden() }
        model.setSidebarPeeking(true)
        try await wait("traffic lights shown during a peek", timeout: 3) { !lightsHidden() }
        model.setSidebarPeeking(false)
        try await wait("traffic lights hidden after the peek", timeout: 3) { lightsHidden() }
        try await toggle(true)
        try await wait("traffic lights back after ⌘S following a peek", timeout: 3) { !lightsHidden() }
        window.toggleFullScreen(nil)
        try await wait("window in full screen", timeout: 8) { window.styleMask.contains(.fullScreen) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await toggle(false)
        try await toggle(true)
        window.toggleFullScreen(nil)
        try await wait("window out of full screen", timeout: 8) { !window.styleMask.contains(.fullScreen) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try await wait("traffic lights back after ⌘S in full screen", timeout: 3) { !lightsHidden() }
        results.append("(2) traffic lights hide with the sidebar, show during a peek and after ⌘S, and are back after ⌘S in full screen")

        // (3) Edit Theme Color opens the editor under the space header.
        let space = store.activeSpace
        model.themePopoverSpaceID = space.id
        try await wait("theme popover from Edit Theme Color", timeout: 5) { !popoverWindows().isEmpty }
        let headerPopover = popoverWindows()[0].frame
        // Only the window's top half: the bottom bar's space dots carry the space's name too.
        let header = window.contentView.flatMap { root in
            accessibilityElements(under: root)
                .filter { ($0.accessibilityLabel() ?? "").contains(space.name) && $0.accessibilityFrame().minY > window.frame.midY }
                .max { $0.accessibilityFrame().maxY < $1.accessibilityFrame().maxY }
        }?.accessibilityFrame()
        model.themePopoverSpaceID = nil
        try await wait("theme popover closed", timeout: 5) { popoverWindows().isEmpty }
        if let header {
            try check(headerPopover.maxY <= header.minY + 2 && headerPopover.maxX > header.minX && headerPopover.minX < header.maxX,
                      "the header's theme popover \(headerPopover) is not under the header \(header)")
        }
        let headerPlace = header.map { String(format: "top %.0f pt under the header", $0.minY - headerPopover.maxY) } ?? "header not found by accessibility"
        // Create a Space opens in the sidebar, not a sheet; its Choose a
        // Theme popover opens over the page, right of the row.
        model.beginSpaceCreation(profileID: store.activeProfileID, in: store.keyWindowID)
        try await wait("Create a Space page", timeout: 5) { self.accessibilityElement(in: window, labelled: "Choose a Theme") != nil }
        try check(window.attachedSheet == nil, "Create a Space must open in the sidebar, not as a sheet")
        let row = accessibilityElement(in: window, labelled: "Choose a Theme")!
        let rowFrame = row.accessibilityFrame()
        try check(rowFrame.maxX <= window.frame.minX + model.sidebarWidth(in: store.keyWindowID) + 2,
                  "the Choose a Theme row \(rowFrame) must be in the sidebar")
        // A real click: the row is a SwiftUI button inside the sidebar's space pager.
        var themePlace = "its theme popover was not clicked (no window-server input)"
        if canPostSystemInput {
            let rowPoint = NSPoint(x: rowFrame.midX, y: rowFrame.midY)
            let themeOpened = try await systemClick(atScreen: rowPoint) { !self.popoverWindows().isEmpty }
            if !themeOpened {
                let hit = sequence(first: window.contentView?.superview?.hitTest(window.convertPoint(fromScreen: rowPoint)), next: { $0?.superview })
                    .prefix(8).compactMap { $0.map { String(describing: Swift.type(of: $0)) } }.joined(separator: " < ")
                throw Failure(description: "Choose a Theme at \(rowFrame) opened no popover (key \(NSApp.keyWindow?.title ?? "none"), hit \(hit))")
            }
            let rowPopover = popoverWindows()[0].frame
            // The popover's window includes its arrow, whose tip reaches back over the row's edge.
            let side = rowPopover.maxX <= rowFrame.minX + 16 ? "left" : rowPopover.minX >= rowFrame.maxX - 16 ? "right" : "over"
            try check(side == "right", "the Choose a Theme popover \(rowPopover) must be right of its row \(rowFrame), got \(side)")
            popoverWindows().forEach { $0.close() }
            themePlace = "its theme popover opens \(side) of the Choose a Theme row"
        } else {
            log(systemInputNote("the Choose a Theme click"))
        }
        model.cancelSpaceCreation()
        try await wait("Create a Space page closed", timeout: 5) {
            self.accessibilityElement(in: window, labelled: "Choose a Theme") == nil && popoverWindows().isEmpty
        }
        results.append("(3) Edit Theme Color's popover opens under the header (\(headerPlace)); Create a Space opens in the sidebar and \(themePlace)")

        // (4) The copy toast's share button opens the share menu.
        model.selectTab(tab.id)
        try await wait("tab A on screen for the toast", timeout: 10) { engine.leaseHolder?.window === window }
        if canPostSystemInput {
            var menuOpened = false
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { note in
                menuOpened = true
                (note.object as? NSMenu)?.cancelTracking()
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
            let pickersBefore = ToastSharePicker.shownCount
            model.copyURL(of: tab.id, format: .plain)
            try await wait("copy toast", timeout: 5) { model.toast != nil }
            try await Task.sleep(nanoseconds: 400_000_000)
            // Aim at the button's own view: SwiftUI's accessibility frame for
            // the overlay need not match where the control is drawn.
            try await wait("the toast's share button", timeout: 3) { ToastSharePicker.anchor?.window === window }
            let anchor = try XCTUnwrapSelfTest(ToastSharePicker.anchor, "the toast's share button")
            let toastFrame = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            let center = NSPoint(x: toastFrame.midX, y: toastFrame.midY)
            // A SwiftUI button ignores the click that only makes its window key.
            window.makeKeyAndOrderFront(nil)
            try await wait("the window key for the share click", timeout: 3) { window.isKeyWindow }
            func pickerOpened() -> Bool {
                menuOpened || ToastSharePicker.shownCount > pickersBefore
                    || NSApp.windows.contains { !windowsBefore.contains(ObjectIdentifier($0)) && $0.isVisible && $0 !== window }
            }
            // The first window-server click after the pointer jumps here is
            // dropped before it reaches the app (no hover, no tap), so a second
            // one is allowed and reported.
            try await systemClick(atScreen: center)
            var opened = await eventually(timeout: 1.5) { pickerOpened() }
            let clicks = opened ? 1 : 2
            if !opened {
                try await systemClick(atScreen: center)
                opened = await eventually(timeout: 4) { pickerOpened() }
            }
            for extra in NSApp.windows where !windowsBefore.contains(ObjectIdentifier(extra)) && extra.isVisible && extra !== window { extra.close() }
            try check(opened, "the toast's share button at \(toastFrame) opened no share menu")
            results.append("(4) the copy toast's share button opens the share \(menuOpened ? "menu" : "picker") (\(clicks == 1 ? "first click" : "second click; the first was dropped"))")
        } else {
            log(systemInputNote("the toast's share click"))
        }

        // (5) The hidden tab's media strip stays through Picture in Picture: a floating panel that
        // presents black must not be the only player (build 677, hardware-decoded video).
        let embeds = model.embedsVideoInSidebar, automatic = model.automaticPictureInPicture
        model.embedsVideoInSidebar = false
        model.automaticPictureInPicture = false
        defer {
            model.embedsVideoInSidebar = embeds
            model.automaticPictureInPicture = automatic
        }
        loadShellTab(model, tab, engine, URL(string: "\(serverBase)/pip")!)
        try await wait("PiP fixture playing for the strip", timeout: 25) { engine.pageTitle == "pip-playing" }
        try await wait("pip_available for the strip", timeout: 15) { model.mediaState(for: tab.id).canPictureInPicture }
        model.selectTab(other.id)
        try await wait("strip for the hidden playing tab", timeout: 10) { model.mediaStrips(in: nil).contains(tab.id) }
        model.setPictureInPicture(true, tabID: tab.id)
        try await wait("PiP open keeps the strip", timeout: 10) {
            model.isPictureInPicture(tab.id) && model.mediaStrips(in: nil).contains(tab.id)
        }
        model.setPictureInPicture(false, tabID: tab.id)
        try await wait("PiP closed leaves the strip", timeout: 10) {
            !model.isPictureInPicture(tab.id) && model.mediaStrips(in: nil).contains(tab.id)
        }
        results.append("(5) the hidden tab's strip stays through PiP open and close "
            + "(\(runtime.capabilities.pipEmbedded ? "the shell's floating panel" : "Chromium's window"))")
        model.selectTab(tab.id)
        loadShellTab(model, tab, engine, URL(string: "\(serverBase)/a")!)
        try await wait("tab A back on /a after the wave 33 checks", timeout: 15) { engine.pageTitle == Self.titleA && !engine.isLoading }
        log("PASS wave 33 UI checks: " + results.joined(separator: "; "))
    }

    private func XCTUnwrapSelfTest<T>(_ value: T?, _ what: String) throws -> T {
        guard let value else { throw Failure(description: "no \(what)") }
        return value
    }
}

// MARK: Wave 34 pinned lifecycle (ARC-RECORDING-2026-11-06.md §4 item 3)

extension ChromiumSelfTest {
    /// The plain sidebar cell drawing `id` on screen in `window`, as a screen rect.
    @MainActor
    private func sidebarRowFrame(_ id: UUID, in window: NSWindow) -> NSRect? {
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let cell = view as? SidebarPlainRowCell, cell.rowID == id, !cell.visibleRect.isEmpty {
                return window.convertToScreen(cell.convert(cell.bounds, to: nil))
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The + New Tab row, from the sidebar table's own rows: the SwiftUI cells
    /// in the table don't reach the accessibility tree the self-test walks.
    private func sidebarNewTabRowFrame(in window: NSWindow) -> NSRect? {
        var stack: [NSView] = window.contentView.map { [$0] } ?? []
        while let view = stack.popLast() {
            if let table = view as? NSTableView, let controller = table.delegate as? SidebarListController,
               !table.visibleRect.isEmpty, let index = controller.rows.firstIndex(of: .newTab) {
                // Only once the table has caught up with its rows: right after a tab is
                // added, row `index` is still the old row (a tab) on screen.
                guard table.numberOfRows == controller.rows.count,
                      let cell = table.view(atColumn: 0, row: index, makeIfNecessary: false),
                      !(cell is SidebarPlainRowCell), !cell.visibleRect.isEmpty else {
                    return nil
                }
                // The row's final rect, and a click there must reach this cell.
                let inWindow = table.convert(table.rect(ofRow: index), to: nil)
                let center = NSPoint(x: inWindow.midX, y: inWindow.midY)
                guard let hit = window.contentView?.superview?.hitTest(center), hit === cell || hit.isDescendant(of: cell) else {
                    return nil
                }
                return window.convertToScreen(inWindow)
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// The hover ✕ of a tab row: 8 pt in from the highlight's trailing edge, 16 pt wide.
    private func closeButtonPoint(in row: NSRect) -> NSPoint {
        NSPoint(x: row.maxX - SidebarMetrics.rowInset - 16, y: row.midY)
    }

    /// A real click, and a second one if the first was dropped (see `systemClick`).
    @MainActor
    private func systemClick(atScreen point: NSPoint, until condition: () -> Bool) async throws -> Bool {
        try await systemClick(atScreen: point)
        if await eventually(timeout: 1.5, condition) { return true }
        try await systemClick(atScreen: point)
        return await eventually(timeout: 4, condition)
    }

    /// A mouse drag through the window server, slow enough for SwiftUI's
    /// drag to begin and its drop target to settle before the release.
    @MainActor
    private func systemDrag(from start: NSPoint, to end: NSPoint) async throws {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        func flipped(_ point: NSPoint) -> CGPoint { CGPoint(x: point.x, y: top - point.y) }
        let source = CGEventSource(stateID: .hidSystemState)
        func post(_ type: CGEventType, _ point: NSPoint) {
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: flipped(point), mouseButton: .left)?.post(tap: .cghidEventTap)
        }
        for _ in 0..<2 {
            post(.mouseMoved, start)
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        post(.leftMouseDown, start)
        try await Task.sleep(nanoseconds: 150_000_000)
        let steps = 24
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, NSPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        post(.leftMouseUp, end)
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Arc's pinned-tab lifecycle with real input: + New Tab, ✕ archives it;
    /// a second tab dragged into Pinned, ✕ unloads it and the row stays;
    /// a click loads its saved URL; three space switches keep the same page
    /// (the /nav fixture counts loads in its title).
    @MainActor
    func pinnedLifecycleChecks(model: BrowserViewModel, store: SidebarStore, home: Tab, homeEngine: ChromiumEngine,
                               window: NSWindow) async throws {
        guard await bringToFront(window, for: "pinned lifecycle checks") else {
            log("NOTE pinned lifecycle checks skipped: they need the window on an unlocked screen")
            return
        }
        guard canPostSystemInput else {
            log(systemInputNote("pinned lifecycle checks"))
            return
        }
        if !model.isSidebarVisible(in: model.store.keyWindowID) {
            model.toggleSidebar()
            try await wait("sidebar shown for the lifecycle checks", timeout: 5) { model.isSidebarVisible(in: model.store.keyWindowID) && !model.isSidebarSliding(in: model.store.keyWindowID) }
        }
        var results: [String] = []
        let homeSpace = store.activeSpaceID
        let anchor = store.addTab(kind: .pinned, title: "Lifecycle anchor", url: URL(string: "\(serverBase)/a")!)
        // The sidebar list takes the new row a moment later and slides the rows below it down:
        // measured before that, + New Tab is one row too high and the click lands on the row above.
        try await wait("pinned anchor row on screen", timeout: 5) { self.sidebarRowFrame(anchor.id, in: window) != nil }
        try await Task.sleep(nanoseconds: 500_000_000)

        // Opens a Today tab from the sidebar's + New Tab and the command bar.
        func openFromNewTab(_ query: String, title: String) async throws -> Tab {
            let before = Set(store.content(for: homeSpace).today.map(\.id))
            let shown = await eventually(timeout: 5) { self.sidebarNewTabRowFrame(in: window) != nil }
            guard shown, let newTab = sidebarNewTabRowFrame(in: window) else {
                // Not a ReArc failure: the table never put the row where a click reaches it in time.
                log("NOTE + New Tab row not clickable in time; opening the new tab with model.newTab()")
                model.newTab()
                model.commandBarText = "\(serverBase)/nav?\(query)"
                model.submitCommandBar()
                guard let tab = store.selectedTab, !before.contains(tab.id), store.kind(of: tab.id) == .today else {
                    throw Failure(description: "New Tab opened no Today tab")
                }
                let engine = try shellEngine(model, tab)
                try await wait("new tab '\(query)' loaded", timeout: 20) { engine.pageTitle?.hasPrefix("nav:") == true && !engine.isLoading }
                store.renameTab(tab.id, to: title)
                return tab
            }
            var downs: [String] = []
            let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
                downs.append("\(event.window?.title ?? "no window") at \(event.locationInWindow)")
                return event
            }
            let clicked = try await systemClick(atScreen: NSPoint(x: newTab.midX, y: newTab.midY)) { model.isCommandBarPresented }
            monitor.map(NSEvent.removeMonitor)
            if !clicked {
                // What the click met: the key window, the window under the point and the view hit there.
                let point = NSPoint(x: newTab.midX, y: newTab.midY)
                let under = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
                // The frame view takes points in window coordinates.
                let hitChain = sequence(first: window.contentView?.superview?.hitTest(window.convertPoint(fromScreen: point)), next: { $0?.superview })
                    .prefix(6).compactMap { $0.map { String(describing: Swift.type(of: $0)) } }.joined(separator: " < ")
                var geometry = ""
                if let leaf = window.contentView?.superview?.hitTest(window.convertPoint(fromScreen: point)),
                   let plain = sequence(first: leaf, next: { $0.superview }).first(where: { $0 is SidebarPlainRowCell }) as? SidebarPlainRowCell,
                   let table = sequence(first: plain as NSView, next: { $0.superview }).first(where: { $0 is NSTableView }) as? NSTableView {
                    let row = table.row(for: plain)
                    let newTabRow = (table.delegate as? SidebarListController)?.rows.firstIndex(of: .newTab) ?? -1
                    geometry = "; plain row \(row) '\(plain.rowID.flatMap { store.tab(withID: $0)?.displayTitle } ?? "?")' frame \(plain.convert(plain.bounds, to: nil)), "
                        + "its hosted view \(leaf.convert(leaf.bounds, to: nil)); + New Tab is row \(newTabRow) at \(table.convert(table.rect(ofRow: max(newTabRow, 0)), to: nil))"
                }
                let hit: String? = hitChain.isEmpty ? nil : hitChain + "; mouse-downs: \(downs)" + geometry
                throw Failure(description: "+ New Tab at \(newTab) opened no command bar (key \(NSApp.keyWindow?.title ?? "none"), "
                    + "window under the point \(under) vs sidebar \(window.windowNumber) '\(NSApp.window(withWindowNumber: under)?.title ?? "?")', "
                    + "hit \(hit ?? "nil"))")
            }
            model.commandBarText = "\(serverBase)/nav?\(query)"
            model.submitCommandBar()
            guard let tab = store.selectedTab, !before.contains(tab.id), store.kind(of: tab.id) == .today else {
                throw Failure(description: "+ New Tab opened no Today tab")
            }
            let engine = try shellEngine(model, tab)
            try await wait("new tab '\(query)' loaded", timeout: 20) { engine.pageTitle?.hasPrefix("nav:") == true && !engine.isLoading }
            // A title of its own, so its row is found by id and its label is unique.
            store.renameTab(tab.id, to: title)
            return tab
        }

        // (1) + New Tab, then ✕: the row is gone and the tab is in the archive.
        let first = try await openFromNewTab("lifecycle=1", title: "Lifecycle Today")
        try await wait("Today row on screen", timeout: 5) { self.sidebarRowFrame(first.id, in: window) != nil }
        let firstRow = try XCTUnwrapSelfTest(sidebarRowFrame(first.id, in: window), "Today row")
        try check(model.closeKind(of: first.id) == .archive, "the Today row's ✕ is not Archive")
        let archived = try await systemClick(atScreen: closeButtonPoint(in: firstRow)) {
            store.tab(withID: first.id) == nil && store.archivedTabs.contains { $0.id == first.id }
        }
        try check(archived, "✕ on the Today row at \(firstRow) did not archive it")
        results.append("(1) + New Tab opened a Today tab; its ✕ (\(TabCloseKind.archive.buttonLabel)) archived it")

        // (2) A second tab dragged into Pinned, below the anchor.
        let second = try await openFromNewTab("lifecycle=2", title: "Lifecycle Pin")
        try await wait("both rows on screen", timeout: 5) {
            self.sidebarRowFrame(second.id, in: window) != nil && self.sidebarRowFrame(anchor.id, in: window) != nil
        }
        let secondRow = try XCTUnwrapSelfTest(sidebarRowFrame(second.id, in: window), "second Today row")
        let anchorRow = try XCTUnwrapSelfTest(sidebarRowFrame(anchor.id, in: window), "pinned anchor row")
        // The anchor's bottom fifth: after it, not into a new folder.
        try await systemDrag(from: NSPoint(x: secondRow.midX, y: secondRow.midY),
                             to: NSPoint(x: anchorRow.midX, y: anchorRow.minY + anchorRow.height * 0.15))
        let dragged = await eventually(timeout: 3) { store.kind(of: second.id) == .pinned }
        if !dragged {
            log("NOTE the window-server drag did not pin the tab; pinning it through the same model call the drop makes")
            model.moveItem(second.id, relativeTo: anchor.id, after: true)
        }
        try check(store.kind(of: second.id) == .pinned, "the tab is not pinned after the drop")
        let saved = try XCTUnwrapSelfTest(store.tab(withID: second.id)?.savedURL, "saved URL after pinning")
        try check(model.renameHintSubtitle(for: second.id) == "Double-click to rename", "no rename hint after the pin")
        results.append("(2) the tab \(dragged ? "dragged" : "moved (drag NOTE)") into Pinned saved \(saved.path)?\(saved.query ?? "") "
            + "and shows \"Double-click to rename\"")

        // (3) ✕ on the pinned row: it stays, unloaded and dimmed.
        model.selectTab(second.id)
        try await wait("pinned row on screen", timeout: 5) { self.sidebarRowFrame(second.id, in: window) != nil }
        let pinnedRow = try XCTUnwrapSelfTest(sidebarRowFrame(second.id, in: window), "pinned row")
        try check(model.closeKind(of: second.id) == .unloadPinned, "the pinned row's ✕ is not an unload")
        let unloaded = try await systemClick(atScreen: closeButtonPoint(in: pinnedRow)) { model.isTabUnloaded(second.id) }
        try check(unloaded && store.kind(of: second.id) == .pinned && store.selectedTabID != second.id,
                  "✕ on the pinned row: unloaded \(model.isTabUnloaded(second.id)), kind \(String(describing: store.kind(of: second.id)))")
        results.append("(3) ✕ on the pinned row unloaded it and the row stayed")

        // (4) A click on the row loads the saved URL.
        let rowAgain = try XCTUnwrapSelfTest(sidebarRowFrame(second.id, in: window), "unloaded pinned row")
        let selected = try await systemClick(atScreen: NSPoint(x: rowAgain.midX, y: rowAgain.midY)) { store.selectedTabID == second.id }
        try check(selected, "a click on the unloaded pinned row did not select it")
        try await wait("pinned tab reloaded on its saved URL", timeout: 20) {
            guard let engine = try? self.shellEngine(model, second) else { return false }
            return engine.currentURL == saved && engine.pageTitle?.hasPrefix("nav:") == true && !engine.isLoading
                && engine.attachmentID != nil && !model.isTabUnloaded(second.id)
        }
        let engine = try shellEngine(model, second)
        let loadedTitle = engine.pageTitle ?? ""
        results.append("(4) a click loaded \(saved.path)?\(saved.query ?? "") ('\(loadedTitle)')")

        // (5) Away to another space and back, three times: same engine, no reload.
        let away = store.addSpace(name: "Lifecycle Away")
        for round in 1...3 {
            model.selectSpace(away.id)
            try await wait("space switch \(round) away", timeout: 5) { store.activeSpaceID == away.id }
            try await Task.sleep(nanoseconds: 400_000_000)
            try check(!model.isTabUnloaded(second.id), "round \(round): the pinned tab unloaded while its space was away")
            model.selectSpace(homeSpace)
            try await wait("space switch \(round) back", timeout: 10) {
                store.activeSpaceID == homeSpace && store.selectedTabID == second.id && engine.attachmentID != nil
            }
            let now = try shellEngine(model, second)
            try check(now === engine, "round \(round): the pinned tab has a new engine")
            try check(engine.pageTitle == loadedTitle && engine.currentURL == saved,
                      "round \(round): the page reloaded ('\(loadedTitle)' -> '\(engine.pageTitle ?? "")')")
        }
        results.append("(5) three space switches kept the same engine and '\(loadedTitle)' (no reload)")

        model.deleteTab(second.id)
        model.deleteTab(anchor.id)
        _ = store.removeSpace(away.id)
        model.selectTab(home.id)
        try await wait("tab A back after the lifecycle checks", timeout: 15) {
            homeEngine.attachmentID != nil && homeEngine.leaseHolder?.window === window
        }
        log("PASS pinned lifecycle: " + results.joined(separator: "; "))
    }
}

// MARK: Media strip in another space (the owner's report on build 726)

extension ChromiumSelfTest {
    /// A video plays in a tab inside a folder in one space; with another tab
    /// of that space selected and the folder collapsed, it has a strip there,
    /// and another space shows the strip at the bottom of the sidebar, drawn,
    /// with its title and its space and folder;
    /// the strip's go to tab brings back the space, opens the folder and
    /// selects the tab. With Automatic Picture in Picture on, the strip or a
    /// panel really on screen shows it, never neither (MINI-PLAYER.md §3.2).
    /// No synthesized input: the strip's button is pressed through accessibility.
    @MainActor
    func mediaStripElsewhereChecks(model: BrowserViewModel, store: SidebarStore, home: Tab, homeEngine: ChromiumEngine, window: NSWindow) async throws {
        guard await bringToFront(window, for: "media strip in another space") else {
            log("NOTE media strip in another space skipped: it needs the window on an unlocked screen")
            return
        }
        let embeds = model.embedsVideoInSidebar, automatic = model.automaticPictureInPicture, sidebarShown = model.isSidebarVisible(in: model.store.keyWindowID)
        model.embedsVideoInSidebar = false
        // Off until (4): a covered or locked session's occlusion trigger opens the panel at once.
        model.automaticPictureInPicture = false
        if !sidebarShown { model.toggleSidebar() }
        defer {
            model.embedsVideoInSidebar = embeds
            model.automaticPictureInPicture = automatic
        }
        let homeSpace = store.activeSpaceID
        let mediaSpace = store.addSpace(name: "Strip Media", profileID: store.activeProfileID)
        let otherSpace = store.addSpace(name: "Strip Elsewhere", profileID: store.activeProfileID)
        var results: [String] = []

        // (1) Play the local media page in a tab inside a folder of its own space.
        model.selectSpace(mediaSpace.id)
        let tab = store.addTab(kind: .pinned, title: "Strip video", url: URL(string: "\(serverBase)/pip")!, in: mediaSpace.id)
        guard let folder = store.createFolder(title: "Strip Folder", in: mediaSpace.id, containing: [tab.id]) else {
            throw Failure(description: "no folder for the media tab")
        }
        store.setFolderExpanded(folder.id, true)
        model.selectTab(tab.id)
        let engine = try shellEngine(model, tab)
        loadShellTab(model, tab, engine, URL(string: "\(serverBase)/pip")!)
        try await wait("media page playing in the folder tab", timeout: 25) {
            engine.pageTitle == "pip-playing" || engine.pageTitle?.hasPrefix("pip-err") == true
        }
        try check(engine.pageTitle == "pip-playing", "media page: '\(engine.pageTitle ?? "")'")
        try await wait("the folder tab's media session reached the model (else: entry never made, no media snapshot)", timeout: 15) {
            model.mediaState(for: tab.id).isPlaying && model.mediaControls.contains(tab.id)
        }
        try check(!model.mediaStrips(in: store.keyWindowID).contains(tab.id), "a strip showed while its tab is on screen")
        // The state the owner's run did not try: another tab of the space selected, the folder collapsed.
        let neighbour = store.addTab(kind: .today, title: "Strip neighbour", url: URL(string: "\(serverBase)/a")!, in: mediaSpace.id)
        model.selectTab(neighbour.id)
        store.setFolderExpanded(folder.id, false)
        do {
            try await wait("a strip in the tab's own space once another tab is selected", timeout: 10) {
                model.mediaStrips(in: store.keyWindowID).contains(tab.id)
            }
        } catch {
            throw Failure(description: "no strip beside the collapsed folder: " + stripDiagnosis(model: model, tab: tab))
        }
        results.append("(1) '\(engine.pageTitle ?? "")' plays in a tab inside '\(folder.title)', collapsed, another tab selected: strip shown")

        // (2) Another space: the strip is in the window's view tree, drawn, with its title.
        model.selectSpace(otherSpace.id)
        try await wait("space switch to '\(otherSpace.name)'", timeout: 5) { store.activeSpaceID == otherSpace.id }
        do {
            try await wait("a strip in '\(otherSpace.name)' for the playing tab", timeout: 10) {
                model.mediaStrips(in: store.keyWindowID).contains(tab.id)
            }
        } catch {
            throw Failure(description: "no strip in another space: " + stripDiagnosis(model: model, tab: tab))
        }
        guard let info = model.mediaStripInfo(for: tab.id), !info.title.isEmpty else {
            throw Failure(description: "the strip has no title (mediaStripInfo: tab not resolved through its space or folder)")
        }
        func stripElement() -> TestAccessibilityElement? {
            accessibilityElement(in: window, labelled: "Media controls for \(info.title)")
        }
        do {
            try await wait("the strip in the window's view tree", timeout: 5) {
                guard let frame = stripElement()?.accessibilityFrame() else { return false }
                return frame.width > 1 && frame.height > 1 && window.frame.intersects(frame)
            }
        } catch {
            let frame = stripElement().map { NSStringFromRect($0.accessibilityFrame()) } ?? "absent"
            throw Failure(description: "the model has the strip but the window does not draw it (view not drawn: the stack missing, "
                          + "zero height or off the window; mini sidebar \(model.isMiniSidebar(in: store.keyWindowID)), "
                          + "sidebar shown \(model.isSidebarVisible(in: model.store.keyWindowID))); element \(frame)")
        }
        let location = "\(mediaSpace.name) › \(folder.title)"
        try check(info.location == location && (stripElement()?.accessibilityLabel() ?? "").contains(location),
                  "the strip does not say where the tab is: '\(info.location)', label '\(stripElement()?.accessibilityLabel() ?? "")'")
        let stripFrame = stripElement()!.accessibilityFrame()
        try check(stripFrame.minY < window.frame.minY + window.frame.height / 3,
                  "the strip \(NSStringFromRect(stripFrame)) is not at the bottom of the sidebar in \(NSStringFromRect(window.frame))")
        results.append(String(format: "(2) '%@' shows the strip '%@' in '%@', %.0f x %.0f pt, %.0f pt above the window's bottom",
                              otherSpace.name, info.title, location, stripFrame.width, stripFrame.height, stripFrame.minY - window.frame.minY))

        // (3) The strip's go to tab: its space, the folder open, the tab selected and its row on screen.
        guard let goTo = accessibilityElement(in: window, labelled: "Go to \(info.title)") else {
            throw Failure(description: "the strip has no Go to button in the view tree")
        }
        try check(goTo.press(), "the strip's Go to button took no accessibility press")
        do {
            try await wait("go to tab: space, folder and tab", timeout: 10) {
                store.activeSpaceID == mediaSpace.id && store.isFolderExpanded(folder.id) && store.selectedTabID == tab.id
            }
        } catch {
            throw Failure(description: "go to tab: space \(store.activeSpaceID == mediaSpace.id ? "ok" : "not selected"), "
                          + "folder \(store.isFolderExpanded(folder.id) ? "open" : "still collapsed"), "
                          + "tab \(store.selectedTabID == tab.id ? "selected" : "not selected")")
        }
        do {
            try await wait("the tab's row on screen in the list", timeout: 5) { self.sidebarRowFrame(tab.id, in: window) != nil }
        } catch {
            throw Failure(description: "go to tab selected the tab but its row is not on screen (folder not drawn open, or not scrolled to)")
        }
        try await wait("the strip leaves once its tab is on screen", timeout: 5) { stripElement() == nil }
        results.append("(3) Go to opened '\(folder.title)', selected the tab in '\(mediaSpace.name)' and showed its row")

        // (4) The owner's settings: Automatic Picture in Picture on. The strip or a panel on screen shows the video.
        model.automaticPictureInPicture = true
        model.selectSpace(otherSpace.id)
        try await wait("space switch back to '\(otherSpace.name)'", timeout: 5) { store.activeSpaceID == otherSpace.id }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        // A panel counts only on the window's display (the owner's window was on his external one).
        let panelShows = model.livePanelTabID == tab.id && model.livePanel.isShowing
            && model.livePanel.window?.screen == window.screen
        let stripShows = model.mediaStrips(in: store.keyWindowID).contains(tab.id) && stripElement() != nil
        try check(panelShows || stripShows, "Automatic Picture in Picture on: neither a strip nor a panel on screen: "
                  + stripDiagnosis(model: model, tab: tab))
        results.append("(4) with Automatic Picture in Picture on, " + (panelShows ? "the floating panel on screen shows it" : "the strip shows it")
                       + " (placement \(model.livePlacements[tab.id].map { "\($0)" } ?? "none"))")

        model.selectSpace(homeSpace)
        model.deleteTab(tab.id)
        model.deleteTab(neighbour.id)
        _ = store.removeSpace(mediaSpace.id)
        _ = store.removeSpace(otherSpace.id)
        model.selectTab(home.id)
        try await wait("tab A back after the media strip checks", timeout: 15) {
            homeEngine.attachmentID != nil && homeEngine.leaseHolder?.window === window
        }
        log("PASS media strip in another space: " + results.joined(separator: "; "))
    }

    /// Which reason a playing tab has no strip in the key window.
    @MainActor
    private func stripDiagnosis(model: BrowserViewModel, tab: Tab) -> String {
        let media = model.mediaState(for: tab.id)
        let window = model.store.keyWindowID
        if model.store.tab(withID: tab.id) == nil { return "the tab is gone" }
        if model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab)) == nil {
            return "entry never made: the tab's engine was released when its space went off screen"
        }
        if !media.hasSession { return "entry never made: no media snapshot for the tab (media subscription or engine) [\(media)]" }
        guard model.mediaControls.contains(tab.id) else { return "entry never made though the session is live [\(media)]" }
        if model.mediaControls.entries.first(where: { $0.tabID == tab.id })?.isDismissed == true {
            return "strip suppressed: a dismissed entry that never reset"
        }
        if model.visibleTabIDs(in: window).contains(tab.id) { return "the window counts the tab as on screen" }
        if model.captureStateByTab[tab.id] != nil { return "strip suppressed: call card" }
        if let placement = model.effectiveLivePlacement(for: tab.id) {
            return "live video placement \(placement), panel \(model.livePanel.isShowing ? "showing" : "not showing") "
                + "tab \(model.livePanelTabID == tab.id ? "this one" : "\(model.livePanelTabID.map { "\($0)" } ?? "none")")"
        }
        if media.isPictureInPicture { return "strip suppressed: a PiP session with no shell placement (pip_embedded \(runtime.capabilities.pipEmbedded))" }
        return "strips \(model.mediaStrips(in: window)), entries \(model.mediaControls.entries.map(\.tabID)), media \(media)"
    }
}

// MARK: Split pane toolbar rows (SPLIT-VIEW §3.1)

extension ChromiumSelfTest {
    /// Each pane has its own row; only the focused one has the site controls,
    /// and a click in the other pane's page moves them there.
    @MainActor
    func splitPaneRowChecks(model: BrowserViewModel, store: SidebarStore, splitID: SplitViewItem.ID, focused: ChromiumEngine,
                            other: ChromiumEngine, otherTab: Tab.ID, window: NSWindow) async throws {
        guard UserDefaults.standard.object(forKey: ToolbarURLPreference.key) as? Bool ?? ToolbarURLPreference.defaultValue else {
            log("SKIP split pane rows: URL in toolbar is off, so panes have no rows")
            return
        }
        func labelled(_ label: String) -> [TestAccessibilityElement] {
            guard let root = window.contentView else { return [] }
            return accessibilityElements(under: root).filter { $0.accessibilityLabel() == label }
        }
        func screenRect(_ engine: ChromiumEngine) -> NSRect? {
            guard let host = engine.leaseHolder, let hostWindow = host.window else { return nil }
            return hostWindow.convertToScreen(host.convert(host.bounds, to: nil))
        }
        func controlsAbove(_ engine: ChromiumEngine) -> Bool {
            let controls = labelled("Site controls")
            guard controls.count == 1, let pane = screenRect(engine) else { return false }
            let midX = controls[0].accessibilityFrame().midX
            return midX > pane.minX && midX < pane.maxX
        }
        try await wait("a toolbar row per split pane, site controls in the focused one", timeout: 10) {
            labelled("Close Pane").count == 2 && controlsAbove(focused)
        }
        guard let target = screenRect(other) else { throw Failure(description: "the companion pane has no host view") }
        click(atScreen: NSPoint(x: target.midX, y: target.midY), in: window)
        try await wait("a click in the companion pane focuses it", timeout: 10) {
            store.split(withID: splitID)?.focusTabID == otherTab
        }
        try await wait("site controls moved to the companion pane's row", timeout: 10) {
            labelled("Close Pane").count == 2 && controlsAbove(other)
        }
        log("PASS split pane rows: 2 rows, site controls in the focused pane's row, moved by a click in the other pane")
    }
}

// MARK: Split pane order (View > Move Pane Left/Right/Up/Down, owner report 2026-11-22)

extension ChromiumSelfTest {
    /// A two-pane split, side by side then stacked: View > Move Pane Right / Left / Down / Up
    /// (the real menu's items, with their live titles and enabled state) swap the two engine
    /// views' frames, each pane keeps its width, the moved pane keeps the focus, and neither
    /// page loads again (same document and navigation, a value set in each page still there).
    @MainActor
    func splitPaneMoveChecks(model: BrowserViewModel, store: SidebarStore, splitID: SplitViewItem.ID, paneA: ChromiumEngine, tabA: Tab.ID,
                             paneB: ChromiumEngine, tabB: Tab.ID, base: String, window: NSWindow) async throws {
        func screenRect(_ engine: ChromiumEngine) -> NSRect? {
            guard let host = engine.leaseHolder, let hostWindow = host.window, hostWindow === window else { return nil }
            return hostWindow.convertToScreen(host.convert(host.bounds, to: nil))
        }
        func order() -> [Tab.ID] { store.split(withID: splitID)?.tabs.map(\.id) ?? [] }
        // The View menu as it is when opened: titles and enabled state read again.
        func viewItem(_ title: String) -> NSMenuItem? {
            guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else { return nil }
            menu.delegate?.menuNeedsUpdate?(menu)
            menu.update()
            return menu.items.first { $0.title == title && !$0.isHidden }
        }
        func viewTitles() -> [String] {
            NSApp.mainMenu?.items.first { $0.title == "View" }?.submenu?.items.filter { !$0.isHidden }.map(\.title) ?? []
        }
        func choose(_ title: String) throws {
            guard let item = viewItem(title), item.isEnabled, let action = item.action else {
                throw Failure(description: "View > \(title) is missing or disabled; View menu: \(viewTitles())")
            }
            try check(NSApp.sendAction(action, to: item.target, from: item), "View > \(title) ran nothing")
        }
        var sawLoading = false
        func settled() -> Bool {
            sawLoading = sawLoading || paneA.isLoading || paneB.isLoading
            return paneA.attachmentID != nil && paneB.attachmentID != nil && screenRect(paneA) != nil && screenRect(paneB) != nil
        }

        model.selectSplit(splitID, focusTabID: tabA)
        try await wait("split side by side again, both panes attached", timeout: 20) {
            store.split(withID: splitID)?.orientation == .horizontal && settled()
        }
        try check(order() == [tabA, tabB], "the split does not start as [tab A, companion]")
        // Both panes on a real page, with widths that differ: 30 % and 70 %.
        paneB.load(URL(string: "\(base)/nav")!)
        try await wait("companion pane loaded /nav", timeout: 20) { paneB.currentURL?.path == "/nav" && !paneB.isLoading && !paneA.isLoading }
        store.resizeSplitPanes(splitID: splitID, widthFactors: [tabA: 0.3, tabB: 0.7])
        try await wait("panes laid out 30/70, tab A on the left", timeout: 10) {
            guard settled(), let a = screenRect(paneA), let b = screenRect(paneB) else { return false }
            return a.maxX <= b.minX + 1 && a.width > 100 && a.width < b.width * 0.6
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        guard let startA = screenRect(paneA), let startB = screenRect(paneB) else { throw Failure(description: "a pane has no host view") }
        let scripted = paneA.supportsScriptEvaluation
        if scripted {
            _ = try await paneA.evaluate("(function(){ window.__darniPaneMove = 'A'; return 1; })()", in: .page)
            _ = try await paneB.evaluate("(function(){ window.__darniPaneMove = 'B'; return 1; })()", in: .page)
        }
        let documentA = paneA.currentDocumentIdentity, documentB = paneB.currentDocumentIdentity
        let engineTabs = [paneA.tabID, paneB.tabID], urls = [paneA.currentURL, paneB.currentURL]
        sawLoading = false

        /// Neither page loaded again since the values above were taken.
        func checkNoReload(_ step: String) async throws {
            try check(!sawLoading, "\(step): a pane was loading during the move")
            try check([paneA.tabID, paneB.tabID] == engineTabs, "\(step): the panes' engine tabs changed (\(engineTabs) -> \([paneA.tabID, paneB.tabID]))")
            try check([paneA.currentURL, paneB.currentURL] == urls, "\(step): a pane's URL changed")
            if let documentA, let documentB {
                let nowA = paneA.currentDocumentIdentity, nowB = paneB.currentDocumentIdentity
                try check(nowA?.isSameDocument(as: documentA, sameNavigation: true) == true,
                          "\(step): tab A has a new document [\(String(describing: nowA))] was [\(documentA)]")
                try check(nowB?.isSameDocument(as: documentB, sameNavigation: true) == true,
                          "\(step): the companion has a new document [\(String(describing: nowB))] was [\(documentB)]")
            }
            if scripted {
                let markA = try await paneA.evaluate("String(window.__darniPaneMove)", in: .page) as? String
                let markB = try await paneB.evaluate("String(window.__darniPaneMove)", in: .page) as? String
                try check(markA == "A" && markB == "B", "\(step): the pages lost their state (tab A '\(markA ?? "nil")', companion '\(markB ?? "nil")')")
            }
        }
        func near(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) <= 2 }

        // The real View menu: Arc's items are there, and the first pane can only go right.
        let titles = viewTitles()
        try check(titles.contains("Separate Page from Split View") && titles.contains("Add Split View")
                  && titles.contains("Close this Split Pane"), "View menu lacks Arc's split items: \(titles)")
        try check(viewItem("Move Pane Left")?.isEnabled == false && viewItem("Move Pane Right")?.isEnabled == true,
                  "tab A is the first pane: Move Pane Left \(String(describing: viewItem("Move Pane Left")?.isEnabled)), "
                  + "Move Pane Right \(String(describing: viewItem("Move Pane Right")?.isEnabled)); View menu: \(viewTitles())")

        // Move Pane Right: the views swap, each with its own width.
        try choose("Move Pane Right")
        try check(order() == [tabB, tabA], "Move Pane Right left the order \(order() == [tabA, tabB] ? "unchanged" : "wrong")")
        try await wait("Move Pane Right: the engine views swapped places and kept their widths", timeout: 20) {
            guard settled(), let a = screenRect(paneA), let b = screenRect(paneB) else { return false }
            return b.maxX <= a.minX + 1 && near(a.width, startA.width) && near(b.width, startB.width)
                && near(b.minX, startA.minX) && near(a.maxX, startB.maxX)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = settled()
        try check(store.split(withID: splitID)?.focusTabID == tabA && store.selectedItemID == splitID, "the moved pane lost the focus")
        try checkOneLease(paneA, "moved pane A")
        try checkOneLease(paneB, "moved companion")
        try await checkNoReload("Move Pane Right")
        try check(viewItem("Move Pane Left")?.isEnabled == true && viewItem("Move Pane Right")?.isEnabled == false,
                  "tab A is now the last pane, the View menu does not say so")
        let movedA = screenRect(paneA) ?? .zero, movedB = screenRect(paneB) ?? .zero

        // Move Pane Left: back where they were.
        try choose("Move Pane Left")
        try await wait("Move Pane Left: the engine views are back in their places", timeout: 20) {
            guard settled(), order() == [tabA, tabB], let a = screenRect(paneA), let b = screenRect(paneB) else { return false }
            return near(a.minX, startA.minX) && near(a.width, startA.width) && near(b.minX, startB.minX) && near(b.width, startB.width)
        }
        try await checkNoReload("Move Pane Left")

        // Stacked: the same two items are Move Pane Up and Move Pane Down.
        model.flipSplitOrientation(splitID)
        try await wait("split stacked, tab A on top", timeout: 20) {
            guard settled(), store.split(withID: splitID)?.orientation == .vertical,
                  let a = screenRect(paneA), let b = screenRect(paneB) else { return false }
            return a.minY >= b.maxY - 1
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        guard let stackedA = screenRect(paneA), let stackedB = screenRect(paneB) else { throw Failure(description: "a stacked pane has no host view") }
        let stackedTitles = viewTitles()
        try check(viewItem("Move Pane Up")?.isEnabled == false && viewItem("Move Pane Down")?.isEnabled == true
                  && viewItem("Move Pane Left") == nil && viewItem("Move Pane Right") == nil,
                  "a stacked split's View menu should read Move Pane Up (disabled) and Move Pane Down: \(stackedTitles) -> \(viewTitles())")
        try choose("Move Pane Down")
        try await wait("Move Pane Down: the engine views swapped places and kept their heights", timeout: 20) {
            guard settled(), order() == [tabB, tabA], let a = screenRect(paneA), let b = screenRect(paneB) else { return false }
            return b.minY >= a.maxY - 1 && near(a.height, stackedA.height) && near(b.height, stackedB.height)
        }
        try check(store.split(withID: splitID)?.focusTabID == tabA, "the pane moved down lost the focus")
        try await checkNoReload("Move Pane Down")
        try choose("Move Pane Up")
        try await wait("Move Pane Up: tab A on top again", timeout: 20) {
            guard settled(), order() == [tabA, tabB], let a = screenRect(paneA), let b = screenRect(paneB) else { return false }
            return a.minY >= b.maxY - 1
        }
        try await checkNoReload("Move Pane Up")

        // As the split was, for the steps after this one.
        model.flipSplitOrientation(splitID)
        store.resizeSplitPanes(splitID: splitID, widthFactors: [tabA: 0.5, tabB: 0.5])
        try await wait("split side by side and even again", timeout: 20) {
            store.split(withID: splitID)?.orientation == .horizontal && settled()
        }
        log("PASS Split pane order: View > Move Pane Right swapped the engine views (tab A x \(Int(startA.minX)) w \(Int(startA.width)) -> x "
            + "\(Int(movedA.minX)) w \(Int(movedA.width)); companion x \(Int(startB.minX)) w \(Int(startB.width)) -> x \(Int(movedB.minX)) w "
            + "\(Int(movedB.width))), Move Pane Left put them back, Move Pane Down / Up did the same stacked; focus stayed on the moved pane; "
            + "ends disabled in the View menu; no reload (same engine tabs and URLs, never loading"
            + "\(documentA != nil && documentB != nil ? ", same document and navigation" : "")\(scripted ? ", page state kept" : ""))")
    }
}
#endif
