import Foundation

/// 고아 판정 중간 결과 (모듈 내부). 최종적으로 `Candidate`로 바뀐다.
struct OrphanItem {
    var url: URL
    var category: ItemCategory
    var domain: Domain
    /// 소유 앱 단서: BID (원래 대소문자)
    var bundleID: String?
    var teamID: String?
    /// 소유 앱 단서: BID가 아닌 이름 (Electron 앱 폴더 등)
    var name: String?
    /// 기록된 앱 경로에서 얻은 앱 이름 (Launch plist 실행 파일, 영수증의 `.app`, Caskroom)
    var appNameHint: String?
    var caskToken: String?
    var packageID: String?
    var confidence: Confidence
    var evidence: [Evidence]
    var notes: [EngineText] = []
    var launchService: LaunchServiceRef?
    var preferencesDomain: String?
    var share: ShareStatus = .exclusive
    /// 앱이 연결 해제된 외장 볼륨에 있을 수 있음 → Low 고정
    var offline = false
    /// 같은 그룹의 High 근거로 승격됨
    var promoted = false
    /// 같은 그룹의 High 근거로 승격할 수 있는지 (살아 있는 서비스 등은 false)
    var promotable = true
    var lastModified: Date?

    var standardizedPath: String { url.standardizedFileURL.path }

    mutating func addNote(_ note: EngineText) {
        if !notes.contains(note) { notes.append(note) }
    }
}

/// 인벤토리 조회 색인 (스캔 1회용, 단일 스레드에서 사용)
final class InventoryIndex {
    enum Ownership: Equatable {
        case installed
        case offline
        case notFound
    }

    let snapshot: InventorySnapshot
    let bundleIDs: Set<String>
    let launchLabels: Set<String>
    let appGroups: Set<String>
    /// Team ID → 앱 이름
    let teams: [String: [String]]
    /// 벤더 접두사(`com.google`) → 앱 이름
    let vendorPrefixes: [String: [String]]
    /// 벤더 이름(정규화) — BID의 벤더 구성요소와 앱 이름의 첫 단어
    let vendorNames: Set<String>
    /// 정규화한 앱 이름·표시 이름·파일명·실행 파일명
    let appNames: Set<String>
    /// `foo.app` (소문자)
    let appFileNames: Set<String>
    let offlineBundleIDs: Set<String>

    private let paths: SystemPaths
    private let launchServices: LaunchServicesLookup
    private let isMounted: @Sendable (URL) -> Bool
    private var registrationCache: [String: LaunchServicesRegistry.Registration] = [:]

    init(snapshot: InventorySnapshot, paths: SystemPaths, launchServices: @escaping LaunchServicesLookup,
         isMounted: @escaping @Sendable (URL) -> Bool) {
        self.snapshot = snapshot
        self.paths = paths
        self.launchServices = launchServices
        self.isMounted = isMounted
        bundleIDs = snapshot.allBundleIDs
        launchLabels = Set(snapshot.allLaunchLabels.map { $0.lowercased() })
        appGroups = Set(snapshot.apps.flatMap(\.appGroups).map { $0.lowercased() })
        var teams: [String: [String]] = [:]
        var vendors: [String: [String]] = [:]
        var vendorNames = Set<String>()
        var names = Set<String>()
        var files = Set<String>()
        for app in snapshot.apps {
            if let t = app.teamID { teams[t, default: []].append(app.name) }
            if let v = BundleIDHeuristics.vendorPrefix(app.bundleID) { vendors[v, default: []].append(app.name) }
            if let v = BundleIDHeuristics.vendorName(app.bundleID), v.count >= 3 { vendorNames.insert(BundleIDHeuristics.normalizedName(v)) }
            let fileName = app.url.deletingPathExtension().lastPathComponent
            for n in [app.name, fileName, app.executableName, Self.bundleIDAppName(app.bundleID)].compactMap({ $0 }) {
                let norm = BundleIDHeuristics.normalizedName(n)
                if !norm.isEmpty { names.insert(norm) }
                if let first = n.split(separator: " ").first, first.count >= 3, n.contains(" ") {
                    vendorNames.insert(BundleIDHeuristics.normalizedName(String(first)))
                }
            }
            files.insert(app.url.lastPathComponent.lowercased())
        }
        self.teams = teams
        self.vendorPrefixes = vendors
        self.vendorNames = vendorNames
        self.appNames = names
        self.appFileNames = files
        offlineBundleIDs = Set(snapshot.offlineVolumeBundleIDs.map { $0.lowercased() })
    }

    /// BID의 소유 앱이 설치돼 있는지 (내장 번들·Wrapped·Launch Label·LaunchServices 등록 포함)
    func ownership(of bid: String) -> Ownership {
        let lower = bid.lowercased()
        if BundleIDHeuristics.matchesAny(lower, in: bundleIDs) || launchLabels.contains(lower) { return .installed }
        if BundleIDHeuristics.matchesAny(lower, in: offlineBundleIDs) { return .offline }
        switch registration(for: bid) {
        case .installed: return .installed
        case .offlineVolume: return .offline
        case .notRegistered: return .notFound
        }
    }

    private func registration(for bid: String) -> LaunchServicesRegistry.Registration {
        if let hit = registrationCache[bid] { return hit }
        let r = LaunchServicesRegistry.registration(for: bid, lookup: launchServices, paths: paths, isMounted: isMounted)
        registrationCache[bid] = r
        return r
    }

    /// BID의 앱 구성요소 — 표시 이름이 바뀐 앱의 옛 이름 폴더도 그 앱 것으로 본다
    /// (`com.openai.codex` → `codex`: 표시 이름은 ChatGPT, 데이터는 `Codex`·`~/.codex`). 벤더 이름만 남으면 nil.
    static func bundleIDAppName(_ bid: String) -> String? {
        guard let comp = OrphanGrouper.meaningfulComponent(of: bid),
              comp.lowercased() != BundleIDHeuristics.vendorName(bid), comp.count >= 3 else { return nil }
        return comp
    }

    func matchesInstalledName(_ name: String) -> Bool {
        let n = BundleIDHeuristics.normalizedName(name)
        return !n.isEmpty && appNames.contains(n)
    }

    func installedVendorApps(for bid: String) -> [String] {
        BundleIDHeuristics.vendorPrefix(bid).flatMap { vendorPrefixes[$0] } ?? []
    }
}

/// 고아 스캔 전용 제외 규칙 (plan.md 4.5.5)
struct ExclusionRules {
    let exclusions: OrphanExclusions
    let paths: SystemPaths
    private let appleNames: Set<String>
    private let vendorFolders: Set<String>
    private let securityDotfiles: Set<String>
    private let prefixes: [String]
    private let excludedRoots: [String]

    init(exclusions: OrphanExclusions, paths: SystemPaths) {
        self.exclusions = exclusions
        self.paths = paths
        appleNames = Set(exclusions.appleSystemNames.map { $0.lowercased() })
        vendorFolders = Set(exclusions.vendorFolders.map { BundleIDHeuristics.normalizedName($0) })
        securityDotfiles = Set(exclusions.securityDotfiles.map { $0.lowercased() } + [".ssh", ".gnupg"])
        prefixes = (exclusions.nonAppBundleIDPrefixes + ["com.apple."]).map { $0.lowercased() }
        var roots = exclusions.alwaysExcludedPaths.map { paths.home($0).standardizedFileURL.path }
        // iPhone 백업·iCloud는 규칙 데이터와 무관하게 항상 제외 (plan.md 4.5.5)
        roots.append(paths.home("Library/Application Support/MobileSync").standardizedFileURL.path)
        roots.append(paths.home("Library/Mobile Documents").standardizedFileURL.path)
        // 본 앱 자신의 데이터
        roots.append(paths.appDataDir.standardizedFileURL.path)
        roots.append(paths.holdingDir.deletingLastPathComponent().standardizedFileURL.path)
        excludedRoots = roots
    }

    func isExcludedBundleID(_ bid: String) -> Bool {
        let lower = bid.lowercased()
        if lower == paths.selfBundleID.lowercased() || lower.hasPrefix(paths.selfBundleID.lowercased() + ".") { return true }
        // 접두사 자신(`com.github.Electron.` ↔ `com.github.Electron`)도 제외
        if prefixes.contains(where: { lower.hasPrefix($0) || (($0.hasSuffix(".")) && lower == String($0.dropLast())) }) { return true }
        // `group.com.apple.*`, `<TEAM>.com.apple.*`, `systemgroup.com.apple.*`
        return lower.contains(".com.apple.") || lower.hasPrefix("com.apple")
    }

    func isExcludedPath(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return excludedRoots.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// Apple 시스템 데이터 이름 (규칙 데이터). `daemonNames`면 `routined`·`familycircled` 같은
    /// 소문자 데몬 이름도 시스템 것으로 본다 (Caches·Logs 전용 — Application Support의 `discord` 같은 앱 폴더와 구분).
    func isAppleSystemName(_ name: String, daemonNames: Bool = false) -> Bool {
        let lower = name.lowercased()
        if appleNames.contains(lower) || lower.hasPrefix("com.apple") { return true }
        guard daemonNames else { return false }
        return name == lower && lower.count >= 5 && lower.hasSuffix("d") && lower.allSatisfy { $0.isLowercase && $0.isASCII }
    }

    func isVendorFolder(_ name: String) -> Bool {
        vendorFolders.contains(BundleIDHeuristics.normalizedName(name))
    }

    func isSecurityDotfile(_ name: String) -> Bool {
        securityDotfiles.contains(name.lowercased())
    }
}

extension Confidence {
    var koreanLabel: String {
        switch self {
        case .high: return "높음"
        case .medium: return "보통"
        case .low: return "낮음"
        }
    }
}
