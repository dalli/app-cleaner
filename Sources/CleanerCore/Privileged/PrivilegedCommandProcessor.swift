import Foundation

/// 권한 헬퍼가 실행하는 명령 처리기 (plan.md 5.3). 앱의 판단을 신뢰하지 않고 모든 값을 다시 검증한다.
///
/// - 명령은 `AdminOperation` 6종뿐이다 (보류 폴더 이동·복원·영구 삭제, 시스템 서비스 중지·재등록, 영수증 삭제).
///   임의 셸 명령·임의 경로 쓰기는 없다. 외부 명령은 `launchctl`·`pkgutil` 고정 경로에 인자 배열로만 넘긴다.
/// - 경로: 구문 → 허용 루트 → 보호 목록(헬퍼 고정 목록 + `SafetyGuard`) → fd 기반 이동(`SecureFileOperations`).
/// - 레이블·패키지 ID: `[A-Za-z0-9._-]`, `com.apple.*`·본 앱(헬퍼 포함) 금지.
/// - `runner`가 nil이면(테스트 루트) `launchctl`·`pkgutil`을 실행하지 않고 `test-mode`로 보고한다.
public struct PrivilegedCommandProcessor: Sendable {
    public let files: SecureFileOperations
    public let safety: SafetyGuard
    public let identity: PrivilegedHelperIdentity
    public let runner: CommandRunning?

    public static let launchctl = "/bin/launchctl"
    public static let pkgutil = "/usr/sbin/pkgutil"

    public init(files: SecureFileOperations, paths: SystemPaths, identity: PrivilegedHelperIdentity, runner: CommandRunning?) {
        self.files = files
        var paths = paths
        paths.selfBundleID = identity.appBundleID
        self.safety = SafetyGuard(paths: paths)
        self.identity = identity
        self.runner = runner
    }

    /// 헬퍼 프로세스(root)용 조립: 시스템 루트 `/`, 외부 명령 실행
    public static func live(identity: PrivilegedHelperIdentity) -> PrivilegedCommandProcessor {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let home = URL(fileURLWithPath: "/var/root", isDirectory: true)
        let holding = URL(fileURLWithPath: SecureFileOperations.holding, isDirectory: true)
        let paths = SystemPaths(home: home, root: root, userCacheDir: home.appendingPathComponent("Library/Caches"),
                                userTempDir: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
                                appDataDir: holding.deletingLastPathComponent(), holdingDir: holding,
                                uid: 0, selfBundleID: identity.appBundleID)
        return PrivilegedCommandProcessor(files: SecureFileOperations(rootPath: "/"), paths: paths, identity: identity,
                                          runner: ProcessCommandRunner(timeout: 120))
    }

    public func perform(_ operations: [AdminOperation]) -> [AdminOperationResult] {
        operations.map(perform)
    }

    public func perform(_ op: AdminOperation) -> AdminOperationResult {
        do {
            return AdminOperationResult(operation: op, succeeded: true, message: try execute(op))
        } catch let f as SecureFileOperations.Failure {
            return AdminOperationResult(operation: op, succeeded: false, message: f.code)
        } catch {
            return AdminOperationResult(operation: op, succeeded: false, message: "error")
        }
    }

    private func execute(_ op: AdminOperation) throws -> String {
        typealias Failure = SecureFileOperations.Failure
        switch op {
        case .moveToHolding(let session, let path):
            try checkTarget(path)
            return try files.moveToHolding(session: session, logicalPath: path, isProtectedBundleID: isProtectedBundleID)
        case .restoreFromHolding(let session, let original, let restoreTo):
            try checkTarget(original)
            if let restoreTo { try checkTarget(restoreTo) }
            return try files.restoreFromHolding(session: session, originalPath: original, restoreTo: restoreTo,
                                                isProtectedBundleID: isProtectedBundleID)
        case .purgeHolding(let session):
            try files.purgeHolding(session: session)
            return "purged"
        case .bootoutSystem(let label):
            try checkIdentifier(label)
            guard let runner else { return "test-mode" }
            let status = try run(runner, Self.launchctl, ["bootout", "system/\(label)"])
            // 이미 내려가 있으면 3(ESRCH)·113(서비스 없음) — 목표 상태이므로 성공
            guard [0, 3, 113].contains(status) else { throw Failure("launchctl-\(status)") }
            return "bootout"
        case .bootstrapSystem(let plist):
            _ = try SecureFileOperations.components(of: plist)
            try checkProtected(plist)
            try files.verifyLaunchDaemonPlist(plist)
            guard let runner else { return "test-mode" }
            let status = try run(runner, Self.launchctl, ["bootstrap", "system", files.fullPath(plist)])
            guard status == 0 else { throw Failure("launchctl-\(status)") }
            return "bootstrap"
        case .pkgForget(let id):
            try checkIdentifier(id)
            guard let runner else { return "test-mode" }
            let status = try run(runner, Self.pkgutil, ["--forget", id])
            guard status == 0 else { throw Failure("pkgutil-\(status)") }
            return "forgot"
        }
    }

    private func run(_ runner: CommandRunning, _ executable: String, _ arguments: [String]) throws -> Int32 {
        do {
            return try runner.run(executable, arguments).status
        } catch {
            throw SecureFileOperations.Failure("launch-failed")
        }
    }

    // MARK: 검증

    /// 구문 + 허용 루트 + 보호 목록
    func checkTarget(_ logical: String) throws {
        _ = try SecureFileOperations.target(logical)
        try checkProtected(logical)
    }

    /// 헬퍼 고정 보호 목록(privileged-op.sh와 같음)을 먼저 보고, 이어서 `SafetyGuard`(plan.md 5.1)로 독립 재검증한다.
    func checkProtected(_ logical: String) throws {
        typealias Failure = SecureFileOperations.Failure
        let key = SafetyGuard.key(logical)
        let subtrees = ["/library/application support/\(SystemPaths.ourAppFolderName.lowercased())",
                        "/library/application support/apple", "/library/application support/mobilesync"]
        if subtrees.contains(where: { key == $0 || key.hasPrefix($0 + "/") }) { throw Failure("protected") }
        if ["/library/logs/diagnosticreports", "/applications/utilities"].contains(key) { throw Failure("protected") }
        let selfID = identity.appBundleID.lowercased()
        for comp in key.split(separator: "/") {
            if comp.hasPrefix("com.apple.") || comp.hasPrefix("group.com.apple.") || comp == selfID || comp.hasPrefix(selfID + ".") {
                throw Failure("protected")
            }
        }
        if case .blocked(let reason, _) = safety.verdict(for: URL(fileURLWithPath: files.fullPath(logical)), bundleID: nil) {
            throw Failure(reason == .symlinkEscape ? "symlink" : "protected")
        }
    }

    func checkIdentifier(_ id: String) throws {
        guard SafeIdentifier.isValid(id) else { throw SecureFileOperations.Failure("bad-identifier") }
        if isProtectedBundleID(id) { throw SecureFileOperations.Failure("protected") }
    }

    /// Apple·본 앱(헬퍼·CLI 포함) 식별자
    func isProtectedBundleID(_ id: String) -> Bool {
        let l = id.lowercased()
        let selfID = identity.appBundleID.lowercased()
        return SafeIdentifier.isApple(l) || l == selfID || l.hasPrefix(selfID + ".")
    }
}
