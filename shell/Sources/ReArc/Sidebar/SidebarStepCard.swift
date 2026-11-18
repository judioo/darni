import SwiftUI

private enum SidebarStepCardMetrics {
    static let buttonHeight: CGFloat = 22
    static let buttonRadius: CGFloat = 6
    /// The card comes and goes as Finish setup's does.
    static let appear = Animation.easeOut(duration: 0.2)
}

/// A one-time step's place above the bottom bar, where Finish setup sits:
/// the card slides in from the bar and fades out, in the strips' insets.
struct SidebarStepCardSlot<Card: View>: View {
    let shows: Bool
    @ViewBuilder var card: Card
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if shows {
                card
                    .padding(.horizontal, MediaStripMetrics.inset)
                    .padding(.bottom, MediaStripMetrics.gap)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(SidebarStepCardMetrics.appear, value: shows)
    }
}

/// The card of a one-time step (Connect 1Password, the blocking offer): a
/// title, a line or two of text, a prominent and a plain button, and a
/// close button, on the media strips' background.
struct SidebarStepCard: View {
    struct Action {
        let title: String
        let identifier: String
        let perform: () -> Void
    }

    let title: String
    let message: String
    let primary: Action
    let secondary: Action
    let dismissHelp: String
    let dismissLabel: String
    let dismissIdentifier: String
    let identifier: String
    let dismiss: () -> Void
    @Environment(\.themeChrome) private var chrome

    private var text: Color { chrome.isDark ? Color.white.opacity(0.9) : Color.black.opacity(0.8) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(text.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    button(primary, prominent: true)
                    button(secondary)
                }
                .padding(.top, 2)
            }
            .padding(.leading, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            SidebarCardDismissButton(help: dismissHelp, label: dismissLabel, identifier: dismissIdentifier, action: dismiss)
                .padding(4)
        }
        .background(MediaStripBackground())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private func button(_ action: Action, prominent: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: SidebarStepCardMetrics.buttonRadius, style: .continuous)
        return Button(action: action.perform) {
            Text(action.title)
                .font(.system(size: 11, weight: prominent ? .semibold : .medium))
                .foregroundStyle(text)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: SidebarStepCardMetrics.buttonHeight)
                .background(text.opacity(prominent ? 0.14 : 0.06), in: shape)
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(action.identifier)
    }
}
