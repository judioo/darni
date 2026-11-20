import AppKit
import ImageIO
import Observation
import SidebarModel

/// Page thumbnails for the ⌃Tab switcher's cards and the sidebar's hover
/// cards, for every window.
///
/// Only the tab on screen is captured: a hidden page has no reliable
/// pixels, and the engine's capture of one waits for its next frame. A tab
/// gets its thumbnail a moment after it is shown or its page changes
/// (`tabShown`), again when the switcher opens on it or a tab row is hovered
/// (`captureSelectedTab`), and at most once per page per
/// `TabSnapshotCache.maxAge` otherwise. A tab that was never shown has none.
///
/// Privacy: thumbnails are kept in memory only, never written to disk, and
/// are gone when Darni quits. Only tabs of the sidebar are captured, so a
/// private window's page never is. A thumbnail is shown only on its own
/// tab's card, is dropped when its tab closes or moves to another profile
/// or container, and no page or extension can read it.
///
/// Memory: at most `TabSnapshotCache.capacity` (24) thumbnails of at most
/// 520 × 347 px, about 0.7 MB each, 17 MB in all.
@Observable
final class TabThumbnails {
    static let shared = TabThumbnails()

    /// Hover cards are 260 pt wide and the switcher's 158 pt; 2× the wider one.
    static let pixelWidth = 520
    /// After a tab is shown, time for its page to paint.
    static let settleDelay: TimeInterval = 1.2
    /// A page still loading is looked at again this many times.
    static let settleRetries = 4
    /// The switcher asks for the page as it is being left, if the last
    /// capture is older than this.
    static let leavingAge: TimeInterval = 15

    @ObservationIgnored private var cache = TabSnapshotCache<NSImage>()
    /// Counts stored captures, so an open switcher draws one that arrives.
    private(set) var revision = 0
    @ObservationIgnored private var settle: Timer?
    @ObservationIgnored private var settleTries = 0

    func image(for tab: Tab) -> NSImage? {
        image(forTabID: tab.id, url: tab.url)
    }

    /// The thumbnail of this tab's page; nil when the tab shows another page now.
    func image(forTabID id: Tab.ID, url: URL) -> NSImage? {
        _ = revision
        return cache.image(for: id, url: url)
    }

    /// The tab is gone, or its page now belongs to another profile. A
    /// capture of the old page still under way is thrown away when it ends,
    /// whenever that is (the cache's generation, TT-01).
    func remove(_ id: Tab.ID) {
        let had = cache.entries[id] != nil
        cache.remove(id)
        if had { revision += 1 }
    }

    // MARK: When

    func captureSelectedTab(of model: BrowserViewModel?, olderThan age: TimeInterval? = nil) {
        guard let model, let tab = model.store.selectedTab else { return }
        capture(tab, model: model, olderThan: age)
    }

    /// A tab was shown, or the page of the tab on screen changed: capture it
    /// once it has had time to paint. One timer, whatever the number of calls.
    func tabShown(in model: BrowserViewModel) {
        settleTries = 0
        scheduleSettle(model)
    }

    private func scheduleSettle(_ model: BrowserViewModel) {
        settle?.invalidate()
        let timer = Timer(timeInterval: Self.settleDelay, repeats: false) { [weak self, weak model] _ in
            guard let self, let model else { return }
            self.settled(model)
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        settle = timer
    }

    private func settled(_ model: BrowserViewModel) {
        settle = nil
        // Not in front, or covered: the page may not be painting.
        guard NSApplication.shared.isActive, model.windowOcclusionState == .visible,
              let tab = model.store.selectedTab else { return }
        let engine = model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab))
        if engine?.isLoading == true, settleTries < Self.settleRetries {
            settleTries += 1
            scheduleSettle(model)
            return
        }
        capture(tab, model: model, olderThan: nil)
    }

    // MARK: Capture

    private func capture(_ tab: Tab, model: BrowserViewModel, olderThan age: TimeInterval?) {
        guard cache.shouldCapture(tab.id, url: tab.url, now: Date(), olderThan: age),
              let engine = model.engineHost.engine(forTabID: tab.id, profileID: model.profileID(for: tab)) else { return }
        let generation = cache.beginCapture(tab.id)
        let id = tab.id, url = tab.url
        Task { @MainActor [weak self, weak model] in
            let png = try? await engine.captureSnapshot(scope: .visible)
            let image = await Self.thumbnail(from: png)
            guard let self else { return }
            // Removed since (closed, or another profile or container): kept by nobody.
            guard self.cache.finishCapture(image, for: id, url: url, now: Date(), generation: generation) else { return }
            // A tab closed since, this one included, keeps nothing.
            if let model { self.cache.removeAll(except: { model.store.tab(withID: $0) != nil }) }
            self.revision += 1
        }
    }

    /// Decoded and scaled off the main thread: a page's capture is a PNG of
    /// its whole viewport at the display's scale.
    private static func thumbnail(from png: Data?) async -> NSImage? {
        guard let png else { return nil }
        let scaled = await Task.detached(priority: .utility) { Self.scaled(png) }.value
        return scaled.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    /// The top of the page, `pixelWidth` wide at most and no taller than a
    /// card's 3:2, in a bitmap of its own (so the full capture is released).
    static func scaled(_ png: Data, pixelWidth: Int = TabThumbnails.pixelWidth) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              sourceWidth > 0, sourceHeight > 0 else { return nil }
        let width = min(sourceWidth, pixelWidth)
        let fullHeight = max(1, Int((Double(sourceHeight) * Double(width) / Double(sourceWidth)).rounded()))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, fullHeight),
        ]
        guard let small = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let height = min(small.height, max(1, Int((Double(small.width) / TabSwitcherLayout.thumbnailAspect).rounded())))
        guard let context = CGContext(
            data: nil, width: small.width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        // Quartz draws from the bottom: the page's top stays, its bottom is cut.
        context.draw(small, in: CGRect(x: 0, y: height - small.height, width: small.width, height: small.height))
        return context.makeImage()
    }
}
