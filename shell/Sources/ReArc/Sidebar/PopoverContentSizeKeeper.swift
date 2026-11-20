import AppKit
import SwiftUI

/// Keeps a SwiftUI popover as large as its content.
///
/// SwiftUI gives a popover its size when the content's own size changes, and
/// at no other time. If the popover ends up at another size, nothing puts it
/// right until the content changes size again or the popover is reopened:
/// the content keeps its full size, centred, and is cut off at both ends.
/// Seen on screen in build 1126 after Allow in the blocked list: once in
/// eight tries the popover stayed at its short size (308 pt) under content
/// of about 510 pt. The reload empties the list and the page fills it again
/// within a moment, so the popover is told to shrink and then to grow line
/// by line while its resize is still animating. Which of those steps is
/// lost is not known: off screen a popover resizes at once and the race
/// does not happen. The state it leaves is the one above.
///
/// This view sits behind the popover's content. After the content or the
/// popover's window has changed size and both have been still for a moment,
/// it compares the popover with what its content asks for and, if they
/// differ, sets the popover's size. A popover that follows its content, as
/// nearly always, is left alone. Outside a popover it does nothing.
struct PopoverContentSizeKeeper: NSViewRepresentable {
    func makeNSView(context: Context) -> KeeperView { KeeperView() }
    func updateNSView(_ nsView: KeeperView, context: Context) {}

    /// The size the popover should be given, or nil to leave it alone.
    /// `shown` is the size its content view has now, `fitting` the size the
    /// content asks for. A size the screen cannot hold is SwiftUI's to deal with.
    nonisolated static func correction(shown: NSSize, fitting: NSSize, screen: NSSize?) -> NSSize? {
        guard fitting.width > 0, fitting.height > 0 else { return nil }
        if let screen, fitting.width > screen.width || fitting.height > screen.height { return nil }
        guard abs(shown.width - fitting.width) > 0.5 || abs(shown.height - fitting.height) > 0.5 else { return nil }
        return fitting
    }

    final class KeeperView: NSView {
        /// Longer than the popover's own resize animation: a size still on its way is not a wrong one.
        static let settleDelay: TimeInterval = 0.3
        /// Corrections in a row that did not bring agreement; then it stops, so it can never fight the popover for good.
        static let correctionLimit = 3

        private var observer: NSObjectProtocol?
        private var pendingCheck: DispatchWorkItem?
        private var corrections = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observer.map(NotificationCenter.default.removeObserver)
            observer = nil
            pendingCheck?.cancel()
            corrections = 0
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleCheck() }
            }
            scheduleCheck()
        }

        deinit { observer.map(NotificationCenter.default.removeObserver) }

        /// It is as large as the content it sits behind.
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleCheck()
        }

        private func scheduleCheck() {
            pendingCheck?.cancel()
            guard window != nil else { return }
            let check = DispatchWorkItem { [weak self] in self?.check() }
            pendingCheck = check
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: check)
        }

        /// The popover this view is in: its content's view controller hands on to it in the responder chain.
        private var popover: NSPopover? {
            var responder = nextResponder
            while let next = responder {
                if let popover = next as? NSPopover { return popover }
                if next is NSWindow { return nil }
                responder = next.nextResponder
            }
            return nil
        }

        private func check() {
            guard let window, let popover, popover.isShown, let content = popover.contentViewController?.view else { return }
            guard let size = PopoverContentSizeKeeper.correction(shown: content.frame.size, fitting: content.fittingSize,
                                                                 screen: window.screen?.visibleFrame.size) else {
                corrections = 0
                return
            }
            guard corrections < Self.correctionLimit else { return }
            corrections += 1
            if popover.contentSize == size {
                // The popover already holds this size and its window does not show it: setting it again changes nothing.
                let animates = popover.animates
                popover.animates = false
                popover.contentSize = NSSize(width: size.width, height: size.height + 1)
                popover.animates = animates
            }
            popover.contentSize = size
            // Looked at once more when it has settled.
            scheduleCheck()
        }
    }
}
