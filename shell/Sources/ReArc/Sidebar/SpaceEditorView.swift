import AppKit
import SwiftUI
import SidebarModel

/// Edit Space sheet: name, theme (Arc's style editor: colours or a
/// gradient, grain and appearance, SIDEBAR-SPEC §4.6), icon (SF Symbols, an emoji or a picture),
/// profile and boosts. Changes apply live, like Arc's editor, except a profile change,
/// which asks first; Done closes the sheet.
struct SpaceEditorView: View {
    let model: BrowserViewModel
    let spaceID: Space.ID
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    /// A profile change waiting for confirmation (the sheet has its own alert).
    @State private var profileChange: SpaceProfileChange?

    var body: some View {
        let store = model.store
        let space = store.space(withID: spaceID)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                SpaceIconView(iconName: space?.iconName ?? "circle.fill", picture: space?.iconPicture, size: 16)
                    .frame(width: 34, height: 34)
                    .background(color(space?.theme ?? .default).opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                TextField("Space name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .onSubmit(commitName)
            }

            if let space {
                profileRow(space)
                boostsRow(space)
            }

            ChooseThemeRow(theme: Binding(
                get: { model.store.space(withID: spaceID)?.theme ?? .default },
                set: { model.store.setSpaceTheme(spaceID, theme: $0) }
            ), title: "Edit Theme Color")

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon").font(.headline)
                SpaceIconPicker(iconName: space?.iconName ?? "", picture: space?.iconPicture,
                                setIcon: { store.setSpaceIcon(spaceID, iconName: $0) },
                                setPicture: { store.setSpacePicture(spaceID, picture: $0) })
            }

            HStack {
                Button("Delete Space…", role: .destructive) {
                    dismiss()
                    model.pendingDeletion = .space(spaceID)
                }
                .disabled(!model.canDeleteSpaces)
                Spacer()
                Button("Done") {
                    commitName()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .alert(profileChange.map(model.spaceProfileChangeMessage)?.title ?? "", isPresented: Binding(
            get: { profileChange != nil },
            set: { if !$0 { profileChange = nil } }
        )) {
            Button("Cancel", role: .cancel) { profileChange = nil }
            Button("Move Space") {
                if let change = profileChange { model.changeSpaceProfile(change.spaceID, to: change.profileID) }
                profileChange = nil
            }
        } message: {
            Text(profileChange.map(model.spaceProfileChangeMessage)?.message ?? "")
        }
        .onAppear {
            name = space?.name ?? ""
        }
    }

    private func profileRow(_ space: Space) -> some View {
        return HStack {
            Text("Profile").font(.headline)
            Spacer()
            Menu(model.store.profile(withID: model.store.owningProfileID(of: space.profileID))?.name ?? "Profile") {
                SpaceProfileChoices(model: model, space: space) { profileID in
                    profileChange = SpaceProfileChange(spaceID: space.id, profileID: profileID)
                }
            }
            .fixedSize()
            .help("Choose this space's session container")
        }
    }

    /// Off here overrides the profile's boosts for this space only; with the profile's switch off there is nothing to override.
    private func boostsRow(_ space: Space) -> some View {
        let profileOn = model.store.boostLibrary(for: space.profileID).masterEnabled
        return Toggle(isOn: Binding(
            get: { model.store.space(withID: spaceID)?.boostsEnabled ?? true },
            set: { model.setSpaceBoostsEnabled($0, for: spaceID) }
        )) {
            Text("Boosts").font(.headline)
        }
        .toggleStyle(.switch)
        .disabled(!profileOn)
        .help(profileOn ? "Run this profile's boosts in this space" : "Boosts are off for this profile")
    }

    private func color(_ theme: SpaceTheme) -> Color {
        Color(red: theme.red, green: theme.green, blue: theme.blue)
    }

    private func commitName() {
        model.store.renameSpace(spaceID, to: name)
    }
}
