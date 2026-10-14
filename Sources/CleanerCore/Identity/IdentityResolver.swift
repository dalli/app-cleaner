import Foundation

/// 대상 `.app`에서 `AppIdentity`를 구성한다 (plan.md 4.1).
///
/// | 정보 | 출처 |
/// |---|---|
/// | BID·이름·실행 파일·버전 | `Contents/Info.plist` (`BundleInfo`) |
/// | Team ID · App Group | `CodeSignatureReading` (본체 + 내장 번들 + Wrapper) |
/// | 내장 BID | LoginItems, LaunchServices, PlugIns, SystemExtensions, Helpers, Frameworks/*.app |
/// | 내장 Launch 서비스 | `Contents/Library/LaunchAgents·LaunchDaemons/*.plist`의 Label (SMAppService) |
/// | iOS 앱 | `Wrapper/*.app` / `WrappedBundle` |
/// | 패키지 ID | `pkgutil --file-info <앱>` |
/// | Homebrew | Caskroom + 규칙 데이터의 cask (BID·앱 파일명) |
public struct IdentityResolver: IdentityResolving {
    public let paths: SystemPaths
    public let runner: any CommandRunning
    public let signatureReader: any CodeSignatureReading
    public let rules: any RuleDataProviding

    static let pkgutil = "/usr/sbin/pkgutil"

    /// 앱이 아니라 여러 앱이 함께 쓰는 프레임워크의 BID 접두사 — 내장 BID로 쓰면 다른 앱의 잔여물과 겹친다.
    static let sharedFrameworkPrefixes = ["org.sparkle-project.", "com.github.electron", "com.electron.", "org.chromium."]

    /// 내장 번들을 찾는 위치 (`Contents/` 기준)
    static let embeddedDirectories = ["Library/LoginItems", "Library/LaunchServices", "PlugIns", "Library/SystemExtensions",
                                      "Helpers", "Frameworks"]

    public init(paths: SystemPaths, runner: any CommandRunning, signatureReader: any CodeSignatureReading,
                rules: any RuleDataProviding) {
        self.paths = paths
        self.runner = runner
        self.signatureReader = signatureReader
        self.rules = rules
    }

    public func resolve(appAt url: URL) throws -> AppIdentity {
        let fm = FileManager.default
        let app = url.standardizedFileURL
        guard app.pathExtension.lowercased() == "app", fm.isDirectory(app) else { throw ScanError.notAnApp(url) }

        let wrapped = wrappedBundle(in: app)
        let wrappedInfo = wrapped.flatMap { BundleInfo.read(bundleAt: $0) }
        let outerPlist = app.appendingPathComponent("Contents/Info.plist")
        let outerInfo = fm.fileExists(atPath: outerPlist.path) ? BundleInfo.read(bundleAt: app) : nil
        guard let info = outerInfo ?? wrappedInfo else { throw ScanError.notAnApp(url) }

        guard let rawBID = info.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !rawBID.isEmpty,
              BundleIDRules.isSafeComponent(rawBID) else {
            throw ScanError.missingBundleID(url)
        }
        let wrappedBID = wrappedInfo?.bundleID.flatMap { BundleIDRules.isSafeComponent($0) ? $0 : nil }
        for bid in [rawBID, wrappedBID].compactMap({ $0 }) {
            if bid.lowercased().hasPrefix("com.apple.") || bid.lowercased() == "com.apple" { throw ScanError.appleApp(bundleID: bid) }
            if bid.caseInsensitiveCompare(paths.selfBundleID) == .orderedSame { throw ScanError.selfApp(bundleID: bid) }
        }

        // 코드 서명: 본체 → (없으면) Wrapper 내부 번들
        let mainSig = signatureReader.signingInfo(for: app) ?? wrapped.flatMap { signatureReader.signingInfo(for: $0) }
        var teamID = mainSig?.teamID
        var groups: [String] = mainSig?.appGroups ?? []

        // 내장 번들
        var embedded: [String] = []
        for (bid, bundleURL) in embeddedBundles(in: app) {
            embedded.append(bid)
            if let bundleURL, let sig = signatureReader.signingInfo(for: bundleURL) {
                groups.append(contentsOf: sig.appGroups)
                teamID = teamID ?? sig.teamID
            }
        }
        if let wrapped, let sig = signatureReader.signingInfo(for: wrapped) {
            groups.append(contentsOf: sig.appGroups)
            teamID = teamID ?? sig.teamID
        }
        let excluded = Set([rawBID.lowercased()])
        embedded = unique(embedded).filter { !excluded.contains($0.lowercased()) && isAppOwnedBundleID($0) }

        let launchServices = embeddedLaunchServices(in: app)
        let packageIDs = packageIDs(for: app)
        let name = (info.name?.isEmpty == false ? info.name : nil) ?? app.deletingPathExtension().lastPathComponent
        var identity = AppIdentity(
            bundleURL: app,
            bundleID: rawBID,
            name: name,
            displayName: info.displayName?.isEmpty == false ? info.displayName : nil,
            executableName: info.executable,
            version: info.shortVersion ?? info.version,
            teamID: teamID,
            appGroups: unique(groups.filter(BundleIDRules.isSafeComponent)),
            embeddedBundleIDs: embedded,
            embeddedLaunchServices: launchServices,
            wrappedBundleID: wrappedBID,
            packageIDs: packageIDs
        )
        identity.homebrewCask = homebrewCask(for: identity)
        identity.source = installSource(app: app, wrapped: wrapped, identity: identity)
        return identity
    }

    // MARK: - iOS/iPadOS 앱

    /// `Wrapper/*.app` 또는 `WrappedBundle` 링크가 가리키는 내부 번들 (앱 밖을 가리키면 무시)
    func wrappedBundle(in app: URL) -> URL? {
        let fm = FileManager.default
        let wrapperDir = app.appendingPathComponent("Wrapper", isDirectory: true)
        if let inner = fm.children(of: wrapperDir).filter({ $0.pathExtension == "app" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
            return inner
        }
        let link = app.appendingPathComponent("WrappedBundle")
        guard fm.itemExists(link) else { return nil }
        let resolved = link.resolvingSymlinksInPath()
        let resolvedApp = app.resolvingSymlinksInPath()
        return resolved.isStrictlyInside(resolvedApp) && fm.isDirectory(resolved) ? resolved : nil
    }

    // MARK: - 내장 번들

    /// (BID, 번들 URL) — LaunchServices의 권한 헬퍼처럼 번들이 아닌 실행 파일은 파일명이 BID 형태일 때만 쓴다 (URL nil).
    func embeddedBundles(in app: URL) -> [(String, URL?)] {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        var out: [(String, URL?)] = []
        for dir in Self.embeddedDirectories {
            let base = contents.appendingPathComponent(dir, isDirectory: true)
            for child in fm.children(of: base).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                if fm.isSymlink(child) { continue }
                if dir == "Frameworks" && child.pathExtension != "app" { continue }
                if fm.isDirectory(child) {
                    if let bid = BundleInfo.read(bundleAt: child)?.bundleID, !bid.isEmpty { out.append((bid, child)) }
                } else if dir == "Library/LaunchServices" || dir == "Helpers" {
                    let n = child.lastPathComponent
                    if BundleIDRules.looksLikeBundleID(n) { out.append((n, nil)) }
                }
            }
        }
        return out
    }

    func isAppOwnedBundleID(_ bid: String) -> Bool {
        let l = bid.lowercased()
        guard BundleIDRules.isSafeComponent(bid) else { return false }
        let prefixes = Self.sharedFrameworkPrefixes + rules.current().exclusions.nonAppBundleIDPrefixes.map { $0.lowercased() }
        return !prefixes.contains { l.hasPrefix($0.lowercased()) }
    }

    /// 번들 내장 Launch plist (SMAppService) — 번들과 함께 사라져도 launchd 등록은 남는다 (plan.md 3.2).
    func embeddedLaunchServices(in app: URL) -> [LaunchServiceRef] {
        let fm = FileManager.default
        var out: [LaunchServiceRef] = []
        for (dir, domain) in [("LaunchAgents", LaunchServiceRef.LaunchDomain.user), ("LaunchDaemons", .system)] {
            let base = app.appendingPathComponent("Contents/Library/\(dir)", isDirectory: true)
            for plistURL in fm.children(of: base).filter({ $0.pathExtension == "plist" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let label = LaunchPlist.read(at: plistURL)?.label ?? plistURL.deletingPathExtension().lastPathComponent
                guard !label.isEmpty else { continue }
                out.append(LaunchServiceRef(label: label, domain: domain, plistURL: plistURL))
            }
        }
        return out
    }

    // MARK: - 설치 패키지

    /// `pkgutil --file-info <앱 경로>`의 `pkgid:` 줄
    func packageIDs(for app: URL) -> [String] {
        guard let out = runner.output(Self.pkgutil, ["--file-info", paths.logicalPath(of: app)]) else { return [] }
        return unique(Self.parsePackageIDs(out.string))
    }

    static func parsePackageIDs(_ text: String) -> [String] {
        text.split(separator: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("pkgid:") else { return nil }
            let id = t.dropFirst("pkgid:".count).trimmingCharacters(in: .whitespaces)
            return id.isEmpty || !BundleIDRules.isSafeComponent(id) ? nil : id
        }
    }

    // MARK: - Homebrew

    var caskrooms: [URL] { [paths.system("opt/homebrew/Caskroom"), paths.system("usr/local/Caskroom")] }

    /// Caskroom에 설치 기록이 있는 cask 토큰
    func homebrewCask(for identity: AppIdentity) -> String? {
        let fm = FileManager.default
        let installed = Set(caskrooms.flatMap { fm.children(of: $0) }.filter { fm.isDirectory($0) }.map(\.lastPathComponent))
        guard !installed.isEmpty else { return nil }
        let data = rules.current()
        var tokens: [String] = []
        for bid in identity.allBundleIDs { tokens += data.casks(matchingBundleID: bid).map(\.token) }
        tokens += data.casks(matchingAppName: identity.bundleURL.lastPathComponent).map(\.token)
        if let t = tokens.first(where: installed.contains) { return t }
        // 규칙 데이터에 없는 cask: 관례적인 토큰 (`Google Chrome.app` → `google-chrome`)
        let guess = identity.bundleURL.deletingPathExtension().lastPathComponent.lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return installed.contains(guess) ? guess : nil
    }

    // MARK: - 출처

    func installSource(app: URL, wrapped: URL?, identity: AppIdentity) -> InstallSource {
        let fm = FileManager.default
        if fm.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt/receipt").path) { return .appStore }
        if wrapped != nil, fm.fileExists(atPath: app.appendingPathComponent("Wrapper/iTunesMetadata.plist").path) { return .appStore }
        if identity.homebrewCask != nil { return .homebrew }
        if !identity.packageIDs.isEmpty { return .package }
        return .direct
    }

    private func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased()).inserted }
    }
}
