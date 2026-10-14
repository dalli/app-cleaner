import Foundation
import Testing
import Darwin
@testable import CleanerCore
import CleanerTestSupport

@Suite struct JournalTests {
    func setXattr(_ url: URL, _ name: String, _ value: String) {
        let data = Data(value.utf8)
        _ = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
    }

    func mode(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func plan(_ items: [Candidate]) -> CleanupPlan {
        CleanupPlan(kind: .orphanCleanup, targetName: "x", items: items, ruleDataVersion: "t")
    }

    /// 휴지통 이동 → 복원: 내용 + mode(0640) + xattr 보존
    @Test func moveAndRestoreRoundTripPreservesMetadata() async throws {
        let h = try Harness()
        let fx = h.fx
        let file = try fx.file(fx.home("Library/Application Support/com.example.foo/settings.json"), text: "{\"a\":1}")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        setXattr(file, "com.example.tag", "hello")

        let (result, _) = await h.execute(plan([Candidate(url: file, category: .applicationSupport, confidence: .high,
                                                          isSelected: true, size: 7)]))
        #expect(result.movedToTrash == 1)
        let session = try #require(await h.journal.session(id: result.sessionID))
        let item = try #require(session.items.first)
        #expect(item.metadata?.mode == 0o640)
        #expect(item.metadata?.xattrs["com.example.tag"] == Data("hello".utf8))
        #expect(item.movedTo.hasPrefix(fx.paths.trash.path))

        // 휴지통 안에서 메타데이터가 바뀌어도 복원 시 다시 적용된다
        let trashed = URL(fileURLWithPath: item.movedTo)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: trashed.path)
        removexattr(trashed.path, "com.example.tag", XATTR_NOFOLLOW)

        let restore = await h.journal.restore(sessionID: result.sessionID, itemPaths: nil, options: RestoreOptions())
        #expect(restore.restored == [file.path])
        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"a\":1}")
        #expect(try mode(file) == 0o640)
        #expect(FileMetadataIO.readXattrs(file.path)["com.example.tag"] == Data("hello".utf8))
        #expect(await h.journal.session(id: result.sessionID)?.status == .restored)
    }

    @Test func conflictAtOriginalLocationIsRenamedOrSkipped() async throws {
        let h = try Harness()
        let fx = h.fx
        let a = try fx.file(fx.home("Library/Preferences/com.example.a.plist"), text: "old-a")
        let b = try fx.file(fx.home("Library/Caches/com.example.b"), text: "old-b")
        let (result, _) = await h.execute(plan([
            Candidate(url: a, category: .preferences, confidence: .high, isSelected: true),
            Candidate(url: b, category: .caches, confidence: .high, isSelected: true),
        ]))
        #expect(result.movedCount == 2)
        try fx.file(a, text: "new-a")
        try fx.file(b, text: "new-b")

        let skip = await h.journal.restore(sessionID: result.sessionID, itemPaths: [b.path],
                                           options: RestoreOptions(conflictPolicy: .skip))
        #expect(skip.skipped == [b.path] && skip.restored.isEmpty)
        #expect(try String(contentsOf: b, encoding: .utf8) == "new-b")

        let renamed = await h.journal.restore(sessionID: result.sessionID, itemPaths: nil, options: RestoreOptions())
        let renamedA = fx.home("Library/Preferences/com.example.a (복원됨).plist")
        let renamedB = fx.home("Library/Caches/com.example.b (복원됨)")
        #expect(Set(renamed.restored) == [renamedA.path, renamedB.path])
        #expect(try String(contentsOf: renamedA, encoding: .utf8) == "old-a")
        #expect(try String(contentsOf: a, encoding: .utf8) == "new-a")
        #expect(try String(contentsOf: renamedB, encoding: .utf8) == "old-b")
        #expect(JournalStore.renamedURL(for: renamedA.deletingLastPathComponent().appendingPathComponent("com.example.a.plist"))
                .lastPathComponent == "com.example.a (복원됨 2).plist")
    }

    /// 복원 미리보기는 실제 복원과 같은 판정을 쓰고, 항목별 정책은 한 번의 호출로 지킨다
    @Test func restorePreviewMatchesRestoreAndPerItemPolicies() async throws {
        let h = try Harness()
        let fx = h.fx
        let a = try fx.file(fx.home("Library/Preferences/com.example.a.plist"), text: "old-a")
        let b = try fx.file(fx.home("Library/Caches/com.example.b"), text: "old-b")
        let c = try fx.file(fx.home("Library/Logs/com.example.c"), text: "old-c")
        let d = try fx.file(fx.home("Library/Caches/com.example.d"), text: "old-d")
        let (result, _) = await h.execute(plan([a, b, c, d].map {
            Candidate(url: $0, category: .caches, confidence: .high, isSelected: true)
        }))
        #expect(result.movedCount == 4)
        try fx.file(a, text: "new-a")
        try fx.file(b, text: "new-b")
        let session = try #require(await h.journal.session(id: result.sessionID))
        try FileManager.default.removeItem(atPath: try #require(session.items.first { $0.originalPath == c.path }).movedTo)

        let preview = try #require(await h.journal.restorePreview(sessionID: result.sessionID, itemPaths: nil))
        #expect(preview.ready == [d.path])
        #expect(preview.conflicts == [a.path, b.path])
        #expect(preview.missing == [c.path])
        #expect(preview.alreadyRestored.isEmpty)
        #expect(Set(preview.restorable) == [a.path, b.path, d.path])
        #expect(await h.journal.restorePreview(sessionID: result.sessionID, itemPaths: [a.path])?.conflicts == [a.path])
        #expect(await h.journal.restorePreview(sessionID: UUID(), itemPaths: nil) == nil)
        // 미리보기는 아무것도 옮기지 않는다
        #expect(try String(contentsOf: a, encoding: .utf8) == "new-a")
        #expect(!fx.exists(d))

        // a는 건너뛰고 b는 이름 바꿔 복원 — 한 번의 호출
        let restore = await h.journal.restore(sessionID: result.sessionID, itemPaths: nil,
                                              options: RestoreOptions(conflictPolicy: .renameRestored, itemPolicies: [a.path: .skip]))
        #expect(restore.skipped == [a.path])
        #expect(restore.missing == [c.path])
        #expect(Set(restore.restored) == [fx.home("Library/Caches/com.example.b (복원됨)").path, d.path])
        #expect(try String(contentsOf: a, encoding: .utf8) == "new-a")
        #expect(try String(contentsOf: b, encoding: .utf8) == "new-b")

        let after = try #require(await h.journal.restorePreview(sessionID: result.sessionID, itemPaths: nil))
        #expect(after.conflicts == [a.path])
        #expect(Set(after.alreadyRestored) == [b.path, d.path])
        #expect(after.missing == [c.path])
    }

    /// 휴지통을 비운 경우 → 일부 복원 불가 / 복원 불가, 복원 결과에 빠진 항목 표시
    @Test func emptiedTrashMakesSessionPartiallyOrNotRestorable() async throws {
        let h = try Harness()
        let fx = h.fx
        let a = try fx.file(fx.home("Library/Caches/com.example.a/x"))
        let b = try fx.file(fx.home("Library/Logs/com.example.b/y"))
        let (result, _) = await h.execute(plan([
            Candidate(url: a.deletingLastPathComponent(), category: .caches, confidence: .high, isSelected: true),
            Candidate(url: b.deletingLastPathComponent(), category: .logs, confidence: .high, isSelected: true),
        ]))
        var s = try #require(await h.journal.session(id: result.sessionID))
        #expect(s.status == .restorable)

        try FileManager.default.removeItem(atPath: s.items[0].movedTo)
        s = try #require(await h.journal.sessions().first { $0.id == result.sessionID })
        #expect(s.status == .partiallyRestorable)
        #expect(s.missingItems == [a.deletingLastPathComponent().path])

        let partial = await h.journal.restore(sessionID: result.sessionID, itemPaths: nil, options: RestoreOptions())
        #expect(partial.missing == [a.deletingLastPathComponent().path])
        #expect(partial.restored == [b.deletingLastPathComponent().path])
        #expect(fx.exists(b))
        #expect(await h.journal.session(id: result.sessionID)?.status == .notRestorable)

        // 둘 다 사라진 경우
        let c = try fx.file(fx.home("Library/Caches/com.example.c"))
        let (r2, _) = await h.execute(plan([Candidate(url: c, category: .caches, confidence: .high, isSelected: true)]))
        let s2 = try #require(await h.journal.session(id: r2.sessionID))
        try FileManager.default.removeItem(atPath: s2.items[0].movedTo)
        #expect(await h.journal.session(id: r2.sessionID)?.status == .notRestorable)
    }

    @Test func journalIsWrittenIncrementally() async throws {
        let fx = try Fixture()
        let inner = JournalStore(paths: fx.paths)
        let spy = SpyJournal(inner: inner)
        let base = try Harness(fx: fx)
        let executor = CleanupExecutor(paths: fx.paths, runner: base.runner, safety: SafetyGuard(paths: fx.paths),
                                       services: LaunchctlServiceController(paths: fx.paths, runner: base.runner, admin: base.admin),
                                       terminator: ProcessTerminator(table: base.table, timeout: 0.1),
                                       preferences: CFPreferencesFlusher(paths: fx.paths, runner: base.runner),
                                       trash: DirectoryTrash(directory: fx.paths.trash), admin: base.admin, journal: spy)
        let items = try (0..<3).map { i in
            Candidate(url: try fx.file(fx.home("Library/Caches/com.example.n\(i)")), category: .caches, confidence: .high, isSelected: true)
        }
        let result = await executor.execute(plan(items), progress: { _ in }, onUnresponsive: { _ in .skip })
        // 세션 시작 → 항목마다 → 단계 끝 → 종료 시 저장. 항목 수가 1씩 늘어나는 저장이 있어야 한다.
        let counts = spy.itemCounts
        #expect(counts.first == 0)
        for n in 1...3 { #expect(counts.contains(n)) }
        let onDisk = try JSONDecoder.journal.decode(JournalSession.self, from: Data(contentsOf: inner.fileURL(for: result.sessionID)))
        #expect(onDisk.items.count == 3)
        #expect(onDisk.finishedAt != nil)
    }

    @Test func holdingItemsRestoreThroughAdminAndPurge() async throws {
        let fx = try Fixture()
        let h = try Harness(fx: fx, admin: scriptAdmin(fx))
        let daemon = try fx.makeLaunchPlist(at: fx.root("Library/LaunchDaemons/com.example.helper.plist"), label: "com.example.helper")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: daemon.path)
        let (result, _) = await h.execute(plan([
            Candidate(url: daemon, category: .launchDaemon, domain: .system, confidence: .high, isSelected: true, size: 300),
        ]))
        #expect(result.movedToHolding == 1, "\(result.failures)")

        let usage = await h.journal.holdingUsage(retentionDays: 30)
        #expect(usage.totalSize == 300)
        #expect(usage.oldestItemDate != nil)
        #expect(usage.expiredSessionIDs.isEmpty)
        #expect(await h.journal.holdingUsage(retentionDays: -1).expiredSessionIDs == [result.sessionID])

        let restore = await h.journal.restore(sessionID: result.sessionID, itemPaths: nil, options: RestoreOptions())
        #expect(restore.restored == [daemon.path], "\(restore.failures)")
        #expect(try mode(daemon) == 0o644)

        // 다시 옮긴 뒤 보류 폴더 영구 삭제 → 복원 불가
        let (r2, _) = await h.execute(plan([
            Candidate(url: daemon, category: .launchDaemon, domain: .system, confidence: .high, isSelected: true, size: 300),
        ]))
        #expect(await h.journal.purgeHolding(sessionIDs: [r2.sessionID]).isEmpty)
        #expect(!fx.exists(fx.paths.holdingDir.appendingPathComponent(r2.sessionID.uuidString)))
        let s2 = try #require(await h.journal.session(id: r2.sessionID))
        #expect(s2.status == .notRestorable)
        #expect(await h.journal.holdingUsage(retentionDays: 30).totalSize == 0)
        #expect(await h.journal.restore(sessionID: r2.sessionID, itemPaths: nil, options: RestoreOptions()).missing == [daemon.path])
        #expect(await h.journal.restorePreview(sessionID: r2.sessionID, itemPaths: nil)?.missing == [daemon.path])
    }

    /// 엔진이 실제 보류 폴더 위치를 알려 준다 (GUI가 기록에서 추정하지 않음)
    @Test func liveEngineExposesHoldingFolder() throws {
        let fx = try Fixture()
        let engine = LiveCleanerEngine(paths: fx.paths, runner: StubCommandRunner(), adminLauncher: .direct)
        #expect(engine.holdingFolderURL == fx.paths.holdingDir)
    }

    @Test func restoreReregistersStoppedServicesAndExports() async throws {
        let h = try Harness()
        let fx = h.fx
        let agent = try fx.makeLaunchPlist(at: fx.home("Library/LaunchAgents/com.example.agent.plist"), label: "com.example.agent")
        let service = LaunchServiceRef(label: "com.example.agent", domain: .user, plistURL: agent)
        var p = plan([Candidate(url: agent, category: .launchAgent, confidence: .high, isSelected: true, launchService: service)])
        p.servicesToStop = [service]
        let (result, _) = await h.execute(p)
        #expect(result.movedCount == 1)

        _ = await h.journal.restore(sessionID: result.sessionID, itemPaths: nil, options: RestoreOptions(reregisterServices: true))
        #expect(h.log.events.last == "launchctl bootstrap gui/\(fx.paths.uid) \(agent.path)")

        let data = try #require(await h.journal.exportJSON(sessionID: result.sessionID))
        let decoded = try JSONDecoder.journal.decode(JournalSession.self, from: data)
        #expect(decoded.id == result.sessionID)
        #expect(decoded.stoppedServices == [service])
        #expect(await h.journal.exportJSON(sessionID: UUID()) == nil)
    }
}

extension JSONDecoder {
    static var journal: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// 저장할 때마다 항목 수를 기록하는 기록기 (점진 저장 검증)
final class SpyJournal: JournalRecording, @unchecked Sendable {
    let inner: JournalStore
    private let lock = NSLock()
    private var _counts: [Int] = []

    init(inner: JournalStore) { self.inner = inner }

    var itemCounts: [Int] { lock.lock(); defer { lock.unlock() }; return _counts }

    func record(_ session: JournalSession) async throws {
        lock.withLock { _counts.append(session.items.count) }
        try await inner.record(session)
    }

    func preferencesBackupDirectory(for sessionID: UUID) -> URL { inner.preferencesBackupDirectory(for: sessionID) }
    func stagingDirectory(for sessionID: UUID) -> URL { inner.stagingDirectory(for: sessionID) }
}
