import Foundation

/// 패키지 매니저 (docs/packages.md). 설치 기록을 파일로 읽을 수 있는 것만 지원한다.
public enum PackageManager: String, Codable, Sendable, CaseIterable {
    /// `npm install -g` — `<prefix>/lib/node_modules`
    case npm
    /// `cargo install` — `~/.cargo/.crates2.json`
    case cargo
    /// `pipx install` — `<PIPX_HOME>/venvs/*/pipx_metadata.json`
    case pipx
    /// `uv tool install` — `~/.local/share/uv/tools/*/uv-receipt.toml`
    case uv

    /// 사람이 읽는 이름 (번역하지 않는 고유 명칭)
    public var displayName: String {
        switch self {
        case .npm: return "npm"
        case .cargo: return "cargo"
        case .pipx: return "pipx"
        case .uv: return "uv tool"
        }
    }

    /// 패키지 매니저 자체의 제거 명령 (안내용 — 실행하지 않는다)
    public func uninstallCommand(_ name: String) -> String {
        switch self {
        case .npm: return "npm uninstall -g \(name)"
        case .cargo: return "cargo uninstall \(name)"
        case .pipx: return "pipx uninstall \(name)"
        case .uv: return "uv tool uninstall \(name)"
        }
    }
}

/// 패키지 매니저로 설치한 패키지 1개
public struct InstalledPackage: Codable, Sendable, Hashable, Identifiable {
    public var manager: PackageManager
    public var name: String
    public var version: String?
    /// 설치 위치 구분 (npm prefix, `~/.cargo`, pipx 홈, uv tools 폴더)
    public var root: URL
    /// 같은 매니저의 설치 위치가 여럿일 때 구분하는 이름 (예: "node v22.18.0", "Homebrew")
    public var rootLabel: String?
    /// 옮기면 제거가 끝나는 항목: 패키지 폴더(venv) + 실행 파일 링크. 첫 항목이 대표 경로.
    public var installPaths: [URL]
    /// 실행 파일 이름
    public var executables: [String]

    public var id: String { "\(manager.rawValue):\(installPaths.first?.path ?? root.path)" }
    /// 대표 경로 (CLI에서 패키지를 경로로 지정할 때 쓰는 값)
    public var location: URL { installPaths.first ?? root }
    public var title: String { version.map { "\(name) \($0)" } ?? name }

    /// `path`가 이 패키지의 설치 항목인지 (대소문자·유니코드 정규화 무시)
    public func isInstallPath(_ path: String) -> Bool {
        let key = SafetyGuard.key(SafetyGuard.normalize(path))
        return installPaths.contains { SafetyGuard.key(SafetyGuard.normalize($0.path)) == key }
    }

    public init(manager: PackageManager, name: String, version: String? = nil, root: URL, rootLabel: String? = nil,
                installPaths: [URL], executables: [String] = []) {
        self.manager = manager
        self.name = name
        self.version = version
        self.root = root
        self.rootLabel = rootLabel
        self.installPaths = installPaths
        self.executables = executables
    }
}

/// 패키지 1개의 검사 결과: 설치 항목(높음·선택) + 이름이 같은 데이터(낮음·미선택)
public struct PackageReport: Codable, Sendable, Identifiable {
    public var package: InstalledPackage
    public var candidates: [Candidate]
    /// 제거 후 남는 것 등 안내 (예: cargo 설치 기록)
    public var notes: [EngineText]

    public var id: String { package.id }
    public var installCandidates: [Candidate] { candidates.filter { $0.category == .package } }
    public var dataCandidates: [Candidate] { candidates.filter { $0.category != .package } }
    public var installSize: Int64 { installCandidates.reduce(0) { $0 + ($1.size ?? 0) } }
    public var dataSize: Int64 { dataCandidates.reduce(0) { $0 + ($1.size ?? 0) } }
    /// 설치 항목을 옮길 수 없음 (관리자 소유 위치 등)
    public var isRemovable: Bool { !installCandidates.isEmpty && installCandidates.allSatisfy(\.isSelectable) }

    public init(package: InstalledPackage, candidates: [Candidate], notes: [EngineText] = []) {
        self.package = package
        self.candidates = candidates
        self.notes = notes
    }
}

public struct PackageScanOptions: Codable, Sendable, Hashable {
    /// 비어 있으면 모든 매니저
    public var managers: Set<PackageManager>
    /// 이름이 같은 데이터 폴더(`~/.<name>`, `~/.config/<name>` …)도 찾는다
    public var includeData: Bool
    /// 크기 계산 (목록만 필요하면 끈다)
    public var computeSizes: Bool

    public init(managers: Set<PackageManager> = [], includeData: Bool = true, computeSizes: Bool = true) {
        self.managers = managers
        self.includeData = includeData
        self.computeSizes = computeSizes
    }

    public func includes(_ manager: PackageManager) -> Bool { managers.isEmpty || managers.contains(manager) }
}

public struct PackageScanReport: Codable, Sendable {
    public var packages: [PackageReport]
    /// 패키지 매니저 자체의 다운로드 캐시 (`~/.npm/_cacache`, `~/.cargo/registry/cache` …)
    public var caches: [Candidate]
    public var duration: TimeInterval
    public var ruleDataVersion: String
    public var scannedAt: Date

    public init(packages: [PackageReport], caches: [Candidate] = [], duration: TimeInterval = 0, ruleDataVersion: String,
                scannedAt: Date = Date()) {
        self.packages = packages
        self.caches = caches
        self.duration = duration
        self.ruleDataVersion = ruleDataVersion
        self.scannedAt = scannedAt
    }

    /// 이름이 같은 데이터의 합계 (여러 패키지가 같은 폴더를 찾아도 한 번만 센다)
    public var dataSize: Int64 {
        var seen = Set<String>()
        return packages.flatMap(\.dataCandidates).filter { seen.insert($0.path).inserted }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    /// `path`를 후보로 가진 패키지들 (같은 데이터 폴더를 여러 패키지가 찾을 수 있다)
    public func packages(matching path: String) -> [PackageReport] {
        packages.filter { $0.candidates.contains { $0.path == path } }
    }
}
