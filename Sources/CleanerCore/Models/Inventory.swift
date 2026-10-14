import Foundation

/// 설치 앱 인벤토리의 앱 1개 (plan.md 4.5.2)
public struct InventoryApp: Codable, Sendable, Hashable {
    public var url: URL
    public var bundleID: String
    public var name: String
    public var executableName: String?
    public var teamID: String?
    public var appGroups: [String]
    public var embeddedBundleIDs: [String]
    public var launchLabels: [String]
    public var wrappedBundleID: String?
    public var modified: Date?

    public init(url: URL, bundleID: String, name: String, executableName: String? = nil, teamID: String? = nil,
                appGroups: [String] = [], embeddedBundleIDs: [String] = [], launchLabels: [String] = [],
                wrappedBundleID: String? = nil, modified: Date? = nil) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.executableName = executableName
        self.teamID = teamID
        self.appGroups = appGroups
        self.embeddedBundleIDs = embeddedBundleIDs
        self.launchLabels = launchLabels
        self.wrappedBundleID = wrappedBundleID
        self.modified = modified
    }

    public var allBundleIDs: [String] { [bundleID] + embeddedBundleIDs + [wrappedBundleID].compactMap { $0 } }
}

public struct SpotlightStatus: Codable, Sendable, Hashable {
    public var indexingEnabled: Bool
    /// 표준 위치 앱이 모두 Spotlight 결과에 있었는지
    public var complete: Bool
    public var missingApps: [String]

    public init(indexingEnabled: Bool, complete: Bool, missingApps: [String] = []) {
        self.indexingEnabled = indexingEnabled
        self.complete = complete
        self.missingApps = missingApps
    }

    public var isReliable: Bool { indexingEnabled && complete }
    public static let unknown = SpotlightStatus(indexingEnabled: false, complete: false)
}

/// 설치 앱 인벤토리 스냅샷. 앱 제거(공유 판정)와 고아 스캔이 함께 쓴다.
public struct InventorySnapshot: Codable, Sendable {
    public var apps: [InventoryApp]
    /// `brew list --cask` 토큰
    public var homebrewCasks: [String]
    /// `pkgutil --pkgs`
    public var packageIDs: [String]
    /// LaunchServices에 기록됐지만 연결 해제된 외장 볼륨에 있는 앱 BID
    public var offlineVolumeBundleIDs: [String]
    public var spotlight: SpotlightStatus
    public var builtAt: Date

    public init(apps: [InventoryApp], homebrewCasks: [String] = [], packageIDs: [String] = [],
                offlineVolumeBundleIDs: [String] = [], spotlight: SpotlightStatus = .unknown, builtAt: Date = Date()) {
        self.apps = apps
        self.homebrewCasks = homebrewCasks
        self.packageIDs = packageIDs
        self.offlineVolumeBundleIDs = offlineVolumeBundleIDs
        self.spotlight = spotlight
        self.builtAt = builtAt
    }

    /// 내장 번들·Wrapped BID까지 포함한 BID 집합 (소문자)
    public var allBundleIDs: Set<String> {
        Set(apps.flatMap(\.allBundleIDs).map { $0.lowercased() })
    }

    public var allLaunchLabels: Set<String> { Set(apps.flatMap(\.launchLabels)) }

    public func apps(usingGroup group: String) -> [InventoryApp] {
        apps.filter { $0.appGroups.contains(group) }
    }

    public func apps(withTeamID team: String) -> [InventoryApp] {
        apps.filter { $0.teamID == team }
    }

    /// BID 또는 그 하위 BID(`<bid>.`)가 인벤토리에 있는지
    public func containsBundleID(_ bid: String) -> Bool {
        let lower = bid.lowercased()
        return allBundleIDs.contains { $0 == lower || $0.hasPrefix(lower + ".") || lower.hasPrefix($0 + ".") }
    }
}
