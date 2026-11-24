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

/// The reader's web view: a plain context menu, exactly Copy and Look Up.
/// No "Open Link in New Window", "Download Image" or "Reload", which would
/// act outside the tab's profile or load something Darni did not write.
/// WebKit's own Copy Link is dropped too: it would copy the link with its
/// trackers, past `LinkCleaner` (security note R-2). A link is copied from the page.
///
/// The menu is Darni's own, shown with `NSMenu.popUp(positioning:at:in:)`, which
/// adds nothing: AppKit's contextual additions (Services, Writing Tools, Siri
/// and the like) come only with a context menu shown through
/// `popUpContextMenu`. Darni ships no AI features, so none may appear here.
/// Should WebKit still open its own menu (the keyboard's menu key, VoiceOver),
/// `willOpenMenu` replaces every item with Darni's two.
final class ReaderWKWebView: WKWebView {
    static let copyIdentifier = NSUserInterfaceItemIdentifier("DarniReaderMenuCopy")
    static let lookUpIdentifier = NSUserInterfaceItemIdentifier("DarniReaderMenuLookUp")
    /// The app's own world for reading the selection; content JavaScript stays off.
    private static let selectionWorld = WKContentWorld.world(name: "DarniReaderSelection")

    /// The selected text and where its first line sits (the view's coordinates).
    struct Selection: Equatable {
        var text: String
        var origin: CGPoint
    }

    /// What the menu last open was made for: Look Up shows it.
    private var menuSelection: Selection?

    override func rightMouseDown(with event: NSEvent) {
        openMenu(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return openMenu(for: event) }
        super.mouseDown(with: event)
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menuSelection = nil
        Self.fill(menu, target: self, selection: nil)
        super.willOpenMenu(menu, with: event)
    }

    /// Makes `menu` exactly Copy and Look Up, with nothing AppKit may add.
    /// `selection` nil: not known yet (WebKit's own menu), both items stay on
    /// and act on whatever is selected then.
    static func fill(_ menu: NSMenu, target: AnyObject?, selection: Selection?) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        let hasText = selection.map { !$0.text.isEmpty } ?? true
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        copy.identifier = copyIdentifier
        let lookUp = NSMenuItem(title: "Look Up", action: #selector(ReaderWKWebView.lookUpSelection(_:)), keyEquivalent: "")
        lookUp.identifier = lookUpIdentifier
        for item in [copy, lookUp] {
            item.target = target
            item.isEnabled = hasText
            menu.addItem(item)
        }
    }

    /// A right-click on a word with nothing selected selects the word, as in
    /// Safari; then Darni's menu opens at the pointer.
    private func openMenu(for event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        window?.makeFirstResponder(self)
        readSelection(selectingWordAt: point) { [weak self] selection in
            guard let self else { return }
            self.menuSelection = selection
            let menu = NSMenu(title: "Reader")
            Self.fill(menu, target: self, selection: selection ?? Selection(text: "", origin: .zero))
            menu.popUp(positioning: nil, at: point, in: self)
        }
    }

    @objc func lookUpSelection(_ sender: Any?) {
        if let selection = menuSelection, !selection.text.isEmpty { return showDefinition(selection) }
        readSelection(selectingWordAt: nil) { [weak self] selection in
            guard let selection, !selection.text.isEmpty else { return }
            self?.showDefinition(selection)
        }
    }

    private func showDefinition(_ selection: Selection) {
        let text = NSAttributedString(string: selection.text, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize + 4)])
        showDefinition(for: text, at: selection.origin)
    }

    /// The page's selection (the word at `point` selected first when nothing
    /// is), in the reader's own document, from the app's own world.
    private func readSelection(selectingWordAt point: CGPoint?, _ completion: @escaping (Selection?) -> Void) {
        let scale = magnification > 0 ? magnification : 1
        var select = "false"
        if let point {
            let x = point.x / scale, y = (isFlipped ? point.y : bounds.height - point.y) / scale
            select = "\(Double(x)), \(Double(y))"
        }
        let script = """
        (function (at) {
          var s = getSelection();
          if (at && (s.rangeCount === 0 || s.isCollapsed) && document.caretRangeFromPoint) {
            var caret = document.caretRangeFromPoint(at[0], at[1]);
            if (caret && caret.startContainer.nodeType === 3) {
              s.removeAllRanges(); s.addRange(caret);
              s.modify("move", "backward", "word"); s.modify("extend", "forward", "word");
            }
          }
          if (s.rangeCount === 0 || s.isCollapsed) return null;
          var text = s.toString().trim().slice(0, 2000);
          var r = s.getRangeAt(0).getClientRects()[0] || s.getRangeAt(0).getBoundingClientRect();
          return text ? {text: text, x: r.left, y: r.bottom} : null;
        })(\(point == nil ? "null" : "[" + select + "]"))
        """
        evaluateJavaScript(script, in: nil, in: Self.selectionWorld) { [weak self] result in
            guard let self, case .success(let value) = result, let object = value as? [String: Any],
                  let text = object["text"] as? String, let x = object["x"] as? Double, let y = object["y"] as? Double else {
                return completion(nil)
            }
            let viewY = (self.isFlipped ? y * scale : self.bounds.height - y * scale)
            completion(Selection(text: text, origin: CGPoint(x: x * scale, y: viewY)))
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
