import CleanerCore
import Foundation

/// 데모 모드의 관리자 헬퍼 — 시스템에 등록하지 않고 상태만 바꾼다.
/// 설치하면 "승인 필요", 승인 안내(로그인 항목 열기)를 누르면 "설치됨"으로 보여 준다.
final class DemoHelperInstaller: HelperInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var current: HelperInstallState

    init(state: HelperInstallState = .notInstalled) {
        current = state
    }

    func state() -> HelperInstallState { lock.withLock { current } }

    func install() throws { lock.withLock { current = .requiresApproval } }

    func uninstall() async throws { lock.withLock { current = .notInstalled } }

    /// 데모: 로그인 항목에서 허용한 것으로 본다
    func approve() { lock.withLock { if current == .requiresApproval { current = .enabled } } }
}
