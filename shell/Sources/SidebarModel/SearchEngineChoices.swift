import Foundation

/// The default-search choices of one profile, as Chrome's settings offer them
/// (Chromium `ReArcSearchListEngines`, ABI 1.46 `search_engines`): the current
/// default plus the prepopulated and policy-provided engines, in Chromium's
/// order. A Settings pop-up lists `engines` and selects by `id`.
public struct SearchEngineChoices: Equatable, Sendable {
    public struct Engine: Identifiable, Equatable, Sendable {
        /// Chromium's TemplateURLID: stable for the profile, the handle for setting the default.
        public var id: Int64
        public var name: String
        public var keyword: String
        /// Search URL with `%s` where the terms go.
        public var searchTemplate: String
        public var faviconURL: URL?
        public var isDefault: Bool
        public var isPrepopulated: Bool
        /// Chromium's `CanMakeDefault`: false for the current default itself,
        /// and for every engine while the default is policy-managed.
        public var canMakeDefault: Bool

        public init(id: Int64, name: String, keyword: String, searchTemplate: String, faviconURL: URL? = nil,
                    isDefault: Bool = false, isPrepopulated: Bool = false, canMakeDefault: Bool = true) {
            self.id = id
            self.name = name
            self.keyword = keyword
            self.searchTemplate = searchTemplate
            self.faviconURL = faviconURL
            self.isDefault = isDefault
            self.isPrepopulated = isPrepopulated
            self.canMakeDefault = canMakeDefault
        }
    }

    public var engines: [Engine]
    /// An enterprise policy sets the default: show it, disable the pop-up.
    public var isManaged: Bool

    public init(engines: [Engine], isManaged: Bool = false) {
        self.engines = engines
        self.isManaged = isManaged
    }

    public var current: Engine? { engines.first { $0.isDefault } }

    /// What the pop-up lists: the default, and every engine that can become
    /// it. Chromium reports `can_make_default` false for the current default
    /// itself (`TemplateURLService::CanMakeDefault` has `url !=
    /// GetDefaultSearchProvider()`), so the default is listed by `isDefault`.
    public var offered: [Engine] { engines.filter { $0.canMakeDefault || $0.isDefault } }

    /// The pop-up can change the default.
    public var isEditable: Bool { !isManaged && engines.contains { $0.canMakeDefault } }

    /// The list after Chromium accepted `id` as the new default, with
    /// Chromium's flags: the new default can no longer be "made default",
    /// and the old one can again. Moving `isDefault` alone left the old
    /// default with its `canMakeDefault` false, and it dropped out of the
    /// pop-up until the next launch (found on screen 2026-11-22). This is
    /// the shell's own reading of the change; the engine's list, read again
    /// after it, replaces it (`ChromiumSearchEngineSettings.setDefaultEngine`).
    public func selecting(_ id: Int64) -> SearchEngineChoices {
        guard !isManaged, engines.contains(where: { $0.id == id && $0.canMakeDefault }) else { return self }
        var copy = self
        for index in copy.engines.indices {
            if copy.engines[index].id == id {
                copy.engines[index].isDefault = true
                copy.engines[index].canMakeDefault = false
            } else if copy.engines[index].isDefault {
                copy.engines[index].isDefault = false
                copy.engines[index].canMakeDefault = true
            }
        }
        return copy
    }

    /// The engine's list read after a change, keeping every engine `earlier` offered
    /// that the engine no longer lists, as a choice that can be made default again.
    /// Chromium's list is the default plus the prepopulated engines, so a custom
    /// default (a site search, an imported engine) leaves it as soon as another engine
    /// is chosen, though the engine still holds it and takes it back by id (found by
    /// the self-test of RC 1229, 2026-11-22). Kept for this session only; under a
    /// policy nothing is added.
    public func keeping(_ earlier: SearchEngineChoices?) -> SearchEngineChoices {
        guard let earlier, !isManaged else { return self }
        var copy = self
        for engine in earlier.offered where !copy.engines.contains(where: { $0.id == engine.id }) {
            var kept = engine
            kept.isDefault = false
            kept.canMakeDefault = true
            copy.engines.append(kept)
        }
        return copy
    }

    /// The command bar's provider for an engine (suggestions are not part of the list).
    public static func provider(_ engine: Engine) -> SearchProvider {
        SearchProvider(id: engine.keyword, name: engine.name, keyword: engine.keyword, searchTemplate: engine.searchTemplate)
    }
}
