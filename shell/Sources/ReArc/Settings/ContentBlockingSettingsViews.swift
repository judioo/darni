import SidebarModel
import SwiftUI

/// Settings › Profiles › Your Data and Settings: "Block ads and trackers"
/// for one profile (CONTENT-BLOCKING.md §3): the switch, the level, when the
/// lists were last updated with Check Now, and Advanced. Shown only when the
/// engine can block (`ContentBlockingController.isAvailable`).
struct ContentBlockingSettingsGroup: View {
    let model: BrowserViewModel
    let profile: Profile
    @State private var showsAdvanced = false

    static let info = "Darni stops ads and trackers from loading in this profile, using public filter lists it keeps up to date. "
        + "What is blocked is counted on this Mac only. If a site stops working, turn blocking off for it in the site controls, "
        + "the button beside the address. Private windows follow the profile."
    static let levelInfo = "Trackers only: EasyPrivacy and Peter Lowe’s list. Ads and trackers adds EasyList. "
        + "Strict adds Fanboy’s Annoyance list and the EasyList Cookie List, which hide cookie notices and other clutter and can break a site now and then."

    var body: some View {
        let settings = model.store.contentBlocking(for: profile.id)
        let controller = model.contentBlocking
        SettingsGroup {
            SettingsSwitchRow(label: SiteControlCenter.contentBlockingTitle, info: Self.info, isOn: Binding(
                get: { settings.isEnabled },
                set: { model.setContentBlockingEnabled($0, for: profile.id) }
            ))
            if settings.isEnabled {
                SettingsLabeledRow(label: "Level", info: Self.levelInfo) {
                    SettingsPopUp(label: "Blocking level", selection: Binding(
                        get: { settings.strength },
                        set: { model.setContentBlockingStrength($0, for: profile.id) }
                    ), options: ContentBlockingLevel.strengths.map { ($0, $0.title) }, minWidth: 150)
                }
                SettingsLabeledRow(label: controller.listsUpdatedText, detail: controller.lastCheck?.text) {
                    Button(controller.isCheckingLists ? "Checking…" : "Check Now") { model.checkBlocklists() }
                        .disabled(controller.isCheckingLists)
                }
                SettingsLabeledRow(label: "Advanced", detail: "Lists, your own rules and sites with blocking off") {
                    Button("Advanced…") { showsAdvanced = true }
                }
            }
        }
        .sheet(isPresented: $showsAdvanced) {
            ContentBlockingAdvancedView(model: model, profileID: profile.id)
        }
    }
}

/// Advanced: each list on or off, the profile's own rules, and the sites
/// blocking is off for, each with a remove button.
struct ContentBlockingAdvancedView: View {
    let model: BrowserViewModel
    let profileID: Profile.ID
    @Environment(\.dismiss) private var dismiss
    @State private var rules = ""
    @State private var conversion = ContentBlockingRuleConverter.convert("")
    @State private var newException = ""
    @State private var exceptionRefused = false

    private var settings: ContentBlockingSettings { model.store.contentBlocking(for: profileID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            lists
            Divider()
            ownRules
            Divider()
            exceptions
            HStack {
                Spacer()
                Button("Done") {
                    model.setContentBlockingOwnRules(rules, for: profileID)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .onAppear {
            rules = settings.ownRules
            conversion = ContentBlockingRuleConverter.convert(rules)
        }
        .onChange(of: rules) { _, text in conversion = ContentBlockingRuleConverter.convert(text) }
    }

    private func title(_ text: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(text).font(.headline).accessibilityAddTraits(.isHeader)
            Text(note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lists: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Lists", note: "The level chooses the lists. A change here stays until you choose another level.")
            VStack(alignment: .leading, spacing: 5) {
                let rows = model.contentBlockingListRows
                ForEach(rows) { list in
                    Toggle(list.title, isOn: Binding(
                        get: { settings.isListEnabled(list.id, in: rows) },
                        set: { model.setContentBlockingList(list.id, enabled: $0, for: profileID) }
                    ))
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var ownRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Your own rules", note: "One filter a line, in the lists’ syntax: ||ads.example.com^ blocks a host, "
                + "@@||example.com^ allows one. Up to \(ContentBlockingRuleConverter.maxRules) rules. They take effect when you press Done.")
            TextEditor(text: $rules)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.3)))
                .accessibilityLabel("Your own rules")
            Text(conversion.summary).font(.callout).foregroundStyle(.secondary)
            ForEach(conversion.dropped.prefix(3), id: \.line) { dropped in
                Text("Line \(dropped.line): \(dropped.reason.text)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var exceptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Sites with blocking off", note: "Darni blocks nothing on these sites. Add one here, or from a site’s controls beside the address.")
            if settings.exceptions.isEmpty {
                Text("No sites yet.").foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(settings.exceptions, id: \.self) { host in
                            HStack {
                                Text(host).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button { model.removeContentBlockingException(host, for: profileID) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Turn blocking back on for \(host)")
                                    .accessibilityLabel("Remove \(host)")
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            HStack(spacing: 8) {
                TextField("example.com", text: $newException)
                    .textFieldStyle(.roundedBorder)
                    .foregroundStyle(exceptionRefused ? Color.red : Color.primary)
                    .onSubmit(addException)
                    .onChange(of: newException) { _, _ in exceptionRefused = false }
                    .accessibilityLabel("Site to turn blocking off for")
                Button("Add", action: addException)
                    .disabled(newException.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addException() {
        guard !newException.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        if model.addContentBlockingException(newException, for: profileID) {
            newException = ""
        } else {
            exceptionRefused = true
        }
    }
}
