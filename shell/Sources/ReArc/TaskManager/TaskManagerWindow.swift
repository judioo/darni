import AppKit
import SidebarModel
import SwiftUI

/// Sizes of the Task Manager window and its table.
enum TaskManagerMetrics {
    static let windowSize = NSSize(width: 760, height: 480)
    static let minimumSize = NSSize(width: 520, height: 280)
    static let barPadding: CGFloat = 12
    static let searchWidth: CGFloat = 200
    static let rowHeight: CGFloat = 24
    static let iconSize: CGFloat = 16
    static let cellInset: CGFloat = 6

    static func width(of column: TaskManagerColumn) -> (ideal: CGFloat, minimum: CGFloat) {
        switch column {
        case .task: return (300, 160)
        case .profile: return (110, 60)
        case .memoryFootprint: return (120, 80)
        case .cpu: return (60, 44)
        case .network: return (90, 60)
        case .processID: return (90, 60)
        }
    }
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

/// The window's content: Chrome's three segments and search field over the
/// table, End task under it.
struct TaskManagerView: View {
    @Bindable var controller: TaskManagerController
    let endTask: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: TaskManagerMetrics.barPadding) {
                Picker("Show", selection: $controller.category) {
                    ForEach(TaskManagerCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                TaskManagerSearchField(text: $controller.search)
                    .frame(width: TaskManagerMetrics.searchWidth)
            }
            .padding(TaskManagerMetrics.barPadding)
            Divider()
            TaskManagerTable(controller: controller)
                .overlay {
                    if controller.hasReading, controller.rows.isEmpty {
                        Text(controller.search.isEmpty ? "No tasks" : "No tasks match “\(controller.search)”")
                            .foregroundStyle(.secondary)
                    }
                }
            Divider()
            HStack {
                Spacer()
                Button("End task", action: endTask)
                    .disabled(!controller.canEndSelection)
                    .help("Ends the selected process. Its tabs stop until you reload them.")
            }
            .padding(TaskManagerMetrics.barPadding)
        }
        .frame(minWidth: TaskManagerMetrics.minimumSize.width, minHeight: TaskManagerMetrics.minimumSize.height)
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
