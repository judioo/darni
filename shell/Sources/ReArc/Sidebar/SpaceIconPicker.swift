import AppKit
import SwiftUI
import SidebarModel
import UniformTypeIdentifiers

/// A space's icon picker, for a new space (the Create a Space page's popover) and in
/// Edit Space: the shared grid (`IconGridPicker`), then a picture. A picture is
/// chosen, pasted or dropped anywhere on the picker, and made favicon-sized
/// (`SpaceIconImage`: at most 64 pixels on its longer side, kept whole).
struct SpaceIconPicker: View {
    /// The space's icon name now (a symbol, an emoji or a picture).
    let iconName: String
    let set: (String) -> Void
    @State private var problem: String?
    @State private var isReading = false
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconGridPicker(symbols: Space.iconChoices, startsOnEmoji: Self.isEmoji(iconName),
                           isSelected: isSelected) { choice in
                switch choice {
                case .symbol(let name): set(name)
                case .emoji(let text): set(text)
                }
            }
            HStack(spacing: 8) {
                if SpaceIconImage.isImageName(iconName) {
                    SpaceIconView(iconName: iconName, size: 14)
                        .frame(width: 22, height: 22)
                }
                Button("Choose Image…", action: chooseImage)
                Button("Paste Image", action: pasteImage)
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

    private func isSelected(_ choice: IconPick) -> Bool {
        switch choice {
        case .symbol(let name): Space.symbolToDraw(for: iconName) == name
        case .emoji(let text): iconName == text
        }
    }

    static func isEmoji(_ iconName: String) -> Bool {
        !iconName.isEmpty && !SpaceIconImage.isImageName(iconName) && Space.symbolToDraw(for: iconName) == nil
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // An alias is read as the alias file, never followed to what it names.
        panel.resolvesAliases = false
        panel.message = "Choose an image for this space's icon."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adopt(.file(url))
    }

    private func pasteImage() {
        guard let source = ProfileAvatarImageIntake.source(from: .general) else {
            problem = "There's no image to paste. Copy an image or an image file first."
            return
        }
        adopt(source)
    }

    private func adopt(_ source: ProfileAvatarImageIntake.Source) {
        isReading = true
        problem = nil
        ProfileAvatarImageIntake.spaceIconName(from: source) { result in
            isReading = false
            switch result {
            case .success(let name): set(name)
            case .failure(let error): problem = error.message
            }
        }
    }
}
