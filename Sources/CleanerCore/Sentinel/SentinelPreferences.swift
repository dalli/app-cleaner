import Foundation

/// 정기 고아 스캔 주기 (ui-ux.md S7·S10)
public enum PeriodicScanInterval: String, Codable, Sendable, CaseIterable {
    case off
    case weekly
    case monthly
}

/// 본 앱과 Sentinel이 함께 쓰는 식별자·설정 키 (ui-ux.md S10).
///
/// 설정은 본 앱의 `UserDefaults`(`com.dallisoft.AppCleaner`)에 있다. 본 앱은 `UserDefaults.standard`로,
/// Sentinel은 `UserDefaults(suiteName: mainBundleID)`로 같은 도메인을 읽는다.
/// Sentinel은 상태 키(`Keys.status*`)만 쓴다.
public enum SentinelIdentity {
    public static let mainBundleID = SystemPaths.defaultSelfBundleID
    public static let bundleID = mainBundleID + ".Sentinel"
    /// 본 앱 번들 안의 위치: `Contents/Library/LoginItems/<appName>` (`SMAppService.loginItem`이 찾는 곳)
    public static let appName = "App Cleaner Sentinel.app"
    public static let executableName = "AppCleanerSentinel"

    /// Sentinel 번들 위치에서 본 앱 번들 (`…/App Cleaner.app/Contents/Library/LoginItems/Sentinel.app` → `…/App Cleaner.app`).
    /// 이 구조 안에 있지 않으면 nil.
    public static func containingApp(ofHelper helper: URL) -> URL? {
        let loginItems = helper.deletingLastPathComponent()
        let library = loginItems.deletingLastPathComponent()
        let contents = library.deletingLastPathComponent()
        let app = contents.deletingLastPathComponent()
        guard loginItems.lastPathComponent == "LoginItems", library.lastPathComponent == "Library",
              contents.lastPathComponent == "Contents", app.pathExtension.lowercased() == "app" else { return nil }
        return app
    }

    /// 본 앱 번들 안의 Sentinel 위치
    public static func helperURL(inApp app: URL) -> URL {
        app.appendingPathComponent("Contents/Library/LoginItems").appendingPathComponent(appName)
    }

    /// 본 앱 번들 안의 CLI (정기 스캔을 자식 프로세스로 실행)
    public static func cliURL(inApp app: URL) -> URL {
        app.appendingPathComponent("Contents/Helpers/appcleaner")
    }

    public enum Keys {
        public static let trashWatch = "sentinelTrashWatch"
        public static let periodicScan = "sentinelPeriodicScan"
        /// 마지막으로 성공한 정기 스캔 시각 (Sentinel이 씀)
        public static let statusLastScan = "sentinelLastScanAt"
        /// 마지막으로 시도한 정기 스캔 시각 (실패 후 재시도 간격용, Sentinel이 씀)
        public static let statusLastAttempt = "sentinelLastScanAttemptAt"
        /// Sentinel이 `~/.Trash`를 읽을 수 있는지 (Sentinel이 씀)
        public static let statusTrashReadable = "sentinelTrashReadable"
        /// 알림 허용 상태 `SentinelNotificationState` (Sentinel이 씀)
        public static let statusNotifications = "sentinelNotifications"
    }
}

/// Sentinel 알림 허용 상태 (S7·S10 표시용)
public enum SentinelNotificationState: String, Codable, Sendable {
    case allowed
    case denied
    case notDetermined
}

/// 본 앱 설정 중 Sentinel이 따르는 값 + Sentinel이 기록한 상태
public struct SentinelPreferences: Sendable, Hashable {
    public var trashWatch: Bool
    public var periodicScan: PeriodicScanInterval
    public var lastScan: Date?
    public var lastAttempt: Date?
    public var trashReadable: Bool?
    public var notifications: SentinelNotificationState?

    public init(trashWatch: Bool = false, periodicScan: PeriodicScanInterval = .off, lastScan: Date? = nil,
                lastAttempt: Date? = nil, trashReadable: Bool? = nil, notifications: SentinelNotificationState? = nil) {
        self.trashWatch = trashWatch
        self.periodicScan = periodicScan
        self.lastScan = lastScan
        self.lastAttempt = lastAttempt
        self.trashReadable = trashReadable
        self.notifications = notifications
    }

    /// 휴지통 감시나 정기 스캔 중 하나라도 켜져 있으면 Sentinel이 실행되어야 한다
    public var needsSentinel: Bool { trashWatch || periodicScan != .off }

    /// 키 → 값 조회 (`UserDefaults.object(forKey:)` 또는 테스트용 사전)
    public init(read: (String) -> Any?) {
        typealias K = SentinelIdentity.Keys
        self.init(
            trashWatch: read(K.trashWatch) as? Bool ?? false,
            periodicScan: (read(K.periodicScan) as? String).flatMap(PeriodicScanInterval.init(rawValue:)) ?? .off,
            lastScan: read(K.statusLastScan) as? Date,
            lastAttempt: read(K.statusLastAttempt) as? Date,
            trashReadable: read(K.statusTrashReadable) as? Bool,
            notifications: (read(K.statusNotifications) as? String).flatMap(SentinelNotificationState.init(rawValue:))
        )
    }
}

/// 본 앱(엔진 포함) ↔ Sentinel 분산 알림 (`DistributedNotificationCenter`).
/// 받는 쪽이 없으면 아무 일도 일어나지 않는다.
public enum SentinelSignal {
    /// 본 앱이 설정을 바꿨다 → Sentinel이 설정을 다시 읽는다
    public static let settingsChanged = Notification.Name("com.dallisoft.AppCleaner.sentinel.settingsChanged")
    /// App Cleaner(GUI·CLI)가 앱 제거를 시작한다 → Sentinel은 이 앱이 휴지통에 들어와도 알리지 않는다.
    /// `userInfo["bundleIDs"]`: [String]
    public static let appRemovalStarted = Notification.Name("com.dallisoft.AppCleaner.sentinel.appRemovalStarted")
    public static let bundleIDsKey = "bundleIDs"

    /// 앱 본체를 휴지통으로 옮기는 앱 제거 계획이면 그 앱의 번들 ID (아니면 빈 배열)
    public static func removedBundleIDs(in plan: CleanupPlan) -> [String] {
        guard plan.kind == .appRemoval, plan.items.contains(where: { $0.category == .appBundle }),
              let bid = plan.targetBundleID else { return [] }
        return [bid]
    }

    /// 앱 제거 계획이면(앱 본체 포함) 신호를 보낸다
    public static func postAppRemovalIfNeeded(_ plan: CleanupPlan) {
        let bids = removedBundleIDs(in: plan)
        guard !bids.isEmpty else { return }
        DistributedNotificationCenter.default().postNotificationName(
            appRemovalStarted, object: nil, userInfo: [bundleIDsKey: bids], deliverImmediately: true)
    }

    public static func postSettingsChanged() {
        DistributedNotificationCenter.default().postNotificationName(settingsChanged, object: nil, userInfo: nil,
                                                                     deliverImmediately: true)
    }
}
