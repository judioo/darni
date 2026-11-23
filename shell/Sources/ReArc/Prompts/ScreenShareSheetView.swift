import AppKit
import SidebarModel
import SwiftUI

/// What to share with a page that asked (`getDisplayMedia`, Chromium ABI
/// 1.70): one of Darni's tabs, picked here, or a window or the screen, which
/// the person then points at in the macOS picker. Tab-scoped like the other
/// page sheets: only the asking page waits. Nothing is picked for the
/// person and nothing is remembered: every request asks again.
struct ScreenShareSheet: View {
    @Bindable var prompts: PagePromptCenter
    let prompt: PagePromptCenter.ScreenSharePrompt
    @Environment(\.themeChrome) private var chrome

    private var request: ScreenShareRequest { prompt.request }

    var body: some View {
        PageSheet(width: 440) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "rectangle.inset.filled.and.person.filled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(request.title)
                    .font(.headline)
                    .lineLimit(1)
                    // A long name keeps its end: the registrable domain.
                    .truncationMode(.head)
                    .accessibilityIdentifier("screenShareTitle")
            }
            if let note = request.frameNote {
                Label(note, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                ForEach(ScreenShareKind.allCases, id: \.self) { kind in
                    if request.offers(kind) {
                        ScreenShareKindButton(kind: kind, isSelected: prompts.screenShareKind == kind) {
                            prompts.selectScreenShareKind(kind)
                        }
                    }
                }
            }
            content
            if request.offersAudio(for: prompts.screenShareKind), !showsPermissionNote {
                Toggle(request.audioLabel(for: prompts.screenShareKind), isOn: $prompts.screenShareAudio)
                    .toggleStyle(PromptCheckboxStyle())
                    .accessibilityIdentifier("screenShareAudio")
            }
            if let problem = prompts.screenShareProblem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { prompts.answerScreenShare(.cancel) }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(PromptButtonStyle(large: true))
                    .accessibilityIdentifier("screenShareCancel")
                if showsPermissionNote {
                    Button(ScreenShareText.openSettings) {
                        prompts.answerScreenShare(.cancel)
                        ScreenRecordingSettings.open()
                    }
                    .buttonStyle(PromptButtonStyle(prominent: true, large: true))
                    .accessibilityIdentifier("screenShareOpenSettings")
                } else {
                    Button(shareTitle) {
                        if let answer = prompts.screenShareAnswer { prompts.answerScreenShare(answer) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PromptButtonStyle(prominent: true, large: true))
                    .disabled(prompts.screenShareAnswer == nil)
                    .accessibilityIdentifier("screenShareConfirm")
                }
            }
            .controlSize(.regular)
        }
        .onExitCommand { prompts.answerScreenShare(.cancel) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("screenShareSheet")
    }

    /// macOS 14 without Screen Recording: a window or the screen is explained, not offered.
    private var showsPermissionNote: Bool {
        prompts.screenShareKind != .tab && request.needsScreenRecordingPermission
    }

    private var shareTitle: String {
        switch prompts.screenShareKind {
        case .tab: "Share Tab"
        case .window: "Choose Window…"
        case .screen: "Choose Screen…"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch prompts.screenShareKind {
        case .tab:
            if prompt.candidates.isEmpty {
                Text("No open tab can be shared with this page.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(prompt.candidates) { candidate in
                            ScreenShareTabRow(candidate: candidate, isSelected: prompts.screenShareSelection == candidate.engineTabID) {
                                prompts.screenShareSelection = candidate.engineTabID
                            }
                        }
                    }
                }
                .frame(maxHeight: 232)
                .fixedSize(horizontal: false, vertical: true)
            }
        case .window, .screen:
            if showsPermissionNote {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ScreenShareText.permissionTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ScreenShareText.permissionBody)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityIdentifier("screenSharePermissionNote")
            } else {
                Label(ScreenShareText.systemPickerNote, systemImage: prompts.screenShareKind == .screen ? "display" : "macwindow")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Where "Open System Settings" goes: the Screen Recording list. macOS shows
/// an app there only once it has asked, so the app asks (macOS's own prompt,
/// which the person answers) and then opens the pane. Replaceable for tests.
enum ScreenRecordingSettings {
    static let pane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static var open: () -> Void = {
        CGRequestScreenCaptureAccess()
        NSWorkspace.shared.open(pane)
    }
}

/// One of the sheet's kinds: Tab, Window, Entire Screen.
private struct ScreenShareKindButton: View {
    let kind: ScreenShareKind
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.themeChrome) private var chrome
    @State private var isHovering = false

    private var title: String {
        switch kind {
        case .tab: "Tab"
        case .window: "Window"
        case .screen: "Entire Screen"
        }
    }

    private var symbol: String {
        switch kind {
        case .tab: "square.on.square"
        case .window: "macwindow"
        case .screen: "display"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .foregroundStyle(isSelected ? Color.white : chrome.title)
            .background(isSelected ? AnyShapeStyle(Color(chrome.commandBarFill)) : AnyShapeStyle(chrome.title.opacity(isHovering ? 0.1 : 0.06)), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("screenShareKind-\(kind.rawValue)")
    }
}

/// A tab in the sheet's list: its icon, title and site.
private struct ScreenShareTabRow: View {
    let candidate: ScreenShareCandidate
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.themeChrome) private var chrome
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            HStack(spacing: 8) {
                SiteIconView(image: candidate.favicon, token: candidate.faviconToken, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if !candidate.site.isEmpty {
                        Text(candidate.site)
                            .font(.system(size: 11))
                            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 6)
                if candidate.isCurrent {
                    Text("This Tab")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((isSelected ? Color.white : chrome.title).opacity(0.14), in: Capsule())
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(isSelected ? Color.white : chrome.title)
            .background(isSelected ? AnyShapeStyle(Color(chrome.commandBarFill)) : AnyShapeStyle(chrome.title.opacity(isHovering ? 0.08 : 0)), in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(candidate.isCurrent ? "\(candidate.title), this tab" : candidate.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("screenShareTab-\(candidate.engineTabID)")
    }
}

// MARK: - While sharing

/// The bars at the top of a page while something is shared: over the page
/// that shares ("Sharing your screen with meet.google.com") and over a tab
/// another tab's page shares ("meet.google.com is sharing this tab"), each
/// with Stop Sharing. Darni's own, in place of Chromium's sharing bar and its
/// "is sharing your screen" window. A shared tab's stream is the page's own
/// picture, so the bar is never in it.
struct ScreenShareBars: View {
    let prompts: PagePromptCenter

    var body: some View {
        let router = prompts.screenShareRouter
        VStack(spacing: 6) {
            if let line = prompts.sharingLine(titleOf: { router?.screenShareTitle(of: $0) }) {
                ScreenShareBar(text: line, identifier: "screenShareBar") { prompts.stopScreenShare() }
            }
            ForEach(prompts.sharedBy) { viewer in
                ScreenShareBar(text: ScreenShareText.capturedLine(site: viewer.site), identifier: "screenSharedBar") {
                    prompts.stopScreenShare(of: viewer)
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct ScreenShareBar: View {
    let text: String
    let identifier: String
    let stop: () -> Void
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.red)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Button(ScreenShareText.stop, action: stop)
                .buttonStyle(PromptButtonStyle(prominent: true))
                .accessibilityIdentifier(identifier + "Stop")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 34)
        .foregroundStyle(chrome.title)
        .environment(\.colorScheme, chrome.isDark ? .dark : .light)
        .background(chrome.toast, in: Capsule())
        .overlay(Capsule().strokeBorder(chrome.title.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        // A long title is cut in the middle; the bar never spans the page.
        .frame(maxWidth: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(text)
        .accessibilityIdentifier(identifier)
    }
}
