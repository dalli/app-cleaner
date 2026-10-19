import Foundation
import Darwin

/// 패키지 매니저로 설치한 CLI 도구의 설치 항목·데이터·캐시를 후보로 만든다 (docs/packages.md).
///
/// - 설치 항목(패키지 폴더·venv·실행 파일 링크): **높음 · 기본 선택**. 옮기면 패키지 매니저의 제거와 같은 결과가 된다.
///   사용자가 쓸 수 없는 위치(root 소유 `/usr/local` 등)면 옮기지 않고 패키지 매니저 명령을 안내한다.
/// - 이름이 같은 데이터(`~/.<name>`, `~/.config/<name>` …): 이름 기반이라 **낮음 · 기본 미선택**. 짧거나 흔한 이름,
///   보안 폴더, 패키지 매니저 자신의 폴더는 찾지 않는다. 여러 패키지가 같은 폴더를 찾으면 공유로 표시한다.
/// - 패키지 매니저 캐시: 재생성 가능 · 높음 · 기본 선택 (다음 설치 때 다시 내려받는다).
/// - 모든 후보는 SafetyGuard를 거친다. 실행은 기존 정리 흐름(휴지통 이동 + 삭제 기록)을 그대로 쓴다.
public struct PackageScanner: Sendable {
    public let paths: SystemPaths
    public let rules: any RuleDataProviding
    public let safety: any SafetyChecking
    public let inventory: PackageInventory

    public init(paths: SystemPaths, rules: any RuleDataProviding, safety: any SafetyChecking) {
        self.paths = paths
        self.rules = rules
        self.safety = safety
        self.inventory = PackageInventory(paths: paths, rules: rules)
    }

    public func scan(options: PackageScanOptions = PackageScanOptions()) async -> PackageScanReport {
        let started = Date()
        let data = rules.current()
        let packages = inventory.packages(options)

        var reports = packages.map { report(for: $0) }
        if options.includeData { attachData(&reports, rules: data) }
        var caches = cacheCandidates(options)
        if options.computeSizes {
            reports = await withTaskGroup(of: (Int, [Candidate]).self) { group in
                for (i, r) in reports.enumerated() { group.addTask { (i, await FileStatsCalculator.fill(r.candidates)) } }
                var out = reports
                for await (i, filled) in group { out[i].candidates = filled }
                return out
            }
            caches = await FileStatsCalculator.fill(caches)
        }
        return PackageScanReport(packages: reports, caches: caches, duration: Date().timeIntervalSince(started),
                                 ruleDataVersion: data.version)
    }

    // MARK: 설치 항목

    func report(for package: InstalledPackage) -> PackageReport {
        let writable = package.installPaths.allSatisfy { Self.isWritableParent($0) }
        // 설치 기록 없이 실행 파일만 보고 짐작한 항목은 이름만으로 판정한 것이므로 낮음 · 기본 미선택
        let confidence: Confidence = package.isGuessed ? .low : .high
        let selected = !package.isGuessed
        var candidates: [Candidate] = []
        for (i, url) in package.installPaths.enumerated() {
            let detail: EngineText = if i == 0 {
                package.isGuessed
                    ? EngineText(.standaloneGuessed, package.name)
                    : EngineText(.standaloneInstalled, package.name)
            } else {
                EngineText(.packageExecutableLink, package.name, url.lastPathComponent)
            }
            var c = Candidate(url: url, category: .package, confidence: confidence,
                              evidence: [Evidence(.packageManager, detail)], isSelected: selected)
            guarded(&c)
            if !writable {
                if let command = package.manager.uninstallCommand(package.name) {
                    c.protection = c.protection ?? .detectOnly
                    c.notes.append(EngineText(.packageNeedsAdmin, command))
                } else if package.manager == .standalone {
                    c.protection = c.protection ?? .detectOnly
                    c.notes.append(EngineText(.standaloneNeedsAdmin, url.path))
                }
            }
            if c.protection != nil { c.isSelected = false }
            candidates.append(c)
        }
        var notes: [EngineText] = []
        if package.manager == .cargo { notes.append(EngineText(.cargoRecordRemains, package.name)) }
        if package.manager == .standalone {
            notes.append(EngineText(.standaloneNoRecord, package.name))
            if let hint = package.reinstallHint { notes.append(EngineText(.standaloneReinstall, hint)) }
        }
        return PackageReport(package: package, candidates: candidates, notes: notes)
    }

    // MARK: 이름이 같은 데이터

    /// 데이터 폴더를 찾는 위치 (`~` 기준)와 카테고리
    static let dataRoots: [(rel: String, category: ItemCategory, hidden: Bool)] = [
        ("", .dotfile, true),
        (".config", .dotfile, false),
        (".local/share", .dotfile, false),
        (".local/state", .dotfile, false),
        (".cache", .caches, false),
        ("Library/Application Support", .applicationSupport, false),
        ("Library/Caches", .caches, false),
    ]

    func attachData(_ reports: inout [PackageReport], rules data: RuleData) {
        let fm = FileManager.default
        // 위치별 이름 색인 (소문자 → URL)
        var index: [(rel: String, category: ItemCategory, entries: [String: URL])] = []
        for root in Self.dataRoots {
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
            index.append((root.rel, root.category, entries))
        }

        let security = Set(data.exclusions.securityDotfiles.map { $0.lowercased() } + [".ssh", ".gnupg"])
        let managers = managerRoots().map { Self.realKey($0) }
        // 설치 위치(실행 파일 링크가 가리키는 실제 경로까지 포함). 데이터를 이름으로 짐작할 때만 쓴다 —
        // 규칙 데이터가 정한 폴더는 그 안에 실행 파일이 있어도 데이터로 보여 줘야 한다 (계획 단계에서 중복은 정리된다).
        let installPaths = Self.installPathKeys(reports)

        var owners: [String: [Int]] = [:]
        var found: [Int: [Candidate]] = [:]
        for (i, r) in reports.enumerated() {
            var seen = Set<String>()
            // 규칙 데이터가 정한 폴더는 이름 추측 없이 그대로 따른다
            let ruleHits = standaloneHits(r.package, rules: data)
            let hits = ruleHits ?? nameHits(r.package, index: index, isWeak: data.isWeakName)
            // 이름을 짐작한 데이터는 설치 위치를 품으면 건너뛴다 (옮기면 실행 파일도 함께 사라진다).
            // 규칙 데이터가 명시한 폴더는 그 안에 실행 파일이 있어도 보여 준다 — 계획 단계에서 중복을 정리한다.
            let reserved = ruleHits == nil ? managers + installPaths : managers
            for hit in hits {
                let url = hit.url
                guard seen.insert(url.path).inserted else { continue }
                let entry = url.lastPathComponent.lowercased()
                if security.contains(entry) || security.contains("." + entry) { continue }
                let key = Self.realKey(url)
                // 이 폴더를 옮기면 패키지 매니저 폴더나 설치 위치도 함께 옮겨진다
                if reserved.contains(where: { $0 == key || $0.hasPrefix(key + "/") }) { continue }
                var c = Candidate(url: url, category: hit.category, confidence: .low,
                                  evidence: [Evidence(hit.source, hit.detail)],
                                  notes: [EngineText(.packageDataMaybeOther)])
                guarded(&c)
                owners[url.path, default: []].append(i)
                found[i, default: []].append(c)
            }
        }
        for (i, list) in found {
            for var c in list {
                let others = (owners[c.path] ?? []).filter { $0 != i }.map { reports[$0].package }
                if !others.isEmpty {
                    let names = Self.uniqueLabels(others)
                    c.share = .shared(usedBy: names, reason: EngineText(.packageDataShared, names.joined(separator: ", ")))
                }
                reports[i].candidates.append(c)
            }
        }
    }

    struct DataHit {
        var url: URL
        var category: ItemCategory
        var source: EvidenceSource
        var detail: EngineText
    }

    /// 이름이 같은 폴더에서 데이터 후보를 찾는다 (규칙 데이터가 없는 도구)
    func nameHits(_ p: InstalledPackage, index: [(rel: String, category: ItemCategory, entries: [String: URL])],
                  isWeak: (String) -> Bool) -> [DataHit] {
        var out: [DataHit] = []
        for name in Self.dataNames(p) where !isWeak(name) {
            for root in index {
                guard let url = root.entries[name.lowercased()] else { continue }
                out.append(DataHit(url: url, category: root.category, source: .name,
                                   detail: EngineText(.packageDataByName, p.manager.displayName, p.name)))
            }
        }
        return out
    }

    /// 규칙 데이터가 정한 데이터 폴더 (설치 기록이 있는 설치 스크립트 도구).
    /// 자동 탐지로 짐작한 도구는 여기 없으므로 이름 추칭으로 넘어간다 (nil).
    func standaloneHits(_ p: InstalledPackage, rules data: RuleData) -> [DataHit]? {
        guard p.manager == .standalone, !p.isGuessed, let tool = data.standaloneTool(named: p.name) else { return nil }
        let fm = FileManager.default
        var out: [DataHit] = []
        for rel in tool.dataPaths {
            guard let url = paths.mapExternalPath(rel), fm.itemExists(url), !fm.isSymlink(url) else { continue }
            out.append(DataHit(url: url, category: category(forHomeRelative: url), source: .standaloneScript,
                               detail: EngineText(.standaloneData, p.name)))
        }
        return out
    }

    /// 홈 아래 경로의 표시 카테고리 (`dataRoots` 위치 기준). 홈 밖이면 `.other`.
    func category(forHomeRelative url: URL) -> ItemCategory {
        for root in Self.dataRoots where url.isInside(root.rel.isEmpty ? paths.home : paths.home(root.rel)) {
            return root.category
        }
        return url.isInside(paths.home) ? .dotfile : .other
    }

    /// 데이터 폴더 이름 후보: 패키지 이름(scope 제외)과 실행 파일 이름
    static func dataNames(_ p: InstalledPackage) -> [String] {
        var out: [String] = []
        let base = p.name.split(separator: "/").last.map(String.init) ?? p.name
        for n in [base] + p.executables where PackageInventory.isPlainName(n) && !out.contains(n.lowercased()) {
            out.append(n.lowercased())
        }
        return out
    }

    /// 데이터 후보가 될 수 없는 경로: 패키지 매니저 자신의 폴더와 모든 설치 위치 (그 상위 폴더를 옮기면 함께 사라진다)
    ///
    /// - `managerRoots`: 매니저·설치 스크립트가 실행 파일을 두는 폴더. 규칙 데이터로 정한 데이터 폴더에도 항상 적용한다
    /// - `installPaths`: 이 보고서의 실제 설치 위치. **이름을 짐작한** 데이터 후보에만 적용한다
    ///   (규칙 데이터가 `~/.bun`을 데이터로 정했는데 `~/.bun/bin/bun`이 설치 항목인 경우, 데이터로 보여 줘야 한다)
    func managerRoots() -> [URL] {
        [".npm", ".nvm", ".fnm", ".npm-global", ".cargo", ".rustup", ".local", ".local/bin", ".local/pipx",
         ".local/share/uv", ".cache/uv", ".local/share/man", "Library/Application Support/pipx",
         "Library/Application Support/fnm", "Library/Caches/pip", "Library/Caches/pipx", ".cache/pip"]
            .map { paths.home($0) }
    }

    /// 설치 위치 비교 키 (실행 파일 링크는 실제 경로까지 해석해 함께 담는다)
    static func installPathKeys(_ reports: [PackageReport]) -> [String] {
        var out: [String] = []
        for r in reports {
            out.append(realKey(r.package.root))
            out += r.package.installPaths.map(realKey)
        }
        return out
    }

    /// 심볼릭 링크를 해석한 비교 키
    static func realKey(_ url: URL) -> String { SafetyGuard.key(SafetyGuard.realpathOfExistingPrefix(url.path)) }

    static func uniqueLabels(_ packages: [InstalledPackage]) -> [String] {
        var out: [String] = []
        for p in packages {
            let label = p.rootLabel.map { "\(p.name) (\($0))" } ?? "\(p.name) (\(p.manager.displayName))"
            if !out.contains(label) { out.append(label) }
        }
        return out
    }

    // MARK: 패키지 매니저 캐시

    func cacheCandidates(_ options: PackageScanOptions) -> [Candidate] {
        let fm = FileManager.default
        // (필터에 쓰는 매니저, 표시 이름, 경로) — pip 캐시는 pipx가 쓰므로 pipx에 묶는다
        let specs: [(PackageManager, String, String)] = [
            (.npm, "npm", ".npm/_cacache"), (.npm, "npx", ".npm/_npx"),
            (.cargo, "cargo", ".cargo/registry/cache"), (.cargo, "cargo", ".cargo/registry/src"),
            (.cargo, "cargo", ".cargo/git/checkouts"), (.cargo, "cargo", ".cargo/git/db"),
            (.uv, "uv", ".cache/uv"), (.uv, "uv", "Library/Caches/uv"),
            (.pipx, "pipx", ".local/pipx/.cache"), (.pipx, "pipx", "Library/Caches/pipx"),
            (.pipx, "pip", "Library/Caches/pip"), (.pipx, "pip", ".cache/pip"),
        ]
        var out: [Candidate] = []
        for (manager, label, rel) in specs where options.includes(manager) {
            let url = paths.home(rel)
            guard fm.itemExists(url), !fm.isSymlink(url) else { continue }
            var c = Candidate(url: url, category: .caches, confidence: .high, nature: .regenerable,
                              evidence: [Evidence(.packageManager, EngineText(.packageManagerCache, label))],
                              isSelected: true, notes: [EngineText(.packageCacheRedownloaded)])
            guarded(&c)
            if c.protection != nil { c.isSelected = false }
            out.append(c)
        }
        return out
    }

    // MARK: 공용

    /// SafetyGuard 판정을 반영한다.
    func guarded(_ c: inout Candidate) {
        if case .blocked(let reason, let why) = safety.verdict(for: c.url, bundleID: nil) {
            c.protection = reason
            c.isSelected = false
            c.notes.append(why)
        }
    }

    /// 항목이 들어 있는 폴더에 쓸 수 있는지 (휴지통으로 옮길 수 있는지)
    static func isWritableParent(_ url: URL) -> Bool {
        access(url.deletingLastPathComponent().path, W_OK) == 0
    }
}
