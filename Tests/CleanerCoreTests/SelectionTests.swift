import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct SelectionNatureClassifierTests {
    @Test func containerWithDocumentsIsExpandedAndUserData() throws {
        let fx = try Fixture()
        let url = try fx.makeContainer(bundleID: "com.example.notes", documents: 2)
        try fx.dir(url.appendingPathComponent("Data/Library/Saved Application State/x"))
        try fx.symlink(url.appendingPathComponent("Data/Desktop"), to: fx.home("Desktop"))
        let c = DataNatureClassifier().classify(Candidate(url: url, category: .container, confidence: .high))
        #expect(c.nature == .userData)
        let byRel = Dictionary(uniqueKeysWithValues: c.children.map { ($0.url.relativePath(from: url)!, $0) })
        #expect(byRel["Data/Documents"]?.nature == .userData)
        #expect(byRel["Data/Library/Caches"]?.nature == .regenerable)
        #expect(byRel["Data/Library/Preferences"]?.nature == .settings)
        #expect(byRel["Data/Library/Saved Application State"]?.nature == .regenerable)
        #expect(byRel["Data/Desktop"] == nil, "심볼릭 링크는 펼치지 않는다")
        #expect(c.children.allSatisfy { $0.category == .containerItem && $0.confidence == .high })
    }

    @Test func containerWithoutUserDataStaysSettings() throws {
        let fx = try Fixture()
        let url = try fx.makeContainer(bundleID: "com.example.calc")
        try fx.dir(url.appendingPathComponent("Data/Documents"))
        try fx.file(url.appendingPathComponent("Data/Documents/.DS_Store"))
        let c = DataNatureClassifier().classify(Candidate(url: url, category: .container, confidence: .high))
        #expect(c.nature == .settings)
        #expect(c.children.first { $0.url.lastPathComponent == "Documents" }?.nature == .regenerable)
    }

    @Test func containerApplicationSupportIsUserData() throws {
        let fx = try Fixture()
        let url = try fx.makeContainer(bundleID: "com.example.db", appSupportBytes: 512)
        let c = DataNatureClassifier().classify(Candidate(url: url, category: .container, confidence: .high))
        #expect(c.nature == .userData)
        #expect(c.children.first { $0.url.lastPathComponent == "Application Support" }?.nature == .userData)
    }

    @Test func groupContainerDatabases() throws {
        let fx = try Fixture()
        let g = fx.home("Library/Group Containers/ABCDE12345.shared")
        try fx.file(g.appendingPathComponent("Library/Caches/blob"))
        try fx.file(g.appendingPathComponent("Library/Preferences/ABCDE12345.shared.plist"))
        try fx.file(g.appendingPathComponent("Data/store.sqlite"))
        try fx.file(g.appendingPathComponent("Data/store.sqlite-wal"))
        try fx.file(g.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let c = DataNatureClassifier().classify(Candidate(url: g, category: .groupContainer, confidence: .high))
        #expect(c.nature == .userData)
        let names = Dictionary(uniqueKeysWithValues: c.children.map { ($0.url.lastPathComponent, $0.nature) })
        #expect(names["Data"] == .userData)
        #expect(names["Caches"] == .regenerable)
        #expect(names["Preferences"] == .settings)
        #expect(names[".com.apple.containermanagerd.metadata.plist"] == nil)

        let plain = fx.home("Library/Group Containers/ABCDE12345.cacheonly")
        try fx.file(plain.appendingPathComponent("Library/Caches/blob"))
        #expect(DataNatureClassifier().classify(Candidate(url: plain, category: .groupContainer, confidence: .high)).nature == .settings)
    }

    @Test func applicationSupportByNameSizeAndDocuments() throws {
        let fx = try Fixture()
        let classifier = DataNatureClassifier(largeDataThreshold: 32 * 1024)
        let big = try fx.file(fx.home("Library/Application Support/Big/blob.bin"), bytes: 64 * 1024).deletingLastPathComponent()
        let docs = try fx.file(fx.home("Library/Application Support/Docs/My Novel.docx")).deletingLastPathComponent()
        let small = try fx.file(fx.home("Library/Application Support/Small/config.json")).deletingLastPathComponent()
        let bidNamed = try fx.file(fx.home("Library/Application Support/com.example.big/blob.bin"), bytes: 64 * 1024).deletingLastPathComponent()
        func nature(_ u: URL) -> DataNature { classifier.classify(Candidate(url: u, category: .applicationSupport, confidence: .medium)).nature }
        #expect(nature(big) == .userData)
        #expect(nature(docs) == .userData)
        #expect(nature(small) == .settings)
        #expect(nature(bidNamed) == .settings)
    }

    @Test func iCloudIsSynced() {
        let c = DataNatureClassifier().classify(Candidate(url: URL(fileURLWithPath: "/tmp/x"), category: .iCloudContainer, confidence: .high))
        #expect(c.nature == .synced)
    }
}

@Suite struct SelectionPolicyTests {
    func setup() throws -> (Fixture, AppIdentity, SelectionPolicy) {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Microsoft Word", bundleID: "com.microsoft.Word")
        let id = AppIdentity(bundleURL: app, bundleID: "com.microsoft.Word", name: "Microsoft Word", teamID: "UBF8T346G9",
                             appGroups: ["UBF8T346G9.Office", "UBF8T346G9.ms"])
        return (fx, id, SelectionPolicy(paths: fx.paths, rules: ScanKit.provider()))
    }

    @Test func confidenceNatureAndProtectionDecideSelection() throws {
        let (fx, id, policy) = try setup()
        let cs = [
            Candidate(url: fx.home("Library/Caches/com.microsoft.Word"), category: .caches, confidence: .high),
            Candidate(url: fx.home("Library/Application Support/Microsoft Word"), category: .applicationSupport, confidence: .medium,
                      evidence: [Evidence(.name, .verbatim("이름"))]),
            Candidate(url: fx.home(".word"), category: .dotfile, confidence: .low, evidence: [Evidence(.name, .verbatim("이름"))]),
            Candidate(url: fx.home("Library/Application Support/Word Data"), category: .applicationSupport, confidence: .high, nature: .userData),
            Candidate(url: fx.root("Library/Extensions/Word.kext"), category: .kernelExtension, domain: .system, confidence: .high,
                      protection: .detectOnly),
            Candidate(url: fx.home("Library/Mobile Documents/iCloud~com~microsoft~Word"), category: .iCloudContainer, confidence: .high,
                      protection: .iCloudData),
        ]
        let out = policy.evaluate(cs, for: id, inventory: InventorySnapshot(apps: []))
        #expect(out[0].isSelected)
        #expect(out[1].isSelected, "Medium은 선택 유지 (ui-ux 결정 #2)")
        #expect(!out[2].isSelected)
        #expect(out[2].notes.contains(SelectionPolicy.Notes.lowName))
        #expect(!out[3].isSelected)
        #expect(out[3].notes.contains(SelectionPolicy.Notes.userData))
        #expect(!out[4].isSelected)
        #expect(!out[5].isSelected)
        #expect(out[5].notes.contains(SelectionPolicy.Notes.synced))
    }

    @Test func containerChildrenSelectedIndividually() throws {
        let (fx, id, policy) = try setup()
        let url = try fx.makeContainer(bundleID: "com.microsoft.Word", documents: 1)
        let classified = DataNatureClassifier().classify(Candidate(url: url, category: .container, confidence: .high))
        let out = policy.evaluate([classified], for: id, inventory: InventorySnapshot(apps: []))[0]
        #expect(!out.isSelected)
        #expect(out.children.first { $0.url.lastPathComponent == "Documents" }?.isSelected == false)
        #expect(out.children.first { $0.url.lastPathComponent == "Caches" }?.isSelected == true)
        #expect(out.children.first { $0.url.lastPathComponent == "Preferences" }?.isSelected == true)
        let move = [out].itemsToMove.map(\.url.lastPathComponent)
        #expect(Set(move) == ["Caches", "Preferences"])

        let clean = try fx.makeContainer(bundleID: "com.microsoft.Word.share")
        let c2 = policy.evaluate([DataNatureClassifier().classify(Candidate(url: clean, category: .container, confidence: .high))],
                                 for: id, inventory: InventorySnapshot(apps: []))[0]
        #expect(c2.isSelected)
        #expect([c2].itemsToMove.map(\.url) == [clean], "부모가 선택되면 부모만 옮긴다")
    }

    @Test func noInventoryLeavesSharedJudgementTargetsUnselected() throws {
        let (fx, id, policy) = try setup()
        let agent = try fx.makeLaunchPlist(at: fx.home("Library/LaunchAgents/com.microsoft.update.agent.plist"),
                                           label: "com.microsoft.update.agent",
                                           program: fx.root("Library/Application Support/Microsoft/MAU2.0/agent").path)
        let cs = [
            Candidate(url: fx.home("Library/Group Containers/UBF8T346G9.Office"), category: .groupContainer, confidence: .high),
            Candidate(url: fx.home("Library/Application Support/Microsoft"), category: .applicationSupport, confidence: .low),
            Candidate(url: agent, category: .launchAgent, confidence: .high),
            Candidate(url: fx.home("Library/Caches/com.microsoft.Word"), category: .caches, confidence: .high),
        ]
        let out = policy.evaluate(cs, for: id, inventory: nil)
        #expect(!out[0].isSelected)
        #expect(out[0].notes.contains(SelectionPolicy.Notes.inventoryUnknown))
        #expect(!out[1].isSelected)
        #expect(out[1].notes.contains(SelectionPolicy.Notes.inventoryUnknown))
        #expect(!out[2].isSelected)
        #expect(out[2].notes.contains(SelectionPolicy.Notes.inventoryUnknown))
        #expect(out[3].isSelected)
    }

    @Test func targetItselfIsNotCountedAsAnotherUser() throws {
        let (fx, id, policy) = try setup()
        let inv = InventorySnapshot(apps: [
            InventoryApp(url: id.bundleURL, bundleID: "com.microsoft.Word", name: "Microsoft Word", teamID: "UBF8T346G9",
                         appGroups: ["UBF8T346G9.Office"]),
        ])
        let gc = Candidate(url: fx.home("Library/Group Containers/UBF8T346G9.Office"), category: .groupContainer, confidence: .high)
        let out = policy.evaluate([gc], for: id, inventory: inv)[0]
        #expect(!out.share.isShared)
        #expect(out.isSelected)
    }

    @Test func lastAppOfVendorPromotesVendorFolder() throws {
        let (fx, id, policy) = try setup()
        let vendor = Candidate(url: fx.home("Library/Application Support/Microsoft"), category: .applicationSupport, confidence: .low,
                               evidence: [Evidence(.pathRule, .verbatim("벤더"))])
        let teamGroup = Candidate(url: fx.home("Library/Group Containers/UBF8T346G9.OneDriveSync"), category: .groupContainer,
                                  confidence: .low, evidence: [Evidence(.teamIdentifier, .verbatim("team"))])
        let out = policy.evaluate([vendor, teamGroup], for: id,
                                  inventory: InventorySnapshot(apps: [ScanKit.inventoryApp("Slack", bundleID: "com.tinyspeck.slackmacgap", teamID: "BQR82RBBHL", in: fx)]))
        #expect(out[0].confidence == .medium)
        #expect(out[0].isSelected)
        #expect(out[0].notes.contains(SelectionPolicy.Notes.lastOfVendor))
        #expect(out[1].confidence == .medium)
        #expect(out[1].isSelected)
    }

    @Test func usageNoteWording() {
        #expect(SelectionPolicy.usageNote(["Excel"]) == EngineText(.usedBy, "Excel"))
        #expect(SelectionPolicy.usageNote(["Excel"]).text == "Excel이 함께 사용 중")
        #expect(SelectionPolicy.usageNote(["Google Drive"]).text == "Google Drive가 함께 사용 중")
        #expect(SelectionPolicy.usageNote(["Microsoft Excel", "Microsoft PowerPoint"]) == EngineText(.usedByMore, "Microsoft Excel", "1"))
        #expect(SelectionPolicy.usageNote(["Microsoft Excel", "Microsoft PowerPoint"]).text == "Microsoft Excel 외 1개 앱이 함께 사용 중")
        #expect(SelectionPolicy.usageNote(["한글"]).text == "한글이 함께 사용 중")
        #expect(SelectionPolicy.usageNote(["카카오"]).text == "카카오가 함께 사용 중")
        #expect(SelectionPolicy.usageNote(["Excel"], vendor: .item).text == "Excel이 함께 사용 중일 수 있습니다 — 같은 개발사 공용 항목")
        #expect(SelectionPolicy.usageNote(["A", "B", "C"], vendor: .backgroundService).text
                == "A 외 2개 앱이 함께 사용 중일 수 있습니다 — 같은 개발사 공용 백그라운드 서비스")
    }
}
