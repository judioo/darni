import Foundation

/// Whether a sideways swipe at a point may go back or forward: every
/// horizontal scroller under the point must be at that edge. Embedded
/// documents (frames) can't be seen into, so never navigate over one.
///
/// The walk follows the composed tree: into open shadow roots under the point
/// and up through slots and shadow hosts. Custom elements are ordinary
/// elements to it: YouTube and GitHub are built from them, and a swipe there
/// used to go to the page (owner, 2026-11-21).
///
/// `overscroll-behavior-x: none | contain` stops the swipe only where Chrome
/// lets it: on the root (Chrome takes the viewport's value from the root
/// element), and on a horizontal scroller whose own scrolling would otherwise
/// chain on to the page. On any other element it has no effect.
enum HistorySwipeEdgeScript {
    static func source(x: Double, y: Double) -> String {
        """
        (() => {
          const px = innerWidth * \(x), py = innerHeight * \(y);
          let node = document.elementFromPoint(px, py);
          if (!node) return {back: false, forward: false};
          for (let depth = 0; node.shadowRoot && depth < 32; depth++) {
            const inner = node.shadowRoot.elementFromPoint(px, py);
            if (!inner || inner === node) break;
            node = inner;
          }
          const root = document.documentElement;
          const stops = (style) => style.overscrollBehaviorX === 'none' || style.overscrollBehaviorX === 'contain';
          let back = true, forward = true;
          while (node) {
            if (/^(IFRAME|FRAME|OBJECT|EMBED)$/.test(node.tagName))
              return {back: false, forward: false};
            const style = getComputedStyle(node);
            const isRoot = node === root || node === document.scrollingElement;
            const range = node.scrollWidth - node.clientWidth;
            if (range > 1 && (isRoot || /^(auto|scroll|overlay)$/.test(style.overflowX))) {
              const min = style.direction === 'rtl' ? -range : 0;
              const max = style.direction === 'rtl' ? 0 : range;
              back = back && node.scrollLeft <= min + 1;
              forward = forward && node.scrollLeft >= max - 1;
              if (!isRoot && stops(style)) return {back: false, forward: false};
            }
            if (node === root && stops(style)) return {back: false, forward: false};
            const host = node.parentNode instanceof ShadowRoot ? node.parentNode.host : null;
            node = node.assignedSlot || node.parentElement || host;
          }
          return {back, forward};
        })()
        """
    }
}
