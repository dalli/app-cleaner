import Foundation
import CleanerCore

/// CLI 명령 (plan.md 7.3)
enum Command: Equatable {
    case scan(app: String, json: Bool, showAll: Bool)
    case remove(app: String, dryRun: Bool, yes: Bool, json: Bool, resetPrivacy: Bool)
    case orphans(options: OrphanScanOptions, json: Bool)
    case orphansClean(options: OrphanScanOptions, dryRun: Bool, yes: Bool, json: Bool, includeMedium: Bool)
    case history(json: Bool)
    case restore(sessionID: UUID, yes: Bool)
    case help
    case version
}

struct UsageError: Error, CustomStringConvertible {
    var description: String
    init(_ message: String) { description = message }
}

enum ArgumentParser {
    static let usage = """
    사용법: appcleaner <명령> [옵션]

    명령:
      scan <앱 경로|이름>          앱과 잔여물을 검사만 한다 (아무것도 지우지 않음)
          --all                     남겨두는 항목까지 모두 표시
          --json                    JSON 출력
      remove <앱 경로|이름>        기본 선택 항목을 휴지통/보류 폴더로 이동
          --dry-run                 실제로 옮기지 않고 정리 계획만 출력 (JSON)
          --yes                     확인 없이 진행
          --reset-privacy           개인정보 보호 권한 기록(TCC) 초기화
      orphans                       이미 삭제된 앱의 고아 잔여물 스캔
          --min-confidence <high|medium|low>
          --include-dotfiles        숨김 설정 폴더 포함 (~/.ssh, ~/.gnupg는 항상 제외)
          --json
      orphans clean                 고아 잔여물 정리 (기본: 높음 + 사용자 데이터 아님)
          --dry-run | --yes | --json
          --include-medium          보통 신뢰도 항목도 포함
      history [--json]              삭제 기록
      restore <세션 ID> [--yes]     세션 되돌리기

      --demo                        (개발용) 가짜 데이터 엔진 사용
    """

    static func parse(_ args: [String]) throws -> Command {
        var rest = args.filter { $0 != "--demo" }
        guard let first = rest.first else { return .help }
        rest.removeFirst()
        var flags = Set<String>()
        var values: [String: String] = [:]
        var positionals: [String] = []
        var i = 0
        while i < rest.count {
            let a = rest[i]
            if a == "--min-confidence" {
                guard i + 1 < rest.count else { throw UsageError("--min-confidence 값이 필요합니다") }
                values[a] = rest[i + 1]
                i += 2
                continue
            }
            if a.hasPrefix("--") { flags.insert(a) } else { positionals.append(a) }
            i += 1
        }

        func allow(_ allowed: Set<String>) throws {
            let unknown = flags.subtracting(allowed)
            if let u = unknown.sorted().first { throw UsageError("알 수 없는 옵션: \(u)") }
        }

        func orphanOptions() throws -> OrphanScanOptions {
            var opts = OrphanScanOptions(includeDotfiles: flags.contains("--include-dotfiles"))
            if let v = values["--min-confidence"] {
                switch v.lowercased() {
                case "high": opts.minimumConfidence = .high
                case "medium": opts.minimumConfidence = .medium
                case "low": opts.minimumConfidence = .low
                default: throw UsageError("--min-confidence는 high, medium, low 중 하나입니다")
                }
            }
            return opts
        }

        switch first {
        case "help", "-h", "--help":
            return .help
        case "version", "--version":
            return .version
        case "scan":
            try allow(["--json", "--all"])
            guard let app = positionals.first else { throw UsageError("검사할 앱을 지정하세요") }
            return .scan(app: app, json: flags.contains("--json"), showAll: flags.contains("--all"))
        case "remove":
            try allow(["--dry-run", "--yes", "--json", "--reset-privacy"])
            guard let app = positionals.first else { throw UsageError("제거할 앱을 지정하세요") }
            return .remove(app: app, dryRun: flags.contains("--dry-run"), yes: flags.contains("--yes"),
                           json: flags.contains("--json"), resetPrivacy: flags.contains("--reset-privacy"))
        case "orphans":
            if positionals.first == "clean" {
                try allow(["--dry-run", "--yes", "--json", "--include-dotfiles", "--include-medium"])
                return .orphansClean(options: try orphanOptions(), dryRun: flags.contains("--dry-run"),
                                     yes: flags.contains("--yes"), json: flags.contains("--json"),
                                     includeMedium: flags.contains("--include-medium"))
            }
            if let p = positionals.first { throw UsageError("알 수 없는 하위 명령: orphans \(p)") }
            try allow(["--json", "--include-dotfiles"])
            return .orphans(options: try orphanOptions(), json: flags.contains("--json"))
        case "history":
            try allow(["--json"])
            return .history(json: flags.contains("--json"))
        case "restore":
            try allow(["--yes"])
            guard let raw = positionals.first, let id = UUID(uuidString: raw) else {
                throw UsageError("되돌릴 세션 ID(UUID)를 지정하세요 — `appcleaner history`로 확인")
            }
            return .restore(sessionID: id, yes: flags.contains("--yes"))
        default:
            throw UsageError("알 수 없는 명령: \(first)")
        }
    }
}
