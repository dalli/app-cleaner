import Foundation

/// 패키지 매니저의 설치 기록을 파일로 읽는다 (docs/packages.md). 패키지 매니저 명령은 실행하지 않는다.
///
/// | 매니저 | 설치 기록 | 설치 항목 |
/// |---|---|---|
/// | npm | `<prefix>/lib/node_modules/<name>/package.json` | 패키지 폴더 + `<prefix>/bin`에서 그 폴더를 가리키는 링크 |
/// | cargo | `~/.cargo/.crates2.json` (`.crates.toml`) | `~/.cargo/bin/<bin>` |
/// | pipx | `<PIPX_HOME>/venvs/<name>/pipx_metadata.json` | venv + `~/.local/bin`·`~/.local/share/man`에서 venv를 가리키는 링크 |
/// | uv | `~/.local/share/uv/tools/<name>/uv-receipt.toml` | 도구 폴더 + receipt의 `install-path` 중 도구 폴더를 가리키는 링크 |
/// | standalone | 규칙 데이터(`standalone-tools.json`)의 실행 파일 경로 | 그 경로들 (설치 스크립트는 설치 기록을 남기지 않는다) |
/// | standalone | 규칙 데이터(`standalone-tools.json`)의 실행 파일 경로 | 그 경로 (설치 스크립트는 설치 기록을 남기지 않는다) |
///
/// 실행 파일 링크는 **설치 폴더를 가리키는 심볼릭 링크만** 설치 항목으로 본다 (기록이 다른 파일을 가리켜도 옮기지 않는다).
public struct PackageInventory: Sendable {
    public let paths: SystemPaths
    /// 설치 스크립트 도구 목록 (규칙 데이터). 갱신된 규칙 데이터도 따라가도록 지연 조회한다
    let standaloneToolsProvider: @Sendable () -> [StandaloneTool]

    /// node에 딸려 오는 패키지 — 지우면 npm 자체가 망가진다
    static let bundledNpmPackages: Set<String> = ["npm", "corepack"]

    public init(paths: SystemPaths, standaloneTools: [StandaloneTool] = []) {
        self.paths = paths
        standaloneToolsProvider = { standaloneTools }
    }

    /// 규칙 데이터가 나중에 갱신돼도 다음 검사부터 따라간다 (`RuleDataStore`)
    public init(paths: SystemPaths, rules: any RuleDataProviding) {
        self.paths = paths
        standaloneToolsProvider = { rules.current().standaloneTools }
    }

    var standaloneTools: [StandaloneTool] { standaloneToolsProvider() }

    public func packages(_ options: PackageScanOptions = PackageScanOptions()) -> [InstalledPackage] {
        var out: [InstalledPackage] = []
        if options.includes(.npm) { out += npmPackages() }
        if options.includes(.cargo) { out += cargoPackages() }
        if options.includes(.pipx) { out += pipxPackages() }
        if options.includes(.uv) { out += uvPackages() }
        if options.includes(.standalone) {
            let known = standalonePackages()
            out += known
            out += guessedStandalonePackages(known: out)
        }
        return out
    }

    // MARK: - npm

    /// 전역 설치 prefix 후보: Homebrew·/usr/local node, nvm·fnm 버전별 node, `~/.npmrc`의 `prefix`, 흔한 사용자 prefix
    func npmPrefixes() -> [(url: URL, label: String?)] {
        let fm = FileManager.default
        var out: [(URL, String?)] = [
            (paths.system("opt/homebrew"), "Homebrew"),
            (paths.system("usr/local"), "/usr/local"),
        ]
        for v in fm.children(of: paths.home(".nvm/versions/node")).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            out.append((v, "node \(v.lastPathComponent)"))
        }
        for base in [paths.home(".fnm/node-versions"), paths.home("Library/Application Support/fnm/node-versions")] {
            for v in fm.children(of: base).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                out.append((v.appendingPathComponent("installation"), "node \(v.lastPathComponent)"))
            }
        }
        if let prefix = npmrcPrefix() { out.append((prefix, homeLabel(prefix))) }
        for rel in [".npm-global", ".local"] { out.append((paths.home(rel), "~/" + rel)) }

        var seen = Set<String>()
        return out.filter { prefix, _ in
            fm.isDirectory(prefix.appendingPathComponent("lib/node_modules"))
                && seen.insert(SafetyGuard.realpathOfExistingPrefix(prefix.path)).inserted
        }
    }

    /// 홈 아래면 `~/…`, 아니면 전체 경로
    func homeLabel(_ url: URL) -> String {
        url.relativePath(from: paths.home).map { "~/" + $0 } ?? url.path
    }

    /// `~/.npmrc`의 `prefix=…` (`~`·`${HOME}` 확장)
    func npmrcPrefix() -> URL? {
        guard let text = try? String(contentsOf: paths.home(".npmrc"), encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("prefix") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "prefix" else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            for home in ["${HOME}", "$HOME"] where value.hasPrefix(home) { value = "~" + value.dropFirst(home.count) }
            if value.hasPrefix("~/") { return paths.home(String(value.dropFirst(2))) }
            if value.hasPrefix("/") { return URL(fileURLWithPath: value) }
        }
        return nil
    }

    func npmPackages() -> [InstalledPackage] {
        let fm = FileManager.default
        var out: [InstalledPackage] = []
        for (prefix, label) in npmPrefixes() {
            let lib = prefix.appendingPathComponent("lib/node_modules")
            var dirs: [URL] = []
            for child in fm.children(of: lib) {
                let name = child.lastPathComponent
                if name.hasPrefix(".") { continue }
                if name.hasPrefix("@") {
                    dirs += fm.children(of: child).filter { !$0.lastPathComponent.hasPrefix(".") }
                } else {
                    dirs.append(child)
                }
            }
            let links = binLinks(in: prefix.appendingPathComponent("bin"))
            for dir in dirs.sorted(by: { $0.path < $1.path }) {
                let manifest = Self.readJSON(dir.appendingPathComponent("package.json"))
                let folderName = dir.deletingLastPathComponent() == lib
                    ? dir.lastPathComponent
                    : "\(dir.deletingLastPathComponent().lastPathComponent)/\(dir.lastPathComponent)"
                let name = (manifest?["name"] as? String) ?? folderName
                if Self.bundledNpmPackages.contains(folderName) { continue }
                let mine = links.filter { Self.points($0.target, into: dir) }
                out.append(InstalledPackage(manager: .npm, name: name, version: manifest?["version"] as? String,
                                            root: prefix, rootLabel: label,
                                            installPaths: [dir] + mine.map(\.link),
                                            executables: mine.map(\.link.lastPathComponent)))
            }
        }
        return out
    }

    // MARK: - cargo

    var cargoHome: URL { paths.home(".cargo") }

    func cargoPackages() -> [InstalledPackage] {
        let bin = cargoHome.appendingPathComponent("bin")
        var installs: [(spec: String, bins: [String])] = []
        if let json = Self.readJSON(cargoHome.appendingPathComponent(".crates2.json")),
           let map = json["installs"] as? [String: Any] {
            for (spec, value) in map {
                let bins = ((value as? [String: Any])?["bins"] as? [String]) ?? []
                installs.append((spec, bins))
            }
        } else if let toml = try? String(contentsOf: cargoHome.appendingPathComponent(".crates.toml"), encoding: .utf8) {
            installs = Self.parseCratesToml(toml)
        }
        let fm = FileManager.default
        return installs.sorted { $0.spec < $1.spec }.compactMap { spec, bins in
            let words = spec.split(separator: " ")
            guard let name = words.first.map(String.init) else { return nil }
            // 경로 구성요소가 될 수 없는 이름은 무시 (기록이 손상된 경우)
            let files = bins.filter(Self.isPlainName).map { bin.appendingPathComponent($0) }.filter { fm.itemExists($0) }
            guard !files.isEmpty else { return nil }
            return InstalledPackage(manager: .cargo, name: name, version: words.count > 1 ? String(words[1]) : nil,
                                    root: cargoHome, installPaths: files, executables: files.map(\.lastPathComponent))
        }
    }

    /// `[v1]` 표: `"ripgrep 14.1.0 (registry+…)" = ["rg"]`
    static func parseCratesToml(_ text: String) -> [(spec: String, bins: [String])] {
        var out: [(String, [String])] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\""), let close = line.dropFirst().firstIndex(of: "\""),
                  let open = line.firstIndex(of: "["), let end = line.lastIndex(of: "]"), open < end else { continue }
            let spec = String(line[line.index(after: line.startIndex)..<close])
            let bins = line[line.index(after: open)..<end].split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }.filter { !$0.isEmpty }
            out.append((spec, bins))
        }
        return out
    }

    // MARK: - pipx

    func pipxHomes() -> [URL] {
        [paths.home(".local/pipx"), paths.home("Library/Application Support/pipx")]
            .filter { FileManager.default.isDirectory($0.appendingPathComponent("venvs")) }
    }

    func pipxPackages() -> [InstalledPackage] {
        let fm = FileManager.default
        let binDir = paths.home(".local/bin")
        let manDir = paths.home(".local/share/man")
        let links = binLinks(in: binDir)
        var out: [InstalledPackage] = []
        for home in pipxHomes() {
            for venv in fm.children(of: home.appendingPathComponent("venvs")).sorted(by: { $0.path < $1.path })
            where fm.isDirectory(venv) && !venv.lastPathComponent.hasPrefix(".") {
                let meta = Self.readJSON(venv.appendingPathComponent("pipx_metadata.json"))
                let main = meta?["main_package"] as? [String: Any]
                let name = (main?["package"] as? String) ?? venv.lastPathComponent
                let mine = links.filter { Self.points($0.target, into: venv) }
                var installPaths = [venv] + mine.map(\.link)
                for page in (main?["man_pages"] as? [String]) ?? [] where Self.isRelativeSafe(page) {
                    let url = manDir.appendingPathComponent(page)
                    if let target = Self.linkTarget(url), Self.points(target, into: venv) { installPaths.append(url) }
                }
                out.append(InstalledPackage(manager: .pipx, name: name, version: main?["package_version"] as? String,
                                            root: home, installPaths: installPaths, executables: mine.map(\.link.lastPathComponent)))
            }
        }
        return out
    }

    // MARK: - uv tool

    var uvToolsDir: URL { paths.home(".local/share/uv/tools") }

    func uvPackages() -> [InstalledPackage] {
        let fm = FileManager.default
        var out: [InstalledPackage] = []
        for dir in fm.children(of: uvToolsDir).sorted(by: { $0.path < $1.path })
        where fm.isDirectory(dir) && !dir.lastPathComponent.hasPrefix(".") {
            let receipt = (try? String(contentsOf: dir.appendingPathComponent("uv-receipt.toml"), encoding: .utf8)) ?? ""
            var links: [URL] = []
            for path in Self.tomlStrings(receipt, key: "install-path") where path.hasPrefix("/") {
                let url = URL(fileURLWithPath: path)
                if let target = Self.linkTarget(url), Self.points(target, into: dir) { links.append(url) }
            }
            let name = dir.lastPathComponent
            out.append(InstalledPackage(manager: .uv, name: name, version: Self.distInfoVersion(in: dir, name: name),
                                        root: uvToolsDir, installPaths: [dir] + links,
                                        executables: links.map(\.lastPathComponent)))
        }
        return out
    }

    /// `key = "value"` 형태의 모든 값 (TOML 전체를 해석하지 않는다)
    static func tomlStrings(_ text: String, key: String) -> [String] {
        var out: [String] = []
        var rest = Substring(text)
        let needle = key + " = \""
        while let r = rest.range(of: needle) {
            let after = rest[r.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { break }
            out.append(String(after[..<end]))
            rest = after[end...]
        }
        return out
    }

    /// `lib/python*/site-packages/<name>-<version>.dist-info`
    static func distInfoVersion(in toolDir: URL, name: String) -> String? {
        let fm = FileManager.default
        let normalized = name.lowercased().replacingOccurrences(of: "-", with: "_")
        for py in fm.children(of: toolDir.appendingPathComponent("lib")) {
            for entry in fm.children(of: py.appendingPathComponent("site-packages")) {
                let n = entry.lastPathComponent
                guard n.hasSuffix(".dist-info") else { continue }
                let stem = n.dropLast(".dist-info".count)
                guard let dash = stem.firstIndex(of: "-") else { continue }
                if stem[..<dash].lowercased().replacingOccurrences(of: "-", with: "_") == normalized {
                    return String(stem[stem.index(after: dash)...])
                }
            }
        }
        return nil
    }

    // MARK: - standalone (설치 스크립트)

    /// 규칙 데이터(`standalone-tools.json`)에 있는 도구. 실행 파일이 실제로 있는 것만 설치 항목으로 본다.
    ///
    /// 실행 파일 경로는 규칙 데이터가 정한 순서대로 확인하고, **처음 발견한 경로들만** 쓴다
    /// (같은 이름의 다른 사본까지 옮기면 안 되므로). 심볼릭 링크라면 링크 자체만 옮긴다.
    func standalonePackages() -> [InstalledPackage] {
        let fm = FileManager.default
        return standaloneTools.compactMap { tool in
            let found = tool.executables.compactMap { paths.mapExternalPath($0) }.filter { fm.itemExists($0) }
            guard !found.isEmpty else { return nil }
            return InstalledPackage(manager: .standalone, name: tool.name, version: standaloneVersion(tool),
                                    root: found[0].deletingLastPathComponent(),
                                    installPaths: found,
                                    executables: found.map(\.lastPathComponent),
                                    detection: .recorded, reinstallHint: tool.reinstall)
        }
    }

    /// 버전 파일 내용에서 버전 문자열을 뽑는다 (첫 줄 전체). 파일이 없으면 nil.
    func standaloneVersion(_ tool: StandaloneTool) -> String? {
        for rel in tool.versionFiles {
            guard let url = paths.mapExternalPath(rel),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !line.isEmpty { return line }
        }
        return nil
    }

    /// 자동 탐지 대상 bin 폴더. 설치 스크립트가 실행 파일을 두는 곳이다.
    ///
    /// 사용자 소유 폴더만 본다. `/usr/local/bin`처럼 관리자 소유인 곳은 옮길 수 없어(root 소유) 안내만 되고,
    /// Homebrew·공식 설치 프로그램의 실행 파일과 구분도 안 되므로 규칙 데이터로만 찾는다.
    var standaloneBinDirs: [URL] {
        let fm = FileManager.default
        return [paths.home(".local/bin"), paths.home("bin")]
            .filter { fm.isDirectory($0) && access($0.path, W_OK) == 0 }
    }

    /// 규칙 데이터에 없는 설치 스크립트 도구를 `~/.local/bin` 등에서 찾는다.
    ///
    /// - 다른 매니저가 이미 설명하는 링크(npm·pipx·uv·cargo)와 규칙 데이터에 있는 도구는 제외한다.
    /// - 이름만으로 판정하므로 **낮음 · 기본 미선택**이다 (`detection: .guessed`).
    func guessedStandalonePackages(known: [InstalledPackage]) -> [InstalledPackage] {
        let fm = FileManager.default
        var claimed = Set<String>()
        for p in known {
            claimed.insert(SafetyGuard.key(SafetyGuard.normalize(p.location.path)))
            for path in p.installPaths { claimed.insert(SafetyGuard.key(SafetyGuard.normalize(path.path))) }
        }
        let knownNames = Set(known.map { $0.name.lowercased() })
        var out: [InstalledPackage] = []
        for dir in standaloneBinDirs {
            for url in fm.children(of: dir).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                var isDir: ObjCBool = false
                guard Self.isPlainName(name), !name.hasPrefix("."),
                      fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
                      fm.isExecutableFile(atPath: url.path) else { continue }
                guard !knownNames.contains(name.lowercased()) else { continue }
                // 다른 매니저의 설치 항목(또는 링크)이면 이미 목록에 있다
                guard !claimed.contains(SafetyGuard.key(SafetyGuard.normalize(url.path))) else { continue }
                // 링크는 매니저 설치 항목일 수 있다. 규칙 데이터에 없는 링크는 짐작하지 않는다 (대상만 옮기면 깨진다)
                guard !fm.isSymlink(url) else { continue }
                claimed.insert(SafetyGuard.key(SafetyGuard.normalize(url.path)))
                out.append(InstalledPackage(manager: .standalone, name: name, root: dir,
                                            installPaths: [url], executables: [name], detection: .guessed))
            }
        }
        return out
    }

    // MARK: - 공용

    /// `dir` 바로 아래의 심볼릭 링크와 그 대상(링크 위치 기준으로 해석한 어휘적 경로)
    func binLinks(in dir: URL) -> [(link: URL, target: URL)] {
        FileManager.default.children(of: dir).sorted(by: { $0.path < $1.path }).compactMap { link in
            Self.linkTarget(link).map { (link, $0) }
        }
    }

    static func linkTarget(_ link: URL) -> URL? {
        guard let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        let base = link.deletingLastPathComponent()
        let url = dest.hasPrefix("/") ? URL(fileURLWithPath: dest) : base.appendingPathComponent(dest)
        return URL(fileURLWithPath: SafetyGuard.normalize(url.path))
    }

    /// 링크 대상이 `dir` 안인지 — 어휘적 경로와 실제 경로(설치 폴더 자체가 링크인 `npm link` 등) 모두 비교
    static func points(_ target: URL, into dir: URL) -> Bool {
        let t = SafetyGuard.key(target.path)
        let d = SafetyGuard.key(SafetyGuard.normalize(dir.path))
        if t.hasPrefix(d + "/") { return true }
        let rt = SafetyGuard.key(SafetyGuard.realpathOfExistingPrefix(target.path))
        let rd = SafetyGuard.key(SafetyGuard.realpathOfExistingPrefix(dir.path))
        return rt.hasPrefix(rd + "/")
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 경로 구성요소 하나로 쓸 수 있는 이름
    static func isPlainName(_ s: String) -> Bool {
        !s.isEmpty && s != "." && s != ".." && !s.contains("/") && !s.contains("\0")
    }

    /// `man1/foo.1` 같은 상대 경로 (`..`·절대 경로 금지)
    static func isRelativeSafe(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("/") && !s.split(separator: "/").contains("..")
    }
}
