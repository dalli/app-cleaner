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
    /// 이 실행 방식에서는 설치할 수 없음 (`.app` 번들 밖에서 실행, 번들에 헬퍼 plist 없음)
    case unavailable
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
    public let identity: PrivilegedHelperIdentity
    public let bundleURL: URL

    public init(identity: PrivilegedHelperIdentity = .forCurrentProcess(), bundleURL: URL = Bundle.main.bundleURL) {
        self.identity = identity
        self.bundleURL = bundleURL
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
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notInstalled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
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
