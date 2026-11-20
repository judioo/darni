import SwiftUI
import SidebarModel

/// Minimal standalone window (PEEK-LITTLE-BROWSER §2): a compact toolbar
/// with back, forward and reload, the address placeholder that opens its
/// mini command bar, the profile indicator and Open in <Space> (⌘O) with its
/// picker of every space (`LittleArcSpacePickerView`); then the page.
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
    /// Open in ⌄: the space picker is up.
    @State private var showsSpacePicker: Bool

    /// `showsSpacePicker` starts the window with its picker up, for pictures of it.
    init(model: BrowserViewModel, windowID: LittleArcWindow.ID, showsSpacePicker: Bool = false) {
        self.model = model
        self.windowID = windowID
        _showsSpacePicker = State(initialValue: showsSpacePicker)
    }

    private var record: LittleArcWindow? {
        model.store.littleArcWindow(withID: windowID)
    }

    /// The toolbar's height: 22 pt controls in 7 pt of padding above and below.
    static let toolbarHeight: CGFloat = 36
    /// The least the address field keeps when the toolbar is tight.
    static let minimumAddressWidth: CGFloat = 64

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
        .overlay { spacePicker }
        .coordinateSpace(name: LittleArcLayout.space)
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
            confirm: { if model.confirmLittleArcOpenIn(for: windowID) { dismiss() } }
        ))
        .background(
            WindowKeyObserver(
                onBecameKey: { model.keyLittleArcID = windowID },
                onClose: { if model.keyLittleArcID == windowID { model.keyLittleArcID = nil } },
                onResignKey: {
                    if model.keyLittleArcID == windowID { model.keyLittleArcID = nil }
                    // A dropdown does not outlive its window's focus.
                    showsSpacePicker = false
                }
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
        // ⌘O while the picker is up puts its question: the picker gives way to it.
        .onChange(of: openInQuestion != nil) { _, asking in if asking { showsSpacePicker = false } }
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
        showsSpacePicker = false
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
            if let container = model.containerLabel(for: engine, tab: nil) {
                // In a tight toolbar the chip shortens, then is its badge alone, before Open in
                // loses its name. The avatar beside it keeps the container's ring and badge.
                ViewThatFits(in: .horizontal) {
                    ContainerChip(label: container)
                    ContainerChip(label: container, style: .compact, maxWidth: 72)
                    ContainerChip(label: container, style: .badge)
                }
            }
            navButton("square.split.2x1", "Open in Split View", enabled: model.canSplitLittleArcWindow(windowID)) {
                if model.splitLittleArcWindow(windowID) { dismiss() }
            }
            navButton("link", "Copy Link", enabled: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString((engine.currentURL ?? record.url).absoluteString, forType: .string)
            }
            profileMenu(for: record)
            // Asked first what it needs: the address field gives way before a word of it does.
            openInButton(for: record)
                .layoutPriority(1)
            Button {
                model.closeLittleArcWindow(windowID)
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .littleArcPart(.close)
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

    /// Arc's "Open in <Space> ⌘O | ⌄" (`LittleArcOpenInButton`): it names the
    /// space of the last focused browser window, whatever its profile, in that
    /// space's colour, and the ⌄ opens the picker of every space. The main
    /// button and ⌘O go the way a row of the picker goes
    /// (`openLittleArcWindowInTarget`): the page moves only to a space of its
    /// own session; in any other its address opens afresh (S-01), after a
    /// question (OI-01), and only a web address (OI-02).
    private func openInButton(for record: LittleArcWindow) -> some View {
        let target = model.store.littleArcTargetSpace(for: windowID)
        return LittleArcOpenInButton(
            targetName: target?.name,
            theme: target?.theme,
            help: openInHelp(target: target),
            isPickerOpen: showsSpacePicker,
            // The target is read again when the button is pressed, not taken from this drawing.
            open: { choose(nil) },
            togglePicker: { showsSpacePicker.toggle() }
        )
    }

    /// What the main button will do, in its tooltip: said from the address
    /// the window shows now, as the picker's rows are drawn.
    private func openInHelp(target: Space?) -> String {
        guard let target else { return "Open this page as a tab" }
        guard LittleArcOpenInMenu.kind(store: model.store, windowID: windowID, spaceID: target.id) == .reopen else {
            return "Move this page into a tab in \(target.name)"
        }
        guard let url = model.littleArcAddress(windowID), LittleArcOpenInMenu.canCrossSessions(url) else {
            return LittleArcOpenInMenu.webOnlyMessage
        }
        return "Open this page's address as a new tab in \(target.name), in another profile or container"
    }

    /// The main button (the target space), a row of the picker, or ⌘O from
    /// the menu bar: all three ask the model, which asks the store what the
    /// choice does. The window goes only when its page moved. A space of
    /// another session asks first, and the window stays on Cancel, on an
    /// address that cannot cross, and when the space went while the picker
    /// was up.
    private func choose(_ spaceID: Space.ID?) {
        showsSpacePicker = false
        let choice = spaceID.map { model.openLittleArcWindow(windowID, in: $0) } ?? model.openLittleArcWindowInTarget(windowID)
        if choice == .move { dismiss() }
    }

    /// The picker, at the window's top trailing corner over the button it
    /// came from, as Arc's is. A clear layer under it takes the click that
    /// closes it, as under the command bar.
    private var spacePicker: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if showsSpacePicker, record != nil {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { closeSpacePicker() }
                    LittleArcSpacePickerView(
                        // The address the window shows decides which rows can cross sessions.
                        sections: LittleArcOpenInMenu.sections(store: model.store, windowID: windowID, url: model.littleArcAddress(windowID)),
                        space: { model.store.listedSpace(withID: $0) },
                        maxHeight: min(LittleArcSpacePickerView.arcHeight, geometry.size.height - 2 * Self.pickerInset),
                        choose: { choose($0) },
                        close: closeSpacePicker
                    )
                    .padding(Self.pickerInset)
                    .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .animation(.easeOut(duration: 0.12), value: showsSpacePicker)
        }
        // Nothing of it is in the page's way while the picker is away.
        .allowsHitTesting(showsSpacePicker)
    }

    /// Arc's panel sits 4 pt inside the window's top and trailing edges.
    static let pickerInset: CGFloat = 4

    /// Esc, the ⌃ or a click elsewhere: the picker goes and the page has the keyboard again.
    private func closeSpacePicker() {
        showsSpacePicker = false
        (model.littleArcEngine(for: windowID) as? PageFocusing)?.focusPage()
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
        // It gives way to Open in, down to this: room for its icon and a few letters.
        .frame(minWidth: Self.minimumAddressWidth, maxWidth: .infinity)
        .background(Color.primary.opacity(isEditingAddress ? 0.08 : 0.05), in: RoundedRectangle(cornerRadius: 7))
        .littleArcPart(.address)
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
