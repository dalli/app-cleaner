import Foundation

/// 정리 계획 실행 (plan.md 4.4, 6장).
///
/// 순서는 고정: **서비스 중지(bootout) → 프로세스 종료 → cfprefs 비우기 → 이동 → 후처리**.
/// - 이동 직전에 SafetyGuard를 다시 검사한다.
/// - 항목 하나가 실패해도 나머지는 계속하고 실패 목록에 한국어 사유를 남긴다 (롤백하지 않음).
/// - 옮길 때마다 기록을 저장해, 중간에 멈춰도 옮긴 항목까지는 되돌릴 수 있다.
/// - 관리자 작업(보류 폴더 이동 + `pkgutil --forget`)은 한 번의 인증으로 묶는다. 시스템 데몬 중지는 프로세스 종료보다
///   먼저 해야 하므로 별도 배치가 된다 (시스템 데몬이 있을 때만 인증 2회).
public struct CleanupExecutor: CleanupExecuting {
    public let paths: SystemPaths
    public let runner: CommandRunning
    public let safety: SafetyChecking
    public let services: ServiceControlling
    public let terminator: ProcessTerminating
    public let preferences: PreferencesFlushing
    public let trash: TrashProviding
    public let admin: AdminExecuting
    public let journal: JournalRecording

    public static let tccutil = "/usr/bin/tccutil"

    public init(paths: SystemPaths, runner: CommandRunning, safety: SafetyChecking, services: ServiceControlling,
                terminator: ProcessTerminating, preferences: PreferencesFlushing, trash: TrashProviding,
                admin: AdminExecuting, journal: JournalRecording) {
        self.paths = paths
        self.runner = runner
        self.safety = safety
        self.services = services
        self.terminator = terminator
        self.preferences = preferences
        self.trash = trash
        self.admin = admin
        self.journal = journal
    }

    /// 실제 구현 조립. `journal`을 넘기면 엔진의 복원 기능과 같은 인스턴스를 공유한다.
    public static func live(paths: SystemPaths, runner: CommandRunning = ProcessCommandRunner(),
                            journal: JournalStore? = nil) -> CleanupExecutor {
        // 관리자 암호 입력을 기다려야 하므로 긴 시간 제한
        let admin = AppleScriptAdminExecutor(runner: ProcessCommandRunner(timeout: 900))
        return CleanupExecutor(
            paths: paths,
            runner: runner,
            safety: SafetyGuard(paths: paths),
            services: LaunchctlServiceController(paths: paths, runner: runner, admin: admin),
            terminator: ProcessTerminator(),
            preferences: CFPreferencesFlusher(paths: paths, runner: runner),
            trash: FileManagerTrash(),
            admin: admin,
            journal: journal ?? JournalStore(paths: paths, admin: admin,
                                             services: LaunchctlServiceController(paths: paths, runner: runner, admin: admin),
                                             preferences: CFPreferencesFlusher(paths: paths, runner: runner))
        )
    }

    public func execute(
        _ plan: CleanupPlan,
        progress: @escaping @Sendable (CleanupProgress) -> Void,
        onUnresponsive: @escaping @Sendable (UnresponsiveApp) async -> UnresponsiveDecision
    ) async -> CleanupResult {
        let run = Run(plan: plan, progress: progress)
        await journalSave(run)

        // cfprefsd가 plist를 지울 수 있으므로 메타데이터는 먼저 기록해 둔다.
        var premeta: [String: FileMetadata] = [:]
        for item in plan.items { premeta[item.path] = FileMetadataIO.capture(item.url) }

        // 1. 백그라운드 서비스 중지 — 앱보다 먼저 (KeepAlive 재실행 방지)
        if !plan.servicesToStop.isEmpty {
            progress(.stepStarted(.stopServices))
            for r in await services.bootout(plan.servicesToStop) {
                if r.succeeded {
                    run.session.stoppedServices.append(r.service)
                } else {
                    run.fail(r.service.plistURL?.path ?? r.service.label, r.error ?? "서비스를 중지하지 못했습니다", emit: false)
                }
            }
            run.session.steps.append(CleanupStep.stopServices.rawValue)
            await journalSave(run)
            progress(.stepFinished(.stopServices))
        }

        // 2. 실행 중 프로세스 종료
        if !plan.bundleIDsToTerminate.isEmpty || !plan.bundlePathsToTerminate.isEmpty {
            progress(.stepStarted(.terminateApps))
            let report = await terminator.terminate(bundleIDs: plan.bundleIDsToTerminate,
                                                    bundlePaths: plan.bundlePathsToTerminate,
                                                    onUnresponsive: onUnresponsive)
            run.session.steps.append(CleanupStep.terminateApps.rawValue)
            if report.cancelled {
                run.cancelled = true
                run.session.steps.append("cancelled")
                return await finish(run)
            }
            for app in report.remaining {
                run.fail(app.name, "응답하지 않는 프로세스를 종료하지 않고 계속했습니다 (pid \(app.pid))", emit: false)
            }
            await journalSave(run)
            progress(.stepFinished(.terminateApps))
        }

        // 3. 환경설정 캐시 무효화 (사본 보관 → 도메인 삭제)
        var flushed: [String: PreferencesBackup] = [:]
        if !plan.preferencesDomains.isEmpty {
            progress(.stepStarted(.flushPreferences))
            let dir = journal.preferencesBackupDirectory(for: run.session.id)
            for domain in plan.preferencesDomains {
                do {
                    if let backup = try preferences.flush(domain: domain, backupDirectory: dir) {
                        run.session.preferencesBackups.append(backup)
                        flushed[domain] = backup
                    }
                } catch {
                    run.fail(domain, "\(error)", emit: false)
                }
            }
            run.session.steps.append(CleanupStep.flushPreferences.rawValue)
            await journalSave(run)
            progress(.stepFinished(.flushPreferences))
        }

        // 4. 이동
        progress(.stepStarted(.moveItems))
        var holdingQueue: [(item: Candidate, logical: String, meta: FileMetadata?)] = []
        let fm = FileManager.default
        for item in plan.items {
            if Task.isCancelled { run.cancelled = true; break }

            // 이동 직전 SafetyGuard 재검사
            let verdict = safety.verdict(for: item.url, bundleID: plan.kind == .appRemoval ? plan.targetBundleID : nil)
            if case .blocked(_, let why) = verdict {
                run.fail(item.path, "보호된 항목이라 옮기지 않았습니다 (\(why))")
                continue
            }
            let meta = FileMetadataIO.capture(item.url) ?? premeta[item.path]

            guard fm.itemExists(item.url) else {
                // cfprefsd가 plist를 이미 지운 경우: 보관한 사본으로 휴지통 항목을 만들어 되돌릴 수 있게 한다.
                if let backup = backupForMissingPlist(item, flushed: flushed) {
                    do {
                        let staged = try stage(backup, as: item.url.lastPathComponent, session: run.session.id)
                        let dest = try await trash.trash(staged)
                        await moved(run, item, to: dest, .trash, meta)
                    } catch {
                        run.fail(item.path, "환경설정 사본을 휴지통에 넣지 못했습니다: \(error.localizedDescription)")
                    }
                } else {
                    run.fail(item.path, "항목을 찾을 수 없습니다")
                }
                continue
            }

            if item.requiresAdmin && item.category != .appBundle {
                enqueueHolding(item, meta, into: &holdingQueue, run: run)
                continue
            }
            do {
                let dest = try await trash.trash(item.url)
                await moved(run, item, to: dest, .trash, meta)
            } catch {
                // root 소유 앱 번들: Finder 인증 경로 → 실패 시 보류 폴더
                if item.category == .appBundle {
                    if let dest = try? await trash.recycleWithAuthorization(item.url) {
                        await moved(run, item, to: dest, .trash, meta)
                        continue
                    }
                    if item.requiresAdmin || isPermissionError(error) {
                        enqueueHolding(item, meta, into: &holdingQueue, run: run)
                        continue
                    }
                }
                run.fail(item.path, "휴지통으로 옮기지 못했습니다: \(error.localizedDescription)")
            }
        }

        // 관리자 배치: 보류 폴더 이동 + (같은 인증으로) pkgutil --forget — 배치 안에서 이동이 먼저 실행된다.
        var receiptResults: [AdminOperationResult]?
        let receiptOps = plan.receiptsToForget.map { AdminOperation.pkgForget(id: $0) }
        if !holdingQueue.isEmpty && !run.cancelled {
            let moveOps = holdingQueue.map { AdminOperation.moveToHolding(session: run.session.id, path: $0.logical) }
            let results = await admin.run(moveOps + receiptOps)
            for (k, entry) in holdingQueue.enumerated() {
                let r = k < results.count ? results[k] : nil
                if let r, r.succeeded {
                    let dest = AdminPaths.holdingURL(session: run.session.id, logical: entry.logical, holdingDir: paths.holdingDir)
                    await moved(run, entry.item, to: dest, .holding, entry.meta)
                } else {
                    run.fail(entry.item.path, "보류 폴더로 옮기지 못했습니다: \(r?.localizedReason ?? "결과 없음")")
                }
            }
            receiptResults = Array(results.dropFirst(moveOps.count))
        } else if run.cancelled {
            for entry in holdingQueue { run.fail(entry.item.path, "취소되어 옮기지 않았습니다") }
        }
        run.session.steps.append(CleanupStep.moveItems.rawValue)
        await journalSave(run)
        progress(.stepFinished(.moveItems))

        // 5. 후처리
        if !run.cancelled && (!receiptOps.isEmpty || plan.resetPrivacy) {
            progress(.stepStarted(.postProcess))
            if !receiptOps.isEmpty {
                let results: [AdminOperationResult]
                if let receiptResults { results = receiptResults } else { results = await admin.run(receiptOps) }
                for (k, id) in plan.receiptsToForget.enumerated() {
                    let r = k < results.count ? results[k] : nil
                    if r?.succeeded != true {
                        run.fail(id, "설치 기록(pkgutil)을 지우지 못했습니다: \(r?.localizedReason ?? "결과 없음")", emit: false)
                    }
                }
            }
            if plan.resetPrivacy {
                for bid in privacyTargets(plan) {
                    let out = try? runner.run(Self.tccutil, ["reset", "All", bid])
                    if out?.succeeded != true {
                        run.fail(bid, "개인정보 보호 권한 기록을 초기화하지 못했습니다", emit: false)
                    }
                }
            }
            run.session.steps.append(CleanupStep.postProcess.rawValue)
            progress(.stepFinished(.postProcess))
        }

        return await finish(run)
    }

    // MARK: 내부

    /// 실행 1회의 가변 상태
    final class Run: @unchecked Sendable {
        var session: JournalSession
        var failures: [CleanupFailure] = []
        var movedCount = 0
        var movedSize: Int64 = 0
        var toTrash = 0
        var toHolding = 0
        var completed = 0
        var cancelled = false
        let total: Int
        let plan: CleanupPlan
        let progress: @Sendable (CleanupProgress) -> Void

        init(plan: CleanupPlan, progress: @escaping @Sendable (CleanupProgress) -> Void) {
            self.plan = plan
            self.progress = progress
            self.total = plan.items.count
            self.session = JournalSession(kind: plan.kind, targetName: plan.targetName, targetBundleID: plan.targetBundleID,
                                          ruleDataVersion: plan.ruleDataVersion)
        }

        func fail(_ path: String, _ reason: String, emit: Bool = true) {
            failures.append(CleanupFailure(path: path, reason: reason))
            session.failures = failures
            if emit { progress(.itemFailed(path: path, reason: reason)) }
        }
    }

    private func journalSave(_ run: Run) async {
        try? await journal.record(run.session)
    }

    private func moved(_ run: Run, _ item: Candidate, to dest: URL, _ destination: MoveDestination, _ meta: FileMetadata?) async {
        var sources: [EvidenceSource] = []
        for e in item.evidence where !sources.contains(e.source) { sources.append(e.source) }
        run.session.items.append(JournalItem(
            originalPath: item.path, movedTo: dest.path, destination: destination, size: item.size,
            category: item.category, confidence: item.confidence, share: item.share, nature: item.nature,
            sources: sources, metadata: meta))
        run.movedCount += 1
        run.movedSize += item.size ?? 0
        if destination == .trash { run.toTrash += 1 } else { run.toHolding += 1 }
        run.completed += 1
        await journalSave(run)
        run.progress(.itemMoved(path: item.path, completed: run.completed, total: run.total))
    }

    private func enqueueHolding(_ item: Candidate, _ meta: FileMetadata?,
                                into queue: inout [(item: Candidate, logical: String, meta: FileMetadata?)], run: Run) {
        guard let logical = AdminPaths.logicalPath(of: item.url, root: paths.root) else {
            run.fail(item.path, "시스템 루트 밖의 항목이라 관리자 권한으로 옮길 수 없습니다")
            return
        }
        if let issue = AdminOperation.moveToHolding(session: run.session.id, path: logical).preflightIssue {
            run.fail(item.path, PrivilegedScript.localizedReason(issue))
            return
        }
        queue.append((item, logical, meta))
    }

    private func finish(_ run: Run) async -> CleanupResult {
        run.session.failures = run.failures
        run.session.finishedAt = Date()
        await journalSave(run)
        return CleanupResult(sessionID: run.session.id, movedCount: run.movedCount, movedSize: run.movedSize,
                             movedToTrash: run.toTrash, movedToHolding: run.toHolding, failures: run.failures,
                             cancelled: run.cancelled, advisories: run.plan.advisories)
    }

    private func backupForMissingPlist(_ item: Candidate, flushed: [String: PreferencesBackup]) -> PreferencesBackup? {
        guard item.category == .preferences || item.category == .byHostPreferences else { return nil }
        if let d = item.preferencesDomain, let b = flushed[d] { return b }
        let name = item.url.deletingPathExtension().lastPathComponent
        return flushed[name]
    }

    private func stage(_ backup: PreferencesBackup, as name: String, session: UUID) throws -> URL {
        let fm = FileManager.default
        let dir = journal.stagingDirectory(for: session)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let staged = dir.appendingPathComponent(name)
        if fm.itemExists(staged) { try fm.removeItem(at: staged) }
        try fm.copyItem(at: URL(fileURLWithPath: backup.backupPath), to: staged)
        return staged
    }

    private func privacyTargets(_ plan: CleanupPlan) -> [String] {
        var out: [String] = []
        for bid in [plan.targetBundleID].compactMap({ $0 }) + plan.bundleIDsToTerminate
        where !out.contains(bid) && SafeIdentifier.isValid(bid) && !SafeIdentifier.isApple(bid) {
            out.append(bid)
        }
        return out
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileWriteNoPermissionError || ns.code == NSFileReadNoPermissionError) {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return underlying.code == Int(EACCES) || underlying.code == Int(EPERM)
        }
        return ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EACCES) || ns.code == Int(EPERM))
    }
}
