import SwiftUI
import SidebarModel

/// Minimal standalone window (PEEK-LITTLE-BROWSER §2): a compact toolbar
/// with back, forward and reload, the address placeholder that opens its
/// mini command bar, the profile indicator and Open in <Space> (⌘O) with a menu of every other space; then the page.
struct LittleArcWindowView: View {
    @Bindable var model: BrowserViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var colorScheme
    let windowID: LittleArcWindow.ID

    /// The smallest the window goes: the content's minimum, and the floor of `defaultSize`.
    static let minimumSize = CGSize(width: 420, height: 320)

    /// Big enough to read a page in (the owner's chosen size, 2026-11-16;
    /// 520 × 420 was too small), within `visible` (the screen's visible frame)
    /// less a margin on smaller screens.
    static func defaultSize(within visible: CGSize?) -> CGSize {
        let wanted = CGSize(width: 1270, height: 920)
        guard let visible else { return wanted }
        return CGSize(width: max(minimumSize.width, min(wanted.width, visible.width - 80)),
                      height: max(minimumSize.height, min(wanted.height, visible.height - 80)))
    }

    @State private var isEditingAddress = false
    @State private var addressText = ""
    @FocusState private var addressFocused: Bool

    private var record: LittleArcWindow? {
        model.store.littleArcWindow(withID: windowID)
    }

    /// The toolbar's height: 22 pt controls in 7 pt of padding above and below.
    static let toolbarHeight: CGFloat = 36

    /// This window's Open in question, while it waits for its answer.
    private var openInQuestion: LittleArcOpenInMenu.Question? {
        model.pendingLittleArcOpenIn.flatMap { $0.windowID == windowID ? $0 : nil }
    }

    var body: some View {
        Group {
            if let record {
                let engine = model.littleArcEngine(for: windowID)
                VStack(spacing: 0) {
                    toolbar(for: record, engine: engine)
                    Divider()
                    engine.makeView()
                        // No space here: the page's cards take the default theme in this window's appearance.
                        .environment(\.themeChrome, .outsideSpaces(dark: colorScheme == .dark))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .pageStatus(engine.activity) { engine.reload() }
                        .findBar(model.findBar, for: engine)
                }
            } else {
                Text("Little Darni window unavailable")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .overlay(alignment: .topLeading) { LittleArcProbeMarker(windowID: windowID) }
        // Why a row of Open in did nothing, on this window and under its toolbar.
        // A layer of its own: the toast takes the default theme in this window's
        // appearance, as the page's cards do, and the rest of the window keeps its colours.
        .overlay {
            Color.clear
                .shellToast(model.littleArcToast?.windowID == windowID ? model.littleArcToast?.toast : nil,
                            toolbarHeight: Self.toolbarHeight)
                .environment(\.themeChrome, .outsideSpaces(dark: colorScheme == .dark))
                .allowsHitTesting(false)
        }
        // Open in ▸ a space of another session asks here, as Move to Profile asks on its window.
        .modifier(SessionCrossingAlert(
            text: openInQuestion.map(model.littleArcOpenInMessage),
            isPresented: { openInQuestion != nil },
            cancel: { model.cancelLittleArcOpenIn(for: windowID) },
            confirm: { if model.confirmLittleArcOpenIn() { dismiss() } }
        ))
        .background(
            WindowKeyObserver(
                onBecameKey: { model.keyLittleArcID = windowID },
                onClose: { if model.keyLittleArcID == windowID { model.keyLittleArcID = nil } },
                onResignKey: { if model.keyLittleArcID == windowID { model.keyLittleArcID = nil } }
            )
            .frame(width: 0, height: 0)
        )
        .onAppear {
            model.focusedLittleArcID = windowID
            model.touchLittleArcIfNeeded(windowID)
            model.loadLittleArcIfNeeded(windowID)
            consumeFocusRequest()
        }
        .onChange(of: model.littleArcFocusRequest) { _, _ in consumeFocusRequest() }
        // Archived elsewhere (Settings › Links › Archive Little Arcs after): the window goes too.
        .onChange(of: record == nil) { _, gone in if gone { dismiss() } }
        .onDisappear {
            if model.focusedLittleArcID == windowID {
                model.focusedLittleArcID = nil
            }
            model.cancelLittleArcOpenIn(for: windowID)
            if model.store.littleArcWindow(withID: windowID) != nil {
                model.closeLittleArcWindow(windowID)
            }
        }
    }

    private func dismiss() {
        if let presenter = model.windowPresenter {
            presenter.dismissLittleArcWindow(windowID)
        } else {
            dismissWindow(id: "littleArc", value: windowID)
        }
    }

    /// ⌘L or a new blank Little Arc: the address field starts editing.
    private func consumeFocusRequest() {
        guard model.littleArcFocusRequest == windowID else { return }
        model.littleArcFocusRequest = nil
        beginEditing()
    }

    private func beginEditing() {
        addressText = LittleArcChrome.editingText(for: model.littleArcEngine(for: windowID).currentURL ?? record?.url)
        isEditingAddress = true
        DispatchQueue.main.async { addressFocused = true }
    }

    private func toolbar(for record: LittleArcWindow, engine: any WebEngine) -> some View {
        HStack(spacing: 6) {
            navButton("chevron.left", "Back (⌘[)", enabled: engine.canGoBack) { engine.goBack() }
            navButton("chevron.right", "Forward (⌘])", enabled: engine.canGoForward) { engine.goForward() }
            navButton(engine.isLoading ? "xmark" : "arrow.clockwise", engine.isLoading ? "Stop" : "Reload (⌘R)", enabled: true) {
                engine.isLoading ? engine.stopLoading() : engine.reload()
            }
            address(for: record, engine: engine)
            if let container = model.containerLabel(for: engine, tab: nil) { ContainerChip(label: container) }
            navButton("square.split.2x1", "Open in Split View", enabled: model.canSplitLittleArcWindow(windowID)) {
                if model.splitLittleArcWindow(windowID) { dismiss() }
            }
            navButton("link", "Copy Link", enabled: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((engine.currentURL ?? record.url).absoluteString, forType: .string)
            }
            profileMenu(for: record)
            openInButton(for: record)
            Button {
                model.closeLittleArcWindow(windowID)
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            // Tinted with the space Open in targets, as Arc tints it.
            let theme = model.store.littleArcTargetSpace(for: windowID)?.theme
            ZStack {
                Rectangle().fill(.bar)
                if let theme {
                    let color = Color(red: theme.red, green: theme.green, blue: theme.blue)
                    LinearGradient(colors: [color.opacity(0.22), color.opacity(0.12)], startPoint: .leading, endPoint: .trailing)
                }
            }
        }
    }

    /// The words on Open in: full text colour, which keeps 4.5:1 on the tinted
    /// bar for any space. The space's name was once drawn in its theme colour,
    /// unreadable on the default lavender (QA 2026-11-08 #19); the colour is
    /// now a dot beside the name.
    static let labelColor = NSColor.textColor

    /// Arc's "Open in <Space> ⌘O ⌄": the space of the last focused browser
    /// window, with a dot in its theme colour, and a menu of every other space,
    /// grouped by profile (`LittleArcOpenInMenu`). The page moves only to a
    /// space of its own session; in any other space its address opens afresh
    /// (S-01), after a question (OI-01), and only a web address (OI-02).
    @ViewBuilder
    private func openInButton(for record: LittleArcWindow) -> some View {
        let target = model.store.littleArcTargetSpace(for: windowID)
        // The address the window shows decides which rows can cross sessions.
        let sections = LittleArcOpenInMenu.sections(store: model.store, windowID: windowID, url: model.littleArcAddress(windowID))
        HStack(spacing: 0) {
            Button {
                open(into: target?.id)
            } label: {
                HStack(spacing: 4) {
                    Text("Open in").foregroundStyle(Color(nsColor: Self.labelColor))
                    if let theme = target?.theme {
                        Circle()
                            .fill(Color(red: theme.red, green: theme.green, blue: theme.blue))
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                    }
                    Text(target?.name ?? "Darni")
                        .fontWeight(.medium)
                        .foregroundStyle(Color(nsColor: Self.labelColor))
                    Text("⌘O")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08)))
                }
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Move this page into a tab in \(target?.name ?? "your current space")")
            .accessibilityLabel("Open in \(target?.name ?? "Darni")")
            if !sections.isEmpty {
                Divider().frame(height: 14)
                Menu {
                    ForEach(sections) { section in
                        if let header = section.header {
                            Section(header) { openInItems(section.entries) }
                        } else {
                            openInItems(section.entries)
                        }
                    }
                    if let note = LittleArcOpenInMenu.note(for: sections) {
                        // The reason for the disabled rows, in words, as the last line.
                        Divider()
                        Text(note)
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .padding(.horizontal, 6)
                .help("Open in another space")
                .accessibilityLabel("Open in another space")
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
        // The address field gives way: at the default 520 pt the label read "Open… Pers…".
        .fixedSize()
    }

    /// The main button: the page becomes a tab in the target space.
    private func open(into spaceID: Space.ID?) {
        model.promoteLittleArcWindow(windowID, into: spaceID)
        dismiss()
    }

    /// One profile's spaces in the ⌄ menu, each with a dot in its theme colour.
    private func openInItems(_ entries: [LittleArcOpenInMenu.Entry]) -> some View {
        ForEach(entries) { entry in
            Button {
                // The window goes only when its page moved. A space of another session asks
                // first, and the window stays on Cancel, on an address that cannot cross, and
                // when the space went while the menu was up.
                if model.openLittleArcWindow(windowID, in: entry.spaceID) == .move { dismiss() }
            } label: {
                Label {
                    Text(entry.title)
                } icon: {
                    Image(nsImage: Self.menuDot(entry.theme))
                }
            }
            .disabled(!entry.isEnabled)
        }
    }

    /// A menu draws a template symbol in the text colour, so the space's
    /// colour is a small picture of its own, as the dot on the main button.
    static func menuDot(_ theme: SpaceTheme) -> NSImage {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor(srgbRed: theme.red, green: theme.green, blue: theme.blue, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private func navButton(_ symbol: String, _ help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }

    /// The command-bar placeholder: the site's host; click (or ⌘L) to type
    /// a URL or search, which loads in this window. A domain completes inline.
    @ViewBuilder
    private func address(for record: LittleArcWindow, engine: any WebEngine) -> some View {
        Group {
            if isEditingAddress {
                let suffix = InlineDomainCompletion.complete(addressText, candidates: InlineDomainCompletion.candidates(history: model.visitHistory(for: record.profileID)))
                    .flatMap { InlineDomainCompletion.suffix(typed: addressText, completion: $0) }
                TextField("Search or enter URL", text: $addressText)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .overlay(alignment: .leading) {
                        if let suffix {
                            (Text(addressText).foregroundColor(.clear) + Text(suffix).foregroundColor(.secondary.opacity(0.7)))
                                .lineLimit(1)
                                .allowsHitTesting(false)
                        }
                    }
                    .onKeyPress(.rightArrow, phases: .down) { press in
                        guard press.modifiers.isEmpty, let suffix else { return .ignored }
                        addressText += suffix
                        return .handled
                    }
                    .onSubmit {
                        let text = addressText + (suffix ?? "")
                        if model.navigateLittleArc(windowID, to: text) { isEditingAddress = false }
                    }
                    .onExitCommand { isEditingAddress = false }
                    .onChange(of: addressFocused) { _, focused in if !focused { isEditingAddress = false } }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: securityIcon(engine.securityState))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    // Arc centres the host in the field.
                    Spacer(minLength: 0)
                    let text = LittleArcChrome.addressText(for: engine.currentURL ?? record.url)
                    Text(text.isEmpty ? "Search or enter URL" : text)
                        .foregroundStyle(text.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    // Keeps the host centred against the icon on the left.
                    Color.clear.frame(width: 10, height: 1)
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: beginEditing)
                .help((engine.currentURL ?? record.url).absoluteString)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Address, \(record.url.absoluteString)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(isEditingAddress ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 7))
    }

    private func securityIcon(_ state: WebSecurityState) -> String {
        switch state {
        case .secure: return "lock.fill"
        case .insecure, .dangerous: return "exclamationmark.triangle.fill"
        case .none, .unknown: return "globe"
        }
    }

    /// Arc's `littleBrowserProfileIndicator`: which profile this window uses, and a switch.
    @ViewBuilder
    private func profileMenu(for record: LittleArcWindow) -> some View {
        if let profile = model.store.profile(withID: model.store.owningProfileID(of: record.profileID)) {
            // The window's session: a container's shows its parent's avatar with the badge.
            let container = model.store.containerLabel(forEngineProfile: record.profileID)
            Menu {
                ProfileMenuChoices(store: model.store, active: record.profileID, includesContainers: true) { model.changeLittleArcProfile(windowID, to: $0) }
            } label: {
                ProfileAvatarView(profile: profile, diameter: 20)
                    .containerMark(container, ring: .circle(26), surface: .window)
            }
            // As the sidebar's profile menus: a borderless menu draws its label as
            // an NSPopUpButton image at the picture's own size, so a photo avatar
            // filled the toolbar; a plain button keeps the 20 pt frame.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(container.map { "Profile: \(profile.name) · Container: \($0.name), own sign-ins" } ?? "Profile: \(profile.name)")
            .accessibilityLabel(container.map { "Profile \(profile.name), container \($0.name)" } ?? "Profile \(profile.name)")
        }
    }
}
