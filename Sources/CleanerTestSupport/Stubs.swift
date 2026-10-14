import Foundation
import CleanerCore

/// 명령별 응답을 등록하는 가짜 CommandRunner. 등록되지 않은 명령은 종료 코드 1.
/// 호출 기록을 남겨 "bootout이 종료보다 먼저 호출됐는지" 같은 순서 검증에 쓴다.
public final class StubCommandRunner: CommandRunning, @unchecked Sendable {
    public typealias Handler = @Sendable ([String]) -> CommandOutput

    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    private var _calls: [(String, [String])] = []

    public init() {}

    /// `executable`은 전체 경로 또는 파일명 (예: "/usr/sbin/pkgutil" 또는 "pkgutil")
    public func on(_ executable: String, _ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        handlers[executable] = handler
    }

    public func on(_ executable: String, stdout: String, status: Int32 = 0) {
        on(executable) { _ in CommandOutput(status: status, stdout: Data(stdout.utf8)) }
    }

    public var calls: [(executable: String, arguments: [String])] {
        lock.lock(); defer { lock.unlock() }
        return _calls.map { ($0.0, $0.1) }
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        lock.lock()
        _calls.append((executable, arguments))
        let handler = handlers[executable] ?? handlers[URL(fileURLWithPath: executable).lastPathComponent]
        lock.unlock()
        return handler?(arguments) ?? CommandOutput(status: 1, stdout: Data(), stderr: "stub: not registered")
    }
}

/// 경로별 서명 정보를 돌려주는 가짜 리더 (픽스처 앱은 서명이 없으므로)
public final class StubSignatureReader: CodeSignatureReading, @unchecked Sendable {
    private let lock = NSLock()
    private var infos: [String: SigningInfo] = [:]

    public init() {}

    public func set(_ info: SigningInfo, for bundleURL: URL) {
        lock.lock(); defer { lock.unlock() }
        infos[bundleURL.standardizedFileURL.path] = info
    }

    public func signingInfo(for bundleURL: URL) -> SigningInfo? {
        lock.lock(); defer { lock.unlock() }
        return infos[bundleURL.standardizedFileURL.path]
    }
}
