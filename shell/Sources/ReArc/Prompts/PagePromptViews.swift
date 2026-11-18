import AppKit
import SidebarModel
import SwiftUI

extension View {
    /// The page's prompts over this page view only: a JavaScript dialog
    /// (the page dims and waits; other tabs do not), the permission prompt at
    /// the top leading corner next to the sidebar's URL field, and the
    /// password offer at the top trailing corner. The anchor underneath gives
    /// file panels their window and menus their coordinates.
    func pagePrompts(_ prompts: PagePromptCenter) -> some View {
        modifier(PagePromptOverlay(prompts: prompts))
    }
}

private struct PagePromptOverlay: ViewModifier {
    let prompts: PagePromptCenter
    /// With an auto-hiding address bar the cards sit a bar's height lower, always, so the
    /// revealed bar never covers them and they never move under the pointer (S-08, F-04).
    @Environment(\.addressBarAutoHides) private var addressBarAutoHides

    func body(content: Content) -> some View {
        content
            .background(PromptAnchor(prompts: prompts))
            .overlay(alignment: .topLeading) {
                if let permission = prompts.permission {
                    PermissionPromptCard(prompts: prompts, permission: permission)
                        .id(permission.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, addressBarAutoHides ? CardToolbarView.height : 0)
                }
            }
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    if let password = prompts.password {
                        PasswordPromptCard(prompts: prompts, prompt: password.prompt)
                            .id(password.id)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if let save = prompts.autofillSave {
                        AutofillSaveCard(prompts: prompts, offer: save.offer)
                            .id(save.id)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .padding(.top, addressBarAutoHides ? CardToolbarView.height : 0)
            }
            .overlay {
                if let dialog = prompts.dialog {
                    JavaScriptDialogSheet(prompts: prompts, dialog: dialog)
                        .id(dialog.id)
                        .transition(.opacity)
                } else if let auth = prompts.httpAuth {
                    HTTPAuthSheet(prompts: prompts, challenge: auth.challenge)
                        .id(auth.id)
                        .transition(.opacity)
                } else if let certificate = prompts.clientCertificate {
                    ClientCertificateSheet(prompts: prompts, request: certificate.request)
                        .id(certificate.id)
                        .transition(.opacity)
                } else if let passkey = prompts.passkey, passkey.step.showsSheet {
                    // One sheet for the whole request: its steps change inside it.
                    PasskeySheet(prompts: prompts, step: passkey.step)
                        .id(passkey.id)
                        .transition(.opacity)
                }
            }
            .animation(.spring(duration: 0.24, bounce: 0.12), value: prompts.permission?.id)
            .animation(.spring(duration: 0.24, bounce: 0.12), value: prompts.password?.id)
            .animation(.spring(duration: 0.24, bounce: 0.12), value: prompts.autofillSave?.id)
            .animation(.easeOut(duration: 0.14), value: prompts.httpAuth?.id)
            .animation(.easeOut(duration: 0.14), value: prompts.clientCertificate?.id)
            .animation(.easeOut(duration: 0.14), value: prompts.passkeySheetShown)
            .animation(.easeOut(duration: 0.14), value: prompts.dialog?.id)
    }
}

/// Transparent, click-through view the size of the page.
private struct PromptAnchor: NSViewRepresentable {
    let prompts: PagePromptCenter

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        prompts.anchorView = view
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        if prompts.anchorView !== nsView, nsView.window != nil { prompts.anchorView = nsView }
    }

    final class AnchorView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Tab-scoped sheets

/// The frame of a sheet that makes one page wait (a script's dialog, HTTP
/// sign-in, a certificate, a passkey request): the page dims under it and
/// takes no clicks, and the sheet sits near its top on the system's material.
/// The sidebar, other tabs and windows keep working. The caller adds what
/// Escape does and marks the whole as modal.
struct PageSheet<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(18)
                .frame(width: width)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
                .padding(.top, 64)
        }
    }
}

// MARK: - JavaScript dialog

/// A tab-scoped sheet: it dims and blocks only this page, so the sidebar,
/// other tabs and windows keep working while the page waits.
private struct JavaScriptDialogSheet: View {
    @Bindable var prompts: PagePromptCenter
    let dialog: PagePromptCenter.Dialog
    @FocusState private var fieldFocused: Bool

    private var request: JavaScriptDialogRequest { dialog.request }

    var body: some View {
        PageSheet(width: 400) {
            HStack(spacing: 10) {
                Image(systemName: request.kind == .beforeUnload ? "exclamationmark.triangle.fill" : "globe")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(request.kind == .beforeUnload ? Color.orange : Color.secondary)
                Text(request.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !request.displayMessage.isEmpty {
                ScrollView {
                    Text(request.displayMessage)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
            if request.showsTextField {
                TextField("", text: $prompts.dialogText)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { prompts.answerDialog(accept: true) }
            }
            if dialog.offersSuppression {
                Toggle("Don't allow this page to create more dialogs", isOn: $prompts.suppressDialogs)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Spacer()
                if request.showsCancel {
                    Button(request.kind == .beforeUnload ? "Stay" : "Cancel") { prompts.answerDialog(accept: false) }
                        .keyboardShortcut(.cancelAction)
                }
                Button(request.acceptTitle) { prompts.answerDialog(accept: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
        }
        .onExitCommand {
            if request.showsCancel { prompts.answerDialog(accept: false) } else { prompts.answerDialog(accept: true) }
        }
        .onAppear {
            let window = prompts.anchorView?.window
            // The first of a run of dialogs remembers who had the keyboard (the page).
            if prompts.keyboardOwnerBeforeDialog == nil, let owner = window?.firstResponder, owner !== window {
                prompts.keyboardOwnerBeforeDialog = owner
            }
            if request.showsTextField {
                fieldFocused = true
            } else {
                // Take the keyboard from the page so Return and Esc reach the buttons.
                DispatchQueue.main.async { window?.makeFirstResponder(nil) }
            }
        }
        .onDisappear {
            // The last dialog gives the keyboard back to the page.
            guard prompts.dialog == nil, let window = prompts.anchorView?.window,
                  let page = prompts.keyboardOwnerBeforeDialog else { return }
            prompts.keyboardOwnerBeforeDialog = nil
            DispatchQueue.main.async { window.makeFirstResponder(page) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

// MARK: - ReArc look for the page's cards

/// The page's top cards in the space's theme, like ReArc's toasts: the theme's
/// pale tint (`toast`), its title and secondary inks, a hairline in the title
/// ink, and the command bar's accent fill for the glyph and the main action
/// (white on it clears 4.5:1, `CommandBarInk.selectionFill`).
private struct PromptCardChrome: ViewModifier {
    @Environment(\.themeChrome) private var chrome

    func body(content: Content) -> some View {
        content
            .foregroundStyle(chrome.title)
            .background(chrome.toast, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(chrome.title.opacity(0.1)))
            .shadow(color: .black.opacity(0.14), radius: 12, y: 4)
    }
}

/// The card's glyph: white on the accent fill.
private struct PromptGlyph: View {
    let systemName: String
    var size: CGFloat = 13
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Color(chrome.commandBarFill)))
            .accessibilityHidden(true)
    }
}

/// A toast's button, a little larger: the accent fill for the main action,
/// a wash of the title ink for the others. Dimmed while the card is disabled
/// (the permission card's interaction delay).
private struct PromptButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.themeChrome) private var chrome
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: 22)
            .foregroundStyle(prominent ? Color.white : chrome.title)
            .background(prominent ? Color(chrome.commandBarFill) : chrome.title.opacity(0.08), in: shape)
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// The card's ✕, as on the toasts' chips.
private struct PromptCloseButton: View {
    let help: String
    let action: () -> Void
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Circle().fill(chrome.title.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(chrome.secondaryText)
        .help(help)
        .accessibilityLabel("Close")
    }
}

/// A checkbox in the theme's inks; VoiceOver still reads a toggle.
private struct PromptCheckboxStyle: ToggleStyle {
    @Environment(\.themeChrome) private var chrome
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let box = RoundedRectangle(cornerRadius: 3.5, style: .continuous)
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                box.fill(configuration.isOn ? Color(chrome.commandBarFill) : chrome.title.opacity(0.06))
                    .overlay(box.strokeBorder(configuration.isOn ? Color.clear : chrome.title.opacity(0.3)))
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 13, height: 13)
                configuration.label
                    .font(.system(size: 12))
                    .foregroundStyle(chrome.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

// MARK: - Permission prompt

private struct PermissionPromptCard: View {
    @Bindable var prompts: PagePromptCenter
    let permission: PagePromptCenter.Permission
    @Environment(\.themeChrome) private var chrome

    private var request: PermissionPromptRequest { permission.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                PromptGlyph(systemName: request.symbol)
                VStack(alignment: .leading, spacing: 3) {
                    // The host keeps its end (the registrable domain) whatever its length (N-06).
                    Text("\(PageOrigin.shortenedHost(request.host)) wants to")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.head)
                    ForEach(request.phrases, id: \.self) { phrase in
                        Text(phrase)
                            .font(.system(size: 13))
                            .foregroundStyle(chrome.secondaryText)
                    }
                    if let note = request.embeddedNote {
                        Text(note).font(.caption).foregroundStyle(chrome.tertiaryText)
                    }
                }
                Spacer(minLength: 8)
                PromptCloseButton(help: "Dismiss — the site can ask again") { prompts.answerPermission(.dismiss) }
            }
            if request.needsSystemAuthorization {
                Text("macOS may also ask to allow ReArc.")
                    .font(.caption)
                    .foregroundStyle(chrome.tertiaryText)
            }
            HStack(spacing: 8) {
                Toggle("Remember this decision", isOn: $prompts.rememberPermission)
                    .toggleStyle(PromptCheckboxStyle())
                Spacer(minLength: 12)
                Button("Block") { prompts.answerPermission(.deny) }
                    .buttonStyle(PromptButtonStyle())
                Button("Allow") { prompts.answerPermission(.allow) }
                    .buttonStyle(PromptButtonStyle(prominent: true))
            }
        }
        .padding(14)
        .frame(width: 340)
        .modifier(PromptCardChrome())
        .padding(.top, 10)
        .padding(.leading, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.host) wants to \(request.phrases.joined(separator: ", "))")
        .disabled(!prompts.permissionInteractionEnabled || prompts.permissionCovered)
        .onAppear { prompts.rearmPermissionInteractionDelay() }
        // Uncovered or moved (an overlay closed, the sidebar hid for page fullscreen): the card
        // serves its delay again where the user can see it (F-04).
        .onChange(of: prompts.permissionCovered) { _, covered in
            if !covered { prompts.rearmPermissionInteractionDelay() }
        }
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { _ in
            prompts.rearmPermissionInteractionDelay()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow, window === prompts.hostWindow else { return }
            prompts.rearmPermissionInteractionDelay()
        }
    }
}

// MARK: - Password offer

private struct PasswordPromptCard: View {
    let prompts: PagePromptCenter
    let prompt: PasswordSavePrompt
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                PromptGlyph(systemName: "key.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text(prompt.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Label(prompt.displayUsername, systemImage: "person.crop.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(chrome.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(spacing: 8) {
                if !prompt.isUpdate {
                    Button("Never") { prompts.answerPassword(.never) }
                        .buttonStyle(PromptButtonStyle())
                        .help("Never save passwords for this site")
                }
                Spacer(minLength: 12)
                Button("Not Now") { prompts.answerPassword(.notNow) }
                    .buttonStyle(PromptButtonStyle())
                Button(prompt.saveTitle) { prompts.answerPassword(.save) }
                    .buttonStyle(PromptButtonStyle(prominent: true))
            }
        }
        .padding(14)
        .frame(width: 320)
        .modifier(PromptCardChrome())
        .padding(.top, 10)
        .padding(.trailing, 12)
    }
}

// MARK: - Card and address save offer (Chromium ABI 1.37)

private struct AutofillSaveCard: View {
    let prompts: PagePromptCenter
    let offer: AutofillSaveOffer
    @Environment(\.themeChrome) private var chrome

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                PromptGlyph(systemName: offer.symbol, size: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(offer.title)
                        .font(.system(size: 13, weight: .semibold))
                    ForEach(offer.summaryLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 12))
                            .foregroundStyle(chrome.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(offer.footnote)
                        .font(.caption)
                        .foregroundStyle(chrome.tertiaryText)
                }
                Spacer(minLength: 8)
                PromptCloseButton(help: "Not now") { prompts.answerAutofillSave(.ignore) }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 12)
                Button("No Thanks") { prompts.answerAutofillSave(.decline) }
                    .buttonStyle(PromptButtonStyle())
                Button(offer.acceptTitle) { prompts.answerAutofillSave(.accept) }
                    .buttonStyle(PromptButtonStyle(prominent: true))
            }
        }
        .padding(14)
        .frame(width: 320)
        .modifier(PromptCardChrome())
        .padding(.top, 10)
        .padding(.trailing, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(offer.title)
    }
}

// MARK: - HTTP sign-in (Chromium ABI 1.38, WebKit challenges)

/// Tab-scoped like the JavaScript dialog: only this page waits.
private struct HTTPAuthSheet: View {
    @Bindable var prompts: PagePromptCenter
    let challenge: HTTPAuthChallenge
    @FocusState private var focused: Field?

    private enum Field { case username, password }

    var body: some View {
        PageSheet(width: 380) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(challenge.title).font(.headline)
            }
            Text(challenge.message)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if let note = challenge.realmNote {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if challenge.isInsecure {
                Label("Your connection to this site is not private.", systemImage: "lock.open.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            TextField("Username", text: $prompts.authUsername)
                .textFieldStyle(.roundedBorder)
                .textContentType(.username)
                .focused($focused, equals: .username)
                .onSubmit { focused = .password }
            SecureField("Password", text: $prompts.authPassword)
                .textFieldStyle(.roundedBorder)
                .textContentType(.password)
                .focused($focused, equals: .password)
                .onSubmit { prompts.answerHTTPAuth(signIn: true) }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { prompts.answerHTTPAuth(signIn: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Sign In") { prompts.answerHTTPAuth(signIn: true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .onExitCommand { prompts.answerHTTPAuth(signIn: false) }
        .onAppear { focused = .username }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

/// The page asks which certificate identifies you (Chromium ABI 1.41): the
/// identities the engine offers, each with its subject, issuer and expiry.
/// OK sends the selected one, Cancel none (the page then shows Chromium's error).
private struct ClientCertificateSheet: View {
    @Bindable var prompts: PagePromptCenter
    let request: ClientCertificateRequest

    var body: some View {
        let identities = request.sortedIdentities()
        PageSheet(width: 440) {
            HStack(spacing: 10) {
                Image(systemName: "person.text.rectangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(request.title).font(.headline)
            }
            Text(request.message)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if !identities.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(identities) { identity in row(identity) }
                    }
                }
                .frame(maxHeight: 220)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { prompts.answerClientCertificate(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { prompts.answerClientCertificate(prompts.selectedCertificate) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(prompts.selectedCertificate == nil)
            }
        }
        .onExitCommand { prompts.answerClientCertificate(nil) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private func row(_ identity: ClientCertificateIdentity) -> some View {
        let selected = prompts.selectedCertificate == identity.fingerprint
        let expired = identity.isExpired()
        return Button { prompts.selectedCertificate = identity.fingerprint } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(identity.subject.isEmpty ? "Unnamed certificate" : identity.subject)
                        .font(.system(size: 13, weight: .medium))
                    Text("Issued by \(identity.issuer.isEmpty ? "unknown" : identity.issuer)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text((expired ? "Expired " : "Expires ") + identity.expires.formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 11))
                        .foregroundStyle(expired ? .red : .secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Color.accentColor.opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("SHA-256 \(identity.groupedFingerprint)")
        .simultaneousGesture(TapGesture(count: 2).onEnded { prompts.answerClientCertificate(identity.fingerprint) })
    }
}
