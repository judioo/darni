import XCTest
@testable import SidebarModel

private func url(_ host: String) -> URL { URL(string: "https://\(host)/")! }

private func titles(_ entries: [SidebarEntry]) -> [String] {
    entries.map { entry in
        switch entry {
        case .tab(let tab): return tab.displayTitle
        case .folder(let folder): return "[\(folder.title): \(titles(folder.children).joined(separator: ", "))]"
        case .split: return "split"
        case .easel: return "easel"
        case .tabGroup(let reference): return "<\(reference.group.displayName): \(reference.group.tabs.map(\.displayTitle).joined(separator: ", "))>"
        }
    }
}

/// Home (a pinned tab, a Today tab) and Work, with the group "Reading"
/// (Docs, News; purple) pinned in Home and in Work's Today.
private struct GroupFixture {
    let store: SidebarStore
    let home: Space.ID
    let work: Space.ID
    let group: TabGroup.ID
    let homeRow: UUID
    let workRow: UUID
    let docs: Tab.ID
    let news: Tab.ID

    init() throws {
        store = SidebarStore(spaces: [Space(name: "Home", sortRank: "b")], mutationJournal: SidebarMutationJournal(deviceID: UUID()))
        home = store.spaces[0].id
        work = store.addSpace(name: "Work").id
        _ = store.addTab(kind: .pinned, title: "Pin", url: url("pin.test"), in: home)
        _ = store.addTab(kind: .today, title: "Scratch", url: url("scratch.test"), in: home)
        news = store.addTab(kind: .today, title: "News", url: url("news.test"), in: home).id
        docs = store.addTab(kind: .today, title: "Docs", url: url("docs.test"), in: home).id
        let row = try XCTUnwrap(store.createTabGroup(name: "Reading", color: .purple, in: home, containing: [docs, news]))
        group = row.groupID
        homeRow = row.id
        XCTAssertTrue(store.moveItem(row.id, to: .section(spaceID: home, section: .pinned), index: 0))
        workRow = try store.addTabGroup(group, to: work).get().id
    }
}

// MARK: - sidebar.json

final class TabGroupPersistenceTests: XCTestCase {
    private func reload(_ snapshot: SidebarSnapshot) throws -> SidebarStore {
        let data = try JSONEncoder().encode(snapshot)
        let store = SidebarStore()
        store.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: data))
        return store
    }

    func testGroupsAndTheirRowsRoundTrip() throws {
        let f = try GroupFixture()
        f.store.setTabGroupExpanded(f.workRow, false)
        let saved = f.store.makeSnapshot()
        let restored = try reload(saved)

        XCTAssertEqual(restored.tabGroup(withID: f.group), f.store.tabGroup(withID: f.group))
        XCTAssertEqual(titles(restored.content(for: f.home).pinned), ["<Reading: Docs, News>", "Pin"], "pinned, at its rank")
        XCTAssertEqual(titles(restored.content(for: f.home).today), ["Scratch"])
        XCTAssertEqual(titles(restored.content(for: f.work).today), ["<Reading: Docs, News>"])
        XCTAssertEqual(restored.tabGroupReference(ofGroup: f.group, in: f.home)?.id, f.homeRow, "the rows keep their ids")
        XCTAssertEqual(restored.tabGroupReference(ofGroup: f.group, in: f.work)?.id, f.workRow)
        XCTAssertTrue(restored.isTabGroupExpanded(f.homeRow))
        XCTAssertFalse(restored.isTabGroupExpanded(f.workRow), "open and closed is kept per row")
        XCTAssertEqual(restored.makeSnapshot().tabGroups, saved.tabGroups)
        XCTAssertEqual(restored.tabGroup(withID: f.group)?.color, .purple)
    }

    /// ReArc 2026.1117.849 kept a closed group's selected tab on show, so its
    /// file can have one selected. This build shows the blank page for it.
    func testAFileWithAClosedGroupsTabSelectedRestoresBlank() throws {
        let f = try GroupFixture()
        f.store.selectTab(f.news)
        f.store.selectSpace(f.work)
        f.store.selectTab(f.docs)
        var saved = f.store.makeSnapshot()
        XCTAssertEqual(saved.selectedItemID, f.docs)
        XCTAssertEqual(saved.selectionBySpace[f.home], f.news)
        saved.expandedFolderIDs = []

        let restored = try reload(saved)
        XCTAssertEqual(restored.activeSpaceID, f.work)
        XCTAssertNil(restored.selectedItemID, "blank, not the closed group's tab")
        XCTAssertNil(restored.selectedItemID(inSpace: f.home), "nor in the space that only remembered one")
        XCTAssertFalse(restored.isTabGroupExpanded(f.workRow), "the group stays closed")

        restored.setTabGroupExpanded(f.workRow, true)
        restored.setTabGroupExpanded(f.homeRow, true)
        XCTAssertNil(restored.selectedItemID, "opening the group selects nothing")
        XCTAssertNil(restored.selectedItemID(inSpace: f.home))
    }

    func testAnOpenGroupsSelectedTabRestoresSelected() throws {
        let f = try GroupFixture()
        f.store.selectTab(f.news)
        let restored = try reload(f.store.makeSnapshot())
        XCTAssertEqual(restored.selectedItemID, f.news)
        XCTAssertTrue(restored.isTabGroupExpanded(f.homeRow))
    }

    /// The file a build with tab groups writes also reads back without the
    /// stand-in folders: they never reach the store.
    func testTheStandInFoldersNeverReachTheStore() throws {
        let f = try GroupFixture()
        let saved = f.store.makeSnapshot()
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded.foldersByID, saved.foldersByID)
        XCTAssertEqual(decoded.tabsByID, saved.tabsByID)
        XCTAssertEqual(decoded.spaceContainers, saved.spaceContainers)
        XCTAssertEqual(decoded.tabGroups, saved.tabGroups)
        XCTAssertNil(decoded.tabsByID[f.docs], "a group's tabs are in its record, and only there")
    }

    /// A file from before tab groups: no `tabGroups` key, same schema version.
    func testAFileFromBeforeTabGroupsLoads() throws {
        let store = SidebarStore(spaces: [Space(name: "Home", sortRank: "b")])
        _ = store.addTab(kind: .pinned, title: "Pin", url: url("pin.test"))
        let data = try JSONEncoder().encode(store.makeSnapshot())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["tabGroups"], "a sidebar without groups writes no key, so its file is the old file")
        XCTAssertEqual(object["schemaVersion"] as? Int, 10, "the schema version did not move: an older build still reads the file")
        let restored = try reload(JSONDecoder().decode(SidebarSnapshot.self, from: data))
        XCTAssertTrue(restored.tabGroupsByID.isEmpty)
        XCTAssertEqual(titles(restored.content(for: restored.spaces[0].id).pinned), ["Pin"])
    }

    /// What a build from before tab groups reads of a file with groups: it
    /// skips the `tabGroups` key, so it sees each group as a pinned folder
    /// holding copies of the group's tabs, and keeps that folder when it
    /// writes the file back. Nothing else in the file changed.
    func testAnOlderBuildSeesEachGroupAsAPinnedFolderOfItsTabs() throws {
        let f = try GroupFixture()
        let data = try JSONEncoder().encode(f.store.makeSnapshot())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: "tabGroups"))
        let older = SidebarStore()
        older.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: JSONSerialization.data(withJSONObject: object)))

        XCTAssertEqual(titles(older.content(for: f.home).pinned), ["[Reading: Docs, News]", "Pin"], "where the group's pinned row is")
        XCTAssertEqual(titles(older.content(for: f.home).today), ["Scratch"])
        XCTAssertEqual(titles(older.content(for: f.work).today), [], "one folder per group, not one per space")
        let folder = try XCTUnwrap(SidebarTree.folders(older.content(for: f.home).pinned).first)
        let copies = SidebarTree.tabs(folder.children)
        XCTAssertEqual(copies.map(\.url), [url("docs.test"), url("news.test")])
        XCTAssertTrue(Set(copies.map(\.id)).isDisjoint(with: [f.docs, f.news]), "copies with ids of their own")
        XCTAssertNotEqual(folder.id, f.group)

        // The older build saves; this build reads that file: the folder is now a real one, and stays.
        let again = try reload(older.makeSnapshot())
        XCTAssertEqual(titles(again.content(for: f.home).pinned), ["[Reading: Docs, News]", "Pin"])
        XCTAssertTrue(again.tabGroupsByID.isEmpty)
    }

    func testAGroupShownNowhereIsStillRecoverableByAnOlderBuild() throws {
        let f = try GroupFixture()
        XCTAssertTrue(f.store.removeTabGroupReference(f.homeRow))
        XCTAssertTrue(f.store.removeTabGroupReference(f.workRow))
        let data = try JSONEncoder().encode(f.store.makeSnapshot())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["tabGroups"] = nil
        let older = SidebarStore()
        older.applySnapshot(try JSONDecoder().decode(SidebarSnapshot.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertEqual(titles(older.content(for: f.home).pinned), ["Pin", "[Reading: Docs, News]"], "in the first space of its profile")

        let restored = try reload(f.store.makeSnapshot())
        XCTAssertEqual(restored.tabGroup(withID: f.group)?.tabs.map(\.displayTitle), ["Docs", "News"])
        XCTAssertEqual(titles(restored.content(for: f.home).pinned), ["Pin"])
    }

    func testAGroupThisBuildCannotReadDoesNotFailTheFile() throws {
        let f = try GroupFixture()
        let data = try JSONEncoder().encode(f.store.makeSnapshot())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var groups = try XCTUnwrap(object["tabGroups"] as? [String: Any])
        var list = try XCTUnwrap(groups["groups"] as? [[String: Any]])
        list[0]["color"] = "ultraviolet"
        list.append(["id": "not a uuid"])
        groups["groups"] = list
        groups["version"] = 7
        object["tabGroups"] = groups
        let decoded = try JSONDecoder().decode(SidebarSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.tabGroups.groups.map(\.id), [f.group], "the row that does not read is left out; the others load")
        XCTAssertEqual(decoded.tabGroups.groups.first?.color, .grey, "a colour a newer ReArc added reads as grey")
        XCTAssertEqual(decoded.tabGroups.groups.first?.tabs.count, 2)
    }

    /// Sync's tidy-up of copies of one Arc space folds spaces and profiles
    /// together inside a snapshot (`ArcTwinSpaces`): groups follow.
    func testTidyingCopiesOfAnArcSpaceKeepsItsGroups() throws {
        let f = try GroupFixture()
        var snapshot = f.store.makeSnapshot()
        snapshot.fold(space: f.work, into: f.home)
        let merged = try reload(snapshot)
        XCTAssertEqual(merged.spaces(showingTabGroup: f.group).map(\.id), [f.home], "Work's row came along; Home keeps one")
        XCTAssertEqual(merged.tabGroup(withID: f.group)?.tabs.count, 2)

        var renamed = merged.makeSnapshot()
        let newID = UUID(), profile = UUID()
        renamed.rename(space: f.home, to: newID, profile: profile)
        let moved = try reload(renamed)
        XCTAssertEqual(moved.tabGroup(withID: f.group)?.profileID, profile, "a group only that space shows goes to its new profile")
        XCTAssertEqual(moved.spaces(showingTabGroup: f.group).map(\.id), [newID])

        var folded = moved.makeSnapshot()
        let into = f.store.profiles[0].id
        folded.fold(profile: profile, into: into, knownFavoriteURLs: [])
        let back = try reload(folded)
        XCTAssertEqual(back.tabGroup(withID: f.group)?.profileID, into)
        XCTAssertEqual(back.spaces(showingTabGroup: f.group).map(\.id), [newID])
        XCTAssertEqual(back.tabGroup(withID: f.group)?.tabs.map(\.displayTitle), ["Docs", "News"])
    }

    func testARowForAMissingSpaceOrAnotherProfileIsDroppedNotItsGroup() throws {
        let f = try GroupFixture()
        let other = f.store.addProfile(name: "Other")
        var snapshot = f.store.makeSnapshot()
        snapshot.tabGroups.references.append(.init(id: UUID(), groupID: f.group, spaceID: UUID(), pinned: true, sortRank: "m"))
        snapshot.tabGroups.references.append(.init(id: UUID(), groupID: f.group, spaceID: f.store.spaces(in: other.id)[0].id, pinned: false, sortRank: "m"))
        snapshot.tabGroups.references.append(.init(id: UUID(), groupID: f.group, spaceID: f.home, pinned: false, sortRank: "m"))
        let restored = try reload(snapshot)
        XCTAssertEqual(restored.spaces(showingTabGroup: f.group).map(\.id), [f.home, f.work])
        XCTAssertEqual(titles(restored.content(for: f.home).today), ["Scratch"], "one row per space")
        XCTAssertEqual(restored.tabGroup(withID: f.group)?.tabs.count, 2)
    }
}

// MARK: - iCloud sync

@MainActor
private final class SyncClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval = 1) { date = date.addingTimeInterval(seconds) }
}

@MainActor
private final class Mac {
    let store: SidebarStore
    let coordinator: SidebarSyncCoordinator
    let clock: SyncClock

    init(_ name: String, server: InMemorySyncServer, store: SidebarStore? = nil, clock: SyncClock) {
        self.clock = clock
        self.store = store ?? SidebarStore(mutationJournal: SidebarMutationJournal(deviceID: UUID()))
        self.store.now = { [clock] in clock.date }
        coordinator = SidebarSyncCoordinator(transport: server.transport(account: "alice"), stateStore: InMemorySyncStateStore(),
                                             deviceID: name, now: { [clock] in clock.date })
        coordinator.host = self.store
        coordinator.setEnabled(true)
    }

    func sync() async {
        clock.advance()
        _ = await coordinator.sync()
        clock.advance()
    }

    func edited() { coordinator.captureLocalChanges() }

    func space(_ name: String) -> Space.ID { store.spaces.first { $0.name == name }!.id }
}

@MainActor
final class TabGroupSyncTests: XCTestCase {
    private func item(_ id: UUID) -> String { SyncRecordKind.item.recordName(for: id) }

    func testAGroupItsTabsAndItsPinnedRowAreRecords() throws {
        let f = try GroupFixture()
        let records = SidebarSyncProjection.extract(f.store.makeSnapshot())

        XCTAssertEqual(SyncRecordKind.tabGroup.rawValue, "SidebarTabGroupRecord")
        let name = SyncRecordKind.tabGroup.recordName(for: f.group)
        XCTAssertEqual(name, "tabgroup_\(f.group.uuidString.lowercased())")
        XCTAssertEqual(SyncRecordKind.parse(recordName: name)?.kind, .tabGroup)
        let group = try XCTUnwrap(records[name])
        XCTAssertEqual(group.kind, .tabGroup)
        XCTAssertEqual(group.values, [
            "profileID": .string(f.store.activeProfileID.uuidString), "name": .string("Reading"), "color": .string("purple"),
        ])

        let docs = try XCTUnwrap(records[item(f.docs)])
        XCTAssertEqual(docs.kind, .item)
        XCTAssertEqual(docs.values["type"], .string("tab"))
        XCTAssertEqual(docs.values["parent"], .string("group:\(f.group.uuidString.lowercased())"))
        XCTAssertEqual(docs.values["space"], .null, "a group's tab belongs to no one space")
        XCTAssertEqual(docs.values["url"], .string("https://docs.test/"))
        let news = try XCTUnwrap(records[item(f.news)])
        XCTAssertLessThan(try XCTUnwrap(docs.values["sortRank"]?.stringValue), try XCTUnwrap(news.values["sortRank"]?.stringValue))

        let row = try XCTUnwrap(records[item(f.homeRow)])
        XCTAssertEqual(row.values["type"], .string("tabGroup"))
        XCTAssertEqual(row.values["parent"], .string("pinned:\(f.home.uuidString.lowercased())"))
        XCTAssertEqual(row.values["group"], .string(f.group.uuidString.lowercased()))
        XCTAssertNil(records[item(f.workRow)], "a Today row stays on this Mac, as Today tabs do")
    }

    func testAnotherMacGetsTheGroupAndItsPinnedRow() throws {
        let f = try GroupFixture()
        let stamp = SyncStamp(millis: 1_800_000_000_000, device: "a")
        let records = SidebarSyncProjection.extract(f.store.makeSnapshot()).mapValues { body in
            SyncRecordPayload(kind: body.kind, fields: body.values.mapValues { SyncField(value: $0, stamp: stamp) })
        }
        for (name, payload) in records {
            XCTAssertTrue(SidebarSyncProjection.canMaterialize(name, payload), name)
        }
        let other = SidebarStore(mutationJournal: SidebarMutationJournal(deviceID: UUID()))
        other.applySnapshot(SidebarSyncProjection.apply(records, onto: other.makeSnapshot()))

        XCTAssertEqual(other.tabGroup(withID: f.group)?.name, "Reading")
        XCTAssertEqual(other.tabGroup(withID: f.group)?.color, .purple)
        XCTAssertEqual(other.tabGroup(withID: f.group)?.tabs.map(\.id), [f.docs, f.news])
        XCTAssertEqual(other.tabGroup(withID: f.group)?.tabs.map(\.kind), [.today, .today])
        XCTAssertEqual(titles(other.content(for: f.home).pinned), ["<Reading: docs.test, news.test>", "Pin"],
                       "a synced tab's title is its host until this Mac loads it (RC-0.1.0-602 T-05)")
        XCTAssertEqual(other.tabGroupReference(ofGroup: f.group, in: f.home)?.id, f.homeRow)
        XCTAssertEqual(titles(other.content(for: f.work).today), [], "Work's Today row was the first Mac's own")
        XCTAssertEqual(other.tabGroupsAvailable(toAddIn: f.work).map(\.id), [f.group], "so here the command bar offers the group to Work")
        // Applying the same records again changes nothing.
        let once = other.makeSnapshot()
        other.applySnapshot(SidebarSyncProjection.apply(records, onto: once))
        XCTAssertEqual(other.makeSnapshot().tabGroups, once.tabGroups)
        XCTAssertEqual(SidebarSyncProjection.extract(other.makeSnapshot()).keys.sorted(), records.keys.sorted())
    }

    func testThisMacsTodayRowAndTabStateSurviveASync() throws {
        let f = try GroupFixture()
        f.store.updateTabInStore(f.docs) { $0.isUnread = true }
        f.store.updateTab(f.news, title: "Front page", url: url("news.test/#top"))
        let stamp = SyncStamp(millis: 1_800_000_000_000, device: "a")
        let records = SidebarSyncProjection.extract(f.store.makeSnapshot()).mapValues { body in
            SyncRecordPayload(kind: body.kind, fields: body.values.mapValues { SyncField(value: $0, stamp: stamp) })
        }
        XCTAssertEqual(records[item(f.news)]?.values["url"], .string("https://news.test/"), "the address goes without its fragment")
        f.store.applySnapshot(SidebarSyncProjection.apply(records, onto: f.store.makeSnapshot()))
        XCTAssertEqual(titles(f.store.content(for: f.work).today), ["<Reading: Docs, Front page>"], "the Today row and the live titles stay")
        XCTAssertEqual(f.store.tab(withID: f.news)?.url, url("news.test/#top"))
        XCTAssertEqual(f.store.tab(withID: f.docs)?.isUnread, true)
        XCTAssertTrue(f.store.isTabGroupExpanded(f.homeRow))
        XCTAssertTrue(f.store.isTabGroupExpanded(f.workRow))
    }

    func testEditsAndADeleteTravelBetweenTwoMacs() async throws {
        let server = InMemorySyncServer()
        let clock = SyncClock()
        let f = try GroupFixture()
        let a = Mac("mac-a", server: server, store: f.store, clock: clock)
        await a.sync()
        let b = Mac("mac-b", server: server, clock: clock)
        await b.sync()
        XCTAssertEqual(b.store.tabGroup(withID: f.group)?.tabs.map(\.id), [f.docs, f.news])
        XCTAssertEqual(titles(b.store.content(for: b.space("Home")).pinned).first, "<Reading: docs.test, news.test>")

        // B renames the group, recolours it and adds a tab; A closes one.
        b.store.renameTabGroup(f.group, to: "Later")
        b.store.setTabGroupColor(.cyan, for: f.group)
        let wiki = try XCTUnwrap(b.store.addTab(toGroup: f.group, title: "Wiki", url: url("wiki.test")))
        b.edited()
        a.store.closeTab(f.news)
        a.edited()
        await b.sync()
        await a.sync()
        await b.sync()
        for mac in [a, b] {
            XCTAssertEqual(mac.store.tabGroup(withID: f.group)?.name, "Later")
            XCTAssertEqual(mac.store.tabGroup(withID: f.group)?.color, .cyan)
            XCTAssertEqual(mac.store.tabGroup(withID: f.group)?.tabs.map(\.id), [f.docs, wiki.id], "both edits, merged tab by tab")
        }
        XCTAssertEqual(titles(a.store.content(for: f.work).today), ["<Later: Docs, wiki.test>"], "A's Today row follows the shared group")

        // B shows the group in Work's Today; that row is B's own.
        _ = try b.store.addTabGroup(f.group, to: b.space("Work")).get()
        b.edited()
        // A deletes the group: it goes from B too, and B's open tabs of it go to B's archive.
        XCTAssertEqual(a.store.deleteTabGroup(f.group).count, 2)
        a.edited()
        await a.sync()
        await b.sync()
        XCTAssertNil(b.store.tabGroup(withID: f.group))
        XCTAssertEqual(titles(b.store.content(for: b.space("Home")).pinned), ["Pin"])
        XCTAssertEqual(titles(b.store.content(for: b.space("Work")).today), [])
        XCTAssertEqual(Set(b.store.archivedTabs.map(\.id)), [f.docs, wiki.id], "closed here as Delete Group closes them: into the archive")
        await a.sync()
        XCTAssertNil(a.store.tabGroup(withID: f.group), "and it does not come back")
    }

    func testARowPinnedOnAnotherMacReplacesThisMacsTodayRow() throws {
        let f = try GroupFixture()
        let stamp = SyncStamp(millis: 1_800_000_000_000, device: "a")
        var records = SidebarSyncProjection.extract(f.store.makeSnapshot()).mapValues { body in
            SyncRecordPayload(kind: body.kind, fields: body.values.mapValues { SyncField(value: $0, stamp: stamp) })
        }
        // Another Mac pinned the group in Work, and (a bad record) once more.
        let pinned = UUID(), twice = UUID()
        for (id, rank) in [(pinned, "m"), (twice, "n")] {
            records[item(id)] = SyncRecordPayload(kind: .item, fields: [
                "type": SyncField(value: .string("tabGroup"), stamp: stamp),
                "parent": SyncField(value: .string("pinned:\(f.work.uuidString.lowercased())"), stamp: stamp),
                "space": SyncField(value: .string(f.work.uuidString.lowercased()), stamp: stamp),
                "sortRank": SyncField(value: .string(rank), stamp: stamp),
                "group": SyncField(value: .string(f.group.uuidString.lowercased()), stamp: stamp),
            ])
        }
        f.store.applySnapshot(SidebarSyncProjection.apply(records, onto: f.store.makeSnapshot()))
        XCTAssertEqual(titles(f.store.content(for: f.work).pinned), ["<Reading: Docs, News>"], "one row per space")
        XCTAssertEqual(titles(f.store.content(for: f.work).today), [])
        XCTAssertEqual(f.store.tabGroupReference(ofGroup: f.group, in: f.work)?.id, pinned, "the first by rank is the row")
    }

    func testAGroupOfAProfileThatIsGoneIsNotShown() throws {
        let f = try GroupFixture()
        let stamp = SyncStamp(millis: 1_800_000_000_000, device: "a")
        var records = SidebarSyncProjection.extract(f.store.makeSnapshot()).mapValues { body in
            SyncRecordPayload(kind: body.kind, fields: body.values.mapValues { SyncField(value: $0, stamp: stamp) })
        }
        let name = SyncRecordKind.tabGroup.recordName(for: f.group)
        records[name]?.fields["profileID"] = SyncField(value: .string(UUID().uuidString), stamp: stamp)
        let applied = SidebarSyncProjection.apply(records, onto: f.store.makeSnapshot(), now: Date(timeIntervalSince1970: 1_800_000_100))
        XCTAssertTrue(applied.tabGroups.isEmpty)
        XCTAssertEqual(Set(applied.archivedTabs.map(\.id)), [f.docs, f.news], "this Mac's tabs of it are archived, not dropped")

        records[name]?.fields["profileID"] = SyncField(value: .number(4), stamp: stamp)
        XCTAssertFalse(SidebarSyncProjection.canMaterialize(name, try XCTUnwrap(records[name])), "left alone, never tombstoned")
    }

    func testAProfilesRecordsIncludeItsGroups() throws {
        let f = try GroupFixture()
        let other = f.store.addProfile(name: "Other")
        let snapshot = f.store.makeSnapshot()
        let mine = SidebarSyncCoordinator.records(of: [f.store.profiles[0].id], in: snapshot)
        XCTAssertTrue(mine.contains(SyncRecordKind.tabGroup.recordName(for: f.group)))
        XCTAssertTrue(mine.contains(item(f.docs)))
        XCTAssertTrue(mine.contains(item(f.homeRow)))
        let theirs = SidebarSyncCoordinator.records(of: [other.id], in: snapshot)
        XCTAssertFalse(theirs.contains(SyncRecordKind.tabGroup.recordName(for: f.group)))
        XCTAssertFalse(theirs.contains(item(f.docs)))
    }

    func testDeletingAProfileFromICloudDeletesItsGroups() throws {
        let f = try GroupFixture()
        let stamp = SyncStamp(millis: 1_800_000_000_000, device: "a")
        let wires = SidebarSyncProjection.extract(f.store.makeSnapshot()).map { name, body in
            (name, SyncWireRecord(recordName: name, payload: SyncRecordPayload(kind: body.kind, fields: body.values.mapValues { SyncField(value: $0, stamp: stamp) })))
        }
        let deletion = try XCTUnwrap(CloudProfileDeletion(profileID: f.store.profiles[0].id, in: Dictionary(uniqueKeysWithValues: wires)))
        XCTAssertEqual(deletion.changes[SyncRecordKind.tabGroup.recordName(for: f.group)], .delete)
        XCTAssertEqual(deletion.changes[item(f.docs)], .delete)
        XCTAssertEqual(deletion.changes[item(f.news)], .delete)
        XCTAssertEqual(deletion.changes[item(f.homeRow)], .delete)
    }
}
