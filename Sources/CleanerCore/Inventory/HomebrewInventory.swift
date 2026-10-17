import Foundation

/// Homebrew로 설치한 formula·cask 목록을 설치 기록 파일로 읽는다 (`brew` 명령은 실행하지 않는다).
///
/// | 종류 | 설치 기록 |
/// |---|---|
/// | formula | `<prefix>/Cellar/<name>/<version>/INSTALL_RECEIPT.json` (`installed_on_request`, `time`) |
/// | cask | `<prefix>/Caskroom/<token>/.metadata/INSTALL_RECEIPT.json` (`uninstall_artifacts`, `source.version`) |
///
/// 접두사는 Apple Silicon(`/opt/homebrew`)과 Intel(`/usr/local`) 둘 다 본다.
/// 항목마다 관련 경로(`HomebrewRelatedPath`)도 모은다 — 표시용이며 정리 대상이 아니다.
public struct HomebrewInventory: Sendable {
    public let paths: SystemPaths

    static let prefixes = ["opt/homebrew", "usr/local"]

    public init(paths: SystemPaths) {
        self.paths = paths
    }

    /// - Parameter rules: cask zap 규칙 보충(설치 기록에 zap이 없을 때)과 흔한 이름 목록
    public func items(rules: RuleData = .empty) -> [HomebrewItem] {
        let index = RelatedIndex(paths: paths)
        var out: [HomebrewItem] = []
        for p in Self.prefixes {
            let prefix = paths.system(p)
            let links = Self.links(in: prefix)
            out += formulae(in: prefix, links: links, index: index, rules: rules)
            out += casks(in: prefix, links: links, index: index, rules: rules)
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: formula

    func formulae(in prefix: URL, links: [String: [URL]], index: RelatedIndex, rules: RuleData) -> [HomebrewItem] {
        Self.entries(in: prefix.appendingPathComponent("Cellar")).compactMap { dir in
            guard let latest = Self.versionDirectories(in: dir).last else { return nil }
            let receipt = PackageInventory.readJSON(latest.appendingPathComponent("INSTALL_RECEIPT.json"))
            var item = HomebrewItem(kind: .formula, name: dir.lastPathComponent, version: latest.lastPathComponent, location: dir,
                                    installedOnRequest: Self.installedOnRequest(receipt), installedAt: Self.date(receipt?["time"]))
            item.related = related(for: item, prefix: prefix, links: links["Cellar/\(item.name)"] ?? [], zap: [],
                                   index: index, rules: rules)
            return item
        }
    }

    // MARK: cask

    func casks(in prefix: URL, links: [String: [URL]], index: RelatedIndex, rules: RuleData) -> [HomebrewItem] {
        let fm = FileManager.default
        return Self.entries(in: prefix.appendingPathComponent("Caskroom")).map { dir in
            let record = Caskroom.record(at: dir, paths: paths, fallback: rules.casks)
            let receipt = PackageInventory.readJSON(dir.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"))
            let version = ((receipt?["source"] as? [String: Any])?["version"] as? String)
                ?? Self.versionDirectories(in: dir).last?.lastPathComponent
            // 설치 위치 기록(버전 폴더의 링크)이 없으면 표준 위치에서 앱 이름으로 찾는다
            var appURLs = record.appLocations.filter { fm.itemExists($0) }
            if appURLs.isEmpty {
                for name in record.appNames {
                    if let url = [paths.system("Applications"), paths.home("Applications")]
                        .map({ $0.appendingPathComponent(name) }).first(where: { fm.itemExists($0) }) {
                        appURLs.append(url)
                    }
                }
            }
            var item = HomebrewItem(kind: .cask, name: dir.lastPathComponent, version: version, location: dir,
                                    installedOnRequest: Self.installedOnRequest(receipt), installedAt: Self.date(receipt?["time"]),
                                    contentPaths: [dir] + appURLs, apps: record.appNames)
            item.related = related(for: item, prefix: prefix, links: links["Caskroom/\(item.name)"] ?? [], zap: record.zap,
                                   index: index, rules: rules)
            return item
        }
    }

    // MARK: 관련 경로

    /// 홈 폴더의 이름 기반 데이터 위치와 Homebrew 다운로드 캐시 목록 (한 번만 읽는다)
    struct RelatedIndex {
        /// `PackageScanner.dataRoots` 위치별 (소문자 이름 → 경로)
        var homeRoots: [[String: URL]] = []
        var downloads: [URL]
        var caskCache: [URL]

        init(paths: SystemPaths) {
            let fm = FileManager.default
            for root in PackageScanner.dataRoots {
                let dir = root.rel.isEmpty ? paths.home : paths.home(root.rel)
                var entries: [String: URL] = [:]
                for child in fm.children(of: dir) {
                    let name = child.lastPathComponent
                    if root.hidden {
                        guard name.hasPrefix("."), name.count > 1 else { continue }
                        entries[String(name.dropFirst()).lowercased()] = child
                    } else if !name.hasPrefix(".") {
                        entries[name.lowercased()] = child
                    }
                }
                homeRoots.append(entries)
            }
            let cache = paths.home("Library/Caches/Homebrew")
            downloads = fm.children(of: cache.appendingPathComponent("downloads"))
            caskCache = fm.children(of: cache.appendingPathComponent("Cask"))
        }
    }

    func related(for item: HomebrewItem, prefix: URL, links: [URL], zap: [String], index: RelatedIndex,
                 rules: RuleData) -> [HomebrewRelatedPath] {
        let fm = FileManager.default
        var out: [HomebrewRelatedPath] = []
        var seen = Set<String>()
        func add(_ kind: HomebrewRelatedPath.Kind, _ url: URL) {
            guard fm.itemExists(url), seen.insert(SafetyGuard.key(SafetyGuard.normalize(url.path))).inserted else { return }
            out.append(HomebrewRelatedPath(kind, url))
        }

        for url in item.contentPaths { add(.install, url) }
        for link in links { add(.link, link) }
        if item.kind == .formula {
            for rel in ["etc/\(item.name)", "var/\(item.name)", "var/lib/\(item.name)", "var/log/\(item.name)", "var/log/\(item.name).log"] {
                add(.prefixData, prefix.appendingPathComponent(rel))
            }
        }
        for url in expandZap(zap) { add(.zap, url) }

        // 이름이 같은 폴더: 항목 이름, `@버전` 앞 이름, 실행 파일 링크 이름, cask 앱 이름
        var names = [item.name]
        if let at = item.name.firstIndex(of: "@") { names.append(String(item.name[..<at])) }
        names += links.filter { ["bin", "sbin"].contains($0.deletingLastPathComponent().lastPathComponent) }.map(\.lastPathComponent)
        names += item.apps.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        var tried = Set<String>()
        for name in names.map({ $0.lowercased() })
        where name.count >= 2 && name != "homebrew" && !rules.commonNames.contains(name) && tried.insert(name).inserted {
            for root in index.homeRoots { if let url = root[name] { add(.data, url) } }
        }

        if item.kind == .formula {
            for url in index.downloads where Self.isBottleDownload(url.lastPathComponent, of: item.name) { add(.downloadCache, url) }
        } else {
            for link in index.caskCache where link.lastPathComponent.hasPrefix(item.name + "--") {
                add(.downloadCache, PackageInventory.linkTarget(link) ?? link)
            }
        }
        return out
    }

    /// zap 경로 패턴 → 실제로 있는 경로 (와일드카드는 마지막 구성요소에만 있을 때 상위 폴더를 훑는다)
    func expandZap(_ patterns: [String]) -> [URL] {
        let homePath = paths.home.standardizedFileURL.path
        let rootIsSlash = paths.root.path == "/"
        var out: [URL] = []
        for raw in patterns {
            let pattern = ZapPattern(raw, homePath: homePath, rootIsSlash: rootIsSlash, paths: paths)
            if !pattern.isWildcard {
                out.append(URL(fileURLWithPath: pattern.pattern))
            } else if let parent = pattern.fixedParent {
                out += FileManager.default.children(of: URL(fileURLWithPath: parent)).filter(pattern.matches)
            }
        }
        return out
    }

    /// `<해시>--<이름>--<버전>.<태그>.bottle.tar.gz`, `<해시>--<이름>-<버전>.bottle_manifest.json`
    static func isBottleDownload(_ file: String, of name: String) -> Bool {
        guard let sep = file.range(of: "--") else { return false }
        let rest = file[sep.upperBound...]
        if rest.hasPrefix(name + "--") { return true }
        guard rest.hasPrefix(name + "-") else { return false }
        return rest.dropFirst(name.count + 1).first?.isNumber == true
    }

    /// `<prefix>/opt`·`bin`·`sbin`의 링크를 대상 설치 폴더(`Cellar/<이름>`, `Caskroom/<토큰>`)별로
    static func links(in prefix: URL) -> [String: [URL]] {
        var out: [String: [URL]] = [:]
        for dir in ["opt", "bin", "sbin"] {
            for link in FileManager.default.children(of: prefix.appendingPathComponent(dir)).sorted(by: { $0.path < $1.path }) {
                guard let target = PackageInventory.linkTarget(link) else { continue }
                let parts = target.pathComponents
                guard let i = parts.firstIndex(where: { $0 == "Cellar" || $0 == "Caskroom" }), i + 1 < parts.count else { continue }
                out["\(parts[i])/\(parts[i + 1])", default: []].append(link)
            }
        }
        return out
    }

    // MARK: 공용

    static func entries(in dir: URL) -> [URL] {
        let fm = FileManager.default
        return fm.children(of: dir)
            .filter { !$0.lastPathComponent.hasPrefix(".") && !fm.isSymlink($0) && fm.isDirectory($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 버전 폴더를 버전 순으로 (`latest` 같은 링크는 제외)
    static func versionDirectories(in dir: URL) -> [URL] {
        entries(in: dir).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// 기록이 없으면 직접 설치로 본다 (의존성이라고 단정할 근거가 없음)
    static func installedOnRequest(_ receipt: [String: Any]?) -> Bool {
        if let value = receipt?["installed_on_request"] as? Bool { return value }
        if let dependency = receipt?["installed_as_dependency"] as? Bool { return !dependency }
        return true
    }

    static func date(_ value: Any?) -> Date? {
        (value as? Double).map { Date(timeIntervalSince1970: $0) }
    }
}
