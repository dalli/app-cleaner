import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct MoverTests {
    @Test func directoryTrashUsesFinderStyleUniqueNames() async throws {
        let fx = try Fixture()
        let trash = DirectoryTrash(directory: fx.paths.trash)
        let a1 = try fx.file(fx.home("a/Foo.plist"), text: "1")
        let a2 = try fx.file(fx.home("b/Foo.plist"), text: "2")
        let d = try fx.dir(fx.home("c/com.example.dir"))
        let d2 = try fx.dir(fx.home("e/com.example.dir"))
        #expect(try await trash.trash(a1).lastPathComponent == "Foo.plist")
        #expect(try await trash.trash(a2).lastPathComponent == "Foo 2.plist")
        #expect(try await trash.trash(d).lastPathComponent == "com.example.dir")
        #expect(try await trash.trash(d2).lastPathComponent == "com.example 2.dir")
        #expect(try await trash.recycleWithAuthorization(a1) == nil)
    }

    @Test func holdingPathsKeepOriginalStructure() throws {
        let fx = try Fixture()
        let session = UUID()
        let item = fx.root("Library/Application Support/com.example.foo/x.db")
        let logical = try #require(AdminPaths.logicalPath(of: item, root: fx.paths.root))
        #expect(logical == "/Library/Application Support/com.example.foo/x.db")
        #expect(AdminPaths.fullURL(logical: logical, root: fx.paths.root).path == item.path)
        let held = AdminPaths.holdingURL(session: session, logical: logical, holdingDir: fx.paths.holdingDir)
        #expect(held.path == fx.paths.holdingDir.path + "/\(session.uuidString)" + logical)
        #expect(AdminPaths.logicalPath(of: fx.home("x"), root: fx.paths.root) == nil)
        #expect(AdminPaths.logicalPath(of: URL(fileURLWithPath: "/Library/Caches/x"), root: URL(fileURLWithPath: "/")) == "/Library/Caches/x")
    }

    @Test func adminOperationArgumentsAndPreflight() {
        let s = UUID()
        #expect(AdminOperation.moveToHolding(session: s, path: "/Library/Caches/x").arguments == ["move-to-holding", s.uuidString, "/Library/Caches/x"])
        #expect(AdminOperation.restoreFromHolding(session: s, originalPath: "/a", restoreTo: "/b").arguments.count == 4)
        #expect(AdminOperation.moveToHolding(session: s, path: "/Library/Caches/a\tb").preflightIssue == "bad-char")
        #expect(AdminOperation.moveToHolding(session: s, path: "/Library/Caches/../x").preflightIssue == "dotdot")
        #expect(AdminOperation.moveToHolding(session: s, path: "Library/x").preflightIssue == "not-absolute")
        #expect(AdminOperation.pkgForget(id: "com.apple.pkg.Core").preflightIssue == "protected")
        #expect(AdminOperation.bootoutSystem(label: "x y").preflightIssue == "bad-identifier")
        #expect(AdminOperation.moveToHolding(session: s, path: "/Library/Caches/$(x)").preflightIssue == nil)
    }

    @Test func rootOwnedLikeAppBundleFallsBackToHolding() async throws {
        let fx = try Fixture()
        let admin = RecordingAdmin(paths: fx.paths)
        let h = try Harness(fx: fx, admin: admin)
        let app = try fx.makeApp(name: "Locked", bundleID: "com.example.locked")
        // 휴지통 이동이 권한 오류로 실패하는 상황 재현
        let executor = CleanupExecutor(paths: fx.paths, runner: h.runner, safety: SafetyGuard(paths: fx.paths),
                                       services: LaunchctlServiceController(paths: fx.paths, runner: h.runner, admin: admin),
                                       terminator: ProcessTerminator(table: h.table, timeout: 0.1),
                                       preferences: CFPreferencesFlusher(paths: fx.paths, runner: h.runner),
                                       trash: DenyingTrash(), admin: admin, journal: h.journal)
        let plan = CleanupPlan(kind: .appRemoval, targetName: "Locked", targetBundleID: "com.example.locked",
                               items: [Candidate(url: app, category: .appBundle, domain: .system, confidence: .high, isSelected: true)],
                               ruleDataVersion: "t")
        let result = await executor.execute(plan, progress: { _ in }, onUnresponsive: { _ in .skip })
        #expect(result.movedToHolding == 1, "\(result.failures)")
        #expect(admin.batches.first?.first == .moveToHolding(session: result.sessionID, path: "/Applications/Locked.app"))
        #expect(fx.exists(AdminPaths.holdingURL(session: result.sessionID, logical: "/Applications/Locked.app", holdingDir: fx.paths.holdingDir)))
    }
}

/// 휴지통 이동이 항상 권한 오류로 실패 (root 소유 앱 번들 재현)
struct DenyingTrash: TrashProviding {
    func trash(_ url: URL) async throws -> URL {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    }
}
