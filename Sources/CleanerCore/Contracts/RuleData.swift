import Foundation

/// Homebrew Cask 스냅샷의 cask 1개 (zap 경로만 축약 보관)
public struct HomebrewCask: Codable, Sendable, Hashable {
    public var token: String
    public var names: [String]
    /// cask가 설치하는 `.app` 파일명 (예: "Slack.app")
    public var apps: [String]
    /// uninstall/zap에 나오는 BID (launchctl, quit, pkgutil 등)
    public var bundleIDs: [String]
    /// `zap trash:` / `delete:` 경로 (`~` 포함, 와일드카드 가능)
    public var zap: [String]

    public init(token: String, names: [String] = [], apps: [String] = [], bundleIDs: [String] = [], zap: [String] = []) {
        self.token = token
        self.names = names
        self.apps = apps
        self.bundleIDs = bundleIDs
        self.zap = zap
    }
}

/// 설치 스크립트(`curl … | sh`, `npm i -g` 밖의 설치)로 설치하는 CLI 도구 1개 (docs/packages.md)
public struct StandaloneTool: Codable, Sendable, Hashable {
    /// 도구 이름 (설치 항목·데이터 폴더 이름 기준)
    public var name: String
    /// 실행 파일이 놓이는 경로 (`~` 사용 가능). 앞에 있는 것부터 확인하고, 있으면 설치 항목으로 본다
    public var executables: [String]
    /// 버전이 적힌 파일 (`~` 사용 가능). 있으면 내용을 버전으로 보여 준다
    public var versionFiles: [String]
    /// 도구의 데이터 폴더 (`~` 사용 가능). 이름이 같은 폴더를 찾는 대신 이 목록을 쓴다
    public var dataPaths: [String]
    /// 재설치 방법 안내 (예: `curl -fsSL https://… | bash`)
    public var reinstall: String?

    public init(name: String, executables: [String] = [], versionFiles: [String] = [], dataPaths: [String] = [],
                reinstall: String? = nil) {
        self.name = name
        self.executables = executables
        self.versionFiles = versionFiles
        self.dataPaths = dataPaths
        self.reinstall = reinstall
    }
}

/// 고아 스캔 제외 목록 (plan.md 4.5.5)
public struct OrphanExclusions: Codable, Sendable, Hashable {
    /// `Application Support/` 등 아래 Apple 시스템 데이터 이름
    public var appleSystemNames: [String]
    /// 항상 제외할 `~` 기준 상대 경로 (MobileSync, Mobile Documents …)
    public var alwaysExcludedPaths: [String]
    /// 벤더 공용 폴더 이름 → Low + 경고
    public var vendorFolders: [String]
    /// 옵션과 무관하게 제외하는 보안 dotfile
    public var securityDotfiles: [String]
    /// 앱이 아닌 주체가 만드는 BID 접두사 (예: "com.apple.", "org.python.")
    public var nonAppBundleIDPrefixes: [String]

    public init(appleSystemNames: [String] = [], alwaysExcludedPaths: [String] = [], vendorFolders: [String] = [],
                securityDotfiles: [String] = [], nonAppBundleIDPrefixes: [String] = []) {
        self.appleSystemNames = appleSystemNames
        self.alwaysExcludedPaths = alwaysExcludedPaths
        self.vendorFolders = vendorFolders
        self.securityDotfiles = securityDotfiles
        self.nonAppBundleIDPrefixes = nonAppBundleIDPrefixes
    }

    /// 원격 갱신은 항목 추가만 허용한다 (plan.md 4.6)
    public func addingOnly(_ other: OrphanExclusions) -> OrphanExclusions {
        func union(_ a: [String], _ b: [String]) -> [String] { a + b.filter { !a.contains($0) } }
        return OrphanExclusions(
            appleSystemNames: union(appleSystemNames, other.appleSystemNames),
            alwaysExcludedPaths: union(alwaysExcludedPaths, other.alwaysExcludedPaths),
            vendorFolders: union(vendorFolders, other.vendorFolders),
            securityDotfiles: union(securityDotfiles, other.securityDotfiles),
            nonAppBundleIDPrefixes: union(nonAppBundleIDPrefixes, other.nonAppBundleIDPrefixes)
        )
    }
}

/// "무엇을 지울지"를 결정하는 데이터 (plan.md 4.6). 앱 번들에 기본 스냅샷을 포함한다.
public struct RuleData: Sendable {
    public var version: String
    public var commonNames: Set<String>
    public var exclusions: OrphanExclusions
    public var casks: [HomebrewCask]
    /// 설치 스크립트로 설치한 CLI 도구
    public var standaloneTools: [StandaloneTool]
    /// 서명 검증 상태 (번들 기본값은 앱 서명으로 보호되므로 true)
    public var signatureVerified: Bool
    public var updatedAt: Date?

    public init(version: String, commonNames: Set<String>, exclusions: OrphanExclusions, casks: [HomebrewCask],
                standaloneTools: [StandaloneTool] = [], signatureVerified: Bool = true, updatedAt: Date? = nil) {
        self.version = version
        self.commonNames = commonNames
        self.exclusions = exclusions
        self.casks = casks
        self.standaloneTools = standaloneTools
        self.signatureVerified = signatureVerified
        self.updatedAt = updatedAt
    }

    /// 이름이 짧거나 흔하면 이름 매칭은 Low (plan.md 4.3.1)
    public func isWeakName(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        return n.count < 4 || commonNames.contains(n)
    }

    public func casks(matchingBundleID bid: String) -> [HomebrewCask] {
        let lower = bid.lowercased()
        return casks.filter { $0.bundleIDs.contains { $0.lowercased() == lower } }
    }

    public func casks(matchingAppName appFileName: String) -> [HomebrewCask] {
        casks.filter { $0.apps.contains { $0.caseInsensitiveCompare(appFileName) == .orderedSame } }
    }

    public func standaloneTool(named name: String) -> StandaloneTool? {
        standaloneTools.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    public static let empty = RuleData(version: "empty", commonNames: [], exclusions: OrphanExclusions(), casks: [])
}

// MARK: - 번들 기본 스냅샷 로드

public enum BundledRuleData {
    struct Manifest: Codable {
        var version: String
        var files: [String: String]?
    }

    /// 번들 리소스 폴더 위치. `.app`에서는 Contents/Resources, SwiftPM 실행 파일에서는 실행 파일 옆 번들(심볼릭 링크 해석 포함),
    /// 둘 다 없으면 Bundle.module.
    public static func resourceDirectory(resourceURL: URL? = Bundle.main.resourceURL,
                                         executableURL: URL? = Bundle.main.executableURL) -> URL? {
        let fm = FileManager.default
        if let found = BundledResources.locate("RuleData", resourceURL: resourceURL, executableURL: executableURL,
                                               where: { fm.isDirectory($0) }) { return found }
        return Bundle.module.url(forResource: "RuleData", withExtension: nil)
    }

    public static func load(from directory: URL? = resourceDirectory()) -> RuleData {
        guard let dir = directory else { return .empty }
        let decoder = JSONDecoder()
        let manifest = (try? Data(contentsOf: dir.appendingPathComponent("manifest.json")))
            .flatMap { try? decoder.decode(Manifest.self, from: $0) }
        let common = (try? Data(contentsOf: dir.appendingPathComponent("common-names.json")))
            .flatMap { try? decoder.decode([String].self, from: $0) } ?? []
        let exclusions = (try? Data(contentsOf: dir.appendingPathComponent("orphan-exclusions.json")))
            .flatMap { try? decoder.decode(OrphanExclusions.self, from: $0) } ?? OrphanExclusions()
        let casks = (try? Data(contentsOf: dir.appendingPathComponent("homebrew-casks.json")))
            .flatMap { try? decoder.decode([HomebrewCask].self, from: $0) } ?? []
        let standalone = (try? Data(contentsOf: dir.appendingPathComponent("standalone-tools.json")))
            .flatMap { try? decoder.decode([StandaloneTool].self, from: $0) } ?? []
        return RuleData(version: manifest?.version ?? "unknown", commonNames: Set(common.map { $0.lowercased() }),
                        exclusions: exclusions, casks: casks, standaloneTools: standalone)
    }
}
