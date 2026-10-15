import Foundation
import CleanerCore

/// CLI 실행기. GUI와 같은 엔진·같은 기본 선택 규칙을 쓴다 (ui-ux.md 2.1).
struct CLI {
    var engine: any CleanerEngine
    /// 출력 언어 (`--json`은 언어와 무관)
    var language: AppLanguage = .current
    var out: (String) -> Void = { print($0) }
    var err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    /// 확인 질문 (y/N). 비대화형이면 false.
    var confirm: (String) -> Bool = CLI.askYesNo
    var homeApplications: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")

    private var t: CLIText { CLIText(language: language) }
    private var format: Format { Format(language: language) }

    @discardableResult
    func run(_ command: Command) async -> Int32 {
        do {
            switch command {
            case .help:
                out(ArgumentParser.usage(language))
            case .version:
                out(t("appcleaner %@ (규칙 데이터 %@)", CLIVersion.current, engine.ruleDataInfo().version))
            case let .scan(app, json, showAll):
                let report = try await engine.scan(appAt: try await resolveApp(app))
                if json { try printJSON(report) } else { printScan(report, showAll: showAll) }
            case let .remove(app, dryRun, yes, json, resetPrivacy):
                let report = try await engine.scan(appAt: try await resolveApp(app))
                let selected = Set(report.candidates.selectedItems.map(\.path))
                let plan = engine.makePlan(for: report, selectedPaths: selected, resetPrivacy: resetPrivacy)
                return try await runPlan(plan, dryRun: dryRun, yes: yes, json: json)
            case let .orphans(options, json):
                let report = try await engine.scanOrphans(options: options, progress: { _ in })
                if json { try printJSON(report) } else { printOrphans(report) }
            case let .orphansClean(options, dryRun, yes, json, includeMedium):
                let report = try await engine.scanOrphans(options: options, progress: { _ in })
                let items = report.groups.flatMap(\.items).flatMap(\.flattened).filter { c in
                    guard c.isSelectable, c.nature.selectableByDefault, !c.share.isShared else { return false }
                    return c.isSelected || (includeMedium && c.confidence == .medium)
                }
                let plan = engine.makePlan(for: report, selectedPaths: Set(items.map(\.path)))
                return try await runPlan(plan, dryRun: dryRun, yes: yes, json: json)
            case let .packages(options, json):
                let report = try await engine.scanPackages(options: options)
                if json { try printJSON(report) } else { printPackages(report) }
            case let .packagesRemove(targets, options, withData, dryRun, yes, json):
                return try await removePackages(targets, options: options, withData: withData, dryRun: dryRun, yes: yes, json: json)
            case let .packageCaches(options, json):
                let report = try await engine.scanPackages(options: options)
                if json { try printJSON(report.caches) } else { printPackageCaches(report.caches) }
            case let .packageCachesClean(options, dryRun, yes, json):
                var report = try await engine.scanPackages(options: options)
                report.packages = []
                let selected = report.caches.filter { $0.isSelected && $0.isSelectable }.map(\.path)
                let plan = engine.makePlan(for: report, selectedPaths: Set(selected))
                return try await runPlan(plan, dryRun: dryRun, yes: yes, json: json)
            case let .history(json):
                let sessions = await engine.sessions()
                if json { try printJSON(sessions) } else { printHistory(sessions) }
            case let .restore(id, yes):
                guard let session = await engine.sessions().first(where: { $0.id == id }),
                      let preview = await engine.restorePreview(sessionID: id, itemPaths: nil) else {
                    err(t("세션을 찾을 수 없습니다: %@", id.uuidString))
                    return 1
                }
                // 복원과 같은 판정으로 미리 알린다: 충돌은 덮어쓰지 않고 이름을 바꿔 복원
                if !preview.missing.isEmpty {
                    out(t("이동 위치가 사라져 복원할 수 없는 항목 %lld개", preview.missing.count))
                }
                if !preview.conflicts.isEmpty {
                    out(t("원래 위치에 같은 이름이 있어 \"(%@)\"을 붙여 복원할 항목 %lld개:", JournalStore.restoredSuffix, preview.conflicts.count))
                    for path in preview.conflicts { out("  \(path)") }
                }
                if preview.restorable.isEmpty {
                    out(t("되돌릴 항목이 없습니다."))
                    return 0
                }
                if !yes && !confirm(t("%@ 세션의 항목 %lld개를 원래 위치로 되돌릴까요?", sessionTitle(session), preview.restorable.count)) {
                    out(t("취소했습니다."))
                    return 1
                }
                let result = await engine.restore(sessionID: id, itemPaths: nil, options: RestoreOptions())
                out(t("복원 %lld개, 건너뜀 %lld개, 복원 불가 %lld개", result.restored.count, result.skipped.count, result.missing.count))
                for f in result.failures { err(t("  실패: %@ — %@", f.path, format.engine(f.reason))) }
                return result.failures.isEmpty ? 0 : 2
            }
            return 0
        } catch let e as UsageError {
            err(e.message(language))
            return 64
        } catch {
            err(t("오류: %@", format.error(error)))
            return 1
        }
    }

    // MARK: 정리

    private func runPlan(_ plan: CleanupPlan, dryRun: Bool, yes: Bool, json: Bool) async throws -> Int32 {
        if dryRun {
            // S3 미리보기와 같은 정보를 JSON으로 (ui-ux.md S3)
            try printJSON(PlanPreview(plan))
            return 0
        }
        if plan.items.isEmpty {
            out(t("옮길 항목이 없습니다."))
            return 0
        }
        if !json { printPlan(plan) }
        if !yes && !confirm(t("위 %lld개 항목(%@)을 휴지통으로 옮길까요?", plan.items.count, format.size(plan.totalSize))) {
            out(t("취소했습니다. 아무것도 바뀌지 않았습니다."))
            return 1
        }
        let quiet = json
        let t = self.t, format = self.format
        let result = await engine.execute(plan, progress: { event in
            guard !quiet else { return }
            switch event {
            case .stepStarted(let step): print("· \(format.step(step))…")
            case .itemFailed(let path, let reason): print(t("  실패: %@ — %@", path, format.engine(reason)))
            default: break
            }
        }, onUnresponsive: { app in
            // 비대화형 CLI는 강제 종료하지 않고 건너뛴다.
            print(t("  %@이(가) 종료 요청에 응답하지 않아 건너뜁니다.", app.name))
            return .skip
        })
        if json {
            try printJSON(result)
        } else {
            out("\n" + t("%lld개 · %@를 옮겼습니다 (휴지통 %lld, 보류 폴더 %lld).", result.movedCount, format.size(result.movedSize),
                          result.movedToTrash, result.movedToHolding))
            if !result.failures.isEmpty {
                out(t("실패 %lld개:", result.failures.count))
                for f in result.failures { out("  \(f.path) — \(format.engine(f.reason))") }
            }
            out(t("되돌리기: appcleaner restore %@", result.sessionID.uuidString))
            for a in result.advisories { out(t("직접 확인할 것: %@", format.advisory(a))) }
        }
        return result.failures.isEmpty ? 0 : 2
    }

    // MARK: 패키지

    /// 지정한 패키지의 설치 항목(+ `--with-data`면 다른 설치와 함께 쓰지 않는 데이터)을 옮긴다.
    private func removePackages(_ targets: [String], options: PackageScanOptions, withData: Bool, dryRun: Bool, yes: Bool,
                                json: Bool) async throws -> Int32 {
        var scanOptions = options
        scanOptions.computeSizes = false
        var report = try await engine.scanPackages(options: scanOptions)
        var chosen: [PackageReport] = []
        for target in targets {
            for p in try resolvePackage(target, in: report.packages) where !chosen.contains(where: { $0.id == p.id }) {
                chosen.append(p)
            }
        }
        let ids = Set(chosen.map(\.id))
        var selected = Set<String>()
        for i in chosen.indices {
            chosen[i].candidates = await FileStatsCalculator.fill(chosen[i].candidates)
            let r = chosen[i]
            if !r.isRemovable && !json {
                for c in r.installCandidates where !c.isSelectable {
                    for n in c.notes { err("! \(r.package.name): \(format.engine(n))") }
                }
            }
            for c in r.installCandidates where c.isSelected && c.isSelectable { selected.insert(c.path) }
            guard withData else { continue }
            for c in r.dataCandidates where c.isSelectable {
                // 함께 찾은 다른 설치도 이번에 지우는 경우에만 옮긴다.
                if report.packages(matching: c.path).allSatisfy({ ids.contains($0.id) }) {
                    selected.insert(c.path)
                } else if !json {
                    // --dry-run의 표준 출력은 JSON이므로 안내는 표준 오류로
                    err(t("다른 설치와 함께 쓰는 데이터라 남겨둡니다: %@", c.path))
                }
            }
        }
        report.packages = chosen
        report.caches = []
        let plan = engine.makePlan(for: report, selectedPaths: selected)
        let code = try await runPlan(plan, dryRun: dryRun, yes: yes, json: json)
        if code == 0 && !dryRun && !json && !plan.items.isEmpty {
            for r in chosen { for n in r.notes { out(t("참고: %@", format.engine(n))) } }
        }
        return code
    }

    /// 이름(`@scope/name`·`name`), `매니저:이름`, 또는 설치 경로로 패키지를 찾는다. 이름이 같은 설치가 여럿이면 경로로 지정하게 한다.
    func resolvePackage(_ arg: String, in packages: [PackageReport]) throws -> [PackageReport] {
        let expanded = (arg as NSString).expandingTildeInPath
        if expanded.contains("/") && !expanded.hasPrefix("@") {
            let hits = packages.filter { $0.package.isInstallPath(expanded) }
            guard !hits.isEmpty else { throw UsageError("설치된 패키지에서 '%@'을(를) 찾지 못했습니다. `appcleaner packages`로 확인하세요.", arg) }
            return hits
        }
        var manager: PackageManager?
        var name = arg
        if let colon = arg.firstIndex(of: ":"), let m = PackageManager(rawValue: arg[..<colon].lowercased()) {
            manager = m
            name = String(arg[arg.index(after: colon)...])
        }
        let hits = packages.filter { r in
            let p = r.package
            guard manager == nil || p.manager == manager else { return false }
            let base = p.name.split(separator: "/").last.map(String.init) ?? p.name
            return p.name.caseInsensitiveCompare(name) == .orderedSame || base.caseInsensitiveCompare(name) == .orderedSame
        }
        if hits.isEmpty { throw UsageError("설치된 패키지에서 '%@'을(를) 찾지 못했습니다. `appcleaner packages`로 확인하세요.", arg) }
        if hits.count > 1 {
            let list = hits.map { "  \($0.package.manager.displayName)\($0.package.rootLabel.map { " (\($0))" } ?? "")  \($0.package.location.path)" }
            throw UsageError("'%@'에 해당하는 설치가 여러 개입니다. 경로로 지정하세요:\n%@", arg, list.joined(separator: "\n"))
        }
        return hits
    }

    // MARK: 앱 찾기

    func resolveApp(_ arg: String) async throws -> URL {
        let fm = FileManager.default
        let expanded = (arg as NSString).expandingTildeInPath
        if expanded.contains("/") || expanded.hasSuffix(".app") {
            let url = URL(fileURLWithPath: expanded)
            guard fm.fileExists(atPath: url.path) else { throw UsageError("앱을 찾을 수 없습니다: %@", arg) }
            return url
        }
        // 이름으로 찾기: 정확 일치(대소문자 무시)만 허용 — 부분 일치는 하지 않는다 (plan.md 4.3.1)
        let apps = await engine.installedApps()
        let matches = apps.filter {
            $0.name.caseInsensitiveCompare(arg) == .orderedSame
                || $0.url.deletingPathExtension().lastPathComponent.caseInsensitiveCompare(arg) == .orderedSame
                || $0.bundleID.caseInsensitiveCompare(arg) == .orderedSame
        }
        if matches.count == 1 { return matches[0].url }
        if matches.count > 1 {
            throw UsageError("같은 이름의 앱이 여러 개입니다. 경로로 지정하세요:\n%@", matches.map { "  \($0.url.path)" }.joined(separator: "\n"))
        }
        throw UsageError("설치된 앱에서 '%@'을(를) 찾지 못했습니다. 경로로 지정하세요.", arg)
    }

    // MARK: 출력

    func printJSON<T: Encodable>(_ value: T) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        out(String(decoding: try enc.encode(value), as: UTF8.self))
    }

    private func printScan(_ report: ScanReport, showAll: Bool) {
        let id = report.identity
        out("\(id.title) \(id.version ?? "") · \(id.bundleID)\(id.teamID.map { " · Team \($0)" } ?? "")")
        for w in report.warnings { out("! \(format.warning(w))") }
        let all = report.candidates.flatMap(\.flattened)
        let selected = all.filter { $0.isSelected && $0.isSelectable }
        out(t("선택 %lld개 · %@ / 찾은 항목 %lld개", selected.count, format.size(selected.reduce(0) { $0 + ($1.size ?? 0) }), all.count) + "\n")
        for c in report.candidates {
            printCandidate(c, indent: "", showAll: showAll)
        }
        let kept = all.filter { !($0.isSelected && $0.isSelectable) }
        if !kept.isEmpty && !showAll {
            out("\n" + t("남겨두는 항목 %lld개 (공유 %lld · 사용자 데이터 %lld · 낮음 %lld) — --all로 표시", kept.count,
                          kept.filter(\.share.isShared).count, kept.filter { $0.nature == .userData }.count,
                          kept.filter { $0.confidence == .low }.count))
        }
        out("\n" + t("로그인 항목 · 키체인은 정리 후 안내합니다. 아무것도 지우지 않았습니다."))
    }

    private func printCandidate(_ c: Candidate, indent: String, showAll: Bool) {
        let on = c.isSelected && c.isSelectable
        guard on || showAll || c.children.contains(where: { $0.isSelected }) else { return }
        let mark = c.isSelectable ? (on ? "[x]" : "[ ]") : "[🔒]"
        out("\(indent)\(mark) \(c.path)  \(format.size(c.size))  \(format.badges(c))")
        for n in c.notes { out("\(indent)      \(format.engine(n))") }
        for child in c.children { printCandidate(child, indent: indent + "    ", showAll: showAll) }
    }

    private func printPlan(_ plan: CleanupPlan) {
        out(t("정리 미리보기 — %@. 아직 아무것도 바뀌지 않았습니다.", planTitle(plan)))
        out(t("옮길 항목 %lld개 · 확보 용량 %@ · 남겨둘 항목 %lld개", plan.items.count, format.size(plan.totalSize), plan.keptItems.count))
        out(t("진행 순서: %@", plan.steps.map(format.step).joined(separator: " → ")))
        if plan.requiresAdmin {
            out(t("관리자 암호가 한 번 필요합니다: %@", plan.adminItems.map(\.url.lastPathComponent).joined(separator: ", ")))
        }
        if !plan.riskyItems.isEmpty {
            out(t("⚠︎ 직접 선택한 사용자 데이터·공유 항목:"))
            for c in plan.riskyItems { out("   \(c.path)  \(format.badges(c))") }
        }
        for c in plan.items { out("  → \(c.path)  \(format.size(c.size))") }
    }

    private func printOrphans(_ report: OrphanScanReport) {
        if !report.spotlight.isReliable {
            out("! " + t("Spotlight 색인이 불완전해 일부 앱을 찾지 못했을 수 있습니다. 이름·번들 ID 기반 판정은 낮음으로 낮췄습니다."))
        }
        let seconds = String(format: "%.1f", locale: language.locale(), report.duration)
        out(t("확인한 설치 앱 %lld개 · %@초", report.inventoryAppCount, seconds))
        if report.groups.isEmpty {
            out(report.hiddenByKeepList > 0 ? t("정리할 잔여물이 없습니다. (유지 목록에 숨긴 항목 %lld개)", report.hiddenByKeepList)
                                            : t("정리할 잔여물이 없습니다."))
            return
        }
        for g in report.groups.sorted(by: { $0.totalSize > $1.totalSize }) {
            let suffix = g.nameIsGuess ? t("(추정)") : t("(삭제됨)")
            out("\n" + t("%@ %@ — %@, %lld개 항목, 신뢰도 %@", g.title(language), suffix, format.size(g.totalSize), g.items.count,
                          format.confidence(g.confidence)))
            for n in g.notes { out("   \(format.engine(n))") }
            for c in g.items {
                out("  \(c.isSelected ? "[x]" : "[ ]") \(c.path)  \(format.size(c.size))  \(format.badges(c))")
                if let e = c.evidence.first { out("        " + t("근거: %@", format.engine(e.detail))) }
            }
        }
        if report.hiddenByKeepList > 0 { out("\n" + t("유지 목록에 숨긴 항목 %lld개", report.hiddenByKeepList)) }
        out("\n" + t("아무것도 지우지 않았습니다. 정리: appcleaner orphans clean [--dry-run]"))
    }

    private func printPackages(_ report: PackageScanReport) {
        if report.packages.isEmpty {
            out(t("패키지 매니저로 설치한 패키지가 없습니다."))
            return
        }
        let install = report.packages.reduce(Int64(0)) { $0 + $1.installSize }
        let data = report.dataSize
        out(t("패키지 %lld개 · 설치 %@ · 이름이 같은 데이터 %@", report.packages.count, format.size(install), format.size(data)))
        var groups: [(key: String, items: [PackageReport])] = []
        for r in report.packages {
            let key = r.package.manager.displayName + (r.package.rootLabel.map { " (\($0))" } ?? "")
            if let i = groups.firstIndex(where: { $0.key == key }) { groups[i].items.append(r) } else { groups.append((key, [r])) }
        }
        for g in groups {
            out("\n" + t("%@ — 패키지 %lld개", g.key, g.items.count))
            for r in g.items {
                var line = "  \(r.package.title)  \(format.size(r.installSize))"
                if !r.package.executables.isEmpty { line += "  " + t("실행 파일: %@", r.package.executables.joined(separator: ", ")) }
                if !r.isRemovable { line += "  [🔒]" }
                out(line)
                for c in r.installCandidates where !c.isSelectable {
                    for n in c.notes { out("      \(format.engine(n))") }
                    break
                }
                for c in r.dataCandidates {
                    out("      · \(c.path)  \(format.size(c.size))  \(format.badges(c))")
                }
            }
        }
        out("\n" + t("아무것도 지우지 않았습니다. 제거: appcleaner packages remove <이름> [--with-data] [--dry-run]"))
    }

    private func printPackageCaches(_ caches: [Candidate]) {
        if caches.isEmpty {
            out(t("패키지 매니저 캐시가 없습니다."))
            return
        }
        out(t("캐시 %lld개 · %@", caches.count, format.size(caches.reduce(0) { $0 + ($1.size ?? 0) })))
        for c in caches {
            out("  \(c.isSelected && c.isSelectable ? "[x]" : "[ ]") \(c.path)  \(format.size(c.size))  \(format.badges(c))")
            if let e = c.evidence.first { out("        " + t("근거: %@", format.engine(e.detail))) }
        }
        out("\n" + t("아무것도 지우지 않았습니다. 정리: appcleaner packages caches clean [--dry-run]"))
    }

    private func printHistory(_ sessions: [JournalSession]) {
        if sessions.isEmpty { out(t("삭제 기록이 없습니다.")); return }
        let df = DateFormatter()
        df.locale = language.locale()
        df.dateStyle = .short
        df.timeStyle = .short
        for s in sessions {
            let kind: String
            switch s.kind {
            case .appRemoval: kind = t("앱 제거")
            case .orphanCleanup: kind = t("고아 정리")
            case .packageRemoval: kind = t("패키지 정리")
            }
            out("\(s.id.uuidString)  \(df.string(from: s.startedAt))  \(kind)  \(sessionTitle(s))  "
                + t("%lld개 · %@", s.items.count, format.size(s.totalSize)) + "  [\(format.status(s.status))]")
        }
    }

    /// 세션 대상 이름. 엔진이 고아 정리에 붙이는 고정 이름("고아 잔여물")은 출력 언어로 바꾼다.
    func sessionTitle(_ s: JournalSession) -> String { title(kind: s.kind, targetName: s.targetName) }

    private func planTitle(_ plan: CleanupPlan) -> String { title(kind: plan.kind, targetName: plan.targetName) }

    /// 엔진이 붙이는 고정 이름("고아 잔여물", "패키지 매니저 캐시")은 출력 언어로 바꾼다.
    private func title(kind: SessionKind, targetName: String) -> String {
        if kind == .orphanCleanup && targetName == CleanupPlanner.orphanTargetName { return t("고아 잔여물") }
        if kind == .packageRemoval && targetName == CleanupPlanner.packageCacheTargetName { return t("패키지 매니저 캐시") }
        return targetName
    }

    static func askYesNo(_ question: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0 else { return false }
        print("\(question) [y/N] ", terminator: "")
        guard let line = readLine() else { return false }
        // 한글·일본어 입력 상태에서 친 y도 받는다 (ㅛ, ｙ)
        return ["y", "yes", "예", "ㅛ", "ｙ", "はい"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// `--dry-run` JSON: S3 시트와 같은 정보 (ui-ux.md S3)
struct PlanPreview: Encodable {
    var plan: CleanupPlan
    var summary: Summary
    struct Summary: Encodable {
        var itemCount: Int
        var totalSize: Int64
        var keptCount: Int
        var requiresAdmin: Bool
        var adminItems: [String]
        var riskyItems: [String]
        var steps: [CleanupStep]
    }
    init(_ plan: CleanupPlan) {
        self.plan = plan
        summary = Summary(itemCount: plan.items.count, totalSize: plan.totalSize, keptCount: plan.keptItems.count,
                          requiresAdmin: plan.requiresAdmin, adminItems: plan.adminItems.map(\.path),
                          riskyItems: plan.riskyItems.map(\.path), steps: plan.steps)
    }
}

enum CLIVersion {
    static let current = "0.2.0"
}
