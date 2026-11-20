import AppKit
import SwiftUI
import XCTest
@testable import ReArc
@testable import SidebarModel

/// Little Darni's "Open in <Space> ⌘O | ⌄" pill and its space picker, drawn
/// offscreen: the windows are never ordered in and sit far off any display.
///
/// The checks hold on every run: Open in and its ⌄ are in the toolbar in every
/// window state and width, the address field gives way first, and the pill is
/// opaque, so `LittleArcOpenInInk`'s contrast is what is drawn. Set
/// `REARC_LITTLE_PICKER_DIR` to keep the pictures (shell/dist/little-space-picker),
/// to lay beside Arc's recording.
@MainActor
final class LittleArcSpacePickerLookTests: XCTestCase {

    // MARK: - Fixture

    /// The owner's Arc, as its recording of 2026-11-20 shows it: one profile
    /// with many spaces, each with its emoji, symbol or plain dot, and a
    /// second profile with one space.
    private struct Fixture {
        let store: SidebarStore
        let model: BrowserViewModel
        let personal: Profile.ID
        let spaces: [Space]
        let other: Profile
        let otherSpace: Space
    }

    private func fixture() -> Fixture {
        func theme(_ red: Double, _ green: Double, _ blue: Double) -> SpaceTheme { SpaceTheme(red: red, green: green, blue: blue) }
        let store = SidebarStore(spaces: [Space(name: "Blogging", theme: theme(0.33, 0.62, 0.84), iconName: "✍🏾")])
        let personal = store.activeProfileID
        store.addSpace(name: "Personal", theme: theme(0.45, 0.72, 0.86), iconName: "🖤", profileID: personal)
        store.addSpace(name: "Imara", theme: .default, iconName: "💵", profileID: personal)
        store.addSpace(name: "ReArc", theme: theme(0.9, 0.22, 0.3), iconName: "chevron.left.forwardslash.chevron.right", profileID: personal)
        store.addSpace(name: "Assured.living", theme: theme(0.35, 0.78, 0.5), iconName: "🏡", profileID: personal)
        store.addSpace(name: "BHomes/Cencorp/Engage", theme: theme(0.93, 0.75, 0.1), profileID: personal)
        store.addSpace(name: "Yes&", theme: theme(0.15, 0.2, 0.95), profileID: personal)
        store.addSpace(name: "Daily/Todo", theme: theme(0.95, 0.5, 0.65), iconName: "📚", profileID: personal)
        store.addSpace(name: "Research/Preparation", theme: theme(0.95, 0.8, 0.2), iconName: "magnifyingglass", profileID: personal)
        let other = store.addProfile(name: "CWC - YAVICA")
        let otherSpace = store.spaces(in: other.id)[0]
        store.renameSpace(otherSpace.id, to: "CWC - YAVICA")
        store.setSpaceTheme(otherSpace.id, theme: theme(0.78, 0.66, 0.58))
        let window = SidebarWindowID()
        store.registerWindow(window)
        store.windowBecameKey(window)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rearc-little-picker-\(UUID().uuidString)")
        let model = BrowserViewModel(store: store, persistence: SidebarFilePersistence(fileURL: directory.appendingPathComponent("sidebar.json")),
                                     syncEngine: LocalSyncEngine(), faviconStore: FaviconStore(directory: nil))
        return Fixture(store: store, model: model, personal: personal, spaces: store.spaces(in: personal),
                       other: other, otherSpace: store.spaces(in: other.id)[0])
    }

    private let page = URL(string: "https://little.test/")!
    private let blank = URL(string: "about:blank")!

    // MARK: - The picker

    func testThePickerDrawsEverySpaceWithItsIconInLightAndDark() throws {
        let f = fixture()
        let little = f.store.createLittleArcWindow(url: page, profileID: f.personal)
        let one = SidebarStore(spaces: f.spaces.map { Space(name: $0.name, theme: $0.theme, iconName: $0.iconName) })
        let alone = one.createLittleArcWindow(url: page)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            // One profile, as in Arc's recording: no headers, the pointer on Imara.
            try keep(try render(picker(LittleArcOpenInMenu.sections(store: one, windowID: alone.id), store: one,
                                       highlight: one.spaces[2].id), dark: dark), "panel-\(suffix)")
            // Two profiles: a header over each.
            try keep(try render(picker(LittleArcOpenInMenu.sections(store: f.store, windowID: little.id), store: f.store,
                                       maxHeight: 600), dark: dark, height: 640), "panel-profiles-\(suffix)")
            // Typing filters.
            try keep(try render(picker(LittleArcOpenInMenu.sections(store: f.store, windowID: little.id), store: f.store, query: "re"),
                                dark: dark), "panel-search-\(suffix)")
            try keep(try render(picker(LittleArcOpenInMenu.sections(store: f.store, windowID: little.id), store: f.store, query: "zzz"),
                                dark: dark), "panel-search-nothing-\(suffix)")
        }
    }

    /// A page that is not a web page, and a container: the rows of other
    /// sessions are dimmed, the reason is the last line, and a container's
    /// space keeps its mark.
    func testThePickerDrawsDisabledRowsTheReasonAndContainers() throws {
        let f = fixture()
        XCTAssertNotNil(f.store.createContainer(forSpace: f.spaces[4].id))
        let little = f.store.createLittleArcWindow(url: blank, profileID: f.personal)
        let sections = LittleArcOpenInMenu.sections(store: f.store, windowID: little.id)
        let rows = LittleArcSpacePicker.rows(for: sections)
        XCTAssertEqual(rows.last, .note(LittleArcOpenInMenu.webOnlyMessage))
        XCTAssertTrue(rows.compactMap(\.entry).contains { $0.title == "Assured.living (Container)" && !$0.isEnabled })
        for dark in [false, true] {
            try keep(try render(picker(sections, store: f.store, maxHeight: 640), dark: dark, height: 680),
                     "panel-not-a-web-page-\(dark ? "dark" : "light")")
        }
    }

    /// The list is as tall as its rows up to Arc's height, then it scrolls;
    /// a short window gets a shorter panel that still shows a whole row.
    func testThePanelsHeightFollowsItsRowsAndItsWindow() {
        let f = fixture()
        let little = f.store.createLittleArcWindow(url: page, profileID: f.personal)
        let rows = LittleArcSpacePicker.rows(for: LittleArcOpenInMenu.sections(store: f.store, windowID: little.id))
        typealias View = LittleArcSpacePickerView
        let natural = rows.reduce(CGFloat(0)) { $0 + View.height(of: $1) }
        XCTAssertEqual(natural, 2 * View.headerHeight + 10 * View.rowHeight)
        XCTAssertEqual(View.listHeight(for: rows, maxHeight: View.arcHeight), View.arcHeight - View.searchHeight, "Arc's height: 396 pt in all")
        XCTAssertEqual(View.listHeight(for: Array(rows.prefix(3)), maxHeight: View.arcHeight), View.headerHeight + 2 * View.rowHeight)
        let short = LittleArcWindowView.minimumSize.height - 2 * LittleArcWindowView.pickerInset
        XCTAssertEqual(View.listHeight(for: rows, maxHeight: short), short - View.searchHeight)
        XCTAssertGreaterThanOrEqual(View.listHeight(for: rows, maxHeight: 0), View.rowHeight, "never less than a row")
    }

    // MARK: - The pill

    /// The pill is opaque: whatever the toolbar has behind it, the words sit
    /// on `LittleArcOpenInInk.pill`. That is what makes its contrast knowable.
    func testThePillDrawsItsOwnOpaqueFillOverAnyToolbar() throws {
        for dark in [false, true] {
            let ink = LittleArcOpenInInk(theme: .default, dark: dark)
            for backdrop in [Color.white, .black, .red] {
                let view = LittleArcOpenInButton(targetName: "Imara", theme: .default, help: "", isPickerOpen: false, open: {}, togglePicker: {})
                    .padding(20)
                    .frame(width: 260, height: 62, alignment: .leading)
                    .background(backdrop)
                let rep = try render(view, size: NSSize(width: 260, height: 62), dark: dark)
                // Just inside the pill's leading edge, at its middle: no glyph there.
                let sampled = try XCTUnwrap(Self.color(rep, at: NSPoint(x: 24, y: 31)))
                XCTAssertEqual(Double(sampled.redComponent), ink.pill.red, accuracy: 0.03, "\(dark) \(backdrop)")
                XCTAssertEqual(Double(sampled.greenComponent), ink.pill.green, accuracy: 0.03, "\(dark) \(backdrop)")
                XCTAssertEqual(Double(sampled.blueComponent), ink.pill.blue, accuracy: 0.03, "\(dark) \(backdrop)")
            }
        }
    }

    func testThePillInEveryThemeInLightAndDark() throws {
        let themes: [(String, SpaceTheme?)] = [("Imara", .default), ("Blogging", SpaceTheme(red: 0.33, green: 0.62, blue: 0.84)),
                                               ("Research", SpaceTheme(red: 0.95, green: 0.8, blue: 0.2)),
                                               ("ReArc", SpaceTheme(red: 0.9, green: 0.22, blue: 0.3)),
                                               ("Assured.living", SpaceTheme(red: 0.35, green: 0.78, blue: 0.5)),
                                               ("Night", SpaceTheme(red: 0.05, green: 0.08, blue: 0.2)), ("Paper", .white), ("Darni", nil)]
        for dark in [false, true] {
            let column = VStack(alignment: .leading, spacing: 10) {
                ForEach(themes, id: \.0) { name, theme in
                    let tint = theme.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .clear
                    LittleArcOpenInButton(targetName: theme == nil ? nil : name, theme: theme, help: "", isPickerOpen: false, open: {}, togglePicker: {})
                        .padding(.horizontal, 10)
                        .frame(width: 300, height: LittleArcWindowView.toolbarHeight, alignment: .trailing)
                        // The toolbar's own tint toward the target space.
                        .background(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.12)], startPoint: .leading, endPoint: .trailing))
                        .background(dark ? Color(white: 0.2) : Color(white: 0.93))
                }
            }
            .padding(16)
            try keep(try render(column, size: NSSize(width: 332, height: 32 + CGFloat(themes.count) * 46 - 10), dark: dark),
                     "pill-themes-\(dark ? "dark" : "light")")
        }
    }

    // MARK: - The window

    /// Open in and its ⌄ are in the toolbar, whole, in every state of the
    /// window: blank, a page, a page that failed, a container's window, and
    /// the narrowest window with the longest space name. The address field
    /// gives way first and keeps its minimum.
    func testOpenInIsInTheToolbarInEveryStateAndWidth() throws {
        let f = fixture()
        XCTAssertNotNil(f.store.createContainer(forSpace: f.spaces[4].id))
        let container = try XCTUnwrap(f.store.container(ofSpace: f.spaces[4].id))
        let long = f.spaces[5]
        XCTAssertEqual(long.name, "BHomes/Cencorp/Engage")
        let states: [(name: String, url: URL, profile: Profile.ID, target: Space)] = [
            ("blank", blank, f.personal, f.spaces[0]),
            ("page", page, f.personal, f.spaces[0]),
            ("long-name", page, f.personal, long),
            ("other-profile-target", page, f.personal, f.otherSpace),
            ("blank-other-profile-target", blank, f.personal, f.otherSpace),
            ("container-window", page, container.id, long),
        ]
        let widths: [CGFloat] = [LittleArcWindowView.minimumSize.width, 520, 760, 1270]
        for state in states {
            f.store.selectSpace(state.target.id)
            let record = f.model.openLittleArc(url: state.url, profileID: state.profile)
            XCTAssertEqual(f.store.littleArcTargetSpace(for: record.id)?.id, state.target.id)
            for width in widths {
                let size = NSSize(width: width, height: LittleArcWindowView.minimumSize.height)
                let layout = Layout()
                let view = LittleArcWindowView(model: f.model, windowID: record.id).onPreferenceChange(LittleArcLayout.self) { layout.parts = $0 }
                try hosted(view, size: size, dark: false) { host, _ in
                    let what = "\(state.name) at \(Int(width))"
                    let main = try XCTUnwrap(layout.parts[.openIn], "\(what): no Open in")
                    let chevron = try XCTUnwrap(layout.parts[.openInChevron], "\(what): no ⌄")
                    let close = try XCTUnwrap(layout.parts[.close], "\(what): no Close")
                    let address = try XCTUnwrap(layout.parts[.address], "\(what): no address")
                    XCTAssertNil(layout.parts[.picker], "\(what): the picker is away until asked for")
                    for (name, frame) in [("Open in", main), ("⌄", chevron), ("Close", close), ("address", address)] {
                        XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(what): \(name) starts outside the window")
                        XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "\(what): \(name) ends outside the window")
                    }
                    XCTAssertEqual(chevron.width, LittleArcOpenInButton.chevronWidth, accuracy: 0.5, what)
                    XCTAssertGreaterThanOrEqual(main.width, 40, "\(what): room for some of the name")
                    XCTAssertLessThan(main.maxX, chevron.maxX, what)
                    XCTAssertLessThanOrEqual(chevron.maxX, close.minX, "\(what): the pill is whole, before Close")
                    XCTAssertLessThanOrEqual(address.maxX, main.minX, "\(what): the address field is not under the pill")
                    XCTAssertGreaterThanOrEqual(address.width, LittleArcWindowView.minimumAddressWidth - 0.5, "\(what): the address keeps its minimum")
                    for frame in [main, chevron] {
                        XCTAssertGreaterThanOrEqual(frame.minY, 0, what)
                        XCTAssertLessThanOrEqual(frame.maxY, LittleArcWindowView.toolbarHeight + 1, "\(what): inside the toolbar's strip")
                        XCTAssertEqual(frame.height, LittleArcOpenInButton.height, accuracy: 0.5, what)
                    }
                    // What the pill needs with nothing shed: its padding, "Open in", the name and ⌘O.
                    let name = min(Self.textWidth(state.target.name, size: 12, weight: .medium), LittleArcOpenInButton.maxNameWidth)
                    let whole = 16 + Self.textWidth("Open in", size: 12, weight: .regular) + 4 + name + 6
                        + Self.textWidth("⌘O", size: 10, weight: .medium) + 8
                    if width >= 760 {
                        XCTAssertEqual(main.width, whole, accuracy: 4, "\(what): the words, the name and ⌘O, and no wider")
                    } else {
                        XCTAssertLessThanOrEqual(main.width, whole + 4, "\(what): never wider than its words")
                    }
                    try self.keep(Self.crop(try Self.capture(host), height: 60), "toolbar-\(state.name)-\(Int(width))")
                }
            }
            f.model.closeLittleArcWindow(record.id)
        }
    }

    /// The whole window with its picker up, as in Arc's recording, at a
    /// comfortable size and at the smallest.
    func testTheWindowWithItsPickerUp() throws {
        let f = fixture()
        let record = f.model.openLittleArc(url: page, profileID: f.personal)
        for dark in [false, true] {
            for (name, size) in [("window", NSSize(width: 760, height: 520)), ("window-smallest", LittleArcWindowView.minimumSize)] {
                let layout = Layout()
                let view = LittleArcWindowView(model: f.model, windowID: record.id, showsSpacePicker: true)
                    .onPreferenceChange(LittleArcLayout.self) { layout.parts = $0 }
                try hosted(view, size: size, dark: dark) { host, _ in
                    let panel = try XCTUnwrap(layout.parts[.picker], "\(name): no picker")
                    let chevron = try XCTUnwrap(layout.parts[.openInChevron], "\(name): no ⌄")
                    let inset = LittleArcWindowView.pickerInset
                    XCTAssertEqual(panel.width, LittleArcSpacePickerView.width, accuracy: 0.5, name)
                    XCTAssertEqual(panel.maxX, size.width - inset, accuracy: 0.5, "\(name): at the window's trailing edge, as Arc's")
                    XCTAssertEqual(panel.minY, inset, accuracy: 0.5, "\(name): at the window's top")
                    XCTAssertLessThanOrEqual(panel.maxY, size.height - inset + 0.5, "\(name): the panel leaves the window")
                    XCTAssertLessThanOrEqual(panel.height, LittleArcSpacePickerView.arcHeight + 0.5, "\(name): no taller than Arc's")
                    XCTAssertGreaterThanOrEqual(panel.height, LittleArcSpacePickerView.searchHeight + 4 * LittleArcSpacePickerView.rowHeight,
                                                "\(name): the search row and at least four spaces")
                    XCTAssertTrue(panel.contains(chevron), "\(name): the panel covers the ⌄ it came from, as Arc's does")
                    try self.keep(try Self.capture(host), "\(name)-\(dark ? "dark" : "light")")
                }
            }
        }
        f.model.closeLittleArcWindow(record.id)
    }

    // MARK: - Offscreen rendering

    private func picker(_ sections: [LittleArcOpenInMenu.Section], store: SidebarStore, query: String = "", highlight: Space.ID? = nil,
                        maxHeight: CGFloat = LittleArcSpacePickerView.arcHeight) -> some View {
        LittleArcSpacePickerView(sections: sections, space: { store.listedSpace(withID: $0) }, maxHeight: maxHeight, choose: { _ in },
                                 close: {}, initialQuery: query, initialHighlight: highlight, takesFocus: false)
    }

    /// The picker over a stand-in for a page, with room for its shadow.
    private func render<V: View>(_ picker: V, dark: Bool, height: CGFloat = 440) throws -> NSBitmapImageRep {
        let size = NSSize(width: LittleArcSpacePickerView.width + 60, height: height)
        let view = picker
            .padding(.top, 16)
            .padding(.trailing, 20)
            .frame(width: size.width, height: size.height, alignment: .topTrailing)
            .background(dark ? Color(white: 0.11) : Color(red: 0.95, green: 0.94, blue: 0.92))
        return try render(view, size: size, dark: dark)
    }

    private func render<V: View>(_ view: V, size: NSSize, dark: Bool) throws -> NSBitmapImageRep {
        var rep: NSBitmapImageRep?
        try hosted(view, size: size, dark: dark) { host, _ in rep = try Self.capture(host) }
        return try XCTUnwrap(rep)
    }

    private func hosted<V: View>(_ view: V, size: NSSize, dark: Bool, _ body: (NSHostingView<V>, NSWindow) throws -> Void) throws {
        let window = OffscreenWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size),
                                     styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { window.close() }
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        window.contentView = host
        window.setContentSize(size)
        for _ in 0 ..< 2 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        }
        try body(host, window)
    }

    private static func capture(_ host: NSView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// The top `height` points of a picture.
    private static func crop(_ rep: NSBitmapImageRep, height: CGFloat) throws -> NSBitmapImageRep {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        let image = try XCTUnwrap(rep.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(rep.pixelsWide), height: height * scale)))
        return NSBitmapImageRep(cgImage: image)
    }

    private func keep(_ rep: NSBitmapImageRep, _ name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["REARC_LITTLE_PICKER_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// The colour at a point of the view, from its top-left corner.
    private static func color(_ rep: NSBitmapImageRep, at point: NSPoint) -> NSColor? {
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        // The picture's own values: they are what was drawn, whatever colour space it is tagged with.
        return rep.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))
    }

    private static func textWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
    }

    /// The window's `LittleArcLayout`, as its last layout reported it.
    private final class Layout: @unchecked Sendable {
        var parts: [LittleArcLayout.Part: CGRect] = [:]
    }
}

/// Never constrained onto a screen, never ordered in.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
