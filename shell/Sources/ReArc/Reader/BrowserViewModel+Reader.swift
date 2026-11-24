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

/// The reader view in a browser window (docs/FEATURE-SPECS/READER-VIEW.md §3):
/// the button, the View menu's item and ⌥⌘R all come here.
extension BrowserViewModel {
    static let readerMenuKey: Character = "r"
    static let readerMenuModifiers: NSEvent.ModifierFlags = [.command, .option]

    func readerButtonState(for tab: Tab?, engine: (any WebEngine)?) -> ReaderButtonState {
        guard let tab else { return .hidden }
        if reader.isShowing(tab.id) { return .showing }
        if reader.opening.contains(tab.id) { return .opening }
        guard let engine, engine is any ReaderScriptEvaluating else { return .hidden }
        return reader.availability(for: tab.id, url: engine.currentURL) == .article ? .available : .hidden
    }

    /// The menu item: on while a reader shows, or when the page is, or may be, an article.
    func canToggleReader(in window: SidebarWindowID?) -> Bool {
        guard let tab = selectedTab(in: window) else { return false }
        if reader.isShowing(tab.id) { return true }
        guard let engine = focusedEngine(in: window), engine is any ReaderScriptEvaluating, !engine.isLoading else { return false }
        return reader.availability(for: tab.id, url: engine.currentURL) != .notArticle
    }

    func readerMenuTitle(in window: SidebarWindowID?) -> String {
        selectedTab(in: window).map { reader.isShowing($0.id) } == true ? "Hide Reader" : "Show Reader"
    }

    /// Asks a page that finished loading whether it looks like an article (the address field asks for the page it shows).
    func detectReaderArticle(for tab: Tab, engine: any WebEngine) {
        guard let evaluator = engine as? any ReaderScriptEvaluating, !engine.isLoading, !engine.isCrashed,
              let url = engine.currentURL, reader.availability(for: tab.id, url: url) == .unknown else { return }
        let tabID = tab.id
        Task { @MainActor [reader] in await reader.detect(tabID: tabID, url: url, engine: evaluator) }
    }

    /// Which images a tab's reader may load. The reader's page is not the
    /// tab's Chromium profile, so a private window or a container shows none.
    func readerImageMode(for tab: Tab, engine: any WebEngine) -> ReaderImageMode {
        ReaderImageRule.mode(isPrivate: engine.pagePrompts.privateSession != nil,
                             isContainer: store.isContainer(engine.pagePrompts.profileID ?? profileID(for: tab)))
    }

    /// The menu item and ⌥⌘R: the reader of the tab the key window shows.
    func toggleReader(in window: SidebarWindowID? = nil) {
        let window = window ?? store.keyWindowID
        toggleReader(tabID: selectedTab(in: window)?.id)
    }

    /// Opens the tab's reader, or leaves it when it is open.
    func toggleReader(tabID: Tab.ID?) {
        guard let tabID, let tab = store.tab(withID: tabID) else { return }
        if reader.isShowing(tabID) {
            closeReader(tabID: tabID)
            return
        }
        guard let engine = engineHost.engine(forTabID: tabID, profileID: profileID(for: tab)),
              let evaluator = engine as? any ReaderScriptEvaluating,
              let url = engine.currentURL, !engine.isLoading else { return }
        let images = readerImageMode(for: tab, engine: engine)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.reader.open(tabID: tabID, url: url, engine: evaluator, images: images) { [weak self] link, inNewTab in
                    self?.openReaderLink(link, fromTab: tabID, inNewTab: inNewTab)
                }
            } catch ReaderCenter.OpenError.noArticle {
                self.showToast("No article to show in the reader", systemImage: "doc.plaintext")
            } catch {
                self.showToast("The reader could not open this page", systemImage: "doc.plaintext")
            }
        }
    }

    /// Leaves the reader: the page is as it was left, and takes the keyboard back.
    func closeReader(tabID: Tab.ID) {
        guard reader.isShowing(tabID) else { return }
        reader.close(tabID: tabID)
        if let tab = store.tab(withID: tabID),
           let page = engineHost.engine(forTabID: tabID, profileID: profileID(for: tab)) as? PageFocusing {
            page.focusPage()
        }
    }

    /// A link clicked in the reader: an ordinary web address only, opened as
    /// a link the page itself gave (never as a typed or trusted address). A
    /// plain click leaves the reader and loads it in the tab; ⌘-click opens
    /// a new tab in the tab's own profile and the reader stays.
    func openReaderLink(_ url: URL, fromTab tabID: Tab.ID, inNewTab: Bool) {
        guard ReaderLinkRule.allows(url), let tab = store.tab(withID: tabID),
              let engine = engineHost.engine(forTabID: tabID, profileID: profileID(for: tab)) else { return }
        if inNewTab {
            openLinkInNewTab(url, from: engine.pagePrompts)
        } else {
            closeReader(tabID: tabID)
            engine.loadPageLink(url)
        }
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
