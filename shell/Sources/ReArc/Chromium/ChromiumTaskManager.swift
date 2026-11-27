#if REARC_CHROMIUM
import AppKit
import SidebarModel

/// The Task Manager's rows on Chromium: the engine's process list (the
/// bench's `ChromiumPerfMetrics.processes()`, with what `task_manager`
/// adds when the engine has it) and the shell's names for the tabs,
/// profiles and extensions in it.
final class ChromiumTaskManagerSource: TaskManagerSource {
    private unowned let runtime: ChromiumRuntime
    private unowned let model: BrowserViewModel
    /// Pictures made from the engine's PNGs, kept while the PNG is the same.
    private var favicons: [UInt64: (data: Data, image: NSImage)] = [:]
    private var extensionIcons: [String: (data: Data, image: NSImage)] = [:]

    init(runtime: ChromiumRuntime, model: BrowserViewModel) {
        self.runtime = runtime
        self.model = model
    }

    func sample() async -> TaskManagerSample {
        await sample(withDetails: runtime.capabilities.taskManager)
    }

    /// No details: a tab's processes are the same stack (a frame's process is
    /// a member either way), and the engine counts no network bytes for it.
    func backgroundSample() async -> TaskManagerSample {
        await sample(withDetails: false)
    }

    private func sample(withDetails: Bool) async -> TaskManagerSample {
        let processes = await engineProcesses(withDetails: withDetails)
        // Before the engine answers (or as it stops) there is still ReArc itself.
        guard !processes.isEmpty else { return TaskManagerSample(processes: [TaskManagerProcessControl.browserProcess()]) }
        favicons = favicons.filter { runtime.engine(forTab: $0.key) != nil }
        return TaskManagerSample(processes: processes.map(Self.process), directory: directory(for: processes))
    }

    func icon(for icon: TaskManagerTask.Icon) -> NSImage? {
        switch icon {
        case .browser, .system, .frame, .notLoadedGroup:
            return nil
        case .sidebarTab(let id):
            return model.sidebarTab(fromTaskManager: id).flatMap { model.store.tab(withID: $0) }.flatMap(model.favicon(for:))
        case .tab(let id):
            guard let data = runtime.engine(forTab: id)?.faviconData else { return nil }
            if let cached = favicons[id], cached.data == data { return cached.image }
            guard let image = NSImage(data: data) else { return nil }
            favicons[id] = (data, image)
            return image
        case .browserExtension(let id):
            guard let id, let data = extensionAction(id)?.iconPNG else { return nil }
            if let cached = extensionIcons[id], cached.data == data { return cached.image }
            guard let image = NSImage(data: data) else { return nil }
            extensionIcons[id] = (data, image)
            return image
        }
    }

    /// The pid is checked against the engine's list again first: the row
    /// may be a second old, and only a child the engine still has is ended.
    func endProcess(_ pid: Int32) async -> Bool {
        let processes = await engineProcesses()
        guard processes.contains(where: { $0.pid == pid && $0.kind != .browser }) else { return false }
        return TaskManagerProcessControl.terminate(pid)
    }

    /// A tab of a space (not a Little Arc, a private window's or DevTools).
    func canShowTab(_ tab: TaskManagerTabRef) -> Bool {
        shellTabID(tab) != nil
    }

    func showTab(_ tab: TaskManagerTabRef) {
        guard let id = shellTabID(tab) else { return }
        model.showTabFromTaskManager(id)
    }

    var isLive: Bool { runtime.isReady && !runtime.isStopping }

    func canSleepTab(_ tab: TaskManagerTabRef) -> Bool {
        shellTabID(tab).map(model.canSleepTab) ?? false
    }

    func sleepTab(_ tab: TaskManagerTabRef) {
        guard let id = shellTabID(tab) else { return }
        model.sleepTab(id, cause: .taskManager)
    }

    func canUnloadTab(_ tab: TaskManagerTabRef) -> Bool {
        shellTabID(tab).map(model.canUnloadTab) ?? false
    }

    func unloadTab(_ tab: TaskManagerTabRef) {
        guard let id = shellTabID(tab) else { return }
        model.unloadTab(id, cause: .taskManager)
    }

    /// A tab with a page, of a space: its DevTools open beside it, on the Elements panel.
    func canOpenDevTools(_ tab: TaskManagerTabRef) -> Bool {
        guard case .engine = tab else { return false }
        return model.canOpenDevTools && shellTabID(tab) != nil
    }

    func openDevTools(_ tab: TaskManagerTabRef) {
        guard canOpenDevTools(tab), let id = shellTabID(tab) else { return }
        model.showTabFromTaskManager(id)
        model.openDevTools(for: id)
    }

    private func shellTabID(_ tab: TaskManagerTabRef) -> Tab.ID? {
        switch tab {
        case .engine(let id): return shellTabID(id)
        case .sidebar(let id): return model.sidebarTab(fromTaskManager: id)
        }
    }

    private func shellTabID(_ engineTabID: UInt64) -> Tab.ID? {
        guard let engine = runtime.engine(forTab: engineTabID), !engine.profileKey.isOffTheRecord,
              model.store.tab(withID: engine.shellID) != nil else { return nil }
        return engine.shellID
    }

    private func engineProcesses(withDetails: Bool? = nil) async -> [ChromiumProcessInfo] {
        guard runtime.isReady, !runtime.isStopping else { return [] }
        return await ChromiumPerfMetrics.shared.processes(withDetails: withDetails ?? runtime.capabilities.taskManager)
    }

    private static func process(_ info: ChromiumProcessInfo) -> TaskManagerProcess {
        let kind: TaskManagerProcess.Kind
        switch info.kind {
        case .browser: kind = .browser
        case .renderer: kind = .renderer
        case .gpu: kind = .gpu
        case .utility: kind = .utility
        case .other: kind = .other
        }
        return TaskManagerProcess(
            pid: info.pid, kind: kind, name: info.name, profileID: info.profileID, isExtension: info.isExtension,
            tabIDs: info.tabIDs, memoryFootprint: info.physFootprint, cpuMicros: info.cpuMicros, details: info.details
        )
    }

    private func directory(for processes: [ChromiumProcessInfo]) -> TaskManagerDirectory {
        var directory = TaskManagerDirectory()
        let sleep = model.taskManagerTabSleep()
        let listed = Set(processes.flatMap(\.tabIDs))
        for id in listed {
            directory.tabs[id] = tab(id, sleep: sleep.byTab)
        }
        // A discarded tab is still in the engine's list (its emptied main
        // frame stays in the renderer): the rows tell it by its State, and
        // leave out only the unloaded tabs listed with a page.
        directory.unloadedTabs = sleep.unloaded
        directory.sleepSettings = model.taskManagerSleepSettings(canFreeze: runtime.capabilities.tabFreeze)
        for id in Set(processes.map(\.profileID)) where id != 0 {
            directory.profiles[id] = profileName(id)
        }
        for item in model.extensions.actionsByEngine.values.joined() where directory.extensions[item.id] == nil {
            directory.extensions[item.id] = item.name
        }
        return directory
    }

    private func tab(_ id: UInt64, sleep: [Tab.ID: TaskManagerTabSleep]) -> TaskManagerDirectory.Tab? {
        guard let engine = runtime.engine(forTab: id) else {
            // DevTools windows are engine tabs with no page of the shell's.
            let isDevTools = runtime.devToolsFrontends.contains(id) || runtime.devToolsToolboxes.contains(id)
            return isDevTools ? TaskManagerDirectory.Tab(title: "Developer Tools") : nil
        }
        let url = engine.currentURL
        let saved = model.store.tab(withID: engine.shellID)?.displayTitle
        // Chrome's order: the page's title, else its address.
        let title = [engine.pageTitle, saved, url?.absoluteString].compactMap { $0 }.first { !$0.isEmpty } ?? "New Tab"
        // The page's address for the history's growth rule: without its fragment, which is no new page.
        var page = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        page?.fragment = nil
        return TaskManagerDirectory.Tab(
            title: title, isPrivate: engine.profileKey.isOffTheRecord,
            extensionID: url?.scheme == "chrome-extension" ? url?.host : nil, sleep: sleep[engine.shellID],
            sidebarID: engine.shellID.uuidString, pageURL: page?.string, isLoading: engine.isLoading
        )
    }

    private func profileName(_ engineID: UInt64) -> String? {
        guard let key = runtime.profileKey(forEngineProfile: engineID) else { return nil }
        if key.isOffTheRecord { return "Private" }
        // A container is storage of its own under a profile: the person knows the profile.
        return model.store.profile(withID: model.store.owningProfileID(of: key.parentProfileID))?.name
    }

    private func extensionAction(_ id: String) -> ExtensionActionItem? {
        model.extensions.actionsByEngine.values.joined().first { $0.id == id && $0.iconPNG != nil }
    }
}
#endif
