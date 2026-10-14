import Foundation

public enum InstallSource: String, Codable, Sendable, CaseIterable {
    case appStore
    case homebrew
    case package
    case direct
}

/// 대상 앱의 식별 정보 (plan.md 4.1)
public struct AppIdentity: Codable, Sendable, Hashable {
    public var bundleURL: URL
    public var bundleID: String
    /// CFBundleName (없으면 파일명)
    public var name: String
    public var displayName: String?
    public var executableName: String?
    public var version: String?
    public var teamID: String?
    public var appGroups: [String]
    /// 내장 헬퍼·확장·LoginItem 등의 BID
    public var embeddedBundleIDs: [String]
    /// 번들 내장 Launch plist(SMAppService)의 서비스
    public var embeddedLaunchServices: [LaunchServiceRef]
    /// iOS/iPadOS 앱(Wrapper)의 내부 번들 BID
    public var wrappedBundleID: String?
    public var packageIDs: [String]
    public var homebrewCask: String?
    public var source: InstallSource

    public init(
        bundleURL: URL,
        bundleID: String,
        name: String,
        displayName: String? = nil,
        executableName: String? = nil,
        version: String? = nil,
        teamID: String? = nil,
        appGroups: [String] = [],
        embeddedBundleIDs: [String] = [],
        embeddedLaunchServices: [LaunchServiceRef] = [],
        wrappedBundleID: String? = nil,
        packageIDs: [String] = [],
        homebrewCask: String? = nil,
        source: InstallSource = .direct
    ) {
        self.bundleURL = bundleURL
        self.bundleID = bundleID
        self.name = name
        self.displayName = displayName
        self.executableName = executableName
        self.version = version
        self.teamID = teamID
        self.appGroups = appGroups
        self.embeddedBundleIDs = embeddedBundleIDs
        self.embeddedLaunchServices = embeddedLaunchServices
        self.wrappedBundleID = wrappedBundleID
        self.packageIDs = packageIDs
        self.homebrewCask = homebrewCask
        self.source = source
    }

    /// 본체 + 내장 + Wrapped BID (중복 제거)
    public var allBundleIDs: [String] {
        var seen = Set<String>()
        return ([bundleID] + embeddedBundleIDs + [wrappedBundleID].compactMap { $0 })
            .filter { seen.insert($0).inserted }
    }

    /// 표시용 이름
    public var title: String { displayName ?? name }

    /// 이름 매칭에 쓰는 후보 이름 (CFBundleName, 표시 이름, .app 파일명)
    public var candidateNames: [String] {
        var seen = Set<String>()
        let fileName = bundleURL.deletingPathExtension().lastPathComponent
        return [name, displayName, fileName].compactMap { $0 }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// S1 앱 목록 행
public struct InstalledApp: Codable, Sendable, Hashable, Identifiable {
    public var url: URL
    public var bundleID: String
    public var name: String
    public var version: String?
    public var source: InstallSource
    public var size: Int64?
    public var lastUsed: Date?
    public var isRunning: Bool

    public var id: String { url.path }

    public init(url: URL, bundleID: String, name: String, version: String? = nil, source: InstallSource = .direct,
                size: Int64? = nil, lastUsed: Date? = nil, isRunning: Bool = false) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.version = version
        self.source = source
        self.size = size
        self.lastUsed = lastUsed
        self.isRunning = isRunning
    }
}
