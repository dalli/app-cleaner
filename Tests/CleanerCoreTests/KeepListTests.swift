import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct KeepListTests {
    @Test func storePersistsAndDeduplicates() throws {
        let fx = try Fixture()
        let store = KeepListStore(paths: fx.paths)
        #expect(store.fileURL == fx.paths.appDataDir.appendingPathComponent("keep-list.json"))
        #expect(store.entries().isEmpty)
        store.add(KeepEntry(kind: .group, key: "bid:com.example.a", displayName: "A"))
        store.add(KeepEntry(kind: .item, key: "/tmp/x", displayName: "x"))
        store.add(KeepEntry(kind: .group, key: "bid:com.example.a", displayName: "A (다시)"))
        #expect(store.entries().count == 2)
        #expect(fx.exists(store.fileURL))

        let reopened = KeepListStore(paths: fx.paths)
        #expect(Set(reopened.entries().map(\.id)) == ["group:bid:com.example.a", "item:/tmp/x"])
        #expect(reopened.entries().first { $0.kind == .group }?.displayName == "A (다시)")
        reopened.remove(id: "group:bid:com.example.a")
        #expect(KeepListStore(paths: fx.paths).entries().map(\.id) == ["item:/tmp/x"])
    }

    @Test func storeIsThreadSafe() async throws {
        let fx = try Fixture()
        let store = KeepListStore(paths: fx.paths)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { store.add(KeepEntry(kind: .item, key: "/tmp/\(i)", displayName: "\(i)")) }
            }
        }
        #expect(store.entries().count == 50)
        #expect(KeepListStore(paths: fx.paths).entries().count == 50)
    }

    @Test func scanHidesKeptGroupsAndItemsAndCountsThem() async throws {
        let fx = try Fixture()
        let store = KeepListStore(paths: fx.paths)
        let h = try OrphanHarness(keepList: store)
        try h.fx.file(h.fx.home("Library/Preferences/com.acme.widget.plist"))
        try h.fx.dir(h.fx.home("Library/Caches/com.acme.widget"))
        let gadgetPrefs = try h.fx.file(h.fx.home("Library/Preferences/com.acme2.gadget.plist"))
        let gadgetCaches = try h.fx.dir(h.fx.home("Library/Caches/com.acme2.gadget"))

        let before = try await h.scan()
        #expect(before.groups.count == 2)
        #expect(before.hiddenByKeepList == 0)
        let widget = try #require(before.groups.first { $0.id == "bid:com.acme.widget" })

        store.add(KeepEntry(kind: .group, key: widget.id, displayName: widget.displayName))
        store.add(KeepEntry(kind: .item, key: gadgetPrefs.path, displayName: "prefs"))
        let after = try await h.scan()
        #expect(!after.groups.contains { $0.id == widget.id })
        #expect(!after.contains(gadgetPrefs))
        #expect(after.contains(gadgetCaches))
        #expect(after.hiddenByKeepList == 2)

        // 설정에서 해제하면 다시 보인다
        store.remove(id: "group:\(widget.id)")
        let restored = try await h.scan()
        #expect(restored.groups.contains { $0.id == widget.id })
        #expect(restored.hiddenByKeepList == 1)
    }

    @Test func groupLosingAllItemsDisappears() async throws {
        let h = try OrphanHarness(keepList: InMemoryKeepList())
        let prefs = try h.fx.file(h.fx.home("Library/Preferences/com.acme.solo.plist"))
        h.keepList.add(KeepEntry(kind: .item, key: prefs.path, displayName: "solo"))
        let report = try await h.scan()
        #expect(report.groups.isEmpty)
        #expect(report.hiddenByKeepList == 1)
    }
}
