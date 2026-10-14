import Foundation

/// 관리자 권한 작업 1개. 경로는 **시스템 루트 기준 논리 경로**(`/Library/LaunchDaemons/x.plist`)이며,
/// 권한 스크립트가 루트 접두사를 붙인다 (운영: `/`, 테스트: `APPCLEANER_TEST_ROOT`).
public enum AdminOperation: Sendable, Hashable {
    case moveToHolding(session: UUID, path: String)
    /// `restoreTo`가 있으면 같은 폴더의 다른 이름으로 복원 (충돌 시 "이름 (복원됨)")
    case restoreFromHolding(session: UUID, originalPath: String, restoreTo: String?)
    case bootoutSystem(label: String)
    case bootstrapSystem(plistPath: String)
    case pkgForget(id: String)
    case purgeHolding(session: UUID)

    /// privileged-op.sh 인자 (작업 이름 + 인자)
    public var arguments: [String] {
        switch self {
        case .moveToHolding(let s, let p): return ["move-to-holding", s.uuidString, p]
        case .restoreFromHolding(let s, let p, let to):
            return ["restore-from-holding", s.uuidString, p] + (to.map { [$0] } ?? [])
        case .bootoutSystem(let l): return ["bootout-system", l]
        case .bootstrapSystem(let p): return ["bootstrap-system", p]
        case .pkgForget(let id): return ["pkg-forget", id]
        case .purgeHolding(let s): return ["purge-holding", s.uuidString]
        }
    }

    /// Swift 쪽 사전 검증 (권한 스크립트도 독립적으로 다시 검증한다). 문제가 있으면 사유 코드.
    public var preflightIssue: String? {
        func pathIssue(_ p: String) -> String? {
            guard p.hasPrefix("/") else { return "not-absolute" }
            if p.contains("\t") || p.contains("\n") || p.contains("\r") || p.contains("\0") { return "bad-char" }
            if SafetyGuard.normalize(p) != p { return "dotdot" }
            return nil
        }
        switch self {
        case .moveToHolding(_, let p): return pathIssue(p)
        case .restoreFromHolding(_, let p, let to): return pathIssue(p) ?? to.flatMap(pathIssue)
        case .bootstrapSystem(let p): return pathIssue(p)
        case .bootoutSystem(let l), .pkgForget(let l):
            if !SafeIdentifier.isValid(l) { return "bad-identifier" }
            return SafeIdentifier.isApple(l) ? "protected" : nil
        case .purgeHolding: return nil
        }
    }
}

public struct AdminOperationResult: Sendable, Hashable {
    public var operation: AdminOperation
    public var succeeded: Bool
    /// 성공 시 스크립트 메시지(예: 보류 폴더 내 위치), 실패 시 사유 코드
    public var message: String

    public init(operation: AdminOperation, succeeded: Bool, message: String) {
        self.operation = operation
        self.succeeded = succeeded
        self.message = message
    }

    /// 사용자에게 보여줄 사유
    public var reason: EngineText { succeeded ? EngineText(.adminDone) : PrivilegedScript.reason(message) }

    /// 한국어 사유
    public var localizedReason: String { reason.text }
}

/// 관리자 권한 실행기. **한 번의 호출 = 한 번의 인증**이므로 호출자는 작업을 모아서 보낸다 (plan.md 5.3).
public protocol AdminExecuting: Sendable {
    /// 결과는 입력과 같은 순서·같은 개수
    func run(_ operations: [AdminOperation]) async -> [AdminOperationResult]
}

/// 경로 변환 도구
public enum AdminPaths {
    /// 전체 경로 → 시스템 루트 기준 논리 경로. 루트 밖이면 nil.
    public static func logicalPath(of url: URL, root: URL) -> String? {
        let p = SafetyGuard.normalize(url.path)
        let r = SafetyGuard.normalize(root.path)
        if r == "/" { return p }
        for variant in Set([r, SafetyGuard.realpathOfExistingPrefix(r)]) {
            if p.hasPrefix(variant + "/") { return String(p.dropFirst(variant.count)) }
        }
        let real = SafetyGuard.realpathOfExistingPrefix(p)
        let rr = SafetyGuard.realpathOfExistingPrefix(r)
        if real.hasPrefix(rr + "/") { return String(real.dropFirst(rr.count)) }
        return nil
    }

    /// 논리 경로 → 전체 경로
    public static func fullURL(logical: String, root: URL) -> URL {
        let trimmed = logical.hasPrefix("/") ? String(logical.dropFirst()) : logical
        return root.appendingPathComponent(trimmed)
    }

    /// 보류 폴더 안 위치: `<holdingDir>/<session>/<원래 논리 경로>` (원래 경로 구조 유지)
    public static func holdingURL(session: UUID, logical: String, holdingDir: URL) -> URL {
        let trimmed = logical.hasPrefix("/") ? String(logical.dropFirst()) : logical
        return holdingDir.appendingPathComponent(session.uuidString, isDirectory: true).appendingPathComponent(trimmed)
    }
}

/// 고정 스크립트 `privileged-op.sh`를 관리자 권한으로 실행한다.
///
/// - 실행 전 스크립트 SHA-256을 컴파일된 상수와 비교 (`PrivilegedScript.sha256`).
/// - 작업 목록은 파일로 넘겨 `batch` 한 번으로 실행 → 세션당 인증 1회.
/// - GUI: `/usr/bin/osascript`의 `on run argv` AppleScript가 모든 인자를 `quoted form of`로 감싼다.
///   AppleScript 소스에는 사용자 경로가 들어가지 않는다.
/// - 권한 상승된 쪽에서도 스크립트를 root 소유 임시 폴더에 복사해 해시를 다시 확인한 뒤 그 사본을 실행한다.
/// - CLI: 같은 명령을 `sudo`로 실행.
public struct AppleScriptAdminExecutor: AdminExecuting {
    public enum Launcher: String, Sendable {
        /// GUI: 관리자 인증 대화상자 (`do shell script … with administrator privileges`)
        case osascript
        /// CLI: `sudo`
        case sudo
        /// 테스트·진단 전용: 현재 사용자로 스크립트를 바로 실행한다. root가 아니면 스크립트가 `APPCLEANER_TEST_ROOT`
        /// 아래에서만 동작하고 launchctl·pkgutil은 실행하지 않는다.
        case direct
    }

    public let runner: CommandRunning
    public let scriptURL: URL?
    public let launcher: Launcher
    public let expectedSHA256: String
    /// 작업 목록 파일을 만들 위치 (사용자 임시 폴더)
    public let workDirectory: URL

    public init(runner: CommandRunning, scriptURL: URL? = PrivilegedScript.bundledURL(), launcher: Launcher = .osascript,
                expectedSHA256: String = PrivilegedScript.sha256,
                workDirectory: URL = FileManager.default.temporaryDirectory) {
        self.runner = runner
        self.scriptURL = scriptURL
        self.launcher = launcher
        self.expectedSHA256 = expectedSHA256
        self.workDirectory = workDirectory
    }

    public func run(_ operations: [AdminOperation]) async -> [AdminOperationResult] {
        guard !operations.isEmpty else { return [] }
        var results: [AdminOperationResult?] = Array(repeating: nil, count: operations.count)
        var toRun: [(Int, AdminOperation)] = []
        for (i, op) in operations.enumerated() {
            if let issue = op.preflightIssue {
                results[i] = AdminOperationResult(operation: op, succeeded: false, message: issue)
            } else {
                toRun.append((i, op))
            }
        }
        func finish(_ failAll: String? = nil) -> [AdminOperationResult] {
            for (i, op) in toRun where results[i] == nil {
                results[i] = AdminOperationResult(operation: op, succeeded: false, message: failAll ?? "no-result")
            }
            return results.map { $0! }
        }
        guard !toRun.isEmpty else { return finish() }
        guard let scriptURL, PrivilegedScript.verify(scriptURL, expected: expectedSHA256) else {
            return finish("script-hash-mismatch")
        }

        let fm = FileManager.default
        let dir = workDirectory.appendingPathComponent("appcleaner-ops-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }
        let opsFile = dir.appendingPathComponent("ops.txt")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let body = toRun.map { $0.1.arguments.joined(separator: "\t") }.joined(separator: "\n") + "\n"
            guard fm.createFile(atPath: opsFile.path, contents: Data(body.utf8), attributes: [.posixPermissions: 0o600]) else {
                return finish("ops-file-failed")
            }
        } catch {
            return finish("ops-file-failed")
        }

        let output: CommandOutput
        do {
            output = try launch(script: scriptURL, opsFile: opsFile)
        } catch {
            return finish("launch-failed")
        }

        var byIndex: [Int: (Bool, String)] = [:]
        for line in output.string.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, let n = Int(fields[1]) else { continue }
            let msg = fields.count > 2 ? fields[2] : ""
            if n == 0 { return finish(msg.isEmpty ? "error" : msg) }
            byIndex[n] = (fields[0] == "ok", msg)
        }
        if byIndex.isEmpty && !output.succeeded {
            let cancelled = output.stderr.contains("-128") || output.stderr.lowercased().contains("cancel")
            return finish(cancelled ? "auth-cancelled" : "launch-failed")
        }
        for (k, (i, op)) in toRun.enumerated() {
            if let (ok, msg) = byIndex[k + 1] {
                results[i] = AdminOperationResult(operation: op, succeeded: ok, message: msg)
            }
        }
        return finish()
    }

    private func launch(script: URL, opsFile: URL) throws -> CommandOutput {
        let positional = [script.path, expectedSHA256, opsFile.path]
        switch launcher {
        case .osascript:
            var args: [String] = []
            for line in PrivilegedScript.appleScriptSource { args += ["-e", line] }
            args.append(PrivilegedScript.authorizationPrompt())
            args.append(PrivilegedScript.launcherShell)
            args += positional
            return try runner.run("/usr/bin/osascript", args)
        case .sudo:
            return try runner.run("/usr/bin/sudo", ["/bin/sh", "-c", PrivilegedScript.launcherShell, "appcleaner-op"] + positional)
        case .direct:
            return try runner.run("/bin/sh", [script.path, "batch", opsFile.path])
        }
    }
}
