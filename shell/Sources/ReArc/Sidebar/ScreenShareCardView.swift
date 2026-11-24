import AppKit
import SwiftUI
import SidebarModel

/// The sharing card: a tab's page shares a tab, a window or the screen and
/// this window is not showing that tab. The strip's 33 pt card, as the call
/// card: the tab's favicon and what it shares (back to the tab) and Stop
/// Sharing. State comes from the model's record of live shares
/// (`BrowserViewModel.screenShares`, engine ABI 1.70); the caller decides
/// placement and supplies the actions.
struct ScreenShareCardView: View {
    let line: String
    let favicon: NSImage?
    let faviconToken: String
    var isAlone = false
    let goToTab: () -> Void
    let stop: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            MediaCardLead(title: line, favicon: favicon, faviconToken: faviconToken, isActive: isHovering || isAlone,
                          accessibilityLabel: line, goToTab: goToTab)
            ScreenShareStopButton(action: stop)
                .padding(.trailing, 4)
        }
        .frame(height: MediaStripMetrics.height)
        .background(MediaStripBackground())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(line)
        .accessibilityIdentifier("screenShareCard")
    }
}

/// The stop glyph on a red disc: always red, because something is leaving the Mac while it shows.
private struct ScreenShareStopButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.red.opacity(isHovering ? 1 : 0.85)))
                .frame(width: 30, height: MediaStripMetrics.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(ScreenShareText.stop)
        .accessibilityLabel(ScreenShareText.stop)
        .accessibilityIdentifier("screenShareCardStop")
    }
}
