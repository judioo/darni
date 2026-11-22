import Foundation
import Observation
import SidebarModel

/// Where a profile's default-search choices come from: Chromium's
/// `search_engines` calls (`ChromiumRuntime`, ABI 1.46), or in tests a
/// stand-in that keeps Chromium's flags.
@MainActor
protocol SearchEngineChoicesSource: AnyObject {
    /// The profile's list as the engine has it now; nil when it cannot be read.
    func searchEngines(for profileID: Profile.ID, completion: @escaping (SearchEngineChoices?) -> Void)
    /// Makes `id` the profile's default; false when the engine refused.
    func setDefaultSearchEngine(_ id: Int64, for profileID: Profile.ID, completion: @escaping (Bool) -> Void)
}

/// Settings › Profiles' Search engine pop-up on Chromium: each profile's list
/// from `search_engines` (ABI 1.46), fetched the first time the pane reads it
/// and read again from the engine each time the default changes.
@MainActor
@Observable
final class ChromiumSearchEngineSettings: SearchEngineSettings {
    @ObservationIgnored private let source: any SearchEngineChoicesSource
    private var choices: [Profile.ID: SearchEngineChoices] = [:]
    @ObservationIgnored private var loading: Set<Profile.ID> = []
    /// Counts each profile's changes, so a list read before the latest one is not kept.
    @ObservationIgnored private var changes: [Profile.ID: Int] = [:]

    init(source: any SearchEngineChoicesSource) { self.source = source }

    func engines(for profileID: Profile.ID) -> [SearchEngineChoice] {
        guard let list = list(for: profileID) else { return [] }
        return list.offered.map { SearchEngineChoice(id: String($0.id), name: $0.name) }
    }

    func defaultEngine(for profileID: Profile.ID) -> SearchEngineChoice.ID? {
        list(for: profileID)?.current.map { String($0.id) }
    }

    func isEditable(for profileID: Profile.ID) -> Bool {
        list(for: profileID)?.isEditable ?? false
    }

    /// Chromium's default-list engines (`ShowInDefaultList`). Site searches
    /// a profile holds beyond those are not in that list (ABI 1.46 has no
    /// call for them).
    func siteSearchEngines(for profileID: Profile.ID) -> [SiteSearchEngine] {
        list(for: profileID)?.siteSearchEngines() ?? []
    }

    /// The pop-up shows the choice as soon as the engine accepts it
    /// (`SearchEngineChoices.selecting`), then the list is the engine's own
    /// again: a change moves `can_make_default` between the old default and
    /// the new, and only the engine knows every row's flag.
    func setDefaultEngine(_ id: SearchEngineChoice.ID, for profileID: Profile.ID) {
        guard let engineID = Int64(id) else { return }
        source.setDefaultSearchEngine(engineID, for: profileID) { [weak self] accepted in
            guard let self, accepted else { return }
            if let list = self.choices[profileID] { self.choices[profileID] = list.selecting(engineID) }
            self.reload(profileID)
        }
    }

    /// Reads the profile's list from the engine again. A read that fails
    /// keeps the list there is; one overtaken by a later change is dropped.
    private func reload(_ profileID: Profile.ID) {
        let change = (changes[profileID] ?? 0) + 1
        changes[profileID] = change
        source.searchEngines(for: profileID) { [weak self] list in
            guard let self, self.changes[profileID] == change, let list else { return }
            if self.choices[profileID] != list { self.choices[profileID] = list }
        }
    }

    /// The cached list; a miss starts one fetch.
    private func list(for profileID: Profile.ID) -> SearchEngineChoices? {
        if let list = choices[profileID] { return list }
        if loading.insert(profileID).inserted {
            let change = changes[profileID] ?? 0
            source.searchEngines(for: profileID) { [weak self] list in
                guard let self else { return }
                self.loading.remove(profileID)
                if let list, self.changes[profileID] ?? 0 == change { self.choices[profileID] = list }
            }
        }
        return nil
    }
}

#if REARC_CHROMIUM
extension ChromiumRuntime: SearchEngineChoicesSource {}
#endif
