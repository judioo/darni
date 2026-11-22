import SidebarModel
import SwiftUI

/// Settings › Profiles' Search engine row for one profile, as the pop-up
/// shows it: the profile's engines, its default, and whether it can change.
/// Nil when no engine source exists (Chromium before `search_engines`).
struct ProfileSearchEngineRow: Equatable {
    var options: [SearchEngineChoice]
    var selection: SearchEngineChoice.ID?
    /// False while the list loads, and while policy manages the default.
    var isEditable: Bool

    init?(model: BrowserViewModel, profileID: Profile.ID) {
        guard let search = model.activeSearchEngineSettings else { return nil }
        options = search.engines(for: profileID)
        selection = search.defaultEngine(for: profileID)
        isEditable = !options.isEmpty && search.isEditable(for: profileID)
    }
}

/// The row's box. The pop-up is Darni's own (`SettingsPopUp`); the engine's
/// search settings page is never opened from here.
struct ProfileSearchEngineGroup: View {
    let model: BrowserViewModel
    let profile: Profile

    static let label = "Search engine"

    var body: some View {
        if let row = ProfileSearchEngineRow(model: model, profileID: profile.id) {
            SettingsGroup {
                SettingsLabeledRow(label: Self.label) {
                    SettingsPopUp(label: Self.label, selection: Binding(
                        get: { row.selection ?? "" },
                        set: { model.setDefaultSearchEngine($0, for: profile.id) }
                    ), options: row.options.map { ($0.id, $0.name) })
                    .disabled(!row.isEditable)
                }
            }
        }
    }
}

/// Settings › Profiles' Download location: the folder downloads are saved
/// to, with the downloads tray's own chooser. One folder for every profile.
struct DownloadLocationRow: View {
    let downloads: DownloadsController

    static let label = "Download location"

    var body: some View {
        DownloadLocationRowContent(folderName: DownloadLocationText.folderName(downloads.directory)) { downloads.chooseDirectory() }
    }
}

/// The row for a folder's name, in the 341 pt box beside the profile list
/// (`ProfilesSettingsPane.detailWidth`). The row did not fit there: its
/// label (the 174 pt detail line), "Downloads" and the button came to some
/// 40 pt more than the box, and the stack took it from the button, which
/// read "Chan…". Now the button and the folder's name keep their own widths
/// and go first, the detail line is short enough to stay on one line beside
/// "Downloads", and a long name is shortened in the middle (its tooltip has
/// it whole) so that the label keeps its line.
struct DownloadLocationRowContent: View {
    let folderName: String
    let choose: () -> Void

    static let changeTitle = "Change…"
    static let detail = "Shared by every profile."
    /// The most the folder's name takes: beside it and the button, "Download
    /// location" still has its 112 pt in the 341 pt box.
    static let folderNameMaxWidth: CGFloat = 88

    var body: some View {
        SettingsLabeledRow(label: DownloadLocationRow.label, detail: Self.detail) {
            HStack(spacing: 8) {
                Text(folderName)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: Self.folderNameMaxWidth)
                    .fixedSize()
                    .help(folderName)
                Button(Self.changeTitle, action: choose)
                    .fixedSize()
            }
            .layoutPriority(1)
        }
    }
}
