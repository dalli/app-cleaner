import Foundation

/// 설치 앱 인벤토리 (plan.md 4.5.2). 고아 스캔의 오탐 방지 기반이자 앱 제거의 공유 판정(4.3.2) 근거.
///
/// - 표준 위치(`/Applications`, `~/Applications`, `/System/Applications`, `/System/Library/CoreServices`)를
///   하위 폴더까지 재귀 탐색한다 (`.app` 번들 내부로는 내려가지 않음).
/// - Spotlight 전체 질의로 비표준 위치·외장 볼륨 앱을 더하고, `mdutil -s`·교차 검증으로 색인 상태를 기록한다.
/// - 서명(Team ID·App Group) 읽기는 느리므로 **경로 + 수정일** 키로 디스크에 캐시한다.
public final class AppInventory: InventoryProviding, @unchecked Sendable {
    public let paths: SystemPaths
    public let cacheURL: URL
    private let runner: CommandRunning
    private let signatureReader: CodeSignatureReading
    private let isRunning: @Sendable (String) -> Bool
    private let isMounted: @Sendable (URL) -> Bool
    private let lastUsed: @Sendable (URL) -> Date?
    private let launchServices: LaunchServicesLookup
    private let now: @Sendable () -> Date
    private let maxConcurrency: Int

    private let lock = NSLock()
    private var state: CacheFile?

    /// 외부 명령 경로 (실행 파일 식별자일 뿐 파일 시스템 접근이 아니다 — 테스트는 StubCommandRunner가 파일명으로 가로챈다)
    enum Tool {
        static let mdfind = "/usr/bin/mdfind"
        static let mdutil = "/usr/bin/mdutil"
        static let pkgutil = "/usr/sbin/pkgutil"
    }

    static let applicationQuery = "kMDItemContentType == 'com.apple.application-bundle'"
    static let cacheVersion = 1

    public init(
        paths: SystemPaths,
        runner: CommandRunning,
        signatureReader: CodeSignatureReading = SecCodeSignatureReader(),
        cacheURL: URL? = nil,
        isRunning: @escaping @Sendable (String) -> Bool = LiveAppHooks.isRunning,
        isMounted: @escaping @Sendable (URL) -> Bool = VolumePaths.defaultIsMounted,
        lastUsed: @escaping @Sendable (URL) -> Date? = LiveAppHooks.lastUsed,
        launchServices: @escaping LaunchServicesLookup = LaunchServicesRegistry.live,
        now: @escaping @Sendable () -> Date = { Date() },
        maxConcurrency: Int = 8
    ) {
        self.paths = paths
        self.runner = runner
        self.signatureReader = signatureReader
        self.cacheURL = cacheURL ?? paths.appDataDir.appendingPathComponent("inventory-cache.json")
        self.isRunning = isRunning
        self.isMounted = isMounted
        self.lastUsed = lastUsed
        self.launchServices = launchServices
        self.now = now
        self.maxConcurrency = max(1, maxConcurrency)
    }

    // MARK: - InventoryProviding

    public func cached() -> InventorySnapshot? {
        loadState().snapshot
    }

    public func build() async throws -> InventorySnapshot {
        var state = loadState()
        let fm = FileManager.default

        // 1. 표준 위치 재귀 탐색
        var standard: [URL] = []
        for root in standardRoots { standard.append(contentsOf: Self.findApps(in: root)) }
        let userStandard = Set(standard.filter { url in
            [paths.system("Applications"), paths.home("Applications")].contains { Self.isInside(url, $0) }
        }.map(\.standardizedFileURL.path))

        // 2. Spotlight 색인 상태 (루트 + 연결된 각 볼륨)
        let rootIndexing = spotlightIndexing(for: paths.root)
        var volumeApps: [URL] = []
        for volume in mountedVolumes() {
            // 색인이 꺼진 외장 볼륨은 Spotlight가 앱을 못 찾으므로 볼륨의 Applications를 직접 탐색한다.
            if spotlightIndexing(for: volume) != true {
                volumeApps.append(contentsOf: Self.findApps(in: volume.appendingPathComponent("Applications"), maxDepth: 3))
            }
        }

        // 3. Spotlight 전체 질의 (비표준 위치·외장 볼륨)
        let spotlightResult = runner.output(Tool.mdfind, [Self.applicationQuery])
        let spotlightApps = (spotlightResult?.lines ?? []).compactMap { line -> URL? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(".app") else { return nil }
            let url = paths.resolveRecorded(trimmed)
            return isAcceptableSpotlightApp(url) ? url : nil
        }

        // 4. 합치기 (경로 기준 중복 제거)
        var seen = Set<String>()
        let all = (standard + volumeApps + spotlightApps).filter { seen.insert($0.standardizedFileURL.path).inserted }

        // 5. 앱별 정보 (서명은 캐시)
        let signingCache = state.signing
        let results = await withTaskGroup(of: (InventoryApp?, [String: SigningCacheEntry]).self) { group in
            var out: [(InventoryApp?, [String: SigningCacheEntry])] = []
            var iterator = all.makeIterator()
            func addNext() -> Bool {
                guard let url = iterator.next() else { return false }
                group.addTask { [self] in self.describe(appAt: url, signingCache: signingCache) }
                return true
            }
            for _ in 0..<maxConcurrency where !addNext() { break }
            while let r = await group.next() {
                out.append(r)
                _ = addNext()
            }
            return out
        }
        var newSigning: [String: SigningCacheEntry] = [:]
        var apps: [InventoryApp] = []
        for (app, entries) in results {
            newSigning.merge(entries) { a, _ in a }
            if let app { apps.append(app) }
        }
        apps.sort { $0.url.path < $1.url.path }

        // 6. Spotlight 교차 검증: 사용자 설치 표준 위치 앱이 Spotlight 결과에 있어야 한다.
        let spotlightPaths = Set(spotlightApps.map(\.standardizedFileURL.path))
        let spotlightBIDs = Set(spotlightApps.compactMap { BundleInfo.read(bundleAt: $0)?.bundleID?.lowercased() })
        var missing: [String] = []
        if spotlightResult != nil {
            for app in apps where userStandard.contains(app.url.standardizedFileURL.path) {
                if !spotlightPaths.contains(app.url.standardizedFileURL.path) && !spotlightBIDs.contains(app.bundleID.lowercased()) {
                    missing.append(app.url.standardizedFileURL.path)
                }
            }
        }
        let spotlight = SpotlightStatus(indexingEnabled: rootIndexing == true && spotlightResult != nil,
                                        complete: spotlightResult != nil && missing.isEmpty, missingApps: missing)

        // 7. Homebrew · pkgutil
        let casks = homebrewCasks()
        let packages = runner.output(Tool.pkgutil, ["--pkgs"])?.lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []

        // 8. 외장 볼륨: 이전에 본 볼륨 앱 중 지금 볼륨이 연결돼 있지 않은 것
        var knownVolumeApps = state.volumeApps
        for app in apps where VolumePaths.volumeRoot(of: app.url, paths: paths) != nil {
            knownVolumeApps[app.url.standardizedFileURL.path] = app.bundleID
        }
        var offline: [String] = []
        for (path, bid) in knownVolumeApps.sorted(by: { $0.key < $1.key }) {
            let url = URL(fileURLWithPath: path)
            guard let vol = VolumePaths.volumeRoot(of: url, paths: paths) else { continue }
            if isMounted(vol) {
                // 연결돼 있는데 앱이 없으면 삭제된 것 — 기록에서 뺀다
                if !fm.itemExists(url) { knownVolumeApps[path] = nil }
            } else if !offline.contains(bid) {
                offline.append(bid)
            }
        }

        let snapshot = InventorySnapshot(apps: apps, homebrewCasks: casks, packageIDs: packages,
                                         offlineVolumeBundleIDs: offline, spotlight: spotlight, builtAt: now())
        state.snapshot = snapshot
        state.signing = newSigning
        state.volumeApps = knownVolumeApps
        saveState(state)
        return snapshot
    }

    /// S1 앱 목록: `/Applications`·`~/Applications`(하위 폴더 포함)와 외장 볼륨 앱. Apple 기본 앱·`/System` 앱 제외.
    /// 서명은 읽지 않으므로 빠르다.
    /// 크기는 nil — GUI가 `FileStatsCalculator`로 나중에 채운다.
    public func installedApps() async -> [InstalledApp] {
        var urls: [URL] = []
        for root in [paths.system("Applications"), paths.home("Applications")] { urls.append(contentsOf: Self.findApps(in: root)) }
        // 외장 볼륨의 앱(지난 인벤토리에서 Spotlight로 찾은 것) 중 아직 존재하는 것.
        // 그 밖의 비표준 위치(캐시·업데이터·Application Support 내부 헬퍼 등)는 인벤토리(오탐 방지)에만 쓰고 목록에는 보이지 않는다.
        if let snap = cached() {
            urls.append(contentsOf: snap.apps.map(\.url).filter {
                VolumePaths.volumeRoot(of: $0, paths: paths) != nil && FileManager.default.itemExists($0)
            })
        }
        var seen = Set<String>()
        urls = urls.filter { seen.insert($0.standardizedFileURL.path).inserted }

        let caskRecords = Caskroom.records(paths: paths)
        let caskApps = Set(caskRecords.flatMap(\.appNames).map { $0.lowercased() })
        let caskLocations = Set(caskRecords.flatMap(\.appLocations).map(\.standardizedFileURL.path))
        let packages = runner.output(Tool.pkgutil, ["--pkgs"])?.lines ?? []
        let systemDir = paths.system("System")

        var out: [InstalledApp] = []
        for url in urls {
            guard !Self.isInside(url, systemDir), let info = BundleInfo.read(bundleAt: url), let bid = info.bundleID,
                  !bid.lowercased().hasPrefix("com.apple.") else { continue }
            let source: InstallSource
            if FileManager.default.itemExists(url.appendingPathComponent("Contents/_MASReceipt/receipt")) {
                source = .appStore
            } else if caskLocations.contains(url.standardizedFileURL.path) || caskApps.contains(url.lastPathComponent.lowercased()) {
                source = .homebrew
            } else if Self.packageMatches(appURL: url, bundleID: bid, packages: packages) {
                source = .package
            } else {
                source = .direct
            }
            out.append(InstalledApp(url: url, bundleID: bid, name: info.bestName,
                                    version: info.shortVersion ?? info.version, source: source,
                                    size: nil, lastUsed: lastUsed(url), isRunning: isRunning(bid)))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// LaunchServices 등록 여부 (존재 재확인 포함)
    public func registration(for bundleID: String) -> LaunchServicesRegistry.Registration {
        LaunchServicesRegistry.registration(for: bundleID, lookup: launchServices, paths: paths, isMounted: isMounted)
    }

    // MARK: - 표준 위치 탐색

    var standardRoots: [URL] {
        [paths.system("Applications"), paths.home("Applications"), paths.system("System/Applications"),
         paths.system("System/Library/CoreServices")]
    }

    /// 번들로 취급해 내려가지 않는 확장자 (`.app`은 앱으로 수집)
    static let opaqueExtensions: Set<String> = [
        "framework", "bundle", "plugin", "appex", "kext", "xpc", "systemextension", "prefpane", "qlgenerator", "mdimporter",
        "saver", "wdgt", "component", "driver", "pkg", "mpkg", "lproj", "photoslibrary", "musiclibrary", "dSYM", "dsym",
        "docset", "xcarchive", "playground", "vst", "vst3", "aaxplugin",
    ]

    /// `root` 아래의 `.app` 번들 (하위 폴더 재귀, `.app` 내부로는 내려가지 않음, 심볼릭 링크 폴더는 따라가지 않음)
    static func findApps(in root: URL, maxDepth: Int = 4) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        func walk(_ dir: URL, _ depth: Int) {
            for child in fm.children(of: dir).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                if name.hasPrefix(".") { continue }
                let ext = child.pathExtension.lowercased()
                if ext == "app" {
                    if fm.isDirectory(child) { out.append(child) }
                    continue
                }
                if FileDates.isSymlink(child) || opaqueExtensions.contains(ext) { continue }
                if depth < maxDepth, fm.isDirectory(child) { walk(child, depth + 1) }
            }
        }
        walk(root, 1)
        return out
    }

    static func isInside(_ url: URL, _ dir: URL) -> Bool {
        let p = url.standardizedFileURL.path, d = dir.standardizedFileURL.path
        return p == d || p.hasPrefix(d + "/")
    }

    private func isAcceptableSpotlightApp(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        // 다른 앱 번들 내부(헬퍼), 휴지통은 제외
        let withoutLast = url.deletingLastPathComponent().standardizedFileURL.path + "/"
        if withoutLast.contains(".app/") { return false }
        if Self.isInside(url, paths.trash) || path.contains("/.Trashes/") { return false }
        return FileManager.default.isDirectory(url)
    }

    private func mountedVolumes() -> [URL] {
        let fm = FileManager.default
        return fm.children(of: paths.system("Volumes"))
            .filter { !FileDates.isSymlink($0) && fm.isDirectory($0) && isMounted($0) }
            .sorted { $0.path < $1.path }
    }

    /// `mdutil -s <volume>` → 색인 활성 여부 (판정 불가 시 nil)
    private func spotlightIndexing(for volume: URL) -> Bool? {
        guard let out = try? runner.run(Tool.mdutil, ["-s", volume.path]) else { return nil }
        return Self.parseMdutilStatus(out.string + "\n" + out.stderr)
    }

    /// `mdutil -s` 출력 해석. 상태 줄이 모두 "Indexing enabled."이면 true, 하나라도 비활성·오류면 false, 상태 줄이 없으면 nil.
    public static func parseMdutilStatus(_ output: String) -> Bool? {
        var sawEnabled = false
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if line.hasPrefix("indexing enabled") {
                sawEnabled = true
            } else if line.hasPrefix("indexing disabled") || line.hasPrefix("error") || line.contains("unknown indexing state")
                        || line.hasPrefix("indexing and searching disabled") {
                return false
            }
        }
        return sawEnabled ? true : nil
    }

    private func homebrewCasks() -> [String] {
        var tokens = Caskroom.tokens(paths: paths)
        if let brew = Caskroom.brewExecutable(paths: paths),
           let out = runner.output(brew.path, ["list", "--cask"]) {
            for t in out.lines.map({ $0.trimmingCharacters(in: .whitespaces) }) where !t.isEmpty && !tokens.contains(t) {
                tokens.append(t)
            }
        }
        return tokens.sorted()
    }

    /// pkgutil 패키지 ID로 설치됐는지 추정 (BID 접두 관계 또는 앱 파일명 포함). S1 출처 표시용 — 판정에는 쓰지 않는다.
    static func packageMatches(appURL: URL, bundleID: String, packages: [String]) -> Bool {
        let bid = bundleID.lowercased()
        let appName = BundleIDHeuristics.normalizedName(appURL.deletingPathExtension().lastPathComponent)
        for raw in packages {
            let pkg = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if pkg.isEmpty || pkg.hasPrefix("com.apple.") { continue }
            if BundleIDHeuristics.isSameOrChild(pkg, of: bid) || BundleIDHeuristics.isSameOrChild(bid, of: pkg) { return true }
            if appName.count >= 4, let last = pkg.split(separator: ".").last,
               BundleIDHeuristics.normalizedName(String(last)).hasPrefix(appName) { return true }
            if appName.count >= 4, pkg.split(separator: ".").contains(where: { BundleIDHeuristics.normalizedName(String($0)) == appName }) {
                return true
            }
        }
        return false
    }

    // MARK: - 앱 1개 해석

    /// 앱 1개의 인벤토리 항목과 이번에 사용한 서명 캐시 항목
    private func describe(appAt url: URL, signingCache: [String: SigningCacheEntry]) -> (InventoryApp?, [String: SigningCacheEntry]) {
        guard let info = BundleInfo.read(bundleAt: url), let bid = info.bundleID, !bid.isEmpty else { return (nil, [:]) }
        var used: [String: SigningCacheEntry] = [:]
        func signing(_ bundle: URL) -> SigningInfo? {
            let key = bundle.standardizedFileURL.path
            let stamp = Self.signatureStamp(bundle)
            if let hit = signingCache[key], Self.sameStamp(hit.modified, stamp) {
                used[key] = hit
                return hit.info
            }
            let info = signatureReader.signingInfo(for: bundle)
            used[key] = SigningCacheEntry(modified: stamp, info: info)
            return info
        }

        let embedded = Self.embeddedBundles(of: url)
        var embeddedIDs: [String] = []
        var groups: [String] = []
        let main = signing(url)
        groups.append(contentsOf: main?.appGroups ?? [])
        for e in embedded {
            if let id = e.bundleID, !embeddedIDs.contains(id), id != bid { embeddedIDs.append(id) }
            // 확장·헬퍼는 자체 entitlements에 App Group을 가진다 (공유 판정용)
            if e.isCodeBundle, let s = signing(e.url) {
                for g in s.appGroups where !groups.contains(g) { groups.append(g) }
            }
        }
        let labels = Self.embeddedLaunchLabels(of: url)
        let wrapped = Self.wrappedBundleID(of: url)
        let app = InventoryApp(
            url: url, bundleID: bid, name: info.bestName, executableName: info.executable, teamID: main?.teamID,
            appGroups: groups, embeddedBundleIDs: embeddedIDs, launchLabels: labels, wrappedBundleID: wrapped,
            modified: FileDates.modified(url)
        )
        return (app, used)
    }

    /// 서명 캐시 키의 수정일: 번들 폴더·Info.plist·CodeResources 중 가장 최근
    static func signatureStamp(_ bundle: URL) -> Date? {
        [bundle, bundle.appendingPathComponent("Contents/Info.plist"),
         bundle.appendingPathComponent("Contents/_CodeSignature/CodeResources")]
            .compactMap(FileDates.modified).max()
    }

    static func sameStamp(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return abs(x.timeIntervalSince(y)) < 0.001
        default: return false
        }
    }

    struct EmbeddedBundle {
        var url: URL
        var bundleID: String?
        /// 서명·entitlements를 가진 코드 번들(.app/.appex/.systemextension/.xpc)인지
        var isCodeBundle: Bool
    }

    /// 내장 헬퍼·확장 (plan.md 4.1, 4.5.2). LoginItems·Helpers 안의 앱이 가진 PlugIns까지 한 단계 더 본다.
    static func embeddedBundles(of app: URL, depth: Int = 0) -> [EmbeddedBundle] {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents")
        let codeExts: Set<String> = ["app", "appex", "systemextension", "xpc"]
        var out: [EmbeddedBundle] = []
        let dirs = ["PlugIns", "Library/LoginItems", "Library/LaunchServices", "Helpers", "Frameworks", "XPCServices",
                    "Library/SystemExtensions", "Extensions"]
        for rel in dirs {
            for item in fm.children(of: contents.appendingPathComponent(rel)) {
                let ext = item.pathExtension.lowercased()
                if rel == "Library/LaunchServices" && !fm.isDirectory(item) {
                    // 권한 헬퍼 도구: 파일명이 BID (Info.plist는 Mach-O 내부에 있음)
                    if BundleIDHeuristics.isBundleIDShaped(item.lastPathComponent) {
                        out.append(EmbeddedBundle(url: item, bundleID: item.lastPathComponent, isCodeBundle: false))
                    }
                    continue
                }
                if rel == "Frameworks" && ext != "app" { continue }
                guard fm.isDirectory(item) else { continue }
                let info = BundleInfo.read(bundleAt: item)
                out.append(EmbeddedBundle(url: item, bundleID: info?.bundleID, isCodeBundle: codeExts.contains(ext)))
                if depth < 1 && ext == "app" {
                    out.append(contentsOf: embeddedBundles(of: item, depth: depth + 1))
                }
            }
        }
        // 그 밖의 위치에 둔 내장 앱: Contents/MacOS/*.app (Docker Desktop), Contents/Resources/*.app,
        // Contents/Library/<임의>/*.app|appex|xpc (LoginItems 외 SecretsEngine 등)
        var extraDirs = [contents.appendingPathComponent("MacOS"), contents.appendingPathComponent("Resources")]
        let known = Set(["LoginItems", "LaunchServices", "SystemExtensions", "LaunchAgents", "LaunchDaemons"])
        for sub in fm.children(of: contents.appendingPathComponent("Library")) where !known.contains(sub.lastPathComponent) {
            extraDirs.append(sub)
        }
        for dir in extraDirs {
            for item in fm.children(of: dir) where codeExts.contains(item.pathExtension.lowercased()) && fm.isDirectory(item) {
                out.append(EmbeddedBundle(url: item, bundleID: BundleInfo.read(bundleAt: item)?.bundleID, isCodeBundle: true))
                if depth < 1 && item.pathExtension.lowercased() == "app" {
                    out.append(contentsOf: embeddedBundles(of: item, depth: depth + 1))
                }
            }
        }
        // Electron: Contents/Frameworks/*.framework/Helpers/*.app
        for fw in fm.children(of: contents.appendingPathComponent("Frameworks")) where fw.pathExtension == "framework" {
            for helper in fm.children(of: fw.appendingPathComponent("Helpers")) where helper.pathExtension == "app" {
                out.append(EmbeddedBundle(url: helper, bundleID: BundleInfo.read(bundleAt: helper)?.bundleID, isCodeBundle: true))
            }
        }
        return out
    }

    /// 번들 내장 Launch plist(SMAppService)의 Label
    static func embeddedLaunchLabels(of app: URL) -> [String] {
        var labels: [String] = []
        for rel in ["Contents/Library/LaunchAgents", "Contents/Library/LaunchDaemons"] {
            for plist in FileManager.default.children(of: app.appendingPathComponent(rel)) where plist.pathExtension == "plist" {
                if let label = LaunchPlist.read(at: plist)?.label, !labels.contains(label) { labels.append(label) }
            }
        }
        return labels
    }

    /// iOS/iPadOS 앱(Apple Silicon)의 내부 번들 BID — `Wrapper/*.app/Info.plist`
    static func wrappedBundleID(of app: URL) -> String? {
        for inner in FileManager.default.children(of: app.appendingPathComponent("Wrapper")) where inner.pathExtension == "app" {
            if let bid = BundleInfo.read(bundleAt: inner)?.bundleID { return bid }
        }
        return nil
    }

    // MARK: - 디스크 캐시

    struct SigningCacheEntry: Codable, Sendable, Hashable {
        var modified: Date?
        var info: SigningInfo?
    }

    struct CacheFile: Codable, Sendable {
        var version: Int
        var snapshot: InventorySnapshot?
        /// 번들 경로 → (수정일, 서명 정보)
        var signing: [String: SigningCacheEntry]
        /// 외장 볼륨에서 본 앱: 경로 → BID (볼륨이 연결 해제돼도 기억)
        var volumeApps: [String: String]

        static let empty = CacheFile(version: AppInventory.cacheVersion, snapshot: nil, signing: [:], volumeApps: [:])
    }

    private func loadState() -> CacheFile {
        lock.lock(); defer { lock.unlock() }
        if let state { return state }
        var loaded = CacheFile.empty
        if let data = try? Data(contentsOf: cacheURL) {
            let decoder = JSONDecoder()
            if let file = try? decoder.decode(CacheFile.self, from: data), file.version == Self.cacheVersion { loaded = file }
        }
        state = loaded
        return loaded
    }

    private func saveState(_ new: CacheFile) {
        lock.lock()
        state = new
        lock.unlock()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(new) else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }
}
