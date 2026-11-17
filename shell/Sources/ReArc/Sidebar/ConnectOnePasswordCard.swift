import SidebarModel
import SwiftUI

private enum ConnectOnePasswordMetrics {
    static let buttonHeight: CGFloat = 22
    static let buttonRadius: CGFloat = 6
    /// The card comes and goes as Finish setup's does.
    static let appear = Animation.easeOut(duration: 0.2)
}

/// "Connect 1Password to ReArc" above the bottom bar, in Finish setup's
/// place and card: the one-time step the person does in 1Password, with
/// Open 1Password, Done and a close button (`OnePasswordConnect`). A view of
/// its own, so only it follows the extensions' actions.
struct ConnectOnePasswordSlot: View {
    let model: BrowserViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shows = model.showsOnePasswordPrompt
        VStack(spacing: 0) {
            if shows {
                ConnectOnePasswordCard(model: model)
                    .padding(.horizontal, MediaStripMetrics.inset)
                    .padding(.bottom, MediaStripMetrics.gap)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(ConnectOnePasswordMetrics.appear, value: shows)
    }
}

struct ConnectOnePasswordCard: View {
    let model: BrowserViewModel
    @Environment(\.themeChrome) private var chrome

    private var text: Color { chrome.isDark ? Color.white.opacity(0.9) : Color.black.opacity(0.8) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(OnePasswordConnect.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(OnePasswordConnect.message)
                    .font(.system(size: 12))
                    .foregroundStyle(text.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    button(OnePasswordConnect.open, prominent: true, identifier: "connectOnePasswordOpen") {
                        model.openOnePassword()
                    }
                    button(OnePasswordConnect.done, identifier: "connectOnePasswordDone") {
                        model.markOnePasswordConnected()
                    }
                }
                .padding(.top, 2)
            }
            .padding(.leading, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            SidebarCardDismissButton(help: "Hide for now — the steps stay in Settings › General",
                                     label: "Dismiss Connect 1Password", identifier: "dismissConnectOnePassword") {
                model.dismissOnePasswordPrompt()
            }
            .padding(4)
        }
        .background(MediaStripBackground())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connectOnePasswordCard")
    }

    private func button(_ title: String, prominent: Bool = false, identifier: String, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: ConnectOnePasswordMetrics.buttonRadius, style: .continuous)
        return Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: prominent ? .semibold : .medium))
                .foregroundStyle(text)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: ConnectOnePasswordMetrics.buttonHeight)
                .background(text.opacity(prominent ? 0.14 : 0.06), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
