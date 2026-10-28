import Foundation

/// 설치된 명령줄 도구 색인 (고아 스캔 1회용). 앱 인벤토리에는 CLI 도구가 없으므로
/// `~/.npm`·`~/Library/Caches/pip` 같은 이름 기반 항목이 설치된 도구의 데이터인지 여기서 판정한다 (plan.md 4.5.5).
///
/// | 근거 | 예 |
/// |---|---|
/// | 이름이 명령과 같거나 끝의 버전 숫자만 다름 | `uv`, `npm`, `pip` ↔ `pip3` |
/// | 이름이 사용자 설치 명령 + 구분자로 시작 | `go-build`, `codex-runtimes`, `claude-cli-nodejs` |
/// | 사용자 명령의 실제 위치(링크 대상)가 항목 안 | `~/.nvm`(버전별 node), `~/.codex`(`~/.local/bin/codex`의 링크 대상) |
/// | 실행 파일이 있는 설치 스크립트 도구의 데이터 폴더 (`standalone-tools.json`) | `~/.cursor` ← `cursor-agent` |
/// | 명령과 이름이 다른 도구 데이터 (`orphan-exclusions.json`의 `toolDataOwners`) | `Homebrew` ← `brew` |
///
/// 실행 파일만 확인하고 명령은 실행하지 않는다. GUI 앱은 셸의 `PATH`를 받지 않으므로 흔한 설치 위치를 직접 본다.
struct CommandIndex {
    /// 시스템 명령 폴더 (`/` 기준) — 이름 일치에만 쓴다 (`/usr/bin/open`이 `open-webui` 같은 접두 일치를 만들지 않도록)
    static let systemBinDirs = ["usr/bin", "bin"]
    /// 사용자가 설치한 명령 폴더 (`/` 기준). `/etc/paths.d`에 적힌 폴더도 더한다
    static let userBinDirs = ["opt/homebrew/bin", "opt/homebrew/sbin", "usr/local/bin", "usr/local/sbin", "opt/local/bin"]
    /// 사용자가 설치한 명령 폴더 (`~` 기준)
    static let homeBinDirs = [
        ".local/bin", "bin", ".cargo/bin", ".bun/bin", ".deno/bin", "go/bin", ".npm-global/bin", "Library/pnpm",
        ".volta/bin", ".pyenv/shims", ".rbenv/shims", ".asdf/shims", ".local/share/mise/shims", ".dotnet/tools",
        "google-cloud-sdk/bin", ".orbstack/bin", ".rd/bin", ".lmstudio/bin",
    ]
    /// 버전별 폴더 아래 bin (`~/.nvm/versions/node/<버전>/bin`)
    static let versionedHomeBinDirs: [(parent: String, bin: String)] = [
        (".nvm/versions/node", "bin"), (".fnm/node-versions", "installation/bin"),
        ("Library/Application Support/fnm/node-versions", "installation/bin"),
    ]
    /// Homebrew formula 설치 기록 (`opt/<formula>` 링크) — 명령 이름과 같은 사용자 설치 도구로 본다
    static let homebrewOptDirs = ["opt/homebrew/opt", "usr/local/opt"]

    /// 명령 이름 (소문자, 시스템 명령 포함)
    private let names: Set<String>
    /// 끝의 버전 숫자를 뗀 명령 이름 (`pip3.13` → `pip`)
    private let versionBases: Set<String>
    /// 사용자가 설치한 명령·formula 이름 — 접두 일치는 이것만 본다
    private let userNames: Set<String>
    /// 사용자 명령의 실제 위치와 실행 파일이 있는 설치 스크립트 도구의 데이터 폴더 (`SafetyGuard.key` 비교 키)
    private let ownedPaths: [String]
    /// 데이터 이름(소문자) → 소유 명령(소문자)
    private let dataOwners: [String: [String]]

    init(paths: SystemPaths, standaloneTools: [StandaloneTool] = [], dataOwners: [String: [String]] = [:]) {
        let fm = FileManager.default
        var names = Set<String>()
        var userNames = Set<String>()
        var owned: [String] = []

        func addCommands(in dir: URL, user: Bool) {
            for entry in fm.children(of: dir) {
                // 깨진 링크·폴더는 명령이 아니다 (`fileExists`는 링크를 따라간다)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let name = entry.lastPathComponent.lowercased()
                names.insert(name)
                guard user else { continue }
                userNames.insert(name)
                owned.append(Self.key(entry))
            }
        }

        for rel in Self.systemBinDirs { addCommands(in: paths.system(rel), user: false) }
        var userDirs = Self.userBinDirs.map { paths.system($0) } + Self.homeBinDirs.map { paths.home($0) }
        for (parent, bin) in Self.versionedHomeBinDirs {
            userDirs += fm.children(of: paths.home(parent)).map { $0.appendingPathComponent(bin) }
        }
        userDirs += Self.pathsD(paths)
        var seen = Set<String>()
        for dir in userDirs where seen.insert(dir.standardizedFileURL.path).inserted { addCommands(in: dir, user: true) }

        for rel in Self.homebrewOptDirs {
            for formula in fm.children(of: paths.system(rel)) {
                let name = formula.lastPathComponent.lowercased()
                let base = name.split(separator: "@").first.map(String.init) ?? name
                names.insert(base)
                userNames.insert(base)
            }
        }

        for tool in standaloneTools
        where tool.executables.contains(where: { paths.mapExternalPath($0).map { fm.fileExists(atPath: $0.path) } ?? false }) {
            owned += tool.dataPaths.compactMap { paths.mapExternalPath($0).map(Self.key) }
        }

        self.names = names
        self.userNames = userNames
        versionBases = Set(names.compactMap(Self.versionBase))
        ownedPaths = owned
        self.dataOwners = Dictionary(dataOwners.map { ($0.key.lowercased(), $0.value.map { $0.lowercased() }) },
                                     uniquingKeysWith: { $0 + $1 })
    }

    /// 이름 기반 항목(`~/.<이름>`, `Caches/<이름>` …)이 설치된 명령줄 도구의 것인지
    func ownsData(named name: String, at url: URL) -> Bool {
        let lower = name.lowercased()
        if names.contains(lower) || versionBases.contains(lower) { return true }
        if let owners = dataOwners[lower], owners.contains(where: names.contains) { return true }
        let tokens = lower.split(whereSeparator: { "-_.@".contains($0) })
        if tokens.count > 1, let first = tokens.first, first.count >= 2, userNames.contains(String(first)) { return true }
        guard !ownedPaths.isEmpty else { return false }
        let key = Self.key(url)
        return ownedPaths.contains { $0 == key || $0.hasPrefix(key + "/") }
    }

    /// `pip3.13` → `pip`, `python3` → `python` (버전 숫자가 없거나 남는 이름이 2자 미만이면 nil)
    static func versionBase(_ name: String) -> String? {
        let base = String(name.reversed().drop { $0.isNumber || $0 == "." }.reversed())
        return base.count >= 2 && base != name ? base : nil
    }

    /// `/etc/paths.d/*`에 적힌 명령 폴더 (설치 프로그램이 `PATH`에 더한 곳 — 예: `/usr/local/go/bin`)
    static func pathsD(_ paths: SystemPaths) -> [URL] {
        FileManager.default.children(of: paths.system("etc/paths.d")).flatMap { file -> [URL] in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .compactMap { paths.mapExternalPath($0) }
        }
    }

    /// 링크를 해석한 비교 키
    static func key(_ url: URL) -> String { SafetyGuard.key(SafetyGuard.realpathOfExistingPrefix(url.path)) }
}
