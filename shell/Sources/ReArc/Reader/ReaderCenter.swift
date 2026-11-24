import Foundation
import Observation
import SidebarModel

/// An engine that can run one of the reader's scripts in the reader's own
/// isolated world of the page it shows, and give back the script's answer
/// (JSON text). Chromium: `ReArcTabEvaluateScript` with the reader's world id.
protocol ReaderScriptEvaluating: AnyObject {
    @MainActor func evaluateReaderScript(_ source: String, timeoutMS: UInt32) async throws -> String
}

/// The readers that are open, which pages look like articles, and how the
/// reader looks (docs/FEATURE-SPECS/READER-VIEW.md §3). Nothing here is
/// written to disk but the appearance settings: an article lives in memory
/// while its reader is open and is gone when it closes.
@Observable
final class ReaderCenter {
    enum Availability: Equatable {
        case unknown, checking, article, notArticle
    }

    /// One open reader, over one tab's page. The page underneath is not touched.
    struct Session: Identifiable {
        let id = UUID()
        let tabID: UUID
        let article: ReaderArticle
        let page: ReaderPage
    }

    enum OpenError: Error, Equatable {
        case notReadable
        case noArticle
        case failed
    }

    private(set) var sessions: [UUID: Session] = [:]
    /// The last answer for each tab, with the address it was given for.
    private var answers: [UUID: (url: URL, state: Availability)] = [:]
    /// Tabs whose article is being extracted now.
    private(set) var opening: Set<UUID> = []
    @ObservationIgnored private let store: ReaderAppearanceStore

    /// Font, text size, width and theme, kept in the app's settings. A change shows in every open reader at once.
    var appearance: ReaderAppearance {
        didSet {
            guard appearance != oldValue else { return }
            store.save(appearance, replacing: oldValue)
            for session in sessions.values { session.page.applyAppearance(appearance) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        store = ReaderAppearanceStore(defaults: defaults)
        appearance = store.load()
    }

    // MARK: Is it an article?

    func availability(for tabID: UUID, url: URL?) -> Availability {
        guard let url, ReaderURLPolicy.isReadable(url) else { return .notArticle }
        guard let answer = answers[tabID], answer.url == url else { return .unknown }
        return answer.state
    }

    /// Asks the page once per address. A page still building itself when it
    /// finished loading is asked a second time a moment later. A page too busy
    /// to answer in time (a heavy long read just after loading) is not taken
    /// for "not an article": it is asked again with a longer wait, and if it
    /// never answers its address stays unknown, so the next look asks again.
    @MainActor
    func detect(tabID: UUID, url: URL, engine: any ReaderScriptEvaluating,
                retryAfter delay: Duration = .seconds(2)) async {
        guard ReaderURLPolicy.isReadable(url), availability(for: tabID, url: url) == .unknown else { return }
        answers[tabID] = (url, .checking)
        var answer = await probe(engine, timeoutMS: ReaderScripts.detectionTimeoutMS)
        var asked = 1
        // A "no" is asked once more; a page that did not answer, up to twice more.
        while answer != .article, !Task.isCancelled, delay > .zero,
              asked < (answer == .noAnswer ? ReaderScripts.detectionMaxAsks : 2) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, answers[tabID]?.url == url else { break }
            answer = await probe(engine, timeoutMS: ReaderScripts.detectionRetryTimeoutMS)
            asked += 1
        }
        // The tab moved on while the page was asked: the answer is for a page no longer shown.
        guard answers[tabID]?.url == url else { return }
        switch answer {
        case .article: answers[tabID] = (url, .article)
        case .notArticle: answers[tabID] = Task.isCancelled ? nil : (url, .notArticle)
        case .noAnswer: answers[tabID] = nil
        }
    }

    enum DetectionAnswer: Equatable {
        case article, notArticle
        /// The script failed or timed out: the page said nothing either way.
        case noAnswer
    }

    @MainActor
    private func probe(_ engine: any ReaderScriptEvaluating, timeoutMS: UInt32) async -> DetectionAnswer {
        guard let source = try? ReaderScripts.detection() else { return .notArticle }
        guard let json = try? await engine.evaluateReaderScript(source, timeoutMS: timeoutMS) else { return .noAnswer }
        return ReaderExtraction.looksLikeArticle(json: json) ? .article : .notArticle
    }

    // MARK: Open and close

    func session(for tabID: UUID) -> Session? { sessions[tabID] }
    func isShowing(_ tabID: UUID) -> Bool { sessions[tabID] != nil }

    /// The toolbar's colour over a page: the reader theme's while a reader
    /// shows there, else the page's own (NIGHT-1125 bug 6: the strip kept the
    /// site's colour above the reader).
    func toolbarTint(forPage id: UUID?, pageColor: PageColor?, isDark: Bool) -> PageColor? {
        guard let id, isShowing(id) else { return pageColor }
        return appearance.backgroundColor(isDark: isDark)
    }

    /// Extracts the page's article and opens its reader. `url` is the address
    /// the engine reports, never one the page's script gave. `onLink` gets a
    /// link the person clicked in the reader.
    @MainActor
    @discardableResult
    func open(tabID: UUID, url: URL, engine: any ReaderScriptEvaluating, images: ReaderImageMode,
              onLink: @escaping (URL, Bool) -> Void) async throws -> Session {
        guard ReaderURLPolicy.isReadable(url) else { throw OpenError.notReadable }
        if let existing = sessions[tabID] { return existing }
        guard !opening.contains(tabID) else { throw OpenError.failed }
        opening.insert(tabID)
        defer { opening.remove(tabID) }
        let json: String
        do {
            json = try await engine.evaluateReaderScript(try ReaderScripts.extraction(), timeoutMS: ReaderScripts.extractionTimeoutMS)
        } catch {
            throw OpenError.failed
        }
        let article: ReaderArticle
        do {
            article = try ReaderExtraction.article(json: json, pageURL: url, images: images)
        } catch ReaderExtractionError.noArticle {
            answers[tabID] = (url, .notArticle)
            throw OpenError.noArticle
        } catch {
            throw OpenError.failed
        }
        answers[tabID] = (url, .article)
        return show(article, tabID: tabID, onLink: onLink)
    }

    /// Opens a reader on an article already made (tests, and `open`).
    @discardableResult
    func show(_ article: ReaderArticle, tabID: UUID, onLink: @escaping (URL, Bool) -> Void) -> Session {
        let page = ReaderPage()
        page.onLink = onLink
        page.show(article, appearance: appearance)
        let session = Session(tabID: tabID, article: article, page: page)
        sessions[tabID] = session
        return session
    }

    /// Leaves the reader. The page underneath was never changed, so it is as it was left.
    func close(tabID: UUID) {
        guard let session = sessions.removeValue(forKey: tabID) else { return }
        session.page.onLink = nil
        session.page.webView.stopLoading()
    }

    /// The tab shows another address now: its reader, made from the old one, closes.
    func pageChanged(tabID: UUID, url: URL?) {
        guard let session = sessions[tabID], session.article.sourceURL != url else { return }
        close(tabID: tabID)
    }

    /// A tab is gone: its reader and its answer go with it.
    func forget(tabID: UUID) {
        close(tabID: tabID)
        answers[tabID] = nil
    }
}
