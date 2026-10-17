import Foundation

/// App Cleaner가 들어 있는 마운트된 디스크 이미지 (설치 DMG)
public struct MountedInstaller: Codable, Sendable, Hashable, Identifiable {
    public var mountPoint: URL
    public var imagePath: URL?
    /// 디스크 이미지 안 App Cleaner의 버전
    public var appVersion: String?

    public var id: String { mountPoint.path }

    public init(mountPoint: URL, imagePath: URL? = nil, appVersion: String? = nil) {
        self.mountPoint = mountPoint
        self.imagePath = imagePath
        self.appVersion = appVersion
    }
}

/// 새 버전을 설치한 뒤 남은 App Cleaner 설치 파일·이전 사본
public struct InstallerLeftoverReport: Codable, Sendable {
    public var mounted: [MountedInstaller]
    /// 휴지통으로 옮길 후보: 다운로드 폴더의 설치 파일, 실행 중이 아닌 App Cleaner 사본
    public var candidates: [Candidate]
    /// 실행 중인 앱이 응용 프로그램 폴더 밖(디스크 이미지·다운로드 폴더 등)에 있음 — 정리 대신 옮기라고 안내
    public var runningOutsideApplications: Bool
    public var ruleDataVersion: String

    public init(mounted: [MountedInstaller] = [], candidates: [Candidate] = [], runningOutsideApplications: Bool = false,
                ruleDataVersion: String) {
        self.mounted = mounted
        self.candidates = candidates
        self.runningOutsideApplications = runningOutsideApplications
        self.ruleDataVersion = ruleDataVersion
    }

    public var isEmpty: Bool { mounted.isEmpty && candidates.isEmpty }
}

/// 설치 파일·이전 사본 찾기. 지우지 않고 후보만 만든다 (실행은 `CleanupPlanner` + 정리 실행기 — 휴지통·삭제 기록).
///
/// - 디스크 이미지: `hdiutil info -plist`의 마운트 위치 바로 아래에 본 앱(번들 ID)이 있는 것. 실행 중인 앱이 들어 있는 이미지는 제외
/// - 설치 파일: 다운로드 폴더의 릴리즈 산출물 이름(`AppCleaner-<버전>-macos-<아키텍처>.dmg|zip`, CLI `appcleaner-…tar.gz`와 푼 폴더)
/// - 이전 사본: Spotlight(번들 ID)와 다운로드 폴더의 `.app` 중 실행 중인 번들이 아닌 것.
///   다운로드 폴더 밖(개발 빌드 등)·실행 중인 사본은 목록에만 넣고 기본 선택하지 않는다. 외장 볼륨·휴지통·다른 번들 안은 제외
public struct InstallerLeftoverScanner: Sendable {
    public let paths: SystemPaths
    public let runner: CommandRunning
    public let safety: SafetyGuard
    /// 실행 중인 App Cleaner 번들 (`swift run`·CLI처럼 `.app`이 아니면 nil)
    public let runningBundle: URL?
    public let isRunningAt: @Sendable (URL) -> Bool

    static let hdiutil = "/usr/bin/hdiutil"
    static let mdfind = "/usr/bin/mdfind"

    static let installerFilePattern = #"^AppCleaner-[0-9]+(\.[0-9]+)*-macos-[A-Za-z0-9_]+( \([0-9]+\))?\.(dmg|zip)$"#
    static let cliArchivePattern = #"^appcleaner-[0-9]+(\.[0-9]+)*-macos-[A-Za-z0-9_]+( \([0-9]+\))?(\.tar\.gz)?$"#

    static func matches(_ pattern: String, _ name: String) -> Bool {
        guard let regex = try? Regex(pattern) else { return false }
        return (try? regex.wholeMatch(in: name)) != nil
    }

    public init(paths: SystemPaths, runner: CommandRunning, safety: SafetyGuard? = nil, runningBundle: URL?,
                isRunningAt: @escaping @Sendable (URL) -> Bool = { _ in false }) {
        self.paths = paths
        self.runner = runner
        self.safety = safety ?? SafetyGuard(paths: paths)
        self.runningBundle = runningBundle
        self.isRunningAt = isRunningAt
    }

    /// 실행 중인 프로세스의 앱 번들 (`.app`이 아니면 nil)
    public static var currentAppBundle: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    public func scan(ruleDataVersion: String) async -> InstallerLeftoverReport {
        let running = runningBundle.map { SafetyGuard.key(SafetyGuard.realpathOfExistingPrefix($0.path)) }
        let currentVersion = runningBundle.flatMap { BundleInfo.read(bundleAt: $0)?.shortVersion }
        let mounted = mountedInstallers(runningKey: running)
        let mountKeys = mounted.map { SafetyGuard.key(SafetyGuard.realpathOfExistingPrefix($0.mountPoint.path)) }

        var candidates = installerFiles()
        let known = Set(candidates.map { SafetyGuard.key($0.path) })
        candidates += appCopies(runningKey: running, mountKeys: mountKeys, currentVersion: currentVersion)
            .filter { !known.contains(SafetyGuard.key($0.path)) }
        candidates = await FileStatsCalculator.fill(candidates)

        return InstallerLeftoverReport(mounted: mounted, candidates: candidates,
                                       runningOutsideApplications: running.map(isOutsideApplications) ?? false,
                                       ruleDataVersion: ruleDataVersion)
    }

    // MARK: 디스크 이미지

    func mountedInstallers(runningKey: String?) -> [MountedInstaller] {
        guard let out = runner.output(Self.hdiutil, ["info", "-plist"]),
              let plist = try? PropertyListSerialization.propertyList(from: out.stdout, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        var result: [MountedInstaller] = []
        for image in images {
            let imagePath = (image["image-path"] as? String).map { URL(fileURLWithPath: $0) }
            for entity in image["system-entities"] as? [[String: Any]] ?? [] {
                guard let mount = entity["mount-point"] as? String else { continue }
                let mountURL = URL(fileURLWithPath: mount, isDirectory: true)
                let mountKey = SafetyGuard.key(SafetyGuard.realpathOfExistingPrefix(mount))
                // 이 디스크 이미지에서 실행 중이면 꺼내지 않는다
                if let r = runningKey, r == mountKey || r.hasPrefix(mountKey + "/") { continue }
                guard let app = FileManager.default.children(of: mountURL).first(where: { isSelfApp($0) }) else { continue }
                result.append(MountedInstaller(mountPoint: mountURL, imagePath: imagePath,
                                               appVersion: BundleInfo.read(bundleAt: app)?.shortVersion))
            }
        }
        return result
    }

    // MARK: 설치 파일

    var downloads: URL { paths.home("Downloads") }

    func installerFiles() -> [Candidate] {
        let fm = FileManager.default
        return fm.children(of: downloads).sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { url in
            let name = url.lastPathComponent
            guard Self.matches(Self.installerFilePattern, name) || Self.matches(Self.cliArchivePattern, name), !fm.isSymlink(url) else { return nil }
            var c = Candidate(url: url, category: .other, confidence: .high, nature: .regenerable,
                              evidence: [Evidence(.pathRule, EngineText(.installerFile, name))], isSelected: true)
            guarded(&c, runningBundle: nil)
            return c
        }
    }

    // MARK: 이전 사본

    func appCopies(runningKey: String?, mountKeys: [String], currentVersion: String?) -> [Candidate] {
        let fm = FileManager.default
        var urls: [URL] = []
        let query = "kMDItemCFBundleIdentifier == '\(paths.selfBundleID)'"
        if let out = runner.output(Self.mdfind, [query]) {
            urls += out.lines.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        urls += fm.children(of: downloads).filter { $0.pathExtension == "app" }

        let downloadsKey = SafetyGuard.key(SafetyGuard.realpathOfExistingPrefix(downloads.path))
        let trashKey = SafetyGuard.key(SafetyGuard.realpathOfExistingPrefix(paths.trash.path))
        let volumesKey = SafetyGuard.key(paths.system("Volumes").path)
        var seen = Set<String>()
        var out: [Candidate] = []
        for url in urls {
            let key = SafetyGuard.key(SafetyGuard.realpathOfExistingPrefix(url.path))
            guard seen.insert(key).inserted, key != runningKey, isSelfApp(url) else { continue }
            let inside = { (dir: String) in key.hasPrefix(dir + "/") }
            if mountKeys.contains(where: inside) || inside(trashKey) || inside(volumesKey) { continue }
            // 다른 번들 안(예: 개발 도구가 품은 사본)은 그 번들의 일부
            if url.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) { continue }

            let version = BundleInfo.read(bundleAt: url)?.shortVersion
            let inDownloads = inside(downloadsKey)
            let running = isRunningAt(url)
            var notes: [EngineText] = []
            if running { notes.append(EngineText(.installerCopyRunning)) }
            if !inDownloads { notes.append(EngineText(.installerCopyOutsideDownloads)) }
            var c = Candidate(url: url, category: .appBundle, confidence: .high, nature: .regenerable,
                              evidence: [Evidence(.bundleIdentifier, EngineText(.installerAppCopy, version ?? "?", currentVersion ?? "?"))],
                              isSelected: inDownloads && !running, notes: notes)
            guarded(&c, runningBundle: runningBundle)
            out.append(c)
        }
        return out.sorted { $0.path < $1.path }
    }

    // MARK: 공용

    func isSelfApp(_ url: URL) -> Bool {
        url.pathExtension == "app"
            && BundleInfo.read(bundleAt: url)?.bundleID?.caseInsensitiveCompare(paths.selfBundleID) == .orderedSame
    }

    func isOutsideApplications(_ runningKey: String) -> Bool {
        ![paths.system("Applications"), paths.home("Applications")].contains { dir in
            runningKey.hasPrefix(SafetyGuard.key(SafetyGuard.realpathOfExistingPrefix(dir.path)) + "/")
        }
    }

    func guarded(_ c: inout Candidate, runningBundle: URL?) {
        if case .blocked(let reason, let why) = safety.verdict(for: c.url, allowingSelfAppCopy: runningBundle) {
            c.protection = reason
            c.isSelected = false
            c.notes.append(why)
        }
    }
}
