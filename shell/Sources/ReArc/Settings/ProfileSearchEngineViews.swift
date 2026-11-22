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
        SettingsLabeledRow(label: Self.label, detail: "The same folder for every profile.") {
            HStack(spacing: 8) {
                Text(DownloadLocationText.folderName(downloads.directory))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Change…") { downloads.chooseDirectory() }
            }
        }
    }
}
