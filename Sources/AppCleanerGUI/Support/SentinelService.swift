import AppKit
import CleanerCore
import Foundation
import ServiceManagement

/// Sentinel 로그인 항목 상태 (ui-ux.md S7·S10)
enum SentinelRegistration: Equatable, Sendable {
    /// 등록됨 (로그인 때와 등록 즉시 실행)
    case enabled
    /// 등록했지만 사용자가 시스템 설정 › 로그인 항목에서 허용해야 함
    case requiresApproval
    case disabled
    /// `.app` 번들 밖에서 실행(개발 빌드)했거나 번들에 Sentinel이 없음
    case unavailable

    /// 번들에 Sentinel이 있을 때의 `SMAppService.Status` → 상태.
    /// 한 번도 등록하지 않은 로그인 항목은 `.notFound`가 나온다 (macOS 27에서 확인) — 등록하지 않은 것으로 보고
    /// 등록을 시도한다. 정말 등록할 수 없으면 `register()`가 오류를 내고 S7에 표시된다.
    init(status: SMAppService.Status) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered, .notFound: self = .disabled
        @unknown default: self = .unavailable
        }
    }
}

/// Sentinel 등록·해제. 실제 앱은 `SMAppService.loginItem`, 데모·테스트는 메모리 구현을 쓴다
/// (테스트가 이 Mac의 로그인 항목을 바꾸지 않도록).
@MainActor
protocol SentinelServicing: AnyObject {
    var registration: SentinelRegistration { get }
    func register() throws
    func unregister() async throws
    /// 설정을 바꿨다고 실행 중인 Sentinel에 알린다 (다시 읽거나, 모두 꺼졌으면 종료)
    func notifySettingsChanged()
    /// 등록돼 있지만 사용자가 메뉴에서 종료한 Sentinel을 다시 띄운다
    func launchIfNeeded()
}

@MainActor
final class LiveSentinelService: SentinelServicing {
    private let service: SMAppService?
    private let helperURL: URL

    init(bundle: Bundle = .main) {
        helperURL = SentinelIdentity.helperURL(inApp: bundle.bundleURL)
        let bundled = bundle.bundleIdentifier == SentinelIdentity.mainBundleID
            && FileManager.default.fileExists(atPath: helperURL.path)
        service = bundled ? SMAppService.loginItem(identifier: SentinelIdentity.bundleID) : nil
    }

    var registration: SentinelRegistration {
        guard let service else { return .unavailable }
        return SentinelRegistration(status: service.status)
    }

    func register() throws {
        try service?.register()
    }

    func unregister() async throws {
        try await service?.unregister()
    }

    func notifySettingsChanged() {
        SentinelSignal.postSettingsChanged()
    }

    func launchIfNeeded() {
        guard registration == .enabled else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: helperURL, configuration: config)
    }
}

/// 데모·테스트용 (시스템을 바꾸지 않는다)
@MainActor
final class InMemorySentinelService: SentinelServicing {
    var registration: SentinelRegistration
    /// 다음 `register()`가 던질 오류
    var registerError: (any Error)?
    private(set) var settingsChangedCount = 0
    private(set) var launchCount = 0

    init(registration: SentinelRegistration = .disabled) {
        self.registration = registration
    }

    func register() throws {
        if let e = registerError { registerError = nil; throw e }
        registration = .enabled
    }

    func unregister() async throws {
        registration = .disabled
    }

    func notifySettingsChanged() { settingsChangedCount += 1 }

    func launchIfNeeded() {
        if registration == .enabled { launchCount += 1 }
    }
}
