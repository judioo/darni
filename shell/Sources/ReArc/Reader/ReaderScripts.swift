import CryptoKit
import Foundation

/// The reader's two page scripts, built around the pinned Readability.js in
/// the app's resources (Resources/Reader/README.md). Both run in an isolated
/// world of the page and answer with JSON text, which `ReaderExtraction` checks.
enum ReaderScripts {
    /// What is vendored. The hashes are checked before a file is used.
    static let upstreamVersion = "0.6.0"
    static let upstreamRevision = "d7949dc47dd9ed9ee1d3b34ffdcf3bce28cde435"
    static let readabilityFile = "Readability.js"
    static let readabilitySHA256 = "e9330028c8a5a4aa7d75147be2605d520f7f213c7b28474947dc0e9c984e9bed"
    static let readerableFile = "Readability-readerable.js"
    static let readerableSHA256 = "e73600367067be2da322c0f26be9c4ec7759cd01b630dbb57278c326e5b5aba8"

    /// The isolated world the scripts run in: the reader's own, shared with
    /// no boost and not the boost editor's (`ChromiumScriptWorld.boost`).
    static let worldID = UUID(uuidString: "5EADE200-0D1E-4A11-9E0A-52EAD3B00001")!
    static let detectionTimeoutMS: UInt32 = 3000
    static let extractionTimeoutMS: UInt32 = 12000
    /// Readability gives up on a document with more elements than this.
    static let maxElements = 40_000

    enum LoadError: Error, Equatable {
        case missing(String)
        case hashMismatch(String)
    }

    /// The target's resource bundle (as `SunriseScore.resourceBundle` finds
    /// its own): Contents/Resources in the app, next to the binary for
    /// `swift run`, next to the test bundle for `swift test`.
    static let resourceBundle: Bundle? = {
        let name = "ReArcShell_ReArc.bundle"
        let code = Bundle(for: BundleFinder.self)
        let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL, code.resourceURL,
                     code.bundleURL.deletingLastPathComponent(), Bundle.main.executableURL?.deletingLastPathComponent()]
        return roots.lazy.compactMap { $0.flatMap { Bundle(url: $0.appendingPathComponent(name)) } }.first
    }()

    private final class BundleFinder {}

    static func resourceURL(_ file: String) -> URL? {
        resourceBundle?.resourceURL?.appendingPathComponent("Reader").appendingPathComponent(file)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A vendored file's text, only if its bytes are the pinned ones.
    static func vendored(_ file: String, sha256 expected: String) throws -> String {
        guard let url = resourceURL(file), let data = try? Data(contentsOf: url) else { throw LoadError.missing(file) }
        guard sha256(data) == expected, let text = String(data: data, encoding: .utf8) else { throw LoadError.hashMismatch(file) }
        return text
    }

    private static let loaded: Result<(detection: String, extraction: String), LoadError> = {
        do {
            let readability = try vendored(readabilityFile, sha256: readabilitySHA256)
            let readerable = try vendored(readerableFile, sha256: readerableSHA256)
            return .success((detectionSource(readerable: readerable), extractionSource(readability: readability)))
        } catch let error as LoadError {
            return .failure(error)
        } catch {
            return .failure(.missing(readabilityFile))
        }
    }()

    /// "Does this page look like an article?" Answers `{"article": Bool}`.
    static func detection() throws -> String { try loaded.get().detection }
    /// Extracts the article. Answers `{"ok": false}` or the article (`ReaderExtraction.article`).
    static func extraction() throws -> String { try loaded.get().extraction }

    /// `var module` hides a page element named "module" from upstream's
    /// CommonJS export check, so nothing is written on a page object.
    static func detectionSource(readerable: String) -> String {
        """
        (function () {
        var module;
        \(readerable)
        try {
          if (location.protocol !== "http:" && location.protocol !== "https:") return JSON.stringify({article: false});
          return JSON.stringify({article: isProbablyReaderable(document) === true});
        } catch (error) {
          return JSON.stringify({article: false});
        }
        })()
        """
    }

    /// Walks a DOM element into the plain tree `ReaderSanitiser` reads, with
    /// the DOM's own accessors taken from the prototypes, so a page element
    /// named "attributes" or "firstChild" cannot stand in for them.
    static let walker = """
    var HTML = "http://www.w3.org/1999/xhtml";
    function getter(proto, name) { return Object.getOwnPropertyDescriptor(proto, name).get; }
    var nodeType = getter(Node.prototype, "nodeType"), nodeValue = getter(Node.prototype, "nodeValue");
    var firstChild = getter(Node.prototype, "firstChild"), nextSibling = getter(Node.prototype, "nextSibling");
    var localName = getter(Element.prototype, "localName"), namespaceURI = getter(Element.prototype, "namespaceURI");
    var attributeNames = Element.prototype.getAttributeNames, attribute = Element.prototype.getAttribute;
    var budget = 60000;
    function walk(node, depth) {
      if (budget-- <= 0 || depth > 250) return null;
      var type = nodeType.call(node);
      if (type === 3) return String(nodeValue.call(node));
      if (type !== 1) return null;
      var out = {t: String(localName.call(node))};
      var ns = namespaceURI.call(node);
      if (ns !== HTML) out.ns = String(ns);
      var names = attributeNames.call(node), a = {}, count = 0;
      for (var i = 0; i < names.length && count < 40; i++) {
        var value = attribute.call(node, names[i]);
        if (typeof value === "string" && value.length <= 8192) { a[String(names[i])] = value; count++; }
      }
      if (count) out.a = a;
      var c = [];
      for (var child = firstChild.call(node); child; child = nextSibling.call(child)) {
        var walked = walk(child, depth + 1);
        if (walked !== null) c.push(walked);
      }
      if (c.length) out.c = c;
      return out;
    }
    """

    /// Readability works on a copy of the document (a copy has no browsing
    /// context: nothing in it loads or runs), so the page itself is not
    /// changed. Its result element is walked into plain data (`walker`).
    static func extractionSource(readability: String) -> String {
        """
        (function () {
        var module;
        \(readability)
        \(walker)
        try {
          if (location.protocol !== "http:" && location.protocol !== "https:") return JSON.stringify({ok: false, reason: "scheme"});
          // The images the page itself has loaded: the only ones the reader may show.
          var loaded = [], images = document.images;
          for (var i = 0; i < images.length && loaded.length < 2000; i++) {
            var image = images[i];
            if (image.complete && image.naturalWidth > 1 && image.naturalHeight > 1 && typeof image.currentSrc === "string" && image.currentSrc) {
              loaded.push(image.currentSrc);
            }
          }
          var article = new Readability(document.cloneNode(true), {
            maxElemsToParse: \(maxElements),
            serializer: function (element) { return element; }
          }).parse();
          if (!article || !article.content) return JSON.stringify({ok: false, reason: "no-article"});
          function text(value) { return typeof value === "string" ? value.slice(0, 2000) : null; }
          return JSON.stringify({
            ok: true,
            title: text(article.title),
            byline: text(article.byline),
            siteName: text(article.siteName),
            lang: text(article.lang),
            dir: text(article.dir),
            content: walk(article.content, 0),
            loaded: loaded
          });
        } catch (error) {
          return JSON.stringify({ok: false, reason: "error"});
        }
        })()
        """
    }
}
