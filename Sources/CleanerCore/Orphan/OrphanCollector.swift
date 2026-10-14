import Foundation

/// 2~3단계: 카테고리 루트 바로 아래 항목을 수집하고 소유 앱 단서로 기본 판정한다 (plan.md 4.5.3, 4.5.4).
/// 설치된 앱의 것이거나 제외 대상이면 nil(후보 아님).
struct OrphanCollector {
    let paths: SystemPaths
    let runner: CommandRunning
    let index: InventoryIndex
    let rules: RuleData
    let exclusions: ExclusionRules
    let options: OrphanScanOptions
    let isMounted: @Sendable (URL) -> Bool

    /// 카테고리 루트별 해석 방식
    enum Kind {
        case container
        case groupContainer
        case preferences
        case byHostPreferences
        case savedState
        /// 항목명이 BID여야 판정 (아니면 건너뜀)
        case bundleIDNamed
        /// BID 형태면 BID, 아니면 이름 기반 (Application Support, Logs, Caches)
        case bundleIDOrName(daemonNames: Bool)
        case applicationScripts
        case launchPlist(LaunchServiceRef.LaunchDomain)
        case privilegedHelper
    }

    struct Root {
        var url: URL
        var category: ItemCategory
        var domain: Domain
        var kind: Kind
        /// 이 루트에서 건너뛸 하위 이름 (다른 루트로 따로 처리하는 폴더 등)
        var skipNames: Set<String> = []
    }

    var roots: [Root] {
        let u = paths.userLibrary, s = paths.systemLibrary
        return [
            Root(url: u.appendingPathComponent("Containers"), category: .container, domain: .user, kind: .container),
            Root(url: u.appendingPathComponent("Group Containers"), category: .groupContainer, domain: .user, kind: .groupContainer),
            Root(url: u.appendingPathComponent("Preferences"), category: .preferences, domain: .user, kind: .preferences),
            Root(url: u.appendingPathComponent("Preferences/ByHost"), category: .byHostPreferences, domain: .user,
                 kind: .byHostPreferences),
            Root(url: u.appendingPathComponent("Saved Application State"), category: .savedState, domain: .user, kind: .savedState),
            Root(url: u.appendingPathComponent("Caches"), category: .caches, domain: .user, kind: .bundleIDOrName(daemonNames: true)),
            Root(url: u.appendingPathComponent("HTTPStorages"), category: .httpStorage, domain: .user, kind: .bundleIDNamed),
            Root(url: u.appendingPathComponent("WebKit"), category: .webKit, domain: .user, kind: .bundleIDNamed),
            Root(url: u.appendingPathComponent("Cookies"), category: .cookies, domain: .user, kind: .bundleIDNamed),
            Root(url: u.appendingPathComponent("Application Scripts"), category: .applicationScripts, domain: .user,
                 kind: .applicationScripts),
            Root(url: u.appendingPathComponent("Application Support"), category: .applicationSupport, domain: .user,
                 kind: .bundleIDOrName(daemonNames: false)),
            Root(url: u.appendingPathComponent("Logs"), category: .logs, domain: .user, kind: .bundleIDOrName(daemonNames: true),
                 skipNames: ["DiagnosticReports"]),
            Root(url: u.appendingPathComponent("LaunchAgents"), category: .launchAgent, domain: .user, kind: .launchPlist(.user)),
            Root(url: s.appendingPathComponent("Application Support"), category: .applicationSupport, domain: .system,
                 kind: .bundleIDOrName(daemonNames: false)),
            Root(url: s.appendingPathComponent("Caches"), category: .caches, domain: .system, kind: .bundleIDOrName(daemonNames: true)),
            Root(url: s.appendingPathComponent("Preferences"), category: .preferences, domain: .system, kind: .preferences),
            Root(url: s.appendingPathComponent("Logs"), category: .logs, domain: .system, kind: .bundleIDOrName(daemonNames: true),
                 skipNames: ["DiagnosticReports"]),
            // /Library/LaunchAgents는 각 사용자의 gui 도메인에서 실행된다 (bootout gui/<uid>/<label>)
            Root(url: s.appendingPathComponent("LaunchAgents"), category: .launchAgent, domain: .system, kind: .launchPlist(.user)),
            Root(url: s.appendingPathComponent("LaunchDaemons"), category: .launchDaemon, domain: .system, kind: .launchPlist(.system)),
            Root(url: s.appendingPathComponent("PrivilegedHelperTools"), category: .privilegedHelper, domain: .system,
                 kind: .privilegedHelper),
            Root(url: paths.userCacheDir, category: .tempFiles, domain: .user, kind: .bundleIDNamed),
            Root(url: paths.userTempDir, category: .tempFiles, domain: .user, kind: .bundleIDNamed),
        ]
    }

    // MARK: - 카테고리 루트 수집

    /// 모든 카테고리 루트의 판정 결과와 읽지 못한 루트
    func collectRoots() -> (items: [OrphanItem], unreadable: [URL]) {
        var items: [OrphanItem] = []
        var unreadable: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard fm.isDirectory(root.url) else { continue }
            let names: [String]
            do {
                // 루트가 심볼릭 링크여도 대상 폴더를 나열하되, 항목 경로는 원래 루트 아래로 유지한다
                names = try fm.contentsOfDirectory(atPath: root.url.resolvingSymlinksInPath().path)
            } catch {
                unreadable.append(root.url)   // 전체 디스크 접근 권한 없음 등
                continue
            }
            let children = names.map { root.url.appendingPathComponent($0).standardizedFileURL }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                if name.hasPrefix(".") || root.skipNames.contains(name) { continue }
                if exclusions.isExcludedPath(child) { continue }
                if case .preferences = root.kind, name == "ByHost" { continue }
                if let item = judge(child, root: root) { items.append(item) }
            }
        }
        return (items, unreadable)
    }

    func judge(_ url: URL, root: Root) -> OrphanItem? {
        let name = url.lastPathComponent
        switch root.kind {
        case .container:
            return judgeContainer(url, root: root)
        case .groupContainer:
            return judgeGroup(url, identifier: groupIdentifier(url) ?? name, root: root)
        case .preferences:
            guard url.pathExtension == "plist", !FileManager.default.isDirectory(url) else { return nil }
            let bid = String(name.dropLast(".plist".count))
            guard var item = judgeBundleID(bid, url: url, root: root) else { return nil }
            if root.domain == .user { item.preferencesDomain = bid }
            return item
        case .byHostPreferences:
            guard url.pathExtension == "plist" else { return nil }
            var parts = name.dropLast(".plist".count).split(separator: ".").map(String.init)
            if let last = parts.last, BundleIDHeuristics.isHostIdentifier(last) { parts.removeLast() }
            return judgeBundleID(parts.joined(separator: "."), url: url, root: root)
        case .savedState:
            guard url.pathExtension == "savedState" else { return nil }
            return judgeBundleID(url.deletingPathExtension().lastPathComponent, url: url, root: root)
        case .bundleIDNamed:
            return judgeBundleID(Self.stripKnownExtension(name), url: url, root: root)
        case .bundleIDOrName(let daemonNames):
            let stem = Self.stripKnownExtension(name)
            if BundleIDHeuristics.isBundleIDShaped(stem) { return judgeBundleID(stem, url: url, root: root) }
            return judgeName(stem, url: url, root: root, daemonNames: daemonNames)
        case .applicationScripts:
            if BundleIDHeuristics.teamPrefix(name) != nil || name.hasPrefix("group.") {
                return judgeGroup(url, identifier: name, root: root)
            }
            return judgeBundleID(name, url: url, root: root)
        case .launchPlist(let launchDomain):
            guard url.pathExtension == "plist" else { return nil }
            return judgeLaunchPlist(url, root: root, launchDomain: launchDomain)
        case .privilegedHelper:
            return judgeBundleID(name, url: url, root: root)
        }
    }

    static func stripKnownExtension(_ name: String) -> String {
        for ext in [".binarycookies", ".plist", ".savedState", ".log"] where name.hasSuffix(ext) {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    // MARK: - BID 기반

    /// BID 이름 항목 (Preferences, Caches, HTTPStorages …): 인벤토리에 없으면 Medium
    func judgeBundleID(_ bid: String, url: URL, root: Root) -> OrphanItem? {
        if bid.lowercased().hasPrefix("group.") || BundleIDHeuristics.teamPrefix(bid) != nil {
            return judgeGroup(url, identifier: bid, root: root)
        }
        guard BundleIDHeuristics.isBundleIDShaped(bid), !exclusions.isExcludedBundleID(bid) else { return nil }
        var item = OrphanItem(url: url, category: root.category, domain: root.domain, bundleID: bid, confidence: .medium,
                              evidence: [])
        switch index.ownership(of: bid) {
        case .installed:
            return nil
        case .offline:
            item.offline = true
            item.confidence = .low
            item.evidence.append(Evidence(.inventory, "번들 ID \(bid)인 앱이 연결 해제된 외장 볼륨에 있을 수 있음"))
        case .notFound:
            item.evidence.append(Evidence(.inventory, "번들 ID \(bid)인 앱이 설치 목록에 없음"))
        }
        return item
    }

    /// 컨테이너: 메타데이터 `MCMMetadataIdentifier`가 폴더명보다 우선. 메타데이터 BID가 없으면 High.
    func judgeContainer(_ url: URL, root: Root) -> OrphanItem? {
        let metadata = PlistValue.readDictionary(at: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        let metaID = metadata?["MCMMetadataIdentifier"]?.string
        guard let bid = metaID ?? (BundleIDHeuristics.isBundleIDShaped(url.lastPathComponent) ? url.lastPathComponent : nil),
              !exclusions.isExcludedBundleID(bid) else { return nil }
        var item = OrphanItem(url: url, category: .container, domain: root.domain, bundleID: bid, confidence: .medium,
                              evidence: [])
        switch index.ownership(of: bid) {
        case .installed:
            return nil
        case .offline:
            item.offline = true
            item.confidence = .low
            item.evidence.append(Evidence(.containerMetadata, "컨테이너 소유 앱 \(bid)이(가) 연결 해제된 외장 볼륨에 있을 수 있음"))
        case .notFound:
            if metaID != nil {
                item.confidence = .high
                item.evidence.append(Evidence(.containerMetadata, "컨테이너 소유 앱 \(bid)이(가) 설치되어 있지 않음 (확장·헬퍼 포함)"))
            } else {
                item.evidence.append(Evidence(.inventory, "번들 ID \(bid)인 앱이 설치 목록에 없음 (컨테이너 메타데이터 없음)"))
            }
        }
        return item
    }

    func groupIdentifier(_ url: URL) -> String? {
        PlistValue.readDictionary(at: url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))?["MCMMetadataIdentifier"]?.string
    }

    /// Group Container / 그룹 Application Scripts: `<TEAM>.xxx` 또는 `group.xxx`
    func judgeGroup(_ url: URL, identifier: String, root: Root) -> OrphanItem? {
        let lower = identifier.lowercased()
        let team = BundleIDHeuristics.teamPrefix(identifier)
        var inner = identifier
        if lower.hasPrefix("group.") { inner = String(identifier.dropFirst("group.".count)) }
        else if let team { inner = String(identifier.dropFirst(team.count + 1)) }
        guard !exclusions.isExcludedBundleID(identifier), !exclusions.isExcludedBundleID(inner),
              !lower.hasPrefix("systemgroup.") else { return nil }
        // 설치 앱(내장 번들 포함)의 entitlements에 있으면 사용 중
        if index.appGroups.contains(lower) { return nil }
        let innerIsBID = BundleIDHeuristics.isBundleIDShaped(inner)
        var item = OrphanItem(url: url, category: root.category, domain: root.domain, bundleID: innerIsBID ? inner : nil,
                              teamID: team, name: innerIsBID ? nil : inner, confidence: .medium, evidence: [])
        if innerIsBID {
            switch index.ownership(of: inner) {
            case .installed:
                return nil
            case .offline:
                item.offline = true
                item.confidence = .low
                item.evidence.append(Evidence(.appGroup, "그룹 \(identifier)의 앱이 연결 해제된 외장 볼륨에 있을 수 있음"))
                return item
            case .notFound:
                break
            }
        }
        item.evidence.append(Evidence(.appGroup, "그룹 \(identifier)을(를) 쓰는 설치 앱이 없음"))
        if let team, let users = index.teams[team], !users.isEmpty {
            item.share = .shared(usedBy: users, reason: "같은 개발자(Team ID \(team))의 앱이 설치되어 있음")
        }
        return item
    }

    // MARK: - 이름 기반

    /// BID가 아닌 이름 (Electron 앱의 Application Support 등): 설치 앱 이름과 일치하지 않으면 Low
    func judgeName(_ name: String, url: URL, root: Root, daemonNames: Bool) -> OrphanItem? {
        if exclusions.isAppleSystemName(name, daemonNames: daemonNames) { return nil }
        if index.matchesInstalledName(name) { return nil }
        let normalized = BundleIDHeuristics.normalizedName(name)
        guard !normalized.isEmpty else { return nil }
        // 같은 벤더의 다른 앱이 설치돼 있으면 공용 폴더 — 고아로 보지 않는다 (`Docker Desktop` ↔ Docker, `Google Drive` ↔ Chrome)
        if index.vendorNames.contains(normalized) { return nil }
        if name.contains(" "), let first = name.split(separator: " ").first,
           index.vendorNames.contains(BundleIDHeuristics.normalizedName(String(first))) { return nil }
        var item = OrphanItem(url: url, category: root.category, domain: root.domain, name: name, confidence: .low, evidence: [])
        if exclusions.isVendorFolder(name) {
            item.evidence.append(Evidence(.name, "개발사 공용 폴더 '\(name)' — 같은 개발사의 설치 앱이 없음"))
            item.addNote("여러 앱이 함께 쓰는 개발사 폴더일 수 있음")
        } else {
            item.evidence.append(Evidence(.name, "이름이 '\(name)'인 설치 앱이 없음"))
            if rules.isWeakName(name) { item.addNote("흔한 이름이라 다른 프로그램의 데이터일 수 있음") }
        }
        return item
    }

    // MARK: - Launch plist

    /// LaunchAgent/Daemon: 실행 파일이 없으면 깨진 서비스 → High (연결 해제된 볼륨이면 Low)
    func judgeLaunchPlist(_ url: URL, root: Root, launchDomain: LaunchServiceRef.LaunchDomain) -> OrphanItem? {
        guard let plist = LaunchPlist.read(at: url) else { return nil }
        let label = plist.label ?? url.deletingPathExtension().lastPathComponent
        if exclusions.isExcludedBundleID(label) { return nil }
        let labelIsBID = BundleIDHeuristics.isBundleIDShaped(label)
        if index.launchLabels.contains(label.lowercased()) { return nil }
        let labelOwnership: InventoryIndex.Ownership = labelIsBID ? index.ownership(of: label) : .notFound
        if labelOwnership == .installed { return nil }

        var item = OrphanItem(url: url, category: root.category, domain: root.domain, bundleID: labelIsBID ? label : nil,
                              name: labelIsBID ? nil : label, confidence: .medium, evidence: [],
                              launchService: LaunchServiceRef(label: label, domain: launchDomain, plistURL: url))
        if labelOwnership == .offline {
            item.offline = true
            item.confidence = .low
            item.evidence.append(Evidence(.launchPlist, "서비스 \(label)의 앱이 연결 해제된 외장 볼륨에 있을 수 있음"))
            return item
        }

        if plist.targetExtractionFailed {
            item.confidence = .low
            item.evidence.append(Evidence(.launchPlist, "셸·인터프리터로 실행되어 실행 대상을 확인할 수 없음"))
            return item
        }
        // `open -a /Applications/Foo.app`처럼 상대 경로 실행 파일이면 인자의 절대 경로를 대상으로 본다
        var executable = plist.effectiveExecutable
        if let e = executable, !e.hasPrefix("/") {
            executable = plist.arguments.dropFirst().first { $0.hasPrefix("/") }
            if executable == nil {
                item.confidence = .low
                item.evidence.append(Evidence(.launchPlist, "실행 파일 '\(e)'의 위치를 확인할 수 없음"))
                return item
            }
        }
        guard let exe = executable else {
            guard labelIsBID else { return nil }
            item.evidence.append(Evidence(.launchPlist, "서비스 \(label)의 실행 파일 정보가 없고 소유 앱이 설치 목록에 없음"))
            return item
        }
        let resolved = paths.resolveRecorded(exe)
        // 실행 파일이 살아 있으면 동작 중인 서비스 (CLI 도구·업데이터 등) — 고아 아님
        if FileManager.default.itemExists(resolved) { return nil }
        item.appNameHint = Self.appName(inRecordedPath: exe)
        if let vol = VolumePaths.volumeRoot(of: resolved, paths: paths), !isMounted(vol) {
            item.offline = true
            item.confidence = .low
            item.evidence.append(Evidence(.launchPlist, "실행 파일 \(exe)이(가) 연결 해제된 외장 볼륨에 있음"))
            return item
        }
        item.confidence = .high
        item.evidence.append(Evidence(.launchPlist, "실행 파일 \(exe) 없음"))
        return item
    }

    /// `/Applications/Foo.app/Contents/MacOS/foo` → "Foo"
    static func appName(inRecordedPath path: String) -> String? {
        for comp in path.split(separator: "/") where comp.hasSuffix(".app") {
            return String(comp.dropLast(4))
        }
        return nil
    }

    // MARK: - Dotfiles

    static let ignoredDotfiles: Set<String> = [
        ".Trash", ".DS_Store", ".CFUserTextEncoding", ".localized", ".config", ".local", ".cache", ".zshrc", ".zprofile",
        ".zshenv", ".zlogin", ".zlogout", ".zsh_history", ".zsh_sessions", ".bashrc", ".bash_profile", ".bash_history",
        ".bash_sessions", ".bash_logout", ".profile", ".inputrc", ".viminfo", ".vimrc", ".lesshst", ".gitconfig",
        ".python_history", ".node_repl_history", ".sqlite_history", ".wget-hsts", ".Xauthority", ".hushlogin",
    ]

    /// `~/.<name>`, `~/.config/*`, `~/.local/share/*`, `~/.cache/*` — `includeDotfiles`일 때만 Low (보안 폴더는 항상 제외)
    func collectDotfiles() -> [OrphanItem] {
        guard options.includeDotfiles else { return [] }
        let fm = FileManager.default
        var out: [OrphanItem] = []
        func consider(_ url: URL, stem: String) {
            if exclusions.isExcludedPath(url) { return }
            if exclusions.isAppleSystemName(stem) || index.matchesInstalledName(stem) { return }
            var item = OrphanItem(url: url, category: .dotfile, domain: .user, name: stem, confidence: .low,
                                  evidence: [Evidence(.name, "이름이 '\(stem)'인 설치 앱이 없음 (숨김 설정 폴더)")])
            item.addNote("CLI 도구·런타임 데이터일 수 있음")
            out.append(item)
        }
        for child in fm.children(of: paths.home).map(\.standardizedFileURL).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = child.lastPathComponent
            guard name.hasPrefix("."), name.count > 1, !Self.ignoredDotfiles.contains(name),
                  !exclusions.isSecurityDotfile(name) else { continue }
            consider(child, stem: String(name.dropFirst()))
        }
        for rel in [".config", ".local/share", ".cache"] {
            for child in fm.children(of: paths.home(rel)).map(\.standardizedFileURL).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                guard !name.hasPrefix("."), !exclusions.isSecurityDotfile("." + name) else { continue }
                consider(child, stem: name)
            }
        }
        return out
    }

    // MARK: - Homebrew Caskroom

    /// Caskroom 기록은 있으나 앱 번들이 사라진 cask → High + `brew uninstall --zap --cask` 안내
    func collectHomebrew() -> [OrphanItem] {
        var out: [OrphanItem] = []
        let fm = FileManager.default
        for record in Caskroom.records(paths: paths, fallback: rules.casks) {
            guard !record.appNames.isEmpty else { continue }   // 폰트·CLI·pkg cask는 판정하지 않는다
            let exists = record.appLocations.contains { fm.itemExists($0) } || record.appNames.contains { app in
                fm.itemExists(paths.system("Applications").appendingPathComponent(app))
                    || fm.itemExists(paths.home("Applications").appendingPathComponent(app))
                    || index.appFileNames.contains(app.lowercased())
            }
            if exists { continue }
            if record.bundleIDs.contains(where: { index.ownership(of: $0) == .installed }) { continue }
            let apps = record.appNames.joined(separator: ", ")
            var item = OrphanItem(url: record.caskroomURL, category: .other, domain: .user, bundleID: record.bundleIDs.first,
                                  appNameHint: record.appNames.first.map { String($0.dropLast($0.hasSuffix(".app") ? 4 : 0)) },
                                  caskToken: record.token, confidence: .high,
                                  evidence: [Evidence(.homebrewRecord, "Homebrew cask '\(record.token)' 기록은 있으나 \(apps) 없음")])
            item.addNote("brew uninstall --zap --cask \(record.token) 로 정리하는 것을 권장")
            out.append(item)
        }
        return out
    }

    // MARK: - 설치 영수증

    /// 영수증에 기록된 앱 번들이 모두 사라진 패키지 → 영수증과 그 패키지만 소유한 잔여 파일을 High로
    func collectReceipts() async -> [OrphanItem] {
        let packages = index.snapshot.packageIDs.filter { !exclusions.isExcludedBundleID($0) }
        guard !packages.isEmpty else { return [] }
        let reader = ReceiptReader(paths: paths, runner: runner)
        let listings = await withTaskGroup(of: (String, [String])?.self) { group in
            var results: [String: [String]] = [:]
            var iterator = packages.makeIterator()
            func addNext() -> Bool {
                guard let pkg = iterator.next() else { return false }
                group.addTask { reader.files(pkg).map { (pkg, $0) } }
                return true
            }
            for _ in 0..<8 where !addNext() { break }
            while let r = await group.next() {
                if let (pkg, files) = r { results[pkg] = files }
                _ = addNext()
            }
            return results
        }

        // 카테고리 수준 항목 → 소유 패키지 (다른 패키지와 공유하면 제외 — plan.md 4.3.2)
        var owners: [String: Set<String>] = [:]
        for (pkg, files) in listings {
            for f in files { if let top = Self.categoryLevelPath(f) { owners[top, default: []].insert(pkg) } }
        }

        var out: [OrphanItem] = []
        let fm = FileManager.default
        for pkg in packages.sorted() {
            guard let files = listings[pkg] else { continue }
            // `/Applications`에 설치한 앱만 본다. 임시 위치(`/tmp` 등)에 풀었다가 옮기는 설치기나
            // 앱이 없는 패키지(드라이버·CLI)는 판정하지 않는다.
            let apps = Self.appBundles(in: files).filter { $0.hasPrefix("Applications/") }
            guard !apps.isEmpty else { continue }
            if BundleIDHeuristics.isBundleIDShaped(pkg), index.ownership(of: pkg) == .installed { continue }
            let present = apps.contains { rel in
                fm.itemExists(paths.system(rel)) || index.appFileNames.contains(URL(fileURLWithPath: rel).lastPathComponent.lowercased())
            }
            if present { continue }
            let appNames = apps.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            let hint = appNames.first
            let receiptURL = paths.system("private/var/db/receipts/\(pkg).plist").standardizedFileURL
            out.append(OrphanItem(url: receiptURL, category: .receipt, domain: .system, appNameHint: hint, packageID: pkg,
                                  confidence: .high,
                                  evidence: [Evidence(.receipt, "설치 패키지 \(pkg)의 앱 \(apps.map { "/" + $0 }.joined(separator: ", ")) 없음")]))
            var seen = Set<String>()
            for f in files {
                guard let top = Self.categoryLevelPath(f), seen.insert(top).inserted, owners[top] == [pkg] else { continue }
                let url = paths.system(top).standardizedFileURL
                guard fm.itemExists(url), !exclusions.isExcludedPath(url) else { continue }
                let (category, launchDomain) = Self.systemCategory(of: top)
                var item = OrphanItem(url: url, category: category, domain: .system, appNameHint: hint, packageID: pkg,
                                      confidence: .high,
                                      evidence: [Evidence(.receipt, "설치 패키지 \(pkg)가 설치한 파일 (앱 번들은 삭제됨)")])
                if let launchDomain, let label = LaunchPlist.read(at: url)?.label {
                    item.launchService = LaunchServiceRef(label: label, domain: launchDomain, plistURL: url)
                    if BundleIDHeuristics.isBundleIDShaped(label) { item.bundleID = label }
                }
                out.append(item)
            }
        }
        return out
    }

    /// 목록에서 최상위 `.app` 번들 경로
    static func appBundles(in files: [String]) -> [String] {
        var out: [String] = []
        for f in files {
            var comps: [Substring] = []
            for c in f.split(separator: "/") {
                if c.hasPrefix("._") { break }   // AppleDouble 메타데이터
                comps.append(c)
                if c.hasSuffix(".app") {
                    let p = comps.joined(separator: "/")
                    if !out.contains(p) { out.append(p) }
                    break
                }
            }
        }
        return out
    }

    static let systemCategoryRoots: [(String, ItemCategory, LaunchServiceRef.LaunchDomain?)] = [
        ("Library/Application Support", .applicationSupport, nil),
        ("Library/Caches", .caches, nil),
        ("Library/Preferences", .preferences, nil),
        ("Library/Logs", .logs, nil),
        ("Library/LaunchAgents", .launchAgent, .user),
        ("Library/LaunchDaemons", .launchDaemon, .system),
        ("Library/PrivilegedHelperTools", .privilegedHelper, nil),
    ]

    /// `Library/Application Support/Foo/bar.db` → `Library/Application Support/Foo` (카테고리 루트 바로 아래)
    static func categoryLevelPath(_ rel: String) -> String? {
        for (root, _, _) in systemCategoryRoots where rel.hasPrefix(root + "/") {
            let rest = rel.dropFirst(root.count + 1)
            guard let first = rest.split(separator: "/").first, !first.hasPrefix(".") else { return nil }
            return root + "/" + first
        }
        return nil
    }

    static func systemCategory(of rel: String) -> (ItemCategory, LaunchServiceRef.LaunchDomain?) {
        for (root, cat, domain) in systemCategoryRoots where rel.hasPrefix(root + "/") { return (cat, domain) }
        return (.other, nil)
    }
}

/// `pkgutil --files`·영수증 plist 읽기 (병렬 실행용 Sendable)
struct ReceiptReader: Sendable {
    let paths: SystemPaths
    let runner: CommandRunning

    /// 패키지가 설치한 파일 목록 (`/` 기준 상대 경로)
    func files(_ pkg: String) -> [String]? {
        guard let out = runner.output(AppInventory.Tool.pkgutil, ["--files", pkg]) else { return nil }
        let prefix = installPrefix(pkg)
        return out.lines.map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let joined = prefix.isEmpty ? trimmed : prefix + "/" + trimmed
            return joined.hasPrefix("/") ? String(joined.dropFirst()) : joined
        }.filter { !$0.isEmpty }
    }

    /// 영수증 plist의 `InstallPrefixPath` (없으면 `pkgutil --pkg-info`의 `location:`)
    func installPrefix(_ pkg: String) -> String {
        let plist = paths.system("private/var/db/receipts/\(pkg).plist")
        var prefix = PlistValue.readDictionary(at: plist)?["InstallPrefixPath"]?.string
        var volume = "/"
        if prefix == nil, let info = runner.output(AppInventory.Tool.pkgutil, ["--pkg-info", pkg]) {
            for line in info.lines {
                if line.hasPrefix("location:") { prefix = line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces) }
                if line.hasPrefix("volume:") { volume = line.dropFirst("volume:".count).trimmingCharacters(in: .whitespaces) }
            }
        }
        let combined = (volume == "/" ? "" : volume) + "/" + (prefix ?? "")
        return combined.split(separator: "/").joined(separator: "/")
    }
}
