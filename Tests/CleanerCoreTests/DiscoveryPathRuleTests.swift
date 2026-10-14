import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct DiscoveryPathRuleTests {
    func identity(_ fx: Fixture, name: String = "Foo Writer", bid: String = "com.example.foowriter", team: String? = "ABCDE12345",
                  groups: [String] = [], embedded: [String] = []) throws -> AppIdentity {
        let app = try fx.makeApp(name: name, bundleID: bid)
        return AppIdentity(bundleURL: app, bundleID: bid, name: name, teamID: team, appGroups: groups, embeddedBundleIDs: embedded)
    }

    func source(_ fx: Fixture) -> PathRuleSource { PathRuleSource(paths: fx.paths, rules: ScanKit.provider()) }

    @Test func bundleIDExactAndDotPrefixOnly() throws {
        let fx = try Fixture()
        let id = try identity(fx)
        let L = "Library"
        let hits = [
            "\(L)/Containers/com.example.foowriter", "\(L)/Caches/com.example.foowriter", "\(L)/Caches/com.example.foowriter.ShipIt",
            "\(L)/HTTPStorages/com.example.foowriter", "\(L)/HTTPStorages/com.example.foowriter.binarycookies",
            "\(L)/WebKit/com.example.foowriter", "\(L)/Cookies/com.example.foowriter.binarycookies",
            "\(L)/Saved Application State/com.example.foowriter.savedState", "\(L)/Application Support/com.example.foowriter",
            "\(L)/Application Scripts/com.example.foowriter", "\(L)/Logs/com.example.foowriter",
        ]
        for h in hits { try fx.dir(fx.home(h)) }
        try fx.file(fx.home("\(L)/Preferences/com.example.foowriter.plist"))
        try fx.file(fx.home("\(L)/Preferences/com.example.foowriter.helper.plist"))
        try fx.file(fx.home("\(L)/Preferences/ByHost/com.example.foowriter.0000-1111.plist"))
        // 점 경계 없는 접두사·다른 앱은 매칭 금지
        let misses = ["\(L)/Caches/com.example.foowriterpro", "\(L)/Caches/com.example", "\(L)/Containers/com.example.other"]
        for m in misses { try fx.dir(fx.home(m)) }
        try fx.file(fx.home("\(L)/Preferences/com.example.foowriterx.plist"))

        let found = try source(fx).candidates(for: id)
        for h in hits {
            let c = try #require(found.item(fx.home(h)), "\(h)")
            #expect(c.confidence == .high)
            #expect(c.domain == .user)
            #expect(c.evidence.contains { $0.source == .bundleIdentifier })
        }
        for m in misses { #expect(found.item(fx.home(m)) == nil, "\(m)") }
        #expect(found.item(fx.home("\(L)/Preferences/com.example.foowriterx.plist")) == nil)

        #expect(found.item(fx.home("\(L)/Containers/com.example.foowriter"))?.category == .container)
        #expect(found.item(fx.home("\(L)/Caches/com.example.foowriter.ShipIt"))?.category == .caches)
        let pref = try #require(found.item(fx.home("\(L)/Preferences/com.example.foowriter.plist")))
        #expect(pref.category == .preferences)
        #expect(pref.preferencesDomain == "com.example.foowriter")
        #expect(found.item(fx.home("\(L)/Preferences/com.example.foowriter.helper.plist"))?.preferencesDomain == "com.example.foowriter.helper")
        let byHost = try #require(found.item(fx.home("\(L)/Preferences/ByHost/com.example.foowriter.0000-1111.plist")))
        #expect(byHost.category == .byHostPreferences)
        #expect(found.item(fx.home("\(L)/Saved Application State/com.example.foowriter.savedState"))?.category == .savedState)
    }

    @Test func embeddedBundleIDsMatchToo() throws {
        let fx = try Fixture()
        let id = try identity(fx, embedded: ["com.example.foowriter.share", "net.thirdparty.helper"])
        try fx.dir(fx.home("Library/Containers/com.example.foowriter.share"))
        try fx.dir(fx.home("Library/Caches/net.thirdparty.helper"))
        let found = try source(fx).candidates(for: id)
        #expect(found.item(fx.home("Library/Containers/com.example.foowriter.share"))?.confidence == .high)
        // 다른 벤더 BID의 내장 번들은 Medium
        #expect(found.item(fx.home("Library/Caches/net.thirdparty.helper"))?.confidence == .medium)
    }

    @Test func nameMatchingIsExactCaseInsensitive() throws {
        let fx = try Fixture()
        let id = try identity(fx)
        try fx.dir(fx.home("Library/Application Support/foo writer"))
        try fx.dir(fx.home("Library/Caches/Foo Writer"))
        try fx.dir(fx.home("Library/Logs/Foo Writer"))
        try fx.dir(fx.home("Library/Application Support/Foo Writer Helper"))
        try fx.dir(fx.home("Library/Application Support/My Foo Writer"))
        try fx.dir(fx.root("Library/Application Support/Foo Writer"))
        let found = try source(fx).candidates(for: id)
        let a = try #require(found.item(fx.home("Library/Application Support/foo writer")))
        #expect(a.confidence == .medium)
        #expect(a.evidence.map(\.source) == [.name])
        #expect(found.item(fx.home("Library/Caches/Foo Writer"))?.confidence == .medium)
        #expect(found.item(fx.home("Library/Logs/Foo Writer"))?.category == .logs)
        #expect(found.item(fx.home("Library/Application Support/Foo Writer Helper")) == nil)
        #expect(found.item(fx.home("Library/Application Support/My Foo Writer")) == nil)
        let sys = try #require(found.item(fx.root("Library/Application Support/Foo Writer")))
        #expect(sys.domain == .system)
        #expect(sys.requiresAdmin)
    }

    @Test func weakNamesAreLow() throws {
        let fx = try Fixture()
        let id = try identity(fx, name: "Notes", bid: "com.example.mynotes")
        try fx.dir(fx.home("Library/Application Support/Notes"))
        let found = try source(fx).candidates(for: id)
        #expect(found.item(fx.home("Library/Application Support/Notes"))?.confidence == .low)
    }

    @Test func groupContainersByEntitlementAndTeamPrefix() throws {
        let fx = try Fixture()
        let id = try identity(fx, groups: ["ABCDE12345.foowriter"])
        try fx.dir(fx.home("Library/Group Containers/ABCDE12345.foowriter"))
        try fx.dir(fx.home("Library/Group Containers/ABCDE12345.com.example.foowriter"))
        try fx.dir(fx.home("Library/Group Containers/group.com.example.foowriter"))
        try fx.dir(fx.home("Library/Group Containers/ABCDE12345.vendorshared"))
        try fx.dir(fx.home("Library/Group Containers/ZZZZZ99999.foowriter"))
        try fx.dir(fx.home("Library/Application Scripts/ABCDE12345.foowriter"))
        let found = try source(fx).candidates(for: id)
        let own = try #require(found.item(fx.home("Library/Group Containers/ABCDE12345.foowriter")))
        #expect(own.confidence == .high)
        #expect(own.category == .groupContainer)
        #expect(own.evidence.first?.source == .appGroup)
        #expect(found.item(fx.home("Library/Group Containers/ABCDE12345.com.example.foowriter"))?.confidence == .high)
        #expect(found.item(fx.home("Library/Group Containers/group.com.example.foowriter"))?.confidence == .high)
        let vendor = try #require(found.item(fx.home("Library/Group Containers/ABCDE12345.vendorshared")))
        #expect(vendor.confidence == .low)
        #expect(vendor.evidence.first?.source == .teamIdentifier)
        #expect(found.item(fx.home("Library/Group Containers/ZZZZZ99999.foowriter")) == nil)
        #expect(found.item(fx.home("Library/Application Scripts/ABCDE12345.foowriter"))?.category == .applicationScripts)
    }

    @Test func iCloudContainerIsProtectedAndSynced() throws {
        let fx = try Fixture()
        let id = try identity(fx)
        try fx.dir(fx.home("Library/Mobile Documents/iCloud~com~example~foowriter/Documents"))
        let found = try source(fx).candidates(for: id)
        let c = try #require(found.item(fx.home("Library/Mobile Documents/iCloud~com~example~foowriter")))
        #expect(c.category == .iCloudContainer)
        #expect(c.protection == .iCloudData)
        #expect(c.nature == .synced)
        #expect(!c.isSelectable)
    }

    @Test func diagnosticReportsDotfilesAndTempDirs() throws {
        let fx = try Fixture()
        let id = try identity(fx, name: "Cursor", bid: "com.todesktop.230313mzl4w4u92")
        try fx.file(fx.home("Library/Logs/DiagnosticReports/Cursor-2026-01-01-101010.ips"))
        try fx.file(fx.home("Library/Logs/DiagnosticReports/Cursor_2026-01-01.crash"))
        try fx.file(fx.home("Library/Logs/DiagnosticReports/CursorX-2026.ips"))
        try fx.dir(fx.home(".cursor"))
        try fx.dir(fx.home(".config/Cursor"))
        try fx.dir(fx.home(".local/share/cursor"))
        try fx.dir(fx.home(".cache/cursor"))
        try fx.dir(fx.home(".cursor-tutor"))
        try fx.dir(fx.paths.userCacheDir.appendingPathComponent("com.todesktop.230313mzl4w4u92"))
        try fx.dir(fx.paths.userTempDir.appendingPathComponent("com.todesktop.230313mzl4w4u92.ShipIt"))
        let found = try source(fx).candidates(for: id)
        for rel in ["Library/Logs/DiagnosticReports/Cursor-2026-01-01-101010.ips", "Library/Logs/DiagnosticReports/Cursor_2026-01-01.crash"] {
            let c = try #require(found.item(fx.home(rel)))
            #expect(c.confidence == .low)
            #expect(c.category == .diagnosticReports)
        }
        #expect(found.item(fx.home("Library/Logs/DiagnosticReports/CursorX-2026.ips")) == nil)
        for rel in [".cursor", ".config/Cursor", ".local/share/cursor", ".cache/cursor"] {
            let c = try #require(found.item(fx.home(rel)), "\(rel)")
            #expect(c.confidence == .low)
            #expect(c.category == .dotfile)
        }
        #expect(found.item(fx.home(".cursor-tutor")) == nil)
        #expect(found.item(fx.paths.userCacheDir.appendingPathComponent("com.todesktop.230313mzl4w4u92"))?.category == .tempFiles)
        #expect(found.item(fx.paths.userTempDir.appendingPathComponent("com.todesktop.230313mzl4w4u92.ShipIt"))?.confidence == .high)
    }

    @Test func securityDotfilesNeverMatch() throws {
        let fx = try Fixture()
        let id = try identity(fx, name: "ssh", bid: "com.example.ssh")
        try fx.dir(fx.home(".ssh"))
        let found = try source(fx).candidates(for: id)
        #expect(found.item(fx.home(".ssh")) == nil)
    }

    @Test func pluginsAndKextsByInnerBundleID() throws {
        let fx = try Fixture()
        let id = try identity(fx)
        try fx.plist(fx.home("Library/QuickLook/FooWriter.qlgenerator/Contents/Info.plist"), ["CFBundleIdentifier": "com.example.foowriter.ql"])
        try fx.plist(fx.home("Library/QuickLook/Other.qlgenerator/Contents/Info.plist"), ["CFBundleIdentifier": "com.other.ql"])
        try fx.plist(fx.root("Library/Internet Plug-Ins/Foo.plugin/Contents/Info.plist"), ["CFBundleIdentifier": "com.example.foowriter.plugin"])
        try fx.plist(fx.home("Library/PreferencePanes/Foo.prefPane/Contents/Info.plist"), ["CFBundleIdentifier": "com.example.foowriter.prefpane"])
        try fx.plist(fx.root("Library/Extensions/FooDriver.kext/Contents/Info.plist"), ["CFBundleIdentifier": "com.example.foowriter.driver"])
        let found = try source(fx).candidates(for: id)
        #expect(found.item(fx.home("Library/QuickLook/FooWriter.qlgenerator"))?.category == .plugin)
        #expect(found.item(fx.home("Library/QuickLook/Other.qlgenerator")) == nil)
        #expect(found.item(fx.root("Library/Internet Plug-Ins/Foo.plugin"))?.domain == .system)
        #expect(found.item(fx.home("Library/PreferencePanes/Foo.prefPane")) != nil)
        let kext = try #require(found.item(fx.root("Library/Extensions/FooDriver.kext")))
        #expect(kext.category == .kernelExtension)
        #expect(kext.protection == .detectOnly)
        #expect(kext.domain == .system)
    }

    @Test func systemDomainBundleIDItems() throws {
        let fx = try Fixture()
        let id = try identity(fx)
        try fx.dir(fx.root("Library/Application Support/com.example.foowriter"))
        try fx.dir(fx.root("Library/Caches/com.example.foowriter"))
        try fx.file(fx.root("Library/Preferences/com.example.foowriter.plist"))
        try fx.dir(fx.root("Library/Logs/com.example.foowriter"))
        let found = try source(fx).candidates(for: id)
        for rel in ["Library/Application Support/com.example.foowriter", "Library/Caches/com.example.foowriter",
                    "Library/Preferences/com.example.foowriter.plist", "Library/Logs/com.example.foowriter"] {
            let c = try #require(found.item(fx.root(rel)), "\(rel)")
            #expect(c.domain == .system)
            #expect(c.confidence == .high)
        }
        #expect(found.item(fx.root("Library/Preferences/com.example.foowriter.plist"))?.preferencesDomain == "com.example.foowriter")
    }

    @Test func vendorFolderLowAndInnerAppFolder() throws {
        let fx = try Fixture()
        let id = try identity(fx, name: "Google Chrome", bid: "com.google.Chrome", team: "EQHXZ8M8AV")
        try fx.dir(fx.home("Library/Application Support/Google/Chrome/Default"))
        try fx.dir(fx.home("Library/Application Support/Google/DriveFS"))
        try fx.dir(fx.home("Library/Caches/Google/Chrome"))
        let found = try source(fx).candidates(for: id)
        let vendor = try #require(found.item(fx.home("Library/Application Support/Google")))
        #expect(vendor.confidence == .low)
        #expect(found.item(fx.home("Library/Application Support/Google/Chrome"))?.confidence == .medium)
        #expect(found.item(fx.home("Library/Caches/Google/Chrome"))?.confidence == .medium)
        #expect(found.item(fx.home("Library/Application Support/Google/DriveFS")) == nil)
    }
}
