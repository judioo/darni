import Foundation
import WebKit

/// Runs a reader script in a WKWebView's own isolated content world: the
/// WebKit shell's pages, and the unit tests' pages.
enum ReaderWebKitEvaluation {
    static let world = WKContentWorld.world(name: "DarniReader")

    enum Failure: Error {
        case notText
    }

    @MainActor
    static func evaluate(_ source: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(source, in: nil, in: world) { result in
                switch result {
                case .success(let value as String): continuation.resume(returning: value)
                case .success: continuation.resume(throwing: Failure.notText)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }
}

extension WKEngine: ReaderScriptEvaluating {
    @MainActor
    func evaluateReaderScript(_ source: String, timeoutMS: UInt32) async throws -> String {
        try await ReaderWebKitEvaluation.evaluate(source, in: webView)
    }
}

#if REARC_CHROMIUM
/// Chromium: `ReArcTabEvaluateScript` in the reader's own isolated world
/// (`rearc.boost.<token>.<reader id>`, shared with no boost). The answer is
/// applied only if the tab still shows the document it was made in
/// (`ChromiumEngine.evaluate`).
extension ChromiumEngine: ReaderScriptEvaluating {
    @MainActor
    func evaluateReaderScript(_ source: String, timeoutMS: UInt32) async throws -> String {
        guard let text = try await evaluate(source, in: .boost(ReaderScripts.worldID), timeoutMS: timeoutMS) as? String else {
            throw ChromiumScriptError.invalidResult("the reader script's answer is not text")
        }
        return text
    }
}
#endif
