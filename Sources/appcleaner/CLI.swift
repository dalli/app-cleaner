import Foundation
import CleanerCore

/// CLI 실행기. GUI와 같은 엔진·같은 기본 선택 규칙을 쓴다 (ui-ux.md 2.1).
struct CLI {
    var engine: any CleanerEngine
    var out: (String) -> Void = { print($0) }
    var err: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    /// 확인 질문 (y/N). 비대화형이면 false.
    var confirm: (String) -> Bool = CLI.askYesNo
    var homeApplications: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")

    @discardableResult
    func run(_ command: Command) async -> Int32 {
        do {
            switch command {
            case .help:
                out(ArgumentParser.usage)
            case .version:
                out("appcleaner \(CLIVersion.current) (규칙 데이터 \(engine.ruleDataInfo().version))")
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
            case let .history(json):
                let sessions = await engine.sessions()
                if json { try printJSON(sessions) } else { printHistory(sessions) }
            case let .restore(id, yes):
                guard let session = await engine.sessions().first(where: { $0.id == id }),
                      let preview = await engine.restorePreview(sessionID: id, itemPaths: nil) else {
                    err("세션을 찾을 수 없습니다: \(id)")
                    return 1
                }
                // 복원과 같은 판정으로 미리 알린다: 충돌은 덮어쓰지 않고 이름을 바꿔 복원
                if !preview.missing.isEmpty {
                    out("이동 위치가 사라져 복원할 수 없는 항목 \(preview.missing.count)개")
                }
                if !preview.conflicts.isEmpty {
                    out("원래 위치에 같은 이름이 있어 \"(\(JournalStore.restoredSuffix))\"을 붙여 복원할 항목 \(preview.conflicts.count)개:")
                    for path in preview.conflicts { out("  \(path)") }
                }
                if preview.restorable.isEmpty {
                    out("되돌릴 항목이 없습니다.")
                    return 0
                }
                if !yes && !confirm("\(session.targetName) 세션의 항목 \(preview.restorable.count)개를 원래 위치로 되돌릴까요?") {
                    out("취소했습니다.")
                    return 1
                }
                let result = await engine.restore(sessionID: id, itemPaths: nil, options: RestoreOptions())
                out("복원 \(result.restored.count)개, 건너뜀 \(result.skipped.count)개, 복원 불가 \(result.missing.count)개")
                for f in result.failures { err("  실패: \(f.path) — \(f.reason)") }
                return result.failures.isEmpty ? 0 : 2
            }
            return 0
        } catch let e as UsageError {
            err(e.description)
            return 64
        } catch {
            err("오류: \(error)")
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
            out("옮길 항목이 없습니다.")
            return 0
        }
        if !json { printPlan(plan) }
        if !yes && !confirm("위 \(plan.items.count)개 항목(\(Format.size(plan.totalSize)))을 휴지통으로 옮길까요?") {
            out("취소했습니다. 아무것도 바뀌지 않았습니다.")
            return 1
        }
        let quiet = json
        let result = await engine.execute(plan, progress: { event in
            guard !quiet else { return }
            switch event {
            case .stepStarted(let step): print("· \(Format.step(step))…")
            case .itemFailed(let path, let reason): print("  실패: \(path) — \(reason)")
            default: break
            }
        }, onUnresponsive: { app in
            // 비대화형 CLI는 강제 종료하지 않고 건너뛴다.
            print("  \(app.name)이(가) 종료 요청에 응답하지 않아 건너뜁니다.")
            return .skip
        })
        if json {
            try printJSON(result)
        } else {
            out("\n\(result.movedCount)개 · \(Format.size(result.movedSize))를 옮겼습니다 (휴지통 \(result.movedToTrash), 보류 폴더 \(result.movedToHolding)).")
            if !result.failures.isEmpty {
                out("실패 \(result.failures.count)개:")
                for f in result.failures { out("  \(f.path) — \(f.reason)") }
            }
            out("되돌리기: appcleaner restore \(result.sessionID.uuidString)")
            for a in result.advisories { out("직접 확인할 것: \(Format.advisory(a))") }
        }
        return result.failures.isEmpty ? 0 : 2
    }

    // MARK: 앱 찾기

    func resolveApp(_ arg: String) async throws -> URL {
        let fm = FileManager.default
        let expanded = (arg as NSString).expandingTildeInPath
        if expanded.contains("/") || expanded.hasSuffix(".app") {
            let url = URL(fileURLWithPath: expanded)
            guard fm.fileExists(atPath: url.path) else { throw UsageError("앱을 찾을 수 없습니다: \(arg)") }
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
            throw UsageError("같은 이름의 앱이 여러 개입니다. 경로로 지정하세요:\n" + matches.map { "  \($0.url.path)" }.joined(separator: "\n"))
        }
        throw UsageError("설치된 앱에서 '\(arg)'을(를) 찾지 못했습니다. 경로로 지정하세요.")
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
        for w in report.warnings { out("! \(Format.warning(w))") }
        let all = report.candidates.flatMap(\.flattened)
        let selected = all.filter { $0.isSelected && $0.isSelectable }
        out("선택 \(selected.count)개 · \(Format.size(selected.reduce(0) { $0 + ($1.size ?? 0) })) / 찾은 항목 \(all.count)개\n")
        for c in report.candidates {
            printCandidate(c, indent: "", showAll: showAll)
        }
        let kept = all.filter { !($0.isSelected && $0.isSelectable) }
        if !kept.isEmpty && !showAll {
            out("\n남겨두는 항목 \(kept.count)개 (공유 \(kept.filter(\.share.isShared).count) · 사용자 데이터 \(kept.filter { $0.nature == .userData }.count) · 낮음 \(kept.filter { $0.confidence == .low }.count)) — --all로 표시")
        }
        out("\n로그인 항목 · 키체인은 정리 후 안내합니다. 아무것도 지우지 않았습니다.")
    }

    private func printCandidate(_ c: Candidate, indent: String, showAll: Bool) {
        let on = c.isSelected && c.isSelectable
        guard on || showAll || c.children.contains(where: { $0.isSelected }) else { return }
        let mark = c.isSelectable ? (on ? "[x]" : "[ ]") : "[🔒]"
        out("\(indent)\(mark) \(c.path)  \(Format.size(c.size))  \(Format.badges(c))")
        for n in c.notes { out("\(indent)      \(n)") }
        for child in c.children { printCandidate(child, indent: indent + "    ", showAll: showAll) }
    }

    private func printPlan(_ plan: CleanupPlan) {
        out("정리 미리보기 — \(plan.targetName). 아직 아무것도 바뀌지 않았습니다.")
        out("옮길 항목 \(plan.items.count)개 · 확보 용량 \(Format.size(plan.totalSize)) · 남겨둘 항목 \(plan.keptItems.count)개")
        out("진행 순서: " + plan.steps.map(Format.step).joined(separator: " → "))
        if plan.requiresAdmin {
            out("관리자 암호가 한 번 필요합니다: " + plan.adminItems.map(\.url.lastPathComponent).joined(separator: ", "))
        }
        if !plan.riskyItems.isEmpty {
            out("⚠︎ 직접 선택한 사용자 데이터·공유 항목:")
            for c in plan.riskyItems { out("   \(c.path)  \(Format.badges(c))") }
        }
        for c in plan.items { out("  → \(c.path)  \(Format.size(c.size))") }
    }

    private func printOrphans(_ report: OrphanScanReport) {
        if !report.spotlight.isReliable {
            out("! Spotlight 색인이 불완전해 일부 앱을 찾지 못했을 수 있습니다. 이름·번들 ID 기반 판정은 낮음으로 낮췄습니다.")
        }
        out("확인한 설치 앱 \(report.inventoryAppCount)개 · \(String(format: "%.1f", report.duration))초")
        if report.groups.isEmpty {
            out("정리할 잔여물이 없습니다." + (report.hiddenByKeepList > 0 ? " (유지 목록에 숨긴 항목 \(report.hiddenByKeepList)개)" : ""))
            return
        }
        for g in report.groups.sorted(by: { $0.totalSize > $1.totalSize }) {
            let suffix = g.nameIsGuess ? "(추정)" : "(삭제됨)"
            out("\n\(g.displayName) \(suffix) — \(Format.size(g.totalSize)), \(g.items.count)개 항목, 신뢰도 \(Format.confidence(g.confidence))")
            for n in g.notes { out("   \(n)") }
            for c in g.items {
                out("  \(c.isSelected ? "[x]" : "[ ]") \(c.path)  \(Format.size(c.size))  \(Format.badges(c))")
                if let e = c.evidence.first { out("        근거: \(e.detail)") }
            }
        }
        if report.hiddenByKeepList > 0 { out("\n유지 목록에 숨긴 항목 \(report.hiddenByKeepList)개") }
        out("\n아무것도 지우지 않았습니다. 정리: appcleaner orphans clean [--dry-run]")
    }

    private func printHistory(_ sessions: [JournalSession]) {
        if sessions.isEmpty { out("삭제 기록이 없습니다."); return }
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        for s in sessions {
            let kind = s.kind == .appRemoval ? "앱 제거" : "고아 정리"
            out("\(s.id.uuidString)  \(df.string(from: s.startedAt))  \(kind)  \(s.targetName)  \(s.items.count)개 · \(Format.size(s.totalSize))  [\(Format.status(s.status))]")
        }
    }

    static func askYesNo(_ question: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0 else { return false }
        print("\(question) [y/N] ", terminator: "")
        guard let line = readLine() else { return false }
        return ["y", "yes", "예", "ㅛ"].contains(line.trimmingCharacters(in: .whitespaces).lowercased())
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
    static let current = "0.1.1"
}
