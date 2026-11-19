import AppKit
import SwiftUI
import SidebarModel
import UniformTypeIdentifiers

/// A space's icon picker, for a new space (the Create a Space page's popover) and in
/// Edit Space: the shared grid (`IconGridPicker`), then a picture. A picture is
/// chosen, pasted or dropped anywhere on the picker, and made favicon-sized
/// (`SpaceIconImage`: at most 64 pixels on its longer side, kept whole). The glyph
/// stays underneath: older builds, and a picture that does not decode, show it.
struct SpaceIconPicker: View {
    /// The space's glyph now (a symbol or an emoji), and its picture if it has one.
    let iconName: String
    let picture: Data?
    /// A glyph replaces the picture.
    let setIcon: (String) -> Void
    /// nil shows the glyph again.
    let setPicture: (Data?) -> Void
    @State private var problem: String?
    @State private var isReading = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconGridPicker(symbols: Space.iconChoices, startsOnEmoji: Self.isEmoji(iconName),
                           isSelected: isSelected) { choice in
                switch choice {
                case .sfSymbol(let name): setIcon(name)
                case .emoji(let text): setIcon(text)
                }
            }
            HStack(spacing: 8) {
                if let picture {
                    SpaceIconView(iconName: iconName, picture: picture, size: 14)
                        .frame(width: 22, height: 22)
                }
                Button("Choose Image…", action: chooseImage)
                Button("Paste Image", action: pasteImage)
                if picture != nil {
                    Button("Remove Image") { setPicture(nil) }
                }
                if isReading { ProgressView().controlSize(.small) }
            }
            .disabled(isReading)
            Text(problem ?? "Or drop an image here. A big one is made icon-sized.")
                .font(.caption)
                .foregroundStyle(problem == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                .padding(-6)
                .opacity(isDropTargeted ? 1 : 0)
                .allowsHitTesting(false)
        }
        .onDrop(of: ProfileAvatarImageIntake.dropTypes, isTargeted: $isDropTargeted) { providers in
            ProfileAvatarImageIntake.loadSource(from: providers) { if let source = $0 { adopt(source) } }
        }
        .onPasteCommand(of: ProfileAvatarImageIntake.dropTypes) { providers in
            _ = ProfileAvatarImageIntake.loadSource(from: providers) { if let source = $0 { adopt(source) } }
        }
    }

    /// With a picture set, no glyph is the icon.
    private func isSelected(_ choice: SidebarItemIcon) -> Bool {
        guard picture == nil else { return false }
        return switch choice {
        case .sfSymbol(let name): Space.symbolToDraw(for: iconName) == name
        case .emoji(let text): iconName == text
        }
    }

    static func isEmoji(_ iconName: String) -> Bool {
        !iconName.isEmpty && Space.symbolToDraw(for: iconName) == nil
    }

    private func chooseImage() {
        guard let source = ProfileAvatarImageIntake.chooseFile(message: "Choose an image for this space's icon.") else { return }
        adopt(source)
    }

    private func pasteImage() {
        guard let source = ProfileAvatarImageIntake.source(from: .general) else {
            problem = ProfileAvatarImageIntake.nothingToPaste
            return
        }
        adopt(source)
    }

    private func adopt(_ source: ProfileAvatarImageIntake.Source) {
        isReading = true
        problem = nil
        ProfileAvatarImageIntake.spacePicture(from: source) { result in
            isReading = false
            switch result {
            case .success(let picture): setPicture(picture)
            case .failure(let error): problem = error.message
            }
        }
    }
}
