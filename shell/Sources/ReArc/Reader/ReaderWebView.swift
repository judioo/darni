import AppKit
import SidebarModel
import SwiftUI
import WebKit

/// The reader's page: a WKWebView that runs no page script and has no way
/// back into the shell (docs/FEATURE-SPECS/READER-VIEW.md §6). It is the
/// second barrier behind `ReaderSanitiser`:
///
/// - JavaScript from content is off in the configuration and again for every
///   navigation (`allowsContentJavaScript = false`).
/// - No script message handler and no user script is ever added, so the page
///   has no bridge to call even if a script ran.
/// - Its data store is non-persistent and its own: no cookie, cache or
///   storage is shared with a profile, another reader or the disk.
/// - It shows one document, the one Darni wrote. Every other navigation (a
///   link, a redirect, a form) is cancelled; a link the person clicked is
///   handed to the shell as a plain URL.
final class ReaderPage: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    /// A link the person clicked: the URL and whether ⌘ was held.
    var onLink: ((URL, Bool) -> Void)?
    /// The document finished loading (tests wait on it).
    var onLoad: (() -> Void)?
    /// What the page was denied, for tests: each cancelled navigation's URL.
    private(set) var cancelledNavigations: [URL] = []
    private var documentNavigation: WKNavigation?
    private var hasDocument = false
    private var appearance = ReaderAppearance()

    /// The world the appearance attributes are set from. Content JavaScript
    /// stays off; this is the app's own call (`applyAppearance`).
    private static let appearanceWorld = WKContentWorld.world(name: "DarniReaderAppearance")

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.suppressesIncrementalRendering = false
        return configuration
    }

    override init() {
        webView = ReaderWKWebView(frame: .zero, configuration: Self.makeConfiguration())
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityLabel("Reader")
    }

    /// Shows `article`. The base URL is about:blank, so the document's origin
    /// is its own (opaque): not the article's site, not a Darni page.
    func show(_ article: ReaderArticle, appearance: ReaderAppearance) {
        self.appearance = appearance
        loadDocument(ReaderHTML.document(for: article, appearance: appearance))
    }

    /// Loads HTML as the reader's document (tests load hostile HTML straight in).
    func loadDocument(_ html: String) {
        hasDocument = false
        documentNavigation = webView.loadHTMLString(html, baseURL: nil)
    }

    /// A changed setting: the root element's attributes change in place, so
    /// the place in the article is kept. The stylesheet already has a rule
    /// for every value; no style text is written.
    func applyAppearance(_ appearance: ReaderAppearance) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        guard hasDocument else { return }
        let assignments = appearance.rootAttributes.map { attribute in
            "document.documentElement.setAttribute(\(Self.literal(attribute.name)), \(Self.literal(attribute.value)));"
        }.joined()
        webView.evaluateJavaScript(assignments + "true", in: nil, in: Self.appearanceWorld) { _ in }
    }

    /// The root element's appearance attributes as the page has them now (tests).
    func readAppearanceAttributes(_ completion: @escaping ([String: String]) -> Void) {
        let names = appearance.rootAttributes.map(\.name)
        let script = "JSON.stringify(Object.fromEntries(" + "[\(names.map(Self.literal).joined(separator: ","))]"
            + ".map(function (n) { return [n, document.documentElement.getAttribute(n)]; })))"
        webView.evaluateJavaScript(script, in: nil, in: Self.appearanceWorld) { result in
            guard case .success(let value) = result, let text = value as? String,
                  let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String] else {
                return completion([:])
            }
            completion(object)
        }
    }

    private static func literal(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.allowsContentJavaScript = false
        let url = navigationAction.request.url
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? false
        // The one document Darni wrote: loadHTMLString's own navigation.
        if isMainFrame, navigationAction.navigationType == .other, url?.absoluteString == "about:blank", !hasDocument {
            return decisionHandler(.allow, preferences)
        }
        if let url {
            cancelledNavigations.append(url)
            if navigationAction.navigationType == .linkActivated {
                onLink?(url, navigationAction.modifierFlags.contains(.command))
            }
        }
        decisionHandler(.cancel, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Nothing but the written document is ever shown; a response is never a download.
        decisionHandler(navigationResponse.response.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === documentNavigation else { return }
        hasDocument = true
        onLoad?()
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // No credential is ever given: an image that wants one does not load.
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust: completionHandler(.performDefaultHandling, nil)
        default: completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    // MARK: WKUIDelegate

    /// target=_blank and window.open: no window is made.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            cancelledNavigations.append(url)
            if navigationAction.navigationType == .linkActivated { onLink?(url, true) }
        }
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

/// The reader's web view: a plain context menu (Copy and Look Up only; no
/// "Open Link in New Window", "Download Image" or "Reload", which would act
/// outside the tab's profile or load something Darni did not write). WebKit's
/// own Copy Link is dropped too: it would copy the link with its trackers,
/// past `LinkCleaner` (security note R-2). A link is copied from the page.
final class ReaderWKWebView: WKWebView {
    static let keptMenuItems: Set<String> = [
        "WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp",
    ]

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        Self.trim(menu)
        super.willOpenMenu(menu, with: event)
    }

    /// Keeps only `keptMenuItems` (and separators between them).
    static func trim(_ menu: NSMenu) {
        menu.items.removeAll { item in
            guard !item.isSeparatorItem else { return false }
            return !keptMenuItems.contains(item.identifier?.rawValue ?? "")
        }
    }
}

/// The reader's page in SwiftUI. The page takes the keyboard when it appears, so the arrow
/// keys, Space and ⌘C act on the article and not on the page underneath.
struct ReaderPageView: NSViewRepresentable {
    let page: ReaderPage

    final class Coordinator {
        var tookKeyboard = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        // Not in a window yet: try once it is.
        DispatchQueue.main.async { [weak view = page.webView, coordinator = context.coordinator] in
            guard let view else { return }
            Self.takeKeyboard(view, coordinator)
        }
        return page.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        Self.takeKeyboard(nsView, context.coordinator)
    }

    /// Once, when the reader first shows in a key window: later the keyboard is wherever the person put it.
    private static func takeKeyboard(_ view: WKWebView, _ coordinator: Coordinator) {
        guard !coordinator.tookKeyboard, let window = view.window else { return }
        coordinator.tookKeyboard = true
        if window.isKeyWindow { window.makeFirstResponder(view) }
    }
}
