import CleanerCore
import Foundation
import Observation

/// 사이드바 메뉴 (ui-ux.md 2장)
enum SidebarRoute: String, CaseIterable, Hashable, Sendable {
    case apps
    case orphans
    case history
    case settings
}

/// 설정 저장소. 실제 앱은 `UserDefaults`, 테스트는 메모리 저장소를 쓴다 (테스트가 실제 파일을 만들지 않도록).
protocol SettingsStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: SettingsStore {}

final class InMemorySettingsStore: SettingsStore {
    private var values: [String: Any] = [:]
    init(_ values: [String: Any] = [:]) { self.values = values }
    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

/// GUI 쪽 사용자 설정 (UserDefaults). 엔진 계약에 없는 값만 여기에 둔다.
@MainActor
@Observable
final class AppSettings {
    static let retentionChoices = [7, 14, 30, 60]

    @ObservationIgnored private let defaults: SettingsStore

    var holdingRetentionDays: Int { didSet { defaults.set(holdingRetentionDays, forKey: Keys.retention) } }
    var resetPrivacyByDefault: Bool { didSet { defaults.set(resetPrivacyByDefault, forKey: Keys.resetPrivacy) } }
    var includeDotfiles: Bool { didSet { defaults.set(includeDotfiles, forKey: Keys.dotfiles) } }
    var autoUpdateRules: Bool { didSet { defaults.set(autoUpdateRules, forKey: Keys.autoUpdate) } }
    var onboardingCompleted: Bool { didSet { defaults.set(onboardingCompleted, forKey: Keys.onboarding) } }
    var lastRoute: SidebarRoute { didSet { defaults.set(lastRoute.rawValue, forKey: Keys.lastRoute) } }
    /// 휴지통 감시 (Sentinel — ui-ux.md S10). 키는 Sentinel과 함께 쓴다
    var trashWatchEnabled: Bool { didSet { defaults.set(trashWatchEnabled, forKey: SentinelIdentity.Keys.trashWatch) } }
    /// 정기 고아 스캔 주기 (Sentinel이 실행)
    var periodicScan: PeriodicScanInterval {
        didSet { defaults.set(periodicScan.rawValue, forKey: SentinelIdentity.Keys.periodicScan) }
    }

    init(defaults: SettingsStore) {
        self.defaults = defaults
        let retention = defaults.object(forKey: Keys.retention) as? Int ?? 0
        holdingRetentionDays = Self.retentionChoices.contains(retention) ? retention : 30
        resetPrivacyByDefault = defaults.object(forKey: Keys.resetPrivacy) as? Bool ?? false
        includeDotfiles = defaults.object(forKey: Keys.dotfiles) as? Bool ?? false
        autoUpdateRules = defaults.object(forKey: Keys.autoUpdate) as? Bool ?? true
        onboardingCompleted = defaults.object(forKey: Keys.onboarding) as? Bool ?? false
        lastRoute = (defaults.object(forKey: Keys.lastRoute) as? String).flatMap(SidebarRoute.init(rawValue:)) ?? .apps
        let sentinel = SentinelPreferences(read: defaults.object(forKey:))
        trashWatchEnabled = sentinel.trashWatch
        periodicScan = sentinel.periodicScan
    }

    /// Sentinel 설정과 Sentinel이 기록한 상태(마지막 정기 스캔, 휴지통 읽기, 알림 허용)를 저장소에서 다시 읽는다
    func sentinelPreferences() -> SentinelPreferences {
        // Sentinel(다른 프로세스)이 쓴 값을 읽기 전에 동기화
        if defaults is UserDefaults { CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication) }
        return SentinelPreferences(read: defaults.object(forKey:))
    }

    /// 테스트용 메모리 저장소
    static func inMemory() -> AppSettings {
        AppSettings(defaults: InMemorySettingsStore())
    }

    private enum Keys {
        static let retention = "holdingRetentionDays"
        static let resetPrivacy = "resetPrivacyByDefault"
        static let dotfiles = "orphanIncludeDotfiles"
        static let autoUpdate = "ruleDataAutoUpdate"
        static let onboarding = "onboardingCompleted"
        static let lastRoute = "lastSidebarRoute"
    }
}
