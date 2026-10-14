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

/// 사용법 오류. 문구는 키(한국어 원문) + `%@` 인자로 들고 있다가 출력할 때 언어를 고른다.
struct UsageError: Error, CustomStringConvertible {
    var key: String
    var args: [String]

    init(_ key: String, _ args: String...) {
        self.key = key
        self.args = args
    }

    func message(_ language: AppLanguage) -> String {
        CLIText(language: language).format(key, args)
    }

    /// 한국어 문장
    var description: String { message(.ko) }
}

enum ArgumentParser {
    /// 사용법 (긴 문단이라 영문 키 "usage" — 한국어는 `ko.lproj/CLI.strings`)
    static func usage(_ language: AppLanguage) -> String {
        CLIText(language: language)("usage")
    }

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
            if let u = unknown.sorted().first { throw UsageError("알 수 없는 옵션: %@", u) }
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
            if let p = positionals.first { throw UsageError("알 수 없는 하위 명령: orphans %@", p) }
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
            throw UsageError("알 수 없는 명령: %@", first)
        }
    }
}
