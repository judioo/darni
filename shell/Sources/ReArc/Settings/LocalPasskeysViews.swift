import SidebarModel
import SwiftUI

/// Settings › Profiles › Your Data and Settings: "Passkeys on This Mac" for
/// one profile or container (PASSKEYS-AND-SITE-PERMISSIONS.md, 1.7). Shown
/// only when this launch has a store with passkeys to manage
/// (`LocalPasskeysController.isOffered`): an engine with the calls in a
/// build signed for them, or a test launch's fixture.
struct LocalPasskeysSettingsGroup: View {
    let model: BrowserViewModel
    /// The profile, or the container, whose engine profile holds the passkeys.
    let profileID: Profile.ID
    let profileName: String
    @State private var sheet: LocalPasskeysModel?

    static let detail = "See the passkeys this profile keeps on this Mac, and delete one. They do not sync."

    var body: some View {
        if model.localPasskeys.isOffered {
            SettingsGroup {
                SettingsLabeledRow(label: LocalPasskeyText.title, detail: Self.detail) {
                    Button("Manage…") { sheet = model.localPasskeys.model(for: profileID) }
                        .buttonStyle(SettingsButtonStyle())
                        .accessibilityLabel("Manage \(LocalPasskeyText.title)")
                }
            }
            .sheet(isPresented: Binding(get: { sheet != nil }, set: { if !$0 { sheet = nil } })) {
                if let sheet {
                    LocalPasskeysSheet(passkeys: sheet, profileName: profileName)
                }
            }
        }
    }
}

/// The list, and the confirmation that takes its place while one passkey is
/// asked about. Text the site chose (the account) is always a line of its
/// own, cleaned and cut (`LocalPasskey.accountLine`).
struct LocalPasskeysSheet: View {
    let passkeys: LocalPasskeysModel
    let profileName: String
    @Environment(\.dismiss) private var dismiss

    static let width: CGFloat = 480
    static let listHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalPasskeyText.title).font(.headline).accessibilityAddTraits(.isHeader)
                Text(LocalPasskeyText.intro(profile: profileName))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if passkeys.isFixture {
                    Text(LocalPasskeyText.fixtureNote)
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let asking = passkeys.asking {
                confirmation(asking)
            } else {
                content
                footer
            }
        }
        .padding(18)
        .frame(width: Self.width)
        .onAppear { passkeys.refresh() }
        // Escape closes the confirmation first, and never deletes.
        .onExitCommand {
            if passkeys.asking != nil { passkeys.cancelDelete() } else { dismiss() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch passkeys.phase {
        case .loading:
            placeholder(LocalPasskeyText.loading, detail: nil, progress: true)
        case .unavailable:
            placeholder(LocalPasskeyText.unavailable, detail: nil)
        case .failed:
            placeholder(LocalPasskeyText.failed, detail: LocalPasskeyText.failedDetail)
        case .loaded where passkeys.passkeys.isEmpty:
            placeholder(LocalPasskeyText.empty, detail: LocalPasskeyText.emptyDetail)
        case .loaded:
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(passkeys.passkeys.enumerated()), id: \.element.id) { index, passkey in
                        if index > 0 { SettingsHairline() }
                        row(passkey)
                    }
                }
            }
            .frame(maxHeight: Self.listHeight)
            .settingsBox()
        }
    }

    private func row(_ passkey: LocalPasskey) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.badge.key.fill")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: passkey.siteLine).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.head)
                Text(verbatim: passkey.accountLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let second = passkey.secondLine {
                    Text(verbatim: second).font(.system(size: 11)).foregroundStyle(SettingsColors.tertiary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LocalPasskeyText.rowLabel(passkey))
            Spacer(minLength: 8)
            Button("Delete…") { passkeys.ask(passkey) }
                .buttonStyle(SettingsButtonStyle())
                .disabled(passkeys.isDeleting)
                .accessibilityLabel("Delete the passkey for \(passkey.siteLine), \(passkey.accountLine)")
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, 7)
    }

    private func placeholder(_ text: String, detail: String?, progress: Bool = false) -> some View {
        VStack(spacing: 6) {
            if progress { ProgressView().controlSize(.small) }
            Text(text).font(.system(size: 13))
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .settingsBox()
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if let notice = passkeys.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if passkeys.phase == .loaded, !passkeys.passkeys.isEmpty {
                Text(LocalPasskeyText.count(passkeys.passkeys.count)).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Asks before anything is deleted: the site and the account on lines of
    /// their own, what goes with the passkey, and that it is final. Cancel is
    /// the default button; Delete is never reached by Return.
    private func confirmation(_ passkey: LocalPasskey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                Text(LocalPasskeyText.deleteQuestion).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 6) {
                    named(LocalPasskeyText.deleteSiteLabel, passkey.siteLine, mode: .head)
                    named(LocalPasskeyText.deleteAccountLabel, passkey.accountLine, mode: .middle)
                    if let second = passkey.secondLine { named("", second, mode: .tail) }
                }
                Text(LocalPasskeyText.deleteWarning)
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .settingsBox()
            HStack {
                if passkeys.isDeleting { ProgressView().controlSize(.small) }
                Spacer()
                Button(LocalPasskeyText.cancelButton) { passkeys.cancelDelete() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passkeys.isDeleting)
                Button(LocalPasskeyText.deleteButton, role: .destructive) { passkeys.confirmDelete() }
                    .disabled(passkeys.isDeleting)
            }
        }
    }

    private func named(_ label: String, _ value: String, mode: Text.TruncationMode) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(verbatim: value).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(mode)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
