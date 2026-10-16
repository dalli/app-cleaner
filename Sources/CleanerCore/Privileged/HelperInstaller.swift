import Foundation
import ServiceManagement

/// 권한 헬퍼 설치 상태 (ui-ux.md S7 "관리자 헬퍼")
public enum HelperInstallState: String, Sendable, Hashable {
    /// 등록하지 않음 — 관리자 작업은 관리자 암호(AppleScript)로
    case notInstalled
    /// 등록했지만 시스템 설정 › 일반 › 로그인 항목에서 허용해야 실행된다
    case requiresApproval
    /// 등록·허용됨 — 관리자 작업에 암호를 묻지 않는다
    case enabled
    /// 이 실행 방식에서는 설치할 수 없음 (`.app` 번들 밖에서 실행, 번들에 헬퍼 plist 없음, 헬퍼가 연결을 받지 않는 서명)
    case unavailable

    /// `SMAppService.Status` → 설치 상태.
    ///
    /// 한 번도 등록하지 않은 서비스는 번들에 plist가 있어도 `.notFound`가 나온다 (macOS 27에서 확인) — `.notRegistered`와
    /// 같이 "설치 안 됨"으로 본다. 정말 등록할 수 없으면 `register()`가 오류를 낸다.
    /// `canConnect`: 이 빌드의 헬퍼가 연결을 받는지 (Team ID 서명 또는 개발 모드). 아니면 설치해도 쓸 수 없으므로
    /// 설치를 권하지 않는다 — 이미 등록된 헬퍼는 제거할 수 있도록 그대로 보인다.
    public init(status: SMAppService.Status, canConnect: Bool) {
        switch status {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered, .notFound: self = canConnect ? .notInstalled : .unavailable
        @unknown default: self = .unavailable
        }
    }
}

/// 헬퍼 등록·해제 (`SMAppService.daemon(plistName:)`). GUI 설정 화면이 쓴다.
public protocol HelperInstalling: Sendable {
    func state() -> HelperInstallState
    /// 등록. 대부분 사용자가 로그인 항목에서 허용해야 하므로 끝나면 `state()`를 다시 확인한다.
    func install() throws
    func uninstall() async throws
}

/// 헬퍼를 설치할 수 없는 환경 (테스트 기본값)
public struct UnavailableHelperInstaller: HelperInstalling {
    public init() {}
    public func state() -> HelperInstallState { .unavailable }
    public func install() throws { throw CleanupError(.helperNotBundled) }
    public func uninstall() async throws {}
}

/// `SMAppService` 구현. 앱 번들의 `Contents/Library/LaunchDaemons/<plistName>`이 있어야 한다 (`scripts/build-app.sh`).
public struct SMAppServiceHelperInstaller: HelperInstalling {
    /// 개발 모드(`HELPER_DEV=1 scripts/build-app.sh`)로 만든 번들의 Info.plist 표시 — 헬퍼가 Team ID 없이 연결을 받는다
    public static let developmentModeKey = "AppCleanerHelperDevelopment"

    public let identity: PrivilegedHelperIdentity
    public let bundleURL: URL
    /// 이 빌드의 헬퍼가 연결을 받는지: Team ID로 서명했거나 개발 모드 번들
    public let canConnect: Bool

    public init(identity: PrivilegedHelperIdentity = .forCurrentProcess(), bundleURL: URL = Bundle.main.bundleURL,
                canConnect: Bool = SMAppServiceHelperInstaller.currentBuildCanConnect()) {
        self.identity = identity
        self.bundleURL = bundleURL
        self.canConnect = canConnect
    }

    /// 헬퍼는 Team ID가 없는 서명이면 연결을 받지 않는다 (개발 모드 컴파일 조건 제외 — `AppCleanerHelper/main.swift`)
    public static func currentBuildCanConnect(bundle: Bundle = .main,
                                              signing: SigningInfo? = SelfCodeSignature.current()) -> Bool {
        signing?.teamID != nil || bundle.object(forInfoDictionaryKey: developmentModeKey) as? Bool == true
    }

    /// 번들 안 launchd plist 위치
    public var plistURL: URL {
        bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons", isDirectory: true)
            .appendingPathComponent(identity.plistName)
    }

    private var service: SMAppService { SMAppService.daemon(plistName: identity.plistName) }

    private var isBundled: Bool {
        bundleURL.pathExtension == "app" && FileManager.default.fileExists(atPath: plistURL.path)
    }

    public func state() -> HelperInstallState {
        guard isBundled else { return .unavailable }
        return HelperInstallState(status: service.status, canConnect: canConnect)
    }

    public func install() throws {
        guard isBundled else { throw CleanupError(.helperNotBundled) }
        try service.register()
    }

    public func uninstall() async throws {
        guard isBundled else { return }
        try await service.unregister()
    }

    /// 시스템 설정 › 일반 › 로그인 항목 (사용자 승인)
    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
