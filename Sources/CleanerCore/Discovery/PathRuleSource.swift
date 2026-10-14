import Foundation

/// 경로 규칙 스캔 (plan.md 3.1, 3.2, 4.2 #3).
///
/// 각 카테고리 루트를 **한 번만** 나열하고(재귀 탐색 없음) 바로 아래 항목을 `AppIdentity`와 대조한다.
/// - `<BID>*`: `<BID>` 정확 일치 또는 `<BID>.` 접두사 → High
/// - `<NAME>`: 대소문자 무시 정확 일치 → Medium (짧거나 흔한 이름은 Low)
/// - 이름 기반 dotfile, 진단 리포트, 벤더 공용 폴더, `<TEAM>.` 접두 → Low
public struct PathRuleSource: CandidateSource {
    public let paths: SystemPaths
    public let rules: any RuleDataProviding

    public var sourceName: String { "pathRules" }

    public init(paths: SystemPaths, rules: any RuleDataProviding) {
        self.paths = paths
        self.rules = rules
    }

    /// 카테고리 루트 하나에 적용하는 규칙
    struct Root {
        var dir: URL
        var category: ItemCategory
        var domain: Domain
        var byBID = true
        var byName = false
        /// 벤더 공용 폴더 검사 대상인지 (Application Support, Caches, Logs)
        var vendor = false
        var preferences = false
    }

    public func candidates(for identity: AppIdentity) throws -> [Candidate] {
        let data = rules.current()
        let ctx = Context(identity: identity, bids: BundleIDMatcher(identity: identity),
                          names: NameMatcher(identity: identity, rules: data), rules: data)
        let L = paths.userLibrary
        let S = paths.systemLibrary
        func u(_ rel: String) -> URL { L.appendingPathComponent(rel, isDirectory: true) }
        func s(_ rel: String) -> URL { S.appendingPathComponent(rel, isDirectory: true) }

        let roots: [Root] = [
            // 사용자 도메인 (3.1)
            Root(dir: u("Containers"), category: .container, domain: .user),
            Root(dir: u("Application Support"), category: .applicationSupport, domain: .user, byName: true, vendor: true),
            Root(dir: u("Application Scripts"), category: .applicationScripts, domain: .user),
            Root(dir: u("Caches"), category: .caches, domain: .user, byName: true, vendor: true),
            Root(dir: u("HTTPStorages"), category: .httpStorage, domain: .user),
            Root(dir: u("WebKit"), category: .webKit, domain: .user),
            Root(dir: u("Cookies"), category: .cookies, domain: .user),
            Root(dir: u("Preferences"), category: .preferences, domain: .user, preferences: true),
            Root(dir: u("Preferences/ByHost"), category: .byHostPreferences, domain: .user),
            Root(dir: u("Saved Application State"), category: .savedState, domain: .user),
            Root(dir: u("Logs"), category: .logs, domain: .user, byName: true, vendor: true),
            Root(dir: paths.userCacheDir, category: .tempFiles, domain: .user),
            Root(dir: paths.userTempDir, category: .tempFiles, domain: .user),
            // 시스템 도메인 (3.2)
            Root(dir: s("Application Support"), category: .applicationSupport, domain: .system, byName: true, vendor: true),
            Root(dir: s("Caches"), category: .caches, domain: .system),
            Root(dir: s("Preferences"), category: .preferences, domain: .system, preferences: true),
            Root(dir: s("Logs"), category: .logs, domain: .system, byName: true),
        ]

        var out: [Candidate] = []
        for root in roots { out += scan(root, ctx) }
        out += groupContainers(ctx)
        out += applicationScriptGroups(ctx)
        out += iCloudContainers(ctx)
        out += diagnosticReports(u("Logs/DiagnosticReports"), domain: .user, ctx)
        out += diagnosticReports(s("Logs/DiagnosticReports"), domain: .system, ctx)
        for dir in PathCategorizer.pluginDirs {
            out += plugins(u(dir), domain: .user, ctx)
            out += plugins(s(dir), domain: .system, ctx)
        }
        out += kernelExtensions(s("Extensions"), ctx)
        out += dotfiles(ctx)
        return out.mergedByPath()
    }

    struct Context {
        var identity: AppIdentity
        var bids: BundleIDMatcher
        var names: NameMatcher
        var rules: RuleData
    }

    // MARK: - 카테고리 루트

    func scan(_ root: Root, _ ctx: Context) -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        let vendorNames = root.vendor ? associatedVendorFolders(ctx) : []
        for child in fm.children(of: root.dir) {
            let entry = child.lastPathComponent
            if let bid = ctx.bids.match(entry) {
                var c = Candidate(url: child, category: root.category, domain: root.domain,
                                  confidence: ctx.bids.confidence(forMatched: bid),
                                  evidence: [Evidence(.bundleIdentifier, "번들 ID \(bid) 일치")])
                if root.preferences, entry.hasSuffix(".plist") { c.preferencesDomain = String(entry.dropLast(".plist".count)) }
                out.append(c)
            } else if root.byName, let name = ctx.names.match(entry) {
                out.append(Candidate(url: child, category: root.category, domain: root.domain,
                                     confidence: ctx.names.confidence(for: name),
                                     evidence: [Evidence(.name, "이름 '\(name)' 일치 (대소문자 무시)")]))
            }
            if let vendor = vendorNames.first(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }), fm.isDirectory(child) {
                out.append(Candidate(url: child, category: root.category, domain: root.domain, confidence: .low,
                                     evidence: [Evidence(.pathRule, "벤더 공용 폴더 '\(vendor)' — 같은 개발사의 다른 앱도 쓸 수 있음")]))
                out += vendorSubfolders(child, vendor: vendor, root: root, ctx)
            }
        }
        return out
    }

    /// 이 앱과 관련된 벤더 공용 폴더 이름 (규칙 데이터 `vendorFolders` 중 BID 조직명 또는 앱 이름 접두어가 같은 것)
    func associatedVendorFolders(_ ctx: Context) -> [String] {
        let org = ctx.identity.bundleID.lowercased().split(separator: ".").dropFirst().first.map(String.init)
        return ctx.rules.exclusions.vendorFolders.filter { v in
            let key = v.lowercased().replacingOccurrences(of: " ", with: "")
            if let org, org == key { return true }
            return ctx.identity.candidateNames.contains { $0.lowercased().hasPrefix(v.lowercased() + " ") }
        }
    }

    /// 벤더 폴더 안의 앱 이름 폴더 (예: `Application Support/Google/Chrome`)
    func vendorSubfolders(_ vendorDir: URL, vendor: String, root: Root, _ ctx: Context) -> [Candidate] {
        var names = ctx.names.names
        for n in ctx.identity.candidateNames where n.lowercased().hasPrefix(vendor.lowercased() + " ") {
            names.append(String(n.dropFirst(vendor.count + 1)))
        }
        var out: [Candidate] = []
        for child in FileManager.default.children(of: vendorDir) {
            let entry = child.lastPathComponent
            if let bid = ctx.bids.match(entry) {
                out.append(Candidate(url: child, category: root.category, domain: root.domain,
                                     confidence: ctx.bids.confidence(forMatched: bid),
                                     evidence: [Evidence(.bundleIdentifier, "번들 ID \(bid) 일치 (\(vendor) 폴더 안)")]))
            } else if let name = names.first(where: { !$0.isEmpty && $0.caseInsensitiveCompare(entry) == .orderedSame }) {
                out.append(Candidate(url: child, category: root.category, domain: root.domain,
                                     confidence: ctx.names.confidence(for: name),
                                     evidence: [Evidence(.name, "\(vendor) 폴더 안 이름 '\(name)' 일치")]))
            }
        }
        return out
    }

    // MARK: - Group Containers · Application Scripts · iCloud

    func groupContainers(_ ctx: Context) -> [Candidate] {
        let groups = Set(ctx.identity.appGroups.map { $0.lowercased() })
        let team = ctx.identity.teamID.flatMap { BundleIDRules.isSafeComponent($0) ? $0 : nil }
        var out: [Candidate] = []
        for child in FileManager.default.children(of: paths.userLibrary.appendingPathComponent("Group Containers")) {
            let entry = child.lastPathComponent
            let lower = entry.lowercased()
            if groups.contains(lower) {
                out.append(Candidate(url: child, category: .groupContainer, confidence: .high,
                                     evidence: [Evidence(.appGroup, "App Group \(entry) (코드 서명 entitlements)")]))
                continue
            }
            // `group.<BID>` / `<TEAM>.<BID>` 형태
            var rest: String?
            if lower.hasPrefix("group.") { rest = String(entry.dropFirst("group.".count)) }
            if let team, entry.hasPrefix(team + ".") { rest = String(entry.dropFirst(team.count + 1)) }
            if let rest, let bid = ctx.bids.match(rest) {
                out.append(Candidate(url: child, category: .groupContainer, confidence: ctx.bids.confidence(forMatched: bid),
                                     evidence: [Evidence(.bundleIdentifier, "그룹 이름에 번들 ID \(bid) 포함")]))
            } else if let team, entry.hasPrefix(team + ".") {
                out.append(Candidate(url: child, category: .groupContainer, confidence: .low,
                                     evidence: [Evidence(.teamIdentifier, "Team ID \(team) 접두사 — 같은 개발사 공용일 수 있음")]))
            }
        }
        return out
    }

    /// `~/Library/Application Scripts/<GROUP>`
    func applicationScriptGroups(_ ctx: Context) -> [Candidate] {
        let groups = Set(ctx.identity.appGroups.map { $0.lowercased() })
        guard !groups.isEmpty else { return [] }
        return FileManager.default.children(of: paths.userLibrary.appendingPathComponent("Application Scripts"))
            .filter { groups.contains($0.lastPathComponent.lowercased()) }
            .map { Candidate(url: $0, category: .applicationScripts, confidence: .high,
                             evidence: [Evidence(.appGroup, "App Group \($0.lastPathComponent)")]) }
    }

    /// `~/Library/Mobile Documents/iCloud~<BID의 .을 ~로>` — 탐지·안내만 (선택 불가)
    func iCloudContainers(_ ctx: Context) -> [Candidate] {
        let dir = paths.userLibrary.appendingPathComponent("Mobile Documents")
        let wanted = Dictionary(ctx.bids.bundleIDs.map { ("icloud~" + $0.lowercased().replacingOccurrences(of: ".", with: "~"), $0) },
                                uniquingKeysWith: { a, _ in a })
        return FileManager.default.children(of: dir).compactMap { child in
            guard let bid = wanted[child.lastPathComponent.lowercased()] else { return nil }
            return Candidate(url: child, category: .iCloudContainer, confidence: .high, nature: .synced,
                             evidence: [Evidence(.bundleIdentifier, "iCloud 컨테이너 (번들 ID \(bid))")],
                             protection: .iCloudData,
                             notes: ["iCloud에 동기화되는 데이터라 옮기지 않습니다 — 지우면 다른 기기에서도 사라집니다"])
        }
    }

    // MARK: - 이름 기반 (Low)

    func diagnosticReports(_ dir: URL, domain: Domain, _ ctx: Context) -> [Candidate] {
        FileManager.default.children(of: dir).compactMap { child in
            guard let name = ctx.names.matchDiagnostic(child.lastPathComponent) else { return nil }
            return Candidate(url: child, category: .diagnosticReports, domain: domain, confidence: .low,
                             evidence: [Evidence(.name, "진단 리포트 파일명이 '\(name)'(으)로 시작")])
        }
    }

    /// `~/.<name>`, `~/.config/<name>`, `~/.local/share/<name>`, `~/.cache/<name>` — 이름 기반이므로 항상 Low
    func dotfiles(_ ctx: Context) -> [Candidate] {
        let fm = FileManager.default
        let security = Set(ctx.rules.exclusions.securityDotfiles.map { $0.lowercased() })
        var out: [Candidate] = []
        for child in fm.children(of: paths.home) {
            let entry = child.lastPathComponent
            guard entry.hasPrefix("."), !security.contains(entry.lowercased()),
                  let name = ctx.names.match(String(entry.dropFirst())) else { continue }
            out.append(Candidate(url: child, category: .dotfile, confidence: .low,
                                 evidence: [Evidence(.name, "이름 '\(name)' 기반 숨김 설정 '~/\(entry)'")]))
        }
        for rel in [".config", ".local/share", ".cache"] {
            for child in fm.children(of: paths.home(rel)) {
                guard let name = ctx.names.match(child.lastPathComponent) else { continue }
                out.append(Candidate(url: child, category: .dotfile, confidence: .low,
                                     evidence: [Evidence(.name, "이름 기반 설정 '~/\(rel)/\(name)'")]))
            }
        }
        return out
    }

    // MARK: - 번들 내부 Info.plist로 판정

    func plugins(_ dir: URL, domain: Domain, _ ctx: Context) -> [Candidate] {
        FileManager.default.children(of: dir).compactMap { child in
            guard let bid = BundleInfo.read(bundleAt: child)?.bundleID, let matched = ctx.bids.match(bid) else { return nil }
            return Candidate(url: child, category: .plugin, domain: domain, confidence: ctx.bids.confidence(forMatched: matched),
                             evidence: [Evidence(.bundleIdentifier, "플러그인 번들 ID \(bid) 일치")])
        }
    }

    /// `/Library/Extensions/*.kext` — 탐지·안내만 (plan.md 1.3)
    func kernelExtensions(_ dir: URL, _ ctx: Context) -> [Candidate] {
        FileManager.default.children(of: dir).filter { $0.pathExtension == "kext" }.compactMap { child in
            guard let bid = BundleInfo.read(bundleAt: child)?.bundleID, ctx.bids.match(bid) != nil else { return nil }
            return Candidate(url: child, category: .kernelExtension, domain: .system, confidence: .high,
                             evidence: [Evidence(.bundleIdentifier, "커널 확장 번들 ID \(bid)")],
                             protection: .detectOnly,
                             notes: ["커널 확장은 자동으로 제거하지 않습니다 — 정리 후 안내를 확인하세요"])
        }
    }
}
