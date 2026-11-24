import AppKit
import SidebarModel

/// What the reader button in the address field shows for a page.
enum ReaderButtonState: Equatable {
    /// The page is no article (or not a web page): no button.
    case hidden
    case available
    /// The article is being read out of the page.
    case opening
    case showing
}

/// The reader view in a browser window and in a private window
/// (docs/FEATURE-SPECS/READER-VIEW.md §3): the button, the View menu's item
/// and ⌥⌘R all come here. A reader belongs to a page: a tab (by the tab's
/// id) or a private window (by the window's id), with that page's engine.
extension BrowserViewModel {
    static let readerMenuKey: Character = "r"
    static let readerMenuModifiers: NSEvent.ModifierFlags = [.command, .option]

    // MARK: The page a command is for

    /// The page ⌥⌘R and the menu item act on: the key private window's, else the tab the window shows.
    private func readerPage(in window: SidebarWindowID?) -> (id: UUID, engine: (any WebEngine)?)? {
        if !privateWindows.isEmpty, let privateWindow = keyPrivateWindow { return (privateWindow.id, privateWindow.engine) }
        guard let tab = selectedTab(in: window) else { return nil }
        return (tab.id, focusedEngine(in: window))
    }

    /// The engine of the page a reader belongs to.
    private func readerEngine(forPage id: UUID) -> (any WebEngine)? {
        if let privateWindow = privateWindows[id] { return privateWindow.engine }
        guard let tab = store.tab(withID: id) else { return nil }
        return engineHost.engine(forTabID: id, profileID: profileID(for: tab))
    }

    // MARK: The button and the menu item

    func readerButtonState(forPage id: UUID?, engine: (any WebEngine)?) -> ReaderButtonState {
        guard let id else { return .hidden }
        if reader.isShowing(id) { return .showing }
        if reader.opening.contains(id) { return .opening }
        guard let engine, engine is any ReaderScriptEvaluating else { return .hidden }
        return reader.availability(for: id, url: engine.currentURL) == .article ? .available : .hidden
    }

    func readerButtonState(for tab: Tab?, engine: (any WebEngine)?) -> ReaderButtonState {
        readerButtonState(forPage: tab?.id, engine: engine)
    }

    /// The menu item: on while a reader shows, or when the page is, or may be, an article.
    func canToggleReader(in window: SidebarWindowID?) -> Bool {
        guard let page = readerPage(in: window) else { return false }
        if reader.isShowing(page.id) { return true }
        guard let engine = page.engine, engine is any ReaderScriptEvaluating, !engine.isLoading else { return false }
        return reader.availability(for: page.id, url: engine.currentURL) != .notArticle
    }

    func readerMenuTitle(in window: SidebarWindowID?) -> String {
        readerPage(in: window).map { reader.isShowing($0.id) } == true ? "Hide Reader" : "Show Reader"
    }

    /// Asks a page that finished loading whether it looks like an article (the address field asks for the page it shows).
    func detectReaderArticle(forPage id: UUID, engine: any WebEngine) {
        guard let evaluator = engine as? any ReaderScriptEvaluating, !engine.isLoading, !engine.isCrashed,
              let url = engine.currentURL, reader.availability(for: id, url: url) == .unknown else { return }
        Task { @MainActor [reader] in await reader.detect(tabID: id, url: url, engine: evaluator) }
    }

    func detectReaderArticle(for tab: Tab, engine: any WebEngine) {
        detectReaderArticle(forPage: tab.id, engine: engine)
    }

    // MARK: Pictures

    /// Which images a page's reader may load. The reader's page is not the
    /// page's Chromium profile, so a private window or a container shows none.
    func readerImageMode(forPage id: UUID, engine: any WebEngine) -> ReaderImageMode {
        let isPrivate = engine.pagePrompts.privateSession != nil || privateWindows[id] != nil
        let profile = engine.pagePrompts.profileID ?? store.tab(withID: id).map(profileID(for:))
        return ReaderImageRule.mode(isPrivate: isPrivate, isContainer: profile.map(store.isContainer) ?? false)
    }

    func readerImageMode(for tab: Tab, engine: any WebEngine) -> ReaderImageMode {
        readerImageMode(forPage: tab.id, engine: engine)
    }

    // MARK: Open and leave

    /// The menu item and ⌥⌘R: the reader of the page the key window shows.
    func toggleReader(in window: SidebarWindowID? = nil) {
        toggleReader(pageID: readerPage(in: window ?? store.keyWindowID)?.id)
    }

    func toggleReader(tabID: Tab.ID?) { toggleReader(pageID: tabID) }

    /// Opens the page's reader, or leaves it when it is open.
    func toggleReader(pageID: UUID?) {
        guard let pageID else { return }
        if reader.isShowing(pageID) {
            closeReader(pageID: pageID)
            return
        }
        guard let engine = readerEngine(forPage: pageID), let evaluator = engine as? any ReaderScriptEvaluating,
              let url = engine.currentURL, !engine.isLoading else { return }
        let images = readerImageMode(forPage: pageID, engine: engine)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.reader.open(tabID: pageID, url: url, engine: evaluator, images: images) { [weak self] link, inNewTab in
                    self?.openReaderLink(link, fromPage: pageID, inNewTab: inNewTab)
                }
            } catch ReaderCenter.OpenError.noArticle {
                self.showToast("No article to show in the reader", systemImage: "doc.plaintext")
            } catch {
                self.showToast("The reader could not open this page", systemImage: "doc.plaintext")
            }
        }
    }

    /// Leaves the reader: the page is as it was left, and takes the keyboard back.
    func closeReader(pageID: UUID) {
        guard reader.isShowing(pageID) else { return }
        reader.close(tabID: pageID)
        (readerEngine(forPage: pageID) as? PageFocusing)?.focusPage()
    }

    func closeReader(tabID: Tab.ID) { closeReader(pageID: tabID) }

    // MARK: Links

    /// A link clicked in the reader: an ordinary web address only, opened as
    /// a link the page itself gave (never as a typed or trusted address). A
    /// plain click leaves the reader and loads it in the page's own engine;
    /// ⌘-click opens it as the page's "Open Link in New Tab" does (a tab of
    /// the page's own profile, or a window of the same private session) and
    /// the reader stays.
    func openReaderLink(_ url: URL, fromPage pageID: UUID, inNewTab: Bool) {
        guard ReaderLinkRule.allows(url), let engine = readerEngine(forPage: pageID) else { return }
        if inNewTab {
            openLinkInNewTab(url, from: engine.pagePrompts)
        } else {
            closeReader(pageID: pageID)
            engine.loadPageLink(url)
        }
    }

    func openReaderLink(_ url: URL, fromTab tabID: Tab.ID, inNewTab: Bool) {
        openReaderLink(url, fromPage: tabID, inNewTab: inNewTab)
    }
}

/// A link from the reader may be followed only if it is an ordinary web
/// address the shell's navigation policy admits for content from outside
/// Darni's own UI: http or https with a host, no user name or password.
enum ReaderLinkRule {
    static func allows(_ url: URL) -> Bool {
        NavigationURLPolicy.allows(url) && NavigationURLPolicy.isImportableWebPage(url)
    }
}

enum ReaderImageRule {
    static func mode(isPrivate: Bool, isContainer: Bool) -> ReaderImageMode {
        isPrivate || isContainer ? .off : .loadedByPage
    }
}
