import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 고아로 판정되면 안 되는 케이스 (plan.md 9장 "고아 스캔 오탐 테스트")
@Suite struct OrphanFalsePositiveTests {
    @Test func appExtensionContainerOfInstalledApp() async throws {
        let h = try OrphanHarness()
        try h.fx.makeApp(name: "Notes Plus", bundleID: "com.example.notesplus", embedded: [
            .init("Contents/PlugIns/Share.appex", bundleID: "com.example.notesplus.share"),
            // BID가 본체와 무관한 확장 (접두사로는 못 찾음 — 내장 번들 수집이 필요)
            .init("Contents/PlugIns/Widget.appex", bundleID: "net.widgetvendor.notewidget"),
        ])
        let share = try h.fx.makeContainer(bundleID: "com.example.notesplus.share")
        let widget = try h.fx.makeContainer(bundleID: "net.widgetvendor.notewidget")
        let report = try await h.scan()
        #expect(!report.contains(share))
        #expect(!report.contains(widget))
        #expect(report.groups.isEmpty)
    }

    @Test func smAppServiceEmbeddedLaunchServiceOfInstalledApp() async throws {
        let h = try OrphanHarness()
        try h.fx.makeApp(name: "Syncer", bundleID: "io.vendor.syncer", launchPlists: [
            ("Contents/Library/LaunchAgents/com.vendorsvc.syncd.plist", "com.vendorsvc.syncd", "Contents/MacOS/syncd"),
        ])
        // 등록된 서비스가 만든 데이터와, 번들 밖에 남은 BundleProgram 전용 plist
        let prefs = try h.fx.file(h.fx.home("Library/Preferences/com.vendorsvc.syncd.plist"))
        let caches = try h.fx.dir(h.fx.home("Library/Caches/com.vendorsvc.syncd"))
        let agent = try h.fx.plist(h.fx.home("Library/LaunchAgents/com.vendorsvc.syncd.plist"),
                                   ["Label": "com.vendorsvc.syncd", "BundleProgram": "Contents/MacOS/syncd"])
        let report = try await h.scan()
        #expect(!report.contains(prefs))
        #expect(!report.contains(caches))
        #expect(!report.contains(agent))
    }

    @Test func wrappedIOSAppContainerUsesInnerBundleID() async throws {
        let h = try OrphanHarness()
        try h.fx.makeApp(name: "Puzzle", bundleID: "com.example.puzzle.mac-wrapper", wrappedBundleID: "com.example.ios.puzzle")
        // iOS 앱 컨테이너는 UUID 폴더명 + 메타데이터의 내부 BID
        let uuidContainer = h.fx.home("Library/Containers/\(UUID().uuidString)")
        try h.fx.plist(uuidContainer.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"),
                       ["MCMMetadataIdentifier": "com.example.ios.puzzle"])
        try h.fx.file(uuidContainer.appendingPathComponent("Data/Library/Caches/x"))
        let report = try await h.scan()
        #expect(!report.contains(uuidContainer))
    }

    @Test func appsInNonStandardSubfolders() async throws {
        let h = try OrphanHarness()
        try h.fx.makeApp(name: "Focus", bundleID: "com.focuscorp.focus", in: h.fx.root("Applications/Setapp"))
        try h.fx.makeApp(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij", in: h.fx.home("Applications/JetBrains Toolbox"))
        let focusContainer = try h.fx.makeContainer(bundleID: "com.focuscorp.focus")
        let ideaCaches = try h.fx.dir(h.fx.home("Library/Caches/com.jetbrains.intellij"))
        let ideaSupport = try h.fx.dir(h.fx.home("Library/Application Support/JetBrains"))
        let ideaLogs = try h.fx.dir(h.fx.home("Library/Logs/IntelliJ IDEA"))
        let report = try await h.scan()
        for url in [focusContainer, ideaCaches, ideaSupport, ideaLogs] { #expect(!report.contains(url)) }
        #expect(report.spotlight.isReliable)
    }

    @Test func appOnDisconnectedExternalVolumeIsLowWithNote() async throws {
        let h = try OrphanHarness()
        let caches = try h.fx.dir(h.fx.home("Library/Caches/com.example.bigapp"))
        let container = try h.fx.makeContainer(bundleID: "com.example.bigapp")
        let lookup: LaunchServicesLookup = { bid in
            bid.hasPrefix("com.example.bigapp") ? [URL(fileURLWithPath: "/Volumes/Studio SSD/Apps/Big.app")] : []
        }
        let report = try await h.scan(launchServices: lookup)
        for url in [caches, container] {
            let item = try #require(report.item(url))
            #expect(item.confidence == .low)
            #expect(!item.isSelected)
            #expect(item.notes.contains("앱이 외장 볼륨에 있을 수 있음"))
        }
        #expect(report.group(containing: caches)?.notes.contains("앱이 외장 볼륨에 있을 수 있음") == true)
    }

    @Test func launchExecutableOnDisconnectedVolumeIsLow() async throws {
        let h = try OrphanHarness()
        let agent = try h.fx.makeLaunchPlist(at: h.fx.home("Library/LaunchAgents/com.example.render.agent.plist"),
                                             label: "com.example.render.agent",
                                             arguments: ["/Volumes/Work/Render.app/Contents/MacOS/agent"])
        let report = try await h.scan()
        let item = try #require(report.item(agent))
        #expect(item.confidence == .low)
        #expect(!item.isSelected)
        #expect(item.launchService?.label == "com.example.render.agent")
        #expect(item.notes.contains("앱이 외장 볼륨에 있을 수 있음"))
        #expect(item.evidence.contains { $0.detail.contains("연결 해제된 외장 볼륨") })
    }

    @Test func offlineVolumeAppRememberedByInventory() async throws {
        let h = try OrphanHarness()
        let volume = h.fx.root("Volumes/External")
        let ext = try h.fx.makeApp(name: "Ext", bundleID: "com.example.extapp", in: volume.appendingPathComponent("Applications"))
        h.addToSpotlight(ext)
        let prefs = try h.fx.file(h.fx.home("Library/Preferences/com.example.extapp.plist"))
        let mounted = try await h.scan()
        #expect(!mounted.contains(prefs))
        try FileManager.default.removeItem(at: volume)
        let unmounted = try await h.scan()
        let item = try #require(unmounted.item(prefs))
        #expect(item.confidence == .low)
        #expect(!item.isSelected)
    }

    @Test func vendorFolderSharedByInstalledAppOfSameVendor() async throws {
        let h = try OrphanHarness()
        try h.fx.makeApp(name: "Google Chrome", bundleID: "com.google.Chrome")
        let google = try h.fx.dir(h.fx.home("Library/Application Support/Google"))
        let googleCaches = try h.fx.dir(h.fx.home("Library/Caches/Google"))
        // 같은 벤더의 다른(삭제된) 앱 데이터는 남되 강등되어 선택되지 않는다
        let drive = try h.fx.dir(h.fx.home("Library/Caches/com.google.drivefs"))
        // 설치된 벤더 앱이 없는 공용 폴더 → Low + 경고
        let adobe = try h.fx.dir(h.fx.home("Library/Application Support/Adobe"))
        let report = try await h.scan()
        #expect(!report.contains(google))
        #expect(!report.contains(googleCaches))
        let driveItem = try #require(report.item(drive))
        #expect(driveItem.confidence == .low)
        #expect(!driveItem.isSelected)
        #expect(driveItem.notes.contains { $0.contains("Google Chrome") })
        let adobeItem = try #require(report.item(adobe))
        #expect(adobeItem.confidence == .low)
        #expect(!adobeItem.isSelected)
        #expect(adobeItem.notes.contains("여러 앱이 함께 쓰는 개발사 폴더일 수 있음"))
    }

    @Test func groupContainerOfSameTeamIsSharedAndUnselected() async throws {
        let h = try OrphanHarness()
        let word = try h.fx.makeApp(name: "Microsoft Word", bundleID: "com.microsoft.Word")
        let reader = StubSignatureReader()
        reader.set(SigningInfo(teamID: "UBF8T346G9", appGroups: ["UBF8T346G9.Office"]), for: word)
        let office = try h.fx.dir(h.fx.home("Library/Group Containers/UBF8T346G9.Office"))
        let oneNote = try h.fx.dir(h.fx.home("Library/Group Containers/UBF8T346G9.OneNoteSync"))
        let report = try await h.scan(signatures: reader)
        #expect(!report.contains(office))
        let item = try #require(report.item(oneNote))
        #expect(item.confidence == .low)
        #expect(item.share.isShared)
        #expect(item.share.usedBy == ["Microsoft Word"])
        #expect(!item.isSelected)
    }

    @Test func mobileSyncAndICloudAreAlwaysExcluded() async throws {
        let h = try OrphanHarness()
        let backup = try h.fx.file(h.fx.home("Library/Application Support/MobileSync/Backup/0000/Manifest.db"))
        let icloud = try h.fx.dir(h.fx.home("Library/Mobile Documents/iCloud~com~example~gone"))
        // 규칙 데이터가 비어 있어도(원격 데이터 변조 등) 제외된다
        for rules in [BundledRuleData.load(), RuleData.empty] {
            let report = try await h.scan(rules: rules)
            #expect(!report.allItems.contains { $0.path.contains("MobileSync") })
            #expect(!report.contains(backup.deletingLastPathComponent()))
            #expect(!report.allItems.contains { $0.path.contains("Mobile Documents") })
            #expect(!report.contains(icloud))
        }
    }

    @Test func appleSystemDataIsExcluded() async throws {
        let h = try OrphanHarness()
        var urls: [URL] = []
        for name in ["AddressBook", "CallHistoryDB", "CloudDocs", "Knowledge", "CrashReporter", "Dock", "FileProvider"] {
            urls.append(try h.fx.dir(h.fx.home("Library/Application Support/\(name)")))
        }
        urls.append(try h.fx.dir(h.fx.home("Library/Caches/com.apple.Safari")))
        urls.append(try h.fx.dir(h.fx.home("Library/Caches/routined")))
        urls.append(try h.fx.file(h.fx.home("Library/Preferences/com.apple.dock.plist")))
        urls.append(try h.fx.dir(h.fx.home("Library/Group Containers/group.com.apple.notes")))
        urls.append(try h.fx.dir(h.fx.home("Library/Group Containers/243LU875E5.groups.com.apple.podcasts")))
        urls.append(try h.fx.makeContainer(bundleID: "com.apple.mail"))
        urls.append(try h.fx.makeLaunchPlist(at: h.fx.root("Library/LaunchDaemons/com.apple.gone.plist"), label: "com.apple.gone",
                                             program: "/usr/libexec/gone"))
        urls.append(try h.fx.dir(h.fx.paths.userCacheDir.appendingPathComponent("com.apple.nsurlsessiond")))
        let report = try await h.scan()
        for url in urls { #expect(!report.contains(url), "\(url.lastPathComponent)") }
        #expect(report.groups.isEmpty)
    }

    @Test func cliDotfilesExcludedByDefaultAndSecurityDotfilesAlways() async throws {
        let h = try OrphanHarness()
        let npm = try h.fx.dir(h.fx.home(".npm"))
        let cargo = try h.fx.dir(h.fx.home(".cargo"))
        let ssh = try h.fx.file(h.fx.home(".ssh/id_ed25519"))
        let gnupg = try h.fx.dir(h.fx.home(".gnupg"))
        let aws = try h.fx.dir(h.fx.home(".aws"))
        let configTool = try h.fx.dir(h.fx.home(".config/sometool"))
        let byDefault = try await h.scan()
        #expect(byDefault.groups.isEmpty)

        let withDotfiles = try await h.scan(options: OrphanScanOptions(includeDotfiles: true))
        for url in [npm, cargo, configTool] {
            let item = try #require(withDotfiles.item(url))
            #expect(item.confidence == .low)
            #expect(item.category == .dotfile)
            #expect(!item.isSelected)
        }
        for url in [ssh.deletingLastPathComponent(), gnupg, aws] { #expect(!withDotfiles.contains(url)) }
    }

    @Test func recentlyModifiedItemIsDemoted() async throws {
        let h = try OrphanHarness()
        let container = try h.fx.makeContainer(bundleID: "com.example.active")
        let report = try await h.scan(now: { Date() })
        let item = try #require(report.item(container))
        #expect(item.confidence == .medium)
        #expect(!item.isSelected)
        #expect(item.notes.contains { $0.contains("최근에 수정됨") })

        // 7일 창 밖이면 그대로 High
        let later = try await h.scan()
        #expect(later.item(container)?.confidence == .high)
    }

    @Test func spotlightDisabledDemotesMediumToLowAndKeepsHigh() async throws {
        let h = try OrphanHarness()
        h.indexing = "Indexing disabled."
        let prefs = try h.fx.file(h.fx.home("Library/Preferences/com.example.maybe.plist"))
        let agent = try h.fx.makeLaunchPlist(at: h.fx.home("Library/LaunchAgents/com.example.broken.plist"),
                                             label: "com.example.broken", program: "/Applications/Broken.app/Contents/MacOS/b")
        let report = try await h.scan()
        #expect(!report.spotlight.isReliable)
        #expect(!report.spotlight.indexingEnabled)
        let p = try #require(report.item(prefs))
        #expect(p.confidence == .low)
        #expect(p.notes.contains("Spotlight 색인이 불완전해 신뢰도를 낮춤"))
        #expect(report.group(containing: prefs)?.notes.contains { $0.contains("Spotlight") } == true)
        let a = try #require(report.item(agent))
        #expect(a.confidence == .high)
        #expect(a.isSelected)
    }

    @Test func spotlightIncompleteAlsoDemotes() async throws {
        let h = try OrphanHarness()
        try h.fx.makeApp(name: "Hidden", bundleID: "com.example.hidden", in: h.fx.root("Applications/Tools"))
        h.hideFromSpotlight("Hidden.app")
        let prefs = try h.fx.file(h.fx.home("Library/Preferences/com.example.maybe.plist"))
        let report = try await h.scan()
        #expect(report.spotlight.indexingEnabled)
        #expect(!report.spotlight.complete)
        #expect(report.item(prefs)?.confidence == .low)
    }

    @Test func installedAppNamesAndExecutablesAreNotOrphans() async throws {
        let h = try OrphanHarness()
        try h.fx.makeApp(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode", executable: "Electron")
        try h.fx.makeApp(name: "Discord", bundleID: "com.hnc.Discord")
        let code = try h.fx.dir(h.fx.home("Library/Application Support/Code"))
        let vscode = try h.fx.dir(h.fx.home("Library/Application Support/Visual Studio Code"))
        let discord = try h.fx.dir(h.fx.home("Library/Application Support/discord"))
        let report = try await h.scan()
        #expect(!report.contains(vscode))
        #expect(!report.contains(discord))
        // "Code"는 설치 앱 이름이 아니므로 남지만 Low + 흔한 이름 경고, 미선택
        let item = try #require(report.item(code))
        #expect(item.confidence == .low)
        #expect(!item.isSelected)
        #expect(item.notes.contains("흔한 이름이라 다른 프로그램의 데이터일 수 있음"))
    }

    @Test func liveLaunchAgentOfCLIToolIsNotOrphan() async throws {
        let h = try OrphanHarness()
        let tool = try h.fx.file(h.fx.root("opt/homebrew/bin/syncthing"))
        let agent = try h.fx.makeLaunchPlist(at: h.fx.home("Library/LaunchAgents/homebrew.mxcl.syncthing.plist"),
                                             label: "homebrew.mxcl.syncthing", arguments: ["/opt/homebrew/bin/syncthing", "serve"])
        _ = tool
        let report = try await h.scan()
        #expect(!report.contains(agent))
    }

    @Test func launchServicesRegisteredAppIsNotOrphan() async throws {
        let h = try OrphanHarness()
        let elsewhere = try h.fx.makeApp(name: "Portable", bundleID: "com.example.portable", in: h.fx.home("Downloads"))
        let container = try h.fx.makeContainer(bundleID: "com.example.portable")
        let lookup: LaunchServicesLookup = { $0 == "com.example.portable" ? [elsewhere] : [] }
        let report = try await h.scan(launchServices: lookup)
        #expect(!report.contains(container))
    }

    @Test func ownDataIsExcluded() async throws {
        let h = try OrphanHarness()
        try h.fx.file(h.fx.paths.appDataDir.appendingPathComponent("keep-list.json"))
        let prefs = try h.fx.file(h.fx.home("Library/Preferences/\(SystemPaths.defaultSelfBundleID).plist"))
        let report = try await h.scan()
        #expect(!report.contains(h.fx.paths.appDataDir))
        #expect(!report.contains(prefs))
    }
}
