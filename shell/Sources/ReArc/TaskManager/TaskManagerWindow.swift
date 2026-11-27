import AppKit
import SidebarModel
import SwiftUI

/// Sizes of the Task Manager window and its table.
enum TaskManagerMetrics {
    static let windowSize = NSSize(width: 1220, height: 680)
    static let minimumSize = NSSize(width: 520, height: 280)
    static let barPadding: CGFloat = 12
    static let searchWidth: CGFloat = 200
    static let rowHeight: CGFloat = 24
    static let iconSize: CGFloat = 16
    static let cellInset: CGFloat = 6
    /// A stack's chevron, and how far a process under a stack sits in.
    static let disclosureWidth: CGFloat = 12
    static let indent: CGFloat = 18

    static func width(of column: TaskManagerColumn) -> (ideal: CGFloat, minimum: CGFloat) {
        switch column {
        case .task: return (300, 160)
        case .state: return (150, 70)
        case .idle: return (80, 50)
        case .profile: return (110, 60)
        case .memoryFootprint: return (120, 80)
        case .cpu: return (60, 44)
        case .network: return (90, 60)
        case .processID: return (90, 60)
        case .memoryHistory, .cpuHistory: return (78, 50)
        }
    }

    /// The table keeps this much beside the inspector; narrower, the inspector is a sheet.
    static let tableMinimumWidth: CGFloat = 520
}

/// Window › Task Manager: Chrome's task manager for ReArc. One window for
/// the app; the model keeps it (`BrowserViewModel.showTaskManager`). The
/// figures are read only while the window can be seen.
final class TaskManagerWindowController: NSWindowController, NSWindowDelegate {
    let controller: TaskManagerController

    /// Only the frame is remembered (a launch on `REARC_DATA_DIR` keeps its own).
    static let frameName = ShellDataLocation.isOverridden ? "ReArcTaskManager.isolated" : "ReArcTaskManager"

    init(controller: TaskManagerController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: TaskManagerMetrics.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Task Manager"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.contentMinSize = TaskManagerMetrics.minimumSize
        super.init(window: window)
        let hosting = NSHostingView(rootView: TaskManagerView(controller: controller) { [weak self] in self?.endTask() })
        // The window's size is its own and the user's, not the table's.
        hosting.sizingOptions = []
        window.contentView = hosting
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Now, not at the occlusion change that follows: the window opens with its rows.
        controller.startPolling()
    }

    // MARK: Reading only while on screen

    /// On screen: not closed, minimised, hidden with the app or wholly covered.
    private var isOnScreen: Bool {
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    private func syncPolling() {
        if isOnScreen { controller.startPolling() } else { controller.stopPolling() }
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { syncPolling() }

    func windowWillClose(_ notification: Notification) { controller.stopPolling() }

    // MARK: End task

    private func endTask() {
        controller.endSelection { [weak window] question, answer in
            let alert = NSAlert()
            alert.messageText = question.title
            alert.informativeText = question.message
            alert.alertStyle = .warning
            alert.addButton(withTitle: "End task").hasDestructiveAction = true
            alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
            if let window {
                alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
            } else {
                answer(alert.runModal() == .alertFirstButtonReturn)
            }
        }
    }
}

/// The window's content: the filter (everything in stacks, or one kind of
/// task), the view (List, Heat grid, Memory map) and the search field; tab
/// sleep's summary strip; the view with the inspector beside it; End task
/// under it. Darni-styled: the focused space's tint and accent (§4.3).
struct TaskManagerView: View {
    @Bindable var controller: TaskManagerController
    let endTask: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ink = TaskManagerInk(theme: controller.spaceTheme, dark: colorScheme == .dark)
        GeometryReader { proxy in
            let wide = proxy.size.width >= TaskManagerMetrics.tableMinimumWidth + TaskManagerInspector.width
            VStack(spacing: 0) {
                toolbar
                Divider()
                if controller.stacks.contains(where: { $0.kind == .tab }) {
                    TaskManagerSummaryStrip(summary: controller.summary)
                    Divider()
                }
                HStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if wide, controller.isInspectorShown, let stack = controller.focusedStack {
                        Divider()
                        TaskManagerInspector(controller: controller, stack: stack) { controller.isInspectorCollapsed = true }
                            .frame(width: TaskManagerInspector.width)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: controller.isInspectorShown)
                Divider()
                bottomBar
            }
            .sheet(isPresented: Binding(
                get: { !wide && controller.isInspectorShown },
                set: { if !$0 { controller.isInspectorCollapsed = true } }
            )) {
                if let stack = controller.focusedStack {
                    VStack(spacing: 0) {
                        TaskManagerInspector(controller: controller, stack: stack)
                        Divider()
                        HStack {
                            Spacer()
                            Button("Done") { controller.isInspectorCollapsed = true }.keyboardShortcut(.defaultAction)
                        }
                        .padding(TaskManagerMetrics.barPadding)
                    }
                    .frame(width: TaskManagerInspector.width, height: max(320, proxy.size.height - 80))
                    .environment(\.taskManagerInk, ink)
                    .background(TaskManagerBackground(ink: ink))
                }
            }
        }
        .environment(\.taskManagerInk, ink)
        .background(TaskManagerBackground(ink: ink))
        .frame(minWidth: TaskManagerMetrics.minimumSize.width, minHeight: TaskManagerMetrics.minimumSize.height)
    }

    private var toolbar: some View {
        HStack(spacing: TaskManagerMetrics.barPadding) {
            Picker("Show", selection: $controller.filter) {
                ForEach(TaskManagerFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Picker("View", selection: $controller.viewMode) {
                ForEach(TaskManagerViewMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("View")
            Spacer(minLength: 0)
            Button {
                controller.isInspectorCollapsed.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("i", modifiers: [.option, .command])
            .disabled(controller.focusedStack == nil)
            .help(controller.isInspectorCollapsed ? "Show the inspector (⌥⌘I)" : "Hide the inspector (⌥⌘I)")
            .accessibilityLabel(controller.isInspectorCollapsed ? "Show the inspector" : "Hide the inspector")
            TaskManagerSearchField(text: $controller.search)
                .frame(width: TaskManagerMetrics.searchWidth)
        }
        .padding(TaskManagerMetrics.barPadding)
    }

    @ViewBuilder private var content: some View {
        switch controller.viewMode {
        case .list:
            TaskManagerTable(controller: controller)
                .overlay {
                    if controller.hasReading, controller.rows.isEmpty {
                        Text(controller.search.isEmpty ? "No tasks" : "No tasks match “\(controller.search)”")
                            .foregroundStyle(.secondary)
                    }
                }
        case .heatGrid:
            TaskManagerHeatGridView(controller: controller)
        case .memoryMap:
            TaskManagerMemoryMapView(controller: controller)
        }
    }

    private var bottomBar: some View {
        HStack {
            // What "≈" on a tab's row means, where the figures are read.
            Text("≈ A tab's total is an estimate: a process tabs share is split evenly between them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(TaskManagerHelp.estimate)
            Spacer()
            Button("End task", action: endTask)
                .disabled(!controller.canEndSelection)
                .help("Ends the selected processes. Their tabs stop until you reload them.")
        }
        .padding(TaskManagerMetrics.barPadding)
    }
}

/// The window's background: the system's, washed with the space's tint.
struct TaskManagerBackground: View {
    let ink: TaskManagerInk

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            ink.tint
        }
        .ignoresSafeArea()
    }
}

/// "Tab sleep now: 6 asleep, 3 unloaded · freed 1.9 GB by unloading this session".
struct TaskManagerSummaryStrip: View {
    let summary: TaskManagerTabSleepSummary
    @Environment(\.taskManagerInk) private var ink

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .foregroundStyle(ink.accent)
                .accessibilityHidden(true)
            Text(summary.text)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("History in memory only · nothing leaves this Mac")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, TaskManagerMetrics.barPadding)
        .padding(.vertical, 6)
        .background(ink.accent.opacity(0.07))
        .help(TaskManagerTabSleepSummary.help)
        .accessibilityElement(children: .combine)
        .accessibilityHint(TaskManagerTabSleepSummary.help)
    }
}

/// The system's search field (a magnifier, a clear button), as Chrome's window has.
private struct TaskManagerSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Search tasks")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
