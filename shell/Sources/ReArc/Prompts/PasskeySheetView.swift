import AppKit
import CoreImage.CIFilterBuiltins
import SidebarModel
import SwiftUI

/// A passkey or security key request (Chromium ABI 1.68), step by step:
/// the ways to sign in, the QR code for a phone, a security key's PIN, the
/// errors. Tab-scoped like the sign-in sheet: only this page waits, and the
/// sidebar, other tabs and windows keep working. The engine runs the request
/// and sends each step; a button here sends the answer and the sheet changes
/// when the next step arrives.
struct PasskeySheet: View {
    @Bindable var prompts: PagePromptCenter
    let step: PasskeyStep
    @FocusState private var focused: Field?

    private enum Field { case pin, confirmation }

    var body: some View {
        PageSheet(width: 400) {
            // The same line on every step: who the request is for. A touch or a
            // scan is consent to this site, whichever step the request opens on.
            Label(step.requestLine, systemImage: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // A long name keeps its end: the registrable domain.
                .truncationMode(.head)
                .accessibilityIdentifier("passkeyRequestLine")
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: step.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isProblem ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                Text(step.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let account = step.accountLine {
                // The page's own text: one line, apart from what ReArc says.
                Label(account, systemImage: "person.crop.circle")
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Account: \(account)")
            }
            if !step.message.isEmpty {
                Text(step.message)
                    .font(.system(size: 13))
                    .foregroundStyle(step.pinProblem != nil ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(step.keyNotices, id: \.self) { notice in
                Label(notice, systemImage: "info.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
            footer
        }
        .onExitCommand { prompts.answerPasskey(.cancel) }
        .onAppear { focusPin() }
        .onChange(of: step.kind) { _, _ in focusPin() }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// The engine works, or the step has its answer: only Cancel answers.
    private var isLocked: Bool { step.isBusy || prompts.passkeyAwaitsStep }

    private var isProblem: Bool {
        switch step.kind {
        case .failure, .phoneError, .unsupported: return true
        default: return false
        }
    }

    private func focusPin() {
        if case .pin = step.kind { focused = .pin }
    }

    @ViewBuilder
    private var content: some View {
        switch step.kind {
        case .choose, .confirm:
            PasskeyChoiceList(count: step.listedMechanisms.count) {
                ForEach(step.listedMechanisms) { mechanism in
                    PasskeyChoiceRow(symbol: mechanism.symbol, title: mechanism.title, subtitle: mechanism.subtitle,
                                     isButton: step.kind == .choose, isEnabled: !isLocked) {
                        prompts.answerPasskey(.chooseMechanism(mechanism.index))
                    }
                }
            }
        case .account:
            PasskeyChoiceList(count: step.accounts.count) {
                ForEach(step.accounts) { account in
                    PasskeyChoiceRow(symbol: "person.crop.circle", title: account.title,
                                     subtitle: account.subtitle.isEmpty ? PasskeyStep.sourceLabel(account.source) : account.subtitle,
                                     isButton: true, isEnabled: !isLocked) {
                        prompts.answerPasskey(.chooseAccount(account.index))
                    }
                }
            }
        case .qr:
            if let qr = step.qr, let image = PasskeyQRCode.image(for: qr) {
                HStack {
                    Spacer()
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .padding(12)
                        // Always black on white: a camera reads nothing else reliably.
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel("QR code to scan with your phone or tablet")
                    Spacer()
                }
            }
        case .pin(let mode):
            VStack(alignment: .leading, spacing: 8) {
                SecureField(mode == .enter ? "PIN" : "New PIN", text: $prompts.passkeyPin)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused, equals: .pin)
                    .onSubmit { mode == .enter ? prompts.submitPasskeyPin() : (focused = .confirmation) }
                if mode != .enter {
                    SecureField("New PIN again", text: $prompts.passkeyPinConfirmation)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused, equals: .confirmation)
                        .onSubmit { prompts.submitPasskeyPin() }
                }
                if let problem = prompts.passkeyPinProblem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                }
            }
            .disabled(isLocked)
        default:
            EmptyView()
        }
        if step.showsProgress || prompts.passkeyAwaitsStep {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(isLocked ? "Working…" : step.waitingLine)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if step.offersAnotherWay {
                Button("Another Way") { prompts.answerPasskey(.startOver) }
                    .buttonStyle(PromptButtonStyle(large: true))
                    .help("Choose another way to sign in")
                    .disabled(isLocked)
            }
            Spacer()
            Button(step.dismissTitle) { prompts.answerPasskey(.cancel) }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(PromptButtonStyle(large: true))
            if case .pin = step.kind {
                Button("Continue") { prompts.submitPasskeyPin() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PromptButtonStyle(prominent: true, large: true))
                    .disabled(isLocked || prompts.passkeyPin.isEmpty)
            } else if let primary = step.primary {
                Button(primary.title) { prompts.answerPasskey(primary.action) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(PromptButtonStyle(prominent: true, large: true))
                    .disabled(isLocked)
            }
        }
    }
}

/// One way to sign in, or one account: a row that is a button on the steps
/// that ask for a choice, and a plain row where it only names what Continue uses.
private struct PasskeyChoiceRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isButton: Bool
    /// False while the sheet waits for the engine: the row stays, dimmed.
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if isButton {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            // The theme's title ink as the wash, as the cards' secondary buttons.
            .background(chrome.title.opacity(isHovering && isButton && isEnabled ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .opacity(isButton && !isEnabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!isButton || !isEnabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }
}

/// The ways to sign in, or the accounts: a short list as it is, a long one
/// (a site can hold many passkeys) in a scroll view of fixed height, so the
/// buttons below it stay in the window.
private struct PasskeyChoiceList<Rows: View>: View {
    let count: Int
    @ViewBuilder var rows: Rows

    /// Rows shown without scrolling; a row is about 46 points high.
    static var visibleRows: Int { 5 }

    var body: some View {
        if count > Self.visibleRows {
            ScrollView {
                VStack(spacing: 6) { rows }
            }
            // Half a row more: it shows that the list goes on.
            .frame(height: CGFloat(Self.visibleRows) * 52 + 20)
        } else {
            VStack(spacing: 6) { rows }
        }
    }
}

/// The QR code a phone or tablet scans to join the request. Drawn from the
/// engine's text ("FIDO:/…") and never kept: the text is a secret of this one
/// request.
enum PasskeyQRCode {
    /// One point per module, with the quiet zone the filter adds; the view scales it without smoothing.
    static func image(for text: String) -> NSImage? {
        guard !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // Medium correction, as Chromium's own dialog draws it: the code stays coarse enough for a quick scan.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, !output.extent.isEmpty,
              let cgImage = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
