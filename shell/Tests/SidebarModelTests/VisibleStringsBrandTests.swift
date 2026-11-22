import XCTest
@testable import SidebarModel

/// Darni in anything people read (owner rule, the rename at build 1054):
/// the shell's strings do not say "ReArc", and say "Chromium" only where
/// the engine is credited or named for a reason. This reads every string
/// literal in the shell's sources. One that has either word and is not
/// written to a log must be listed here with why it stays, so a new label
/// like the Library's "Open Chromium's Downloads Page" (found on screen
/// 2026-11-22) fails until someone decides.
///
/// Identifiers are not strings people read and are not matched: the scan
/// looks for the words alone, so `ReArcSidebarWidth` or
/// `ReArcEngineConfigure` pass.
final class VisibleStringsBrandTests: XCTestCase {
    private enum Why: String {
        /// Credits Chromium as the engine, where a browser credits its engine.
        case credit
        /// Names another browser, Chromium itself, as a product.
        case otherBrowser
        /// A name on disk, in the keychain or on the wire that installed copies depend on.
        case identifier
        /// Shown only when the engine is missing or too old for a feature: it names what is needed.
        case needsEngine
        /// Goes to stderr, a log or the self-test's output, through a value built here.
        case diagnostic
    }

    private struct Kept {
        let file: String
        /// Part of the literal, enough to tell it from the file's others.
        let text: String
        let why: Why
        let note: String
    }

    private static let kept: [Kept] = [
        // Credits.
        Kept(file: "ChromiumHost.swift", text: "About Chromium Engine", why: .credit, note: "the Darni menu's item for chrome://version"),
        Kept(file: "BrowserInternalPage.swift", text: "About Chromium Engine", why: .credit, note: "that page's tab title"),
        Kept(file: "AppCommandRegistry.swift", text: "About Chromium Engine", why: .credit, note: "the command bar's command for it"),
        Kept(file: "AboutWindow.swift", text: "Chromium Engine Version", why: .credit, note: "About Darni's engine version line"),
        Kept(file: "AboutWindow.swift", text: "made possible by the [Chromium]", why: .credit, note: "About Darni's acknowledgement"),
        Kept(file: "AboutWindow.swift", text: "Chromium's [open source software]", why: .credit, note: "About Darni's link to the engine's licences"),
        // Chromium the browser, as an import source.
        Kept(file: "BrowserImportSources.swift", text: "Chromium", why: .otherBrowser,
             note: "the Chromium browser's name in Import, and its bundle id org.chromium.Chromium"),
        // Names installed copies depend on.
        Kept(file: "ShellDataLocation.swift", text: "ReArc", why: .identifier, note: "Application Support/ReArc, where every install's data is"),
        Kept(file: "BrowserViewModel+Sync.swift", text: "ReArc › Backups in your Application Support folder", why: .identifier,
             note: "the sidebar backup sheet names the real folder, which is still called ReArc"),
        Kept(file: "ChromiumCapabilities.swift", text: "ReArc Safe Storage", why: .identifier, note: "the keychain item of every install; must stay"),
        Kept(file: "ChromiumCapabilities.swift", text: "Chromium Safe Storage", why: .identifier, note: "the keychain item of an engine without the branding patch"),
        Kept(file: "ChromiumHost.swift", text: "Chromium Framework.framework", why: .identifier, note: "the embedded framework's file name"),
        Kept(file: "ChromiumHost.swift", text: "Chromium", why: .identifier, note: "the engine's data folder inside Application Support/ReArc"),
        Kept(file: "ChromiumNativeMessagingHosts.swift", text: "Chromium", why: .identifier, note: "the same folder"),
        Kept(file: "BrowserViewModel+ContentBlocking.swift", text: "ReArc", why: .identifier, note: "the User-Agent of the blocklist mirror's requests"),
        Kept(file: "BrowserViewModel+MembershipCard.swift", text: "ReArc-Card", why: .identifier, note: "a temporary folder's name"),
        Kept(file: "LittleArcMenus.swift", text: "Little ReArc", why: .identifier,
             note: "the stored title of blank windows saved before the rename, matched, never shown"),
        Kept(file: "BoostEditorModel.swift", text: "/* ReArc boost */", why: .identifier,
             note: "the starter comment of boosts made before the rename, matched so they still read as untouched"),
        // Shown without the engine (a development build on WebKit, or an engine older than the feature).
        Kept(file: "BrowserViewModel+DevTools.swift", text: "Developer Tools need the Chromium engine", why: .needsEngine, note: "command result"),
        Kept(file: "BrowserViewModel.swift", text: "needs a newer Chromium engine", why: .needsEngine, note: "command result for an engine page"),
        Kept(file: "BrowserViewModel.swift", text: "needs the Chromium engine", why: .needsEngine, note: "command result for an engine page"),
        Kept(file: "BrowserImportView.swift", text: "Reinstalling extensions needs the Chromium engine", why: .needsEngine, note: "Import's extensions row"),
        Kept(file: "ExtensionReinstallView.swift", text: "The Chromium engine is unavailable.", why: .needsEngine, note: "a failed extension install's reason"),
        // Diagnostics built as values and written out elsewhere.
        Kept(file: "ReArcMain.swift", text: "this binary was built without Chromium", why: .diagnostic, note: "stderr at launch"),
        Kept(file: "ChromiumHost.swift", text: "the bundle does not embed Chromium Framework.framework", why: .diagnostic, note: "stderr at launch"),
        Kept(file: "ChromiumHost.swift", text: "Chromium Framework did not load", why: .diagnostic, note: "stderr at launch"),
        Kept(file: "ChromiumEngine.swift", text: "Chromium tab unavailable", why: .diagnostic, note: "an engine's lastError, read by the self-test"),
        Kept(file: "ChromiumScriptEvaluation.swift", text: "no Chromium tab", why: .diagnostic, note: "a script evaluation error's description, logged"),
        Kept(file: "EngineLaunchOptions.swift", text: "it overlaps the ReArc data directory", why: .diagnostic, note: "a refused launch argument, stderr"),
        Kept(file: "ShellDataLocation.swift", text: "a shipped ReArc ignores", why: .diagnostic, note: "a refused launch, stderr"),
        Kept(file: "ShellDataLocation.swift", text: "a shipped ReArc takes no --user-data-dir", why: .diagnostic, note: "a refused launch, stderr"),
        Kept(file: "ImportPrivacyAccess.swift", text: "ReArc's Relaunch helper", why: .diagnostic, note: "the relaunch helper's log line"),
        Kept(file: "PasskeyPrompt.swift", text: "at Chromium's focus check", why: .diagnostic, note: "a passkey refusal's log line"),
        Kept(file: "BoostInjection.swift", text: "console.error('[ReArc Boost]'", why: .diagnostic,
             note: "the page console's prefix for a boost script's error, seen with Developer Tools open"),
        Kept(file: "BoostPickerScript.swift", text: "Chromium: the isolated-world", why: .diagnostic,
             note: "a comment inside the element picker's injected script"),
    ]

    /// Developer output from end to end: the self-test's log and its fixture pages, and the bench's report.
    private static let developerFiles: Set<String> = [
        "ChromiumSelfTest.swift", "ChromiumBench.swift", "LoopbackFixtureServer.swift", "SelfTestBlockingFixture.swift",
    ]
    /// Calls whose strings go to stderr or a log, never to a view.
    private static let logCalls = ["StandardError.write(", "ChromiumLog.", "NSLog(", "fatalError(", "precondition(", "assertionFailure(", "dlsym("]

    private struct Hit: Hashable {
        let file: String
        let line: Int
        let text: String
    }

    private var sources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
    }

    private static func hasBrandWord(_ text: String) -> Bool {
        text.range(of: #"(?<![A-Za-z0-9_])(Chromium|ReArc)(?![A-Za-z0-9_])"#, options: .regularExpression) != nil
    }

    /// The line's string literals, its code with the literals blanked and any trailing comment cut.
    static func parse(_ line: String) -> (literals: [String], code: String) {
        var literals: [String] = [], code = "", current = ""
        var inString = false, escaped = false
        var previous: Character = " "
        for character in line {
            if inString {
                if escaped {
                    escaped = false
                    current.append(character)
                } else if character == "\\" {
                    escaped = true
                    current.append(character)
                } else if character == "\"" {
                    inString = false
                    literals.append(current)
                    current = ""
                    code.append("\"")
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inString = true
                code.append("\"")
            } else if character == "/", previous == "/" {
                code.removeLast()
                break
            } else {
                code.append(character)
            }
            previous = inString ? " " : character
        }
        return (literals, code)
    }

    /// Every literal with a brand word that no log call takes, in the shell's own targets.
    private func hits() throws -> [Hit] {
        var hits: [Hit] = []
        for target in ["ReArc", "SidebarModel", "Onboarding"] {
            let root = sources.appendingPathComponent(target)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)).compactMap { $0 as? URL }
            for file in files.sorted(by: { $0.path < $1.path })
            where file.pathExtension == "swift" && !Self.developerFiles.contains(file.lastPathComponent) {
                var logDepth = 0      // open parentheses of a log call that goes on over lines
                var inBlockString = false
                for (index, raw) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").enumerated() {
                    let trimmed = raw.trimmingCharacters(in: .whitespaces)
                    if trimmed.contains("\"\"\"") {
                        // A multi-line literal: its lines are read whole.
                        if trimmed.components(separatedBy: "\"\"\"").count == 2 { inBlockString.toggle() }
                        continue
                    }
                    if inBlockString {
                        if logDepth == 0, Self.hasBrandWord(raw) { hits.append(Hit(file: file.lastPathComponent, line: index + 1, text: trimmed)) }
                        continue
                    }
                    if trimmed.hasPrefix("//") { continue }
                    let (literals, code) = Self.parse(raw)
                    var isLog = logDepth > 0
                    var counted = Substring(code)
                    if !isLog, let call = Self.logCalls.compactMap({ code.range(of: $0) }).min(by: { $0.lowerBound < $1.lowerBound }) {
                        isLog = true
                        counted = code[call.lowerBound...]
                    }
                    if isLog {
                        logDepth += counted.filter { $0 == "(" }.count - counted.filter { $0 == ")" }.count
                        logDepth = max(logDepth, 0)
                        continue
                    }
                    for literal in literals where Self.hasBrandWord(literal) {
                        hits.append(Hit(file: file.lastPathComponent, line: index + 1, text: literal))
                    }
                }
            }
        }
        return hits
    }

    func testTheScannerReadsLiteralsAndSkipsCommentsAndIdentifiers() {
        XCTAssertEqual(Self.parse(#"Button("Open Chromium’s Downloads Page") { go() } // "ReArc" in a comment"#).literals,
                       ["Open Chromium’s Downloads Page"])
        XCTAssertEqual(Self.parse(#"let a = "say \"ReArc\" twice", b = "https://x.test//y""#).literals, [#"say \"ReArc\" twice"#, "https://x.test//y"])
        XCTAssertTrue(Self.hasBrandWord("Open Chromium’s Downloads Page"))
        XCTAssertTrue(Self.hasBrandWord("[ReArc] could not save"))
        XCTAssertTrue(Self.hasBrandWord("ReArc-Card"))
        XCTAssertFalse(Self.hasBrandWord("ReArcSidebarWidth"), "an identifier")
        XCTAssertFalse(Self.hasBrandWord("ReArcEngineConfigure"))
        XCTAssertFalse(Self.hasBrandWord("org.chromium.rearc"), "bundle ids are lower case")
        XCTAssertFalse(Self.hasBrandWord("Import from Arc, Chrome or Brave…"), "Chrome the browser is not the engine's name")
    }

    func testNoStringPeopleReadSaysChromiumOrReArcUnlessListed() throws {
        let hits = try hits()
        XCTAssertGreaterThan(hits.count, 20, "the scan found too little to be reading the sources (\(sources.path))")
        let unlisted = hits.filter { hit in !Self.kept.contains { $0.file == hit.file && hit.text.contains($0.text) } }
        XCTAssertTrue(unlisted.isEmpty, "strings that say Chromium or ReArc and are not listed with a reason:\n"
                      + unlisted.map { "  \($0.file):\($0.line): \"\($0.text)\"" }.joined(separator: "\n")
                      + "\nSay Darni (or name the thing, not the engine), or list it in VisibleStringsBrandTests.kept.")
    }

    func testEveryListedStringIsStillThere() throws {
        let hits = try hits()
        for entry in Self.kept {
            XCTAssertTrue(hits.contains { $0.file == entry.file && $0.text.contains(entry.text) },
                          "\(entry.file) no longer has \"\(entry.text)\" (\(entry.why.rawValue): \(entry.note)): take it off the list")
        }
    }

    /// The ones fixed on 2026-11-22 stay fixed.
    func testTheFixedStringsSayDarniOrNameTheThing() {
        XCTAssertEqual(BoostStarterCSS.text, "/* Darni boost */\n")
        XCTAssertTrue(BoostStarterCSS.isStarter(BoostStarterCSS.text))
        XCTAssertTrue(BoostStarterCSS.isStarter("/* ReArc boost */\n"), "a boost made before the rename is still an untouched one")
        XCTAssertFalse(BoostStarterCSS.isStarter("/* Darni boost */\n.ad { display: none }"))
        XCTAssertFalse(BoostStarterCSS.isStarter(""))
        XCTAssertEqual(CaptureCommandTitle.fullPage, "Capture Full Page")
    }
}
