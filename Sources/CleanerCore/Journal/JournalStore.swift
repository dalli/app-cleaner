import Foundation
import Darwin

/// 실행기가 세션 기록을 점진적으로 남기기 위한 쓰기 계약 (크래시가 나도 옮긴 항목까지는 기록이 남는다).
public protocol JournalRecording: Sendable {
    func record(_ session: JournalSession) async throws
    /// cfprefs 도메인 plist 사본을 보관할 폴더
    func preferencesBackupDirectory(for sessionID: UUID) -> URL
    /// 휴지통에 넣을 항목을 잠시 만드는 폴더 (cfprefsd가 plist를 지운 경우 사본으로 휴지통 항목을 만든다)
    func stagingDirectory(for sessionID: UUID) -> URL
}

/// 삭제 기록 및 복원 (plan.md 6.2). 세션마다 `appDataDir/Journal/<id>.json` 1개.
public actor JournalStore: JournalStoring, JournalRecording {
    public nonisolated let paths: SystemPaths
    nonisolated let admin: AdminExecuting?
    nonisolated let services: ServiceControlling?
    nonisolated let preferences: PreferencesFlushing?

    /// 보류 폴더를 영구 삭제한 세션에 남기는 단계 이름
    public static let purgedStep = "purgeHolding"
    /// 이름을 바꿔 복원할 때 붙이는 표시
    public static let restoredSuffix = "복원됨"

    public init(paths: SystemPaths, admin: AdminExecuting? = nil, services: ServiceControlling? = nil,
                preferences: PreferencesFlushing? = nil) {
        self.paths = paths
        self.admin = admin
        self.services = services
        self.preferences = preferences
    }

    /// 실제 구현 조립 (관리자 실행기·launchctl·defaults)
    public static func live(paths: SystemPaths, runner: CommandRunning = ProcessCommandRunner()) -> JournalStore {
        let admin = AppleScriptAdminExecutor(runner: ProcessCommandRunner(timeout: 900))
        return JournalStore(paths: paths, admin: admin,
                            services: LaunchctlServiceController(paths: paths, runner: runner, admin: admin),
                            preferences: CFPreferencesFlusher(paths: paths, runner: runner))
    }

    // MARK: 위치

    public nonisolated var directory: URL { paths.appDataDir.appendingPathComponent("Journal", isDirectory: true) }

    public nonisolated func fileURL(for id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).json") }

    public nonisolated func preferencesBackupDirectory(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString, isDirectory: true).appendingPathComponent("Preferences", isDirectory: true)
    }

    public nonisolated func stagingDirectory(for sessionID: UUID) -> URL {
        directory.appendingPathComponent(sessionID.uuidString, isDirectory: true).appendingPathComponent("Staging", isDirectory: true)
    }

    // MARK: 쓰기

    public func record(_ session: JournalSession) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try Self.encoder.encode(session)
        try data.write(to: fileURL(for: session.id), options: .atomic)
    }

    // MARK: JournalStoring

    public func sessions() async -> [JournalSession] {
        loadAll().map(refreshed).sorted { $0.startedAt > $1.startedAt }
    }

    public func session(id: UUID) async -> JournalSession? {
        load(id).map(refreshed)
    }

    public func restore(sessionID: UUID, itemPaths: Set<String>?, options: RestoreOptions) async -> RestoreResult {
        guard var session = load(sessionID) else {
            return RestoreResult(failures: [CleanupFailure(path: sessionID.uuidString, reason: "작업 기록을 찾을 수 없습니다")])
        }
        let fm = FileManager.default
        var result = RestoreResult()
        let purged = session.steps.contains(Self.purgedStep)
        /// 이번에 원래 이름 그대로 복원한 경로
        var restoredInPlace = Set<String>()

        var holdingOps: [(index: Int, op: AdminOperation, target: String, inPlace: Bool)] = []

        // 기록의 역순으로 되돌린다 (하위 항목 → 상위 폴더 순서를 거꾸로 적용)
        for i in session.items.indices.reversed() {
            let item = session.items[i]
            guard item.restoredAt == nil else { continue }
            if let itemPaths, !itemPaths.contains(item.originalPath) { continue }
            guard Self.isPresent(item, purged: purged) else {
                result.missing.append(item.originalPath)
                continue
            }
            let original = URL(fileURLWithPath: item.originalPath)
            var target = original
            if fm.itemExists(original) {
                switch options.conflictPolicy {
                case .skip:
                    result.skipped.append(item.originalPath)
                    continue
                case .renameRestored:
                    target = Self.renamedURL(for: original)
                }
            }

            switch item.destination {
            case .trash:
                do {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: URL(fileURLWithPath: item.movedTo), to: target)
                    if let meta = item.metadata { FileMetadataIO.apply(meta, to: target) }
                    session.items[i].restoredAt = Date()
                    result.restored.append(target.path)
                    if target == original { restoredInPlace.insert(item.originalPath) }
                } catch {
                    result.failures.append(CleanupFailure(path: item.originalPath, reason: "되돌리지 못했습니다: \(error.localizedDescription)"))
                }
            case .holding:
                guard let logicalOriginal = AdminPaths.logicalPath(of: original, root: paths.root),
                      let logicalTarget = AdminPaths.logicalPath(of: target, root: paths.root) else {
                    result.failures.append(CleanupFailure(path: item.originalPath, reason: "시스템 루트 밖의 경로입니다"))
                    continue
                }
                let op = AdminOperation.restoreFromHolding(session: session.id, originalPath: logicalOriginal,
                                                           restoreTo: target == original ? nil : logicalTarget)
                holdingOps.append((i, op, target.path, target == original))
            }
        }

        if !holdingOps.isEmpty {
            if let admin {
                let results = await admin.run(holdingOps.map(\.op))
                for (k, entry) in holdingOps.enumerated() {
                    let original = session.items[entry.index].originalPath
                    if k < results.count, results[k].succeeded {
                        session.items[entry.index].restoredAt = Date()
                        result.restored.append(entry.target)
                        if entry.inPlace { restoredInPlace.insert(original) }
                    } else {
                        let reason = k < results.count ? results[k].localizedReason : "관리자 작업 결과를 받지 못했습니다"
                        result.failures.append(CleanupFailure(path: original, reason: "보류 폴더에서 되돌리지 못했습니다: \(reason)"))
                    }
                }
            } else {
                for entry in holdingOps {
                    result.failures.append(CleanupFailure(path: session.items[entry.index].originalPath,
                                                          reason: "관리자 권한 실행기가 없어 보류 폴더 항목을 되돌리지 못했습니다"))
                }
            }
        }

        // cfprefs: 원래 이름으로 복원한 plist의 도메인을 `defaults import`로 되살린다.
        if let preferences {
            for backup in session.preferencesBackups {
                let restoredPlist = restoredInPlace.contains {
                    URL(fileURLWithPath: $0).lastPathComponent == "\(backup.domain).plist"
                }
                guard restoredPlist else { continue }
                do { try preferences.restore(backup) } catch {
                    result.failures.append(CleanupFailure(path: backup.backupPath, reason: "\(error)"))
                }
            }
        }

        // 중지했던 서비스 재등록: plist를 원래 위치로 되돌린 서비스만 (번들 내장 SMAppService는 앱이 다시 등록)
        if options.reregisterServices, let services {
            let toStart = session.stoppedServices.filter { s in
                guard let plist = s.plistURL else { return false }
                return restoredInPlace.contains(plist.path) && !plist.path.contains(".app/")
            }
            if !toStart.isEmpty {
                for r in await services.bootstrap(toStart) where !r.succeeded {
                    result.failures.append(CleanupFailure(path: r.service.plistURL?.path ?? r.service.label,
                                                          reason: r.error ?? "서비스를 다시 등록하지 못했습니다"))
                }
            }
        }

        session = refreshed(session)
        try? record(session)
        return result
    }

    public func holdingUsage(retentionDays: Int) async -> HoldingUsage {
        let cutoff = Date().addingTimeInterval(-Double(max(retentionDays, 0)) * 86_400)
        var usage = HoldingUsage()
        for s in loadAll() where !s.steps.contains(Self.purgedStep) {
            let held = s.items.filter { $0.destination == .holding && $0.restoredAt == nil }
            guard !held.isEmpty else { continue }
            usage.totalSize += held.reduce(0) { $0 + ($1.size ?? 0) }
            if usage.oldestItemDate.map({ s.startedAt < $0 }) ?? true { usage.oldestItemDate = s.startedAt }
            if s.startedAt < cutoff { usage.expiredSessionIDs.append(s.id) }
        }
        usage.expiredSessionIDs.sort { $0.uuidString < $1.uuidString }
        return usage
    }

    public func purgeHolding(sessionIDs: [UUID]) async -> [CleanupFailure] {
        let sessions = sessionIDs.compactMap(load)
        let targets = sessions.filter { s in !s.steps.contains(Self.purgedStep) && s.items.contains { $0.destination == .holding } }
        guard !targets.isEmpty else { return [] }
        guard let admin else {
            return targets.map { CleanupFailure(path: holdingPath($0.id), reason: "관리자 권한 실행기가 없습니다") }
        }
        let results = await admin.run(targets.map { .purgeHolding(session: $0.id) })
        var failures: [CleanupFailure] = []
        for (k, var s) in targets.enumerated() {
            if k < results.count, results[k].succeeded {
                s.steps.append(Self.purgedStep)
                s = refreshed(s)
                try? record(s)
            } else {
                failures.append(CleanupFailure(path: holdingPath(s.id),
                                               reason: k < results.count ? results[k].localizedReason : "결과를 받지 못했습니다"))
            }
        }
        return failures
    }

    public func exportJSON(sessionID: UUID) async -> Data? {
        guard let s = load(sessionID) else { return nil }
        return try? Self.encoder.encode(refreshed(s))
    }

    // MARK: 내부

    private nonisolated func holdingPath(_ id: UUID) -> String {
        paths.holdingDir.appendingPathComponent(id.uuidString).path
    }

    private func load(_ id: UUID) -> JournalSession? {
        guard let data = try? Data(contentsOf: fileURL(for: id)) else { return nil }
        return try? Self.decoder.decode(JournalSession.self, from: data)
    }

    private func loadAll() -> [JournalSession] {
        let files = FileManager.default.children(of: directory).filter { $0.pathExtension == "json" }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.decoder.decode(JournalSession.self, from: data)
        }
    }

    /// 이동 위치가 아직 있는지 확인해 `status`·`missingItems`를 갱신한다 (휴지통 비움 감지).
    func refreshed(_ session: JournalSession) -> JournalSession {
        var s = session
        let purged = s.steps.contains(Self.purgedStep)
        let pending = s.items.filter { $0.restoredAt == nil }
        let missing = pending.filter { !Self.isPresent($0, purged: purged) }.map(\.originalPath)
        s.missingItems = missing
        if s.items.isEmpty {
            // 옮긴 것이 없음 — 상태 유지
        } else if pending.isEmpty {
            s.status = .restored
        } else if missing.isEmpty {
            s.status = .restorable
        } else {
            s.status = missing.count == pending.count ? .notRestorable : .partiallyRestorable
        }
        return s
    }

    /// root 소유 `0700` 보류 폴더 안은 일반 사용자가 볼 수 없으므로 EACCES는 "있음"으로 본다.
    static func isPresent(_ item: JournalItem, purged: Bool) -> Bool {
        if item.destination == .holding && purged { return false }
        var st = stat()
        if lstat(item.movedTo, &st) == 0 { return true }
        let err = errno
        if err == ENOENT || err == ENOTDIR { return false }
        return item.destination == .holding
    }

    /// "Foo.plist" → "Foo (복원됨).plist", 이미 있으면 "Foo (복원됨 2).plist"
    static func renamedURL(for original: URL) -> URL {
        let fm = FileManager.default
        let dir = original.deletingLastPathComponent()
        let name = original.lastPathComponent
        let knownExtensions: Set<String> = ["app", "plist", "savedstate", "binarycookies", "bom", "db", "sqlite", "json",
                                            "log", "txt", "appex", "bundle", "prefpane", "qlgenerator", "mdimporter",
                                            "plugin", "kext", "pkg", "dmg", "zip"]
        let ext = (name as NSString).pathExtension
        let useExt = !ext.isEmpty && knownExtensions.contains(ext.lowercased())
        let base = useExt ? (name as NSString).deletingPathExtension : name
        var n = 1
        while true {
            let suffix = n == 1 ? " (\(restoredSuffix))" : " (\(restoredSuffix) \(n))"
            let candidate = dir.appendingPathComponent(useExt ? "\(base)\(suffix).\(ext)" : "\(base)\(suffix)")
            if !fm.itemExists(candidate) { return candidate }
            n += 1
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
