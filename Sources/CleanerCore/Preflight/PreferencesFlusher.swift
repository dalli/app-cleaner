import Foundation

/// 환경설정 캐시 무효화 (plan.md 4.4 3단계, 6.2 복원)
public protocol PreferencesFlushing: Sendable {
    /// plist 사본을 `backupDirectory`에 **먼저** 보관한 뒤 cfprefs 도메인을 지운다. 보관할 내용이 없으면 nil.
    func flush(domain: String, backupDirectory: URL) throws -> PreferencesBackup?
    /// 보관해 둔 사본으로 도메인을 되살린다 (`defaults import`).
    func restore(_ backup: PreferencesBackup) throws
}

/// `defaults` 기반 구현 (외부 명령은 `CommandRunning`으로만 실행).
/// `defaults delete`는 cfprefsd를 거치므로 메모리 캐시가 plist를 되살리는 문제가 없다. 대신 plist 파일도 함께 지워질 수
/// 있으므로 이동 단계는 보관한 사본으로 휴지통 항목을 만든다 (CleanupExecutor 참조).
public struct CFPreferencesFlusher: PreferencesFlushing {
    public let paths: SystemPaths
    public let runner: CommandRunning

    public static let defaults = "/usr/bin/defaults"

    public init(paths: SystemPaths, runner: CommandRunning) {
        self.paths = paths
        self.runner = runner
    }

    public func plistURL(for domain: String) -> URL {
        paths.userLibrary.appendingPathComponent("Preferences/\(domain).plist")
    }

    public func flush(domain: String, backupDirectory: URL) throws -> PreferencesBackup? {
        guard SafeIdentifier.isValid(domain) else { throw CleanupError(.prefsDomainInvalid, domain) }
        guard !SafeIdentifier.isApple(domain), domain.lowercased() != paths.selfBundleID.lowercased() else {
            throw CleanupError(.prefsDomainProtected, domain)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let backup = backupDirectory.appendingPathComponent("\(domain).plist")
        if fm.itemExists(backup) { try fm.removeItem(at: backup) }

        let source = plistURL(for: domain)
        if fm.itemExists(source) {
            try fm.copyItem(at: source, to: backup)
        } else {
            // 파일이 없어도 cfprefsd 메모리에만 남은 값이 있을 수 있다.
            _ = try? runner.run(Self.defaults, ["export", domain, backup.path])
        }

        let out = try runner.run(Self.defaults, ["delete", domain])
        if !out.succeeded && !out.stderr.contains("does not exist") {
            throw CleanupError(.prefsFlushFailed, domain, String(out.status))
        }
        return fm.itemExists(backup) ? PreferencesBackup(domain: domain, backupPath: backup.path) : nil
    }

    public func restore(_ backup: PreferencesBackup) throws {
        guard SafeIdentifier.isValid(backup.domain) else { throw CleanupError(.prefsDomainInvalidNoName) }
        guard FileManager.default.itemExists(URL(fileURLWithPath: backup.backupPath)) else {
            throw CleanupError(.prefsBackupMissing, backup.domain)
        }
        let out = try runner.run(Self.defaults, ["import", backup.domain, backup.backupPath])
        guard out.succeeded else { throw CleanupError(.prefsRestoreFailed, backup.domain, String(out.status)) }
    }
}
