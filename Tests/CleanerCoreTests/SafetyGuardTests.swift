import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct SafetyGuardTests {
    func reason(_ v: SafetyVerdict) -> ProtectionReason? {
        if case .blocked(let r, _) = v { return r }
        return nil
    }

    @Test func systemPathsAreProtected() throws {
        let fx = try Fixture()
        let guardian = SafetyGuard(paths: fx.paths)
        for p in ["System", "System/Library/CoreServices/Finder.app", "usr", "usr/bin/ls", "bin/sh", "sbin/launchd",
                  "private/var/db/dslocal", "private/var/db", "Library/Apple/System/x", "usr/local", ""] {
            #expect(reason(guardian.verdict(for: fx.root(p), bundleID: nil)) == .protectedPath, "/\(p)")
        }
        // /usr/local 아래는 허용, 영수증 파일은 허용 (pkgutil --forget 대상)
        #expect(guardian.verdict(for: fx.root("usr/local/bin/foo-tool"), bundleID: nil).isAllowed)
        #expect(guardian.verdict(for: fx.root("private/var/db/receipts/com.example.pkg.bom"), bundleID: nil).isAllowed)
        #expect(guardian.verdict(for: fx.root("private/var/db/receipts/com.example.pkg.plist"), bundleID: nil).isAllowed)
        #expect(!guardian.verdict(for: fx.root("private/var/db/receipts/other.txt"), bundleID: nil).isAllowed)
        #expect(!guardian.verdict(for: fx.root("private/var/db/receipts"), bundleID: nil).isAllowed)
        #expect(!guardian.verdict(for: fx.root("private/var/db/receipts/x/y.plist"), bundleID: nil).isAllowed)
        // 픽스처 루트를 품은 상위 폴더, 실제 "/"
        #expect(!guardian.verdict(for: fx.base, bundleID: nil).isAllowed)
        #expect(!guardian.verdict(for: URL(fileURLWithPath: "/"), bundleID: nil).isAllowed)
    }

    @Test func everyCategoryRootIsProtectedButItsChildrenAreNot() throws {
        let fx = try Fixture()
        let guardian = SafetyGuard(paths: fx.paths)
        let homeRoots = ["", "Library", "Applications", "Documents", "Desktop", "Downloads",
                         "Library/Containers", "Library/Group Containers", "Library/Application Support",
                         "Library/Application Scripts", "Library/Caches", "Library/HTTPStorages", "Library/WebKit",
                         "Library/Cookies", "Library/Preferences", "Library/Preferences/ByHost", "Library/Saved Application State",
                         "Library/Logs", "Library/Logs/DiagnosticReports", "Library/LaunchAgents", "Library/Internet Plug-Ins",
                         "Library/QuickLook", "Library/Services", "Library/PreferencePanes", "Library/Spotlight",
                         ".config", ".local/share", ".cache"]
        for rel in homeRoots {
            #expect(reason(guardian.verdict(for: fx.home(rel), bundleID: nil)) == .protectedPath, "~/\(rel)")
            if !rel.isEmpty {
                #expect(guardian.verdict(for: fx.home(rel).appendingPathComponent("com.example.foo"), bundleID: nil).isAllowed, "~/\(rel)/child")
            }
        }
        let systemRoots = ["Applications", "Library", "Library/Application Support", "Library/Caches", "Library/Preferences",
                           "Library/Logs", "Library/LaunchAgents", "Library/LaunchDaemons", "Library/PrivilegedHelperTools",
                           "Library/Extensions", "Library/Internet Plug-Ins"]
        for rel in systemRoots {
            #expect(reason(guardian.verdict(for: fx.root(rel), bundleID: nil)) == .protectedPath, "/\(rel)")
            #expect(guardian.verdict(for: fx.root(rel).appendingPathComponent("com.example.foo"), bundleID: nil).isAllowed, "/\(rel)/child")
        }
        for dir in [fx.paths.userCacheDir, fx.paths.userTempDir] {
            #expect(!guardian.verdict(for: dir, bundleID: nil).isAllowed)
            #expect(guardian.verdict(for: dir.appendingPathComponent("com.example.foo"), bundleID: nil).isAllowed)
        }
        // 사용자 폴더는 루트만 보호
        #expect(guardian.verdict(for: fx.home("Documents/report.txt"), bundleID: nil).isAllowed)
        // 대소문자 무시 (APFS 기본) · 어휘적 `..` 정규화
        #expect(!guardian.verdict(for: fx.home("library/CACHES"), bundleID: nil).isAllowed)
        #expect(!guardian.verdict(for: fx.home("Library/Caches/com.example.foo/../.."), bundleID: nil).isAllowed)
    }

    @Test func userDataClassesHaveSpecificReasons() throws {
        let fx = try Fixture()
        let guardian = SafetyGuard(paths: fx.paths)
        #expect(reason(guardian.verdict(for: fx.home("Library/Mobile Documents"), bundleID: nil)) == .iCloudData)
        #expect(reason(guardian.verdict(for: fx.home("Library/Mobile Documents/iCloud~com~example~foo"), bundleID: nil)) == .iCloudData)
        #expect(reason(guardian.verdict(for: fx.home("Library/Application Support/MobileSync/Backup/abc"), bundleID: nil)) == .deviceBackup)
        #expect(reason(guardian.verdict(for: fx.home(".ssh"), bundleID: nil)) == .securityFolder)
        #expect(reason(guardian.verdict(for: fx.home(".ssh/id_ed25519"), bundleID: nil)) == .securityFolder)
        #expect(reason(guardian.verdict(for: fx.home(".gnupg/pubring.kbx"), bundleID: nil)) == .securityFolder)
    }

    @Test func appleAndSelfBundlesAreProtected() throws {
        let fx = try Fixture()
        let guardian = SafetyGuard(paths: fx.paths)
        #expect(reason(guardian.verdict(for: fx.home("Library/Caches/x"), bundleID: "com.apple.Safari")) == .appleBundle)
        #expect(reason(guardian.verdict(for: fx.home("Library/Caches/com.apple.Safari"), bundleID: nil)) == .appleBundle)
        #expect(reason(guardian.verdict(for: fx.home("Library/Group Containers/group.com.apple.notes"), bundleID: nil)) == .appleBundle)
        let pages = try fx.makeApp(name: "Pages", bundleID: "com.apple.iWork.Pages")
        #expect(reason(guardian.verdict(for: pages, bundleID: nil)) == .appleBundle)

        #expect(reason(guardian.verdict(for: fx.home("Library/Caches/x"), bundleID: SystemPaths.defaultSelfBundleID)) == .selfApp)
        #expect(reason(guardian.verdict(for: fx.home("Library/Preferences/com.dallisoft.AppCleaner.plist"), bundleID: nil)) == .selfApp)
        #expect(reason(guardian.verdict(for: fx.paths.appDataDir.appendingPathComponent("Journal/x.json"), bundleID: nil)) == .selfApp)
        #expect(reason(guardian.verdict(for: fx.paths.holdingDir.appendingPathComponent("abc"), bundleID: nil)) == .selfApp)
        let me = try fx.makeApp(name: "App Cleaner", bundleID: SystemPaths.defaultSelfBundleID)
        #expect(reason(guardian.verdict(for: me, bundleID: nil)) == .selfApp)

        let foo = try fx.makeApp(name: "Foo", bundleID: "com.example.foo")
        #expect(guardian.verdict(for: foo, bundleID: "com.example.foo").isAllowed)
    }

    @Test func symlinkedParentIntoProtectedAreaIsBlocked() throws {
        let fx = try Fixture()
        let guardian = SafetyGuard(paths: fx.paths)
        try fx.file(fx.home(".ssh/id_rsa"))
        try fx.symlink(fx.home("Library/Caches/com.example.evil"), to: fx.home(".ssh"))
        #expect(reason(guardian.verdict(for: fx.home("Library/Caches/com.example.evil/id_rsa"), bundleID: nil)) == .symlinkEscape)

        try fx.dir(fx.root("System/Library"))
        try fx.symlink(fx.home("Library/Application Support/com.example.sys"), to: fx.root("System"))
        #expect(reason(guardian.verdict(for: fx.home("Library/Application Support/com.example.sys/Library"), bundleID: nil)) == .symlinkEscape)

        // 상위 링크가 보호 영역의 "루트 폴더 자체"를 가리키는 경우
        try fx.symlink(fx.home("Library/Logs/com.example.lib"), to: fx.paths.userLibrary)
        #expect(reason(guardian.verdict(for: fx.home("Library/Logs/com.example.lib/Caches"), bundleID: nil)) == .symlinkEscape)

        // 허용 영역끼리의 링크는 해석한 실제 경로를 돌려준다
        let real = try fx.dir(fx.home("Library/Caches/com.example.real"))
        try fx.symlink(fx.home("Library/Logs/com.example.alias"), to: real)
        let v = guardian.verdict(for: fx.home("Library/Logs/com.example.alias/item"), bundleID: nil)
        guard case .allowed(let resolved) = v else { Issue.record("blocked: \(v)"); return }
        #expect(resolved.path.hasSuffix("Library/Caches/com.example.real/item"))
    }

    @Test func finalSymlinkComponentIsMovedAsLink() async throws {
        let fx = try Fixture()
        let guardian = SafetyGuard(paths: fx.paths)
        let target = try fx.file(fx.root("System/Library/precious"), text: "keep")
        let link = try fx.symlink(fx.home("Library/Caches/com.example.link"), to: target.deletingLastPathComponent())
        let v = guardian.verdict(for: link, bundleID: nil)
        guard case .allowed(let resolved) = v else { Issue.record("blocked: \(v)"); return }
        #expect(resolved.lastPathComponent == "com.example.link")   // 링크 대상을 따라가지 않음

        let moved = try await DirectoryTrash(directory: fx.paths.trash).trash(link)
        let attrs = try FileManager.default.attributesOfItem(atPath: moved.path)
        #expect(attrs[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(!fx.exists(link))
    }

    @Test func isCheapEnoughForTwoChecksPerItem() throws {
        let fx = try Fixture()
        let guardian = SafetyGuard(paths: fx.paths)
        let urls = (0..<500).map { fx.home("Library/Caches/com.example.app\($0)/data") }
        let start = Date()
        for u in urls { _ = guardian.verdict(for: u, bundleID: "com.example.app") }
        #expect(Date().timeIntervalSince(start) < 2.0)
    }
}
