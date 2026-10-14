import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 앱 제거 시 **선택되면 안 되는** 공유 리소스 (plan.md 4.3.2, 9장)
@Suite struct SharedResourceTests {
    @Test func officeGroupContainerSharedWithExcelAndPowerPoint() async throws {
        let fx = try Fixture()
        let word = try fx.makeApp(name: "Microsoft Word", bundleID: "com.microsoft.Word")
        let sig = StubSignatureReader()
        sig.set(SigningInfo(teamID: "UBF8T346G9", appGroups: ["UBF8T346G9.Office", "UBF8T346G9.ms", "UBF8T346G9.WordOnly"]), for: word)
        let office = try fx.file(fx.home("Library/Group Containers/UBF8T346G9.Office/MicrosoftRegistrationDB.reg"), bytes: 2048)
            .deletingLastPathComponent()
        let ms = try fx.dir(fx.home("Library/Group Containers/UBF8T346G9.ms/Library/Caches"))
            .deletingLastPathComponent().deletingLastPathComponent()
        let wordOnly = try fx.dir(fx.home("Library/Group Containers/UBF8T346G9.WordOnly/Library/Caches"))
            .deletingLastPathComponent().deletingLastPathComponent()
        let oneDrive = try fx.dir(fx.home("Library/Group Containers/UBF8T346G9.OneDriveStandaloneSuite"))
        let container = try fx.makeContainer(bundleID: "com.microsoft.Word")
        // 그룹 이름으로 찾은 Application Scripts도 Group Container와 같은 공유 판정을 받아야 한다 (실기기 회귀)
        let officeScripts = try fx.dir(fx.home("Library/Application Scripts/UBF8T346G9.Office"))
        let wordOnlyScripts = try fx.dir(fx.home("Library/Application Scripts/UBF8T346G9.WordOnly"))

        let inventory = InventorySnapshot(apps: [
            ScanKit.inventoryApp("Microsoft Word", bundleID: "com.microsoft.Word", teamID: "UBF8T346G9",
                                 groups: ["UBF8T346G9.Office", "UBF8T346G9.ms", "UBF8T346G9.WordOnly"], in: fx),
            ScanKit.inventoryApp("Microsoft Excel", bundleID: "com.microsoft.Excel", teamID: "UBF8T346G9",
                                 groups: ["UBF8T346G9.Office", "UBF8T346G9.ms"], in: fx),
            ScanKit.inventoryApp("Microsoft PowerPoint", bundleID: "com.microsoft.Powerpoint", teamID: "UBF8T346G9",
                                 groups: ["UBF8T346G9.Office"], in: fx),
        ])
        let report = try await ScanKit.scanner(fx, signatures: sig).scan(appAt: word, inventory: inventory)
        let c = report.candidates

        let o = try #require(c.item(office))
        #expect(!o.isSelected)
        #expect(o.share.usedBy == ["Microsoft Excel", "Microsoft PowerPoint"])
        #expect(o.notes.contains(EngineText(.usedByMore, "Microsoft Excel", "1")))
        #expect(o.children.allSatisfy { !$0.isSelected && $0.share.isShared })

        let m = try #require(c.item(ms))
        #expect(!m.isSelected)
        #expect(m.share.usedBy == ["Microsoft Excel"])
        #expect(m.notes.contains(EngineText(.usedBy, "Microsoft Excel")))

        // Word만 쓰는 그룹은 단독 소유
        let w = try #require(c.item(wordOnly))
        #expect(!w.share.isShared)
        #expect(w.isSelected)

        // entitlements에 없는 `<TEAM>.` 그룹 + 같은 Team 앱이 남아 있음 → 공유
        let od = try #require(c.item(oneDrive))
        #expect(od.share.isShared)
        #expect(!od.isSelected)

        let os = try #require(c.item(officeScripts))
        #expect(os.share.isShared)
        #expect(!os.isSelected)
        #expect(c.item(wordOnlyScripts)?.isSelected == true)

        #expect(c.item(container)?.isSelected == true)
        #expect(c.item(word)?.isSelected == true)
    }

    @Test func chromeKeystoneAgentSharedWithGoogleDrive() async throws {
        let fx = try Fixture()
        let chrome = try fx.makeApp(name: "Google Chrome", bundleID: "com.google.Chrome")
        let sig = StubSignatureReader()
        sig.set(SigningInfo(teamID: "EQHXZ8M8AV"), for: chrome)
        let keystoneDir = try fx.dir(fx.home("Library/Google/GoogleSoftwareUpdate"))
        let agentExe = try fx.file(keystoneDir.appendingPathComponent(
            "GoogleSoftwareUpdate.bundle/Contents/Resources/GoogleSoftwareUpdateAgent.app/Contents/MacOS/GoogleSoftwareUpdateAgent"), bytes: 64)
        let agent = try fx.makeLaunchPlist(at: fx.home("Library/LaunchAgents/com.google.keystone.agent.plist"),
                                           label: "com.google.keystone.agent",
                                           arguments: [agentExe.path, "-runMode", "ifneeded"], keepAlive: true)
        let chromeSupport = try fx.dir(fx.home("Library/Application Support/Google/Chrome/Default"))
            .deletingLastPathComponent()
        let caches = try fx.dir(fx.home("Library/Caches/com.google.Chrome"))
        let cask = HomebrewCask(token: "google-chrome", names: ["Google Chrome"], apps: ["Google Chrome.app"],
                                bundleIDs: ["com.google.Chrome", "com.google.keystone.agent", "com.google.keystone.daemon"],
                                zap: ["~/Library/Application Support/Google/Chrome", "~/Library/Caches/com.google.Chrome",
                                      "~/Library/Google/GoogleSoftwareUpdate", "~/Library/LaunchAgents/com.google.keystone.agent.plist"])
        let inventory = InventorySnapshot(apps: [
            ScanKit.inventoryApp("Google Chrome", bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV", in: fx),
            ScanKit.inventoryApp("Google Drive", bundleID: "com.google.drivefs", teamID: "EQHXZ8M8AV", in: fx),
        ])
        let report = try await ScanKit.scanner(fx, signatures: sig, casks: [cask]).scan(appAt: chrome, inventory: inventory)
        let c = report.candidates

        let a = try #require(c.item(agent))
        #expect(a.category == .launchAgent)
        #expect(a.share.isShared)
        #expect(a.share.usedBy == ["Google Drive"])
        #expect(!a.isSelected)
        let k = try #require(c.item(keystoneDir))
        #expect(k.share.isShared)
        #expect(!k.isSelected)
        // Chrome 고유 항목은 그대로 선택
        #expect(c.item(chromeSupport)?.isSelected == true)
        #expect(c.item(caches)?.isSelected == true)

        // Google Drive가 없으면(마지막 Google 앱) 공용 업데이터도 함께 정리
        let alone = InventorySnapshot(apps: [ScanKit.inventoryApp("Google Chrome", bundleID: "com.google.Chrome", teamID: "EQHXZ8M8AV", in: fx)])
        let r2 = try await ScanKit.scanner(fx, signatures: sig, casks: [cask]).scan(appAt: chrome, inventory: alone)
        #expect(r2.candidates.item(agent)?.isSelected == true)
        #expect(r2.candidates.item(keystoneDir)?.isSelected == true)
    }

    @Test func vendorFolderWithSameTeamAppIsShared() async throws {
        let fx = try Fixture()
        let chrome = try fx.makeApp(name: "Google Chrome", bundleID: "com.google.Chrome")
        let sig = StubSignatureReader()
        sig.set(SigningInfo(teamID: "EQHXZ8M8AV"), for: chrome)
        let vendor = try fx.dir(fx.home("Library/Application Support/Google/DriveFS")).deletingLastPathComponent()
        let chromeDir = try fx.dir(fx.home("Library/Application Support/Google/Chrome"))
        let inventory = InventorySnapshot(apps: [
            ScanKit.inventoryApp("Google Drive", bundleID: "com.google.drivefs", teamID: "EQHXZ8M8AV", in: fx),
        ])
        let report = try await ScanKit.scanner(fx, signatures: sig).scan(appAt: chrome, inventory: inventory)
        let v = try #require(report.candidates.item(vendor))
        #expect(v.share.isShared)
        #expect(!v.isSelected)
        #expect(v.notes.contains { $0.text.contains("Google Drive가 함께 사용 중일 수 있습니다") })
        #expect(report.candidates.item(chromeDir)?.isSelected == true)

        // Team ID가 달라도 BID 벤더 접두사(com.google.)가 같은 앱이 있으면 공유로 본다
        let other = InventorySnapshot(apps: [
            ScanKit.inventoryApp("Android Studio", bundleID: "com.google.android.studio", teamID: "ZZZZZ99999", in: fx),
        ])
        let r3 = try await ScanKit.scanner(fx, signatures: sig).scan(appAt: chrome, inventory: other)
        #expect(r3.candidates.item(vendor)?.share.usedBy == ["Android Studio"])
        #expect(r3.candidates.item(vendor)?.isSelected == false)

        // 마지막 Google 앱이면 벤더 폴더를 Medium으로 제시하고, 안의 Chrome 폴더는 상위와 함께 옮겨진다
        let r2 = try await ScanKit.scanner(fx, signatures: sig).scan(appAt: chrome, inventory: InventorySnapshot(apps: []))
        let v2 = try #require(r2.candidates.item(vendor))
        #expect(v2.confidence == .medium)
        #expect(v2.isSelected)
        let inner = try #require(r2.candidates.item(chromeDir))
        #expect(!inner.isSelected)
        #expect(r2.candidates.itemsToMove.map(\.url).contains(v2.url))
    }

    @Test func receiptFileOwnedByAnotherPackageIsExcluded() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Pkgd", bundleID: "com.example.pkgd")
        try fx.file(fx.root("usr/local/bin/pkgd"))
        try fx.file(fx.root("usr/local/bin/shared-tool"))
        let runner = DiscoveryReceiptTests.pkgutil(
            files: ["Applications/Pkgd.app", "usr", "usr/local", "usr/local/bin", "usr/local/bin/pkgd", "usr/local/bin/shared-tool"],
            owners: ["/usr/local/bin/shared-tool": ["com.example.pkgd", "com.other.tools"]])
        let report = try await ScanKit.scanner(fx, runner: runner).scan(appAt: app, inventory: InventorySnapshot(apps: []))
        #expect(report.identity.packageIDs == ["com.example.pkgd"])
        #expect(report.candidates.item(fx.root("usr/local/bin/pkgd"))?.isSelected == true)
        #expect(report.candidates.item(fx.root("usr/local/bin/shared-tool")) == nil)
        #expect(report.candidates.item(app)?.evidence.contains { $0.source == .receipt } == true)
    }

    @Test func containerUserDocumentsStayUnselected() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Writer Pro", bundleID: "com.example.writerpro")
        let container = try fx.makeContainer(bundleID: "com.example.writerpro", documents: 3)
        let report = try await ScanKit.scanner(fx).scan(appAt: app, inventory: InventorySnapshot(apps: []))
        let c = try #require(report.candidates.item(container))
        #expect(c.nature == .userData)
        #expect(!c.isSelected)
        let docs = try #require(c.children.first { $0.url.lastPathComponent == "Documents" })
        #expect(docs.nature == .userData)
        #expect(!docs.isSelected)
        let caches = try #require(c.children.first { $0.url.lastPathComponent == "Caches" })
        #expect(caches.isSelected)
        #expect(!report.candidates.itemsToMove.contains { $0.url.lastPathComponent == "Documents" })
    }

    @Test func iCloudContainerIsProtectedAndUnselectable() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Writer Pro", bundleID: "com.example.writerpro")
        let icloud = try fx.file(fx.home("Library/Mobile Documents/iCloud~com~example~writerpro/Documents/novel.txt"))
            .deletingLastPathComponent().deletingLastPathComponent()
        // 실제 SafetyGuard처럼 Mobile Documents를 보호 경로로 막아도 안내용 항목은 남는다
        let report = try await ScanKit.scanner(fx, safety: BlockingSafety(protectedPrefix: fx.home("Library/Mobile Documents")))
            .scan(appAt: app, inventory: InventorySnapshot(apps: []))
        let c = try #require(report.candidates.item(icloud))
        #expect(c.protection == .iCloudData)
        #expect(c.nature == .synced)
        #expect(!c.isSelected)
        #expect(!c.isSelectable)
        #expect(!report.candidates.selectedItems.contains { $0.url == c.url })
        #expect(!report.candidates.itemsToMove.contains { $0.url == c.url })
    }
}

/// 특정 경로 아래를 `.protectedPath`로 막는 테스트용 SafetyChecking
struct BlockingSafety: SafetyChecking {
    var protectedPrefix: URL?
    var appleBundlePath: URL?

    init(protectedPrefix: URL? = nil, appleBundlePath: URL? = nil) {
        self.protectedPrefix = protectedPrefix
        self.appleBundlePath = appleBundlePath
    }

    func verdict(for url: URL, bundleID: String?) -> SafetyVerdict {
        if let p = protectedPrefix, url.isInside(p) { return .blocked(.protectedPath, .verbatim("보호된 위치")) }
        if let a = appleBundlePath, url.isInside(a) { return .blocked(.appleBundle, .verbatim("Apple 항목이라 옮기지 않습니다")) }
        return .allowed(resolved: url)
    }
}
