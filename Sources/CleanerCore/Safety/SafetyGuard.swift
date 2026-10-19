import Foundation
import Darwin

/// 보호 목록 + 심볼릭 링크 해석 (plan.md 5.1).
///
/// - 보호 목록은 코드에 하드코딩되어 있으며 규칙 데이터로 바꿀 수 없다 (plan.md 4.6).
/// - 모든 경로는 `paths.root` / `paths.home` 기준이므로 픽스처에서도 그대로 동작한다.
/// - 상위 구성요소의 심볼릭 링크를 모두 해석한 실제 경로로 다시 검사한다. 입력 경로는 허용인데 실제 경로가
///   보호 영역이면 `.symlinkEscape`. 마지막 구성요소가 링크이면 링크 자체를 대상으로 본다 (대상을 따라가지 않음).
/// - 스캔 시와 이동 직전에 두 번 호출되므로 파일 시스템 접근은 `realpath` 몇 번과 (.app인 경우) Info.plist 1개로 제한한다.
public struct SafetyGuard: SafetyChecking {
    public let paths: SystemPaths
    private let rules: [Rule]
    private let selfBundleID: String

    struct Rule: Sendable, Hashable {
        enum Scope: Sendable, Hashable {
            /// 폴더 자체만 (카테고리 루트 등)
            case exact
            /// 폴더와 그 아래 전체
            case subtree
        }
        enum Exception: Sendable, Hashable {
            /// 이 경로 "아래"는 허용 (예: `/usr/local/…`)
            case below(String)
            /// 이 디렉토리 바로 아래의 `*.bom`, `*.plist`만 허용 (설치 영수증)
            case receiptFiles(String)
        }
        var path: String
        var scope: Scope
        var reason: ProtectionReason
        var exceptions: [Exception] = []
    }

    // MARK: 보호 목록 정의

    /// 시스템 루트 기준, 하위 전체 보호
    static let systemSubtrees: [String] = [
        "System", "usr", "bin", "sbin", "private/var/db", "var/db", "Library/Apple", "private/etc", "etc", "dev",
    ]

    /// 시스템 루트 기준, 폴더 자체만 보호 (카테고리 루트 — plan.md 3.2)
    static let systemExactRoots: [String] = [
        "", "Applications", "Applications/Utilities", "Library", "Users", "Volumes", "private", "private/var", "private/tmp",
        "tmp", "var", "opt", "opt/homebrew", "cores",
        "usr/local", "usr/local/bin", "usr/local/sbin", "usr/local/lib", "usr/local/share", "usr/local/etc",
        "usr/local/include", "usr/local/opt", "usr/local/var", "usr/local/Cellar", "usr/local/Caskroom", "usr/local/Homebrew",
        "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Logs", "Library/Logs/DiagnosticReports",
        "Library/LaunchAgents", "Library/LaunchDaemons", "Library/PrivilegedHelperTools", "Library/Extensions",
        "Library/SystemExtensions", "Library/Internet Plug-Ins", "Library/QuickLook", "Library/Spotlight",
        "Library/PreferencePanes", "Library/Services", "Library/Frameworks", "Library/Receipts",
        "Library/Application Support/AppCleaner",
    ]

    /// 홈 기준, 폴더 자체만 보호 (카테고리 루트 — plan.md 3.1, 사용자 폴더 루트 — 5.1)
    static let homeExactRoots: [String] = [
        "", "Library", "Applications", "Documents", "Desktop", "Downloads", "Movies", "Music", "Pictures", "Public", ".Trash",
        "Library/Containers", "Library/Group Containers", "Library/Application Support", "Library/Application Scripts",
        "Library/Caches", "Library/HTTPStorages", "Library/WebKit", "Library/Cookies", "Library/Preferences",
        "Library/Preferences/ByHost", "Library/Saved Application State", "Library/Logs", "Library/Logs/DiagnosticReports",
        "Library/LaunchAgents", "Library/Internet Plug-Ins", "Library/QuickLook", "Library/Services",
        "Library/PreferencePanes", "Library/Spotlight", "Library/Frameworks",
        ".config", ".local", ".local/share", ".cache",
        // 패키지 매니저 설치 위치의 상위 폴더 (docs/packages.md) — 그 안의 항목만 옮긴다
        ".local/bin", ".local/state", ".local/lib", ".local/lib/node_modules", ".local/pipx", ".local/pipx/venvs",
        ".local/share/uv", ".local/share/uv/tools", ".local/share/man", ".cargo/bin",
        // npm 계열 전역 설치 (bun·pnpm) — 아래 download cache만 옮길 수 있다
        ".bun", ".bun/bin", ".bun/install/global/node_modules", "Library/pnpm", "Library/pnpm/global",
        // 설치 스크립트가 실행 파일을 두는 폴더 (docs/packages.md)
        "bin", ".bun/bin", ".deno/bin", ".opencode/bin",
    ]

    /// 홈 기준, 하위 전체 보호
    static let homeSubtrees: [(String, ProtectionReason)] = [
        ("Library/Mobile Documents", .iCloudData),
        ("Library/Application Support/MobileSync", .deviceBackup),
        (".ssh", .securityFolder),
        (".gnupg", .securityFolder),
        ("Library/Keychains", .securityFolder),
    ]

    public init(paths: SystemPaths) {
        self.paths = paths
        self.selfBundleID = paths.selfBundleID.lowercased()
        var rules: [Rule] = []

        let roots = Self.variants(of: paths.root.path)
        let homes = Self.variants(of: paths.home.path)

        for root in roots {
            for rel in Self.systemSubtrees {
                var exceptions: [Rule.Exception] = []
                if rel == "usr" { exceptions.append(.below(Self.join(root, "usr/local"))) }
                if rel.hasSuffix("var/db") { exceptions.append(.receiptFiles(Self.join(root, rel + "/receipts"))) }
                rules.append(Rule(path: Self.join(root, rel), scope: .subtree, reason: .protectedPath, exceptions: exceptions))
            }
            for rel in Self.systemExactRoots {
                rules.append(Rule(path: Self.join(root, rel), scope: .exact, reason: .protectedPath))
            }
        }
        for home in homes {
            for (rel, reason) in Self.homeSubtrees {
                rules.append(Rule(path: Self.join(home, rel), scope: .subtree, reason: reason))
            }
            for rel in Self.homeExactRoots + (paths.xdgRelativeDirs ?? []) {
                rules.append(Rule(path: Self.join(home, rel), scope: .exact, reason: .protectedPath))
            }
        }
        for dir in [paths.userCacheDir, paths.userTempDir] {
            for v in Self.variants(of: dir.path) {
                rules.append(Rule(path: v, scope: .exact, reason: .protectedPath))
            }
        }
        // 본 앱 자신의 데이터 (삭제 기록·보류 폴더)
        for dir in [paths.appDataDir, paths.holdingDir.deletingLastPathComponent(), paths.holdingDir] {
            for v in Self.variants(of: dir.path) {
                rules.append(Rule(path: v, scope: .subtree, reason: .selfApp))
            }
        }

        // 구체적인 이유(iCloud, 보안 폴더 …)가 일반 보호보다 먼저 보고되도록 정렬
        var seen = Set<Rule>()
        self.rules = rules.filter { seen.insert($0).inserted }
            .sorted { lhs, rhs in Self.priority(lhs.reason) > Self.priority(rhs.reason) }
    }

    // MARK: SafetyChecking

    public func verdict(for url: URL, bundleID: String?) -> SafetyVerdict {
        if let bid = bundleID?.lowercased(), !bid.isEmpty {
            if let reason = bundleReason(bid) { return .blocked(reason, EngineText(.protectedBundleID, bundleID!)) }
        }

        let lexical = Self.normalize(url.path)
        if lexical == "/" { return .blocked(.protectedPath, EngineText(.rootDirectory)) }

        if let hit = check(lexical) { return .blocked(hit.0, hit.1) }

        // 상위 구성요소의 심볼릭 링크를 모두 해석한 실제 경로로 재검사 (마지막 구성요소는 해석하지 않음)
        let name = (lexical as NSString).lastPathComponent
        let parent = (lexical as NSString).deletingLastPathComponent
        let realParent = Self.realpathOfExistingPrefix(parent)
        let real = Self.join(realParent, name)
        if real != lexical, let hit = check(real) {
            return .blocked(.symlinkEscape, EngineText(.symlinkToProtected, real, parts: [hit.1]))
        }

        // 앱 번들이면 번들 ID 확인 (Apple 앱·본 앱)
        if name.lowercased().hasSuffix(".app"), let bid = BundleInfo.read(bundleAt: URL(fileURLWithPath: real))?.bundleID?.lowercased(),
           let reason = bundleReason(bid) {
            return .blocked(reason, EngineText(.protectedApp, bid))
        }
        return .allowed(resolved: URL(fileURLWithPath: real))
    }

    public func verdict(for url: URL, allowingSelfAppCopy runningBundle: URL?) -> SafetyVerdict {
        let base = verdict(for: url, bundleID: nil)
        guard case .blocked(.selfApp, _) = base else { return base }
        let lexical = Self.normalize(url.path)
        let name = (lexical as NSString).lastPathComponent
        guard name.lowercased().hasSuffix(".app") else { return base }
        let real = Self.join(Self.realpathOfExistingPrefix((lexical as NSString).deletingLastPathComponent), name)
        // 경로 규칙(본 앱 데이터·보류 폴더 등)에 걸린 것이면 그대로 막는다 — 번들 ID 판정만 푼다
        if check(lexical) != nil || check(real) != nil { return base }
        if let runningBundle {
            let running = Self.key(Self.realpathOfExistingPrefix(runningBundle.path))
            let k = Self.key(real)
            if k == running || running.hasPrefix(k + "/") { return base }
        }
        return .allowed(resolved: URL(fileURLWithPath: real))
    }

    // MARK: 판정

    private func bundleReason(_ bid: String) -> ProtectionReason? {
        if bid == "com.apple" || bid.hasPrefix("com.apple.") { return .appleBundle }
        if bid == selfBundleID || bid.hasPrefix(selfBundleID + ".") { return .selfApp }
        return nil
    }

    /// 보호 대상이면 (이유, 설명)
    private func check(_ path: String) -> (ProtectionReason, EngineText)? {
        let key = Self.key(path)
        let name = (key as NSString).lastPathComponent
        if name.hasPrefix("com.apple.") || name.hasPrefix("group.com.apple.") {
            return (.appleBundle, EngineText(.appleData, path))
        }
        if name == selfBundleID || name.hasPrefix(selfBundleID + ".") {
            return (.selfApp, EngineText(.selfAppData, path))
        }

        var ancestorHit: Rule?
        for rule in rules {
            let rp = Self.key(rule.path)
            switch rule.scope {
            case .exact:
                if key == rp { return (rule.reason, EngineText(.protectedFolder, rule.path)) }
            case .subtree:
                if key == rp || key.hasPrefix(rp == "/" ? "/" : rp + "/") {
                    if !isException(key, rule) { return (rule.reason, EngineText(.protectedLocation, rule.path)) }
                }
            }
            // 보호 경로를 품고 있는 상위 폴더 자체를 옮기면 보호 경로도 함께 옮겨진다.
            if ancestorHit == nil, rp.hasPrefix(key + "/") { ancestorHit = rule }
        }
        if let a = ancestorHit { return (.protectedPath, EngineText(.containsProtectedLocation, a.path)) }
        return nil
    }

    private func isException(_ key: String, _ rule: Rule) -> Bool {
        for e in rule.exceptions {
            switch e {
            case .below(let dir):
                if key.hasPrefix(Self.key(dir) + "/") { return true }
            case .receiptFiles(let dir):
                let d = Self.key(dir)
                guard key.hasPrefix(d + "/") else { continue }
                let rest = String(key.dropFirst(d.count + 1))
                guard !rest.contains("/") else { continue }
                if (rest.hasSuffix(".bom") && rest.count > 4) || (rest.hasSuffix(".plist") && rest.count > 6) { return true }
            }
        }
        return false
    }

    private static func priority(_ r: ProtectionReason) -> Int {
        switch r {
        case .iCloudData, .deviceBackup, .securityFolder: return 3
        case .selfApp, .appleBundle: return 2
        case .protectedPath, .symlinkEscape, .detectOnly: return 1
        }
    }

    // MARK: 경로 도구

    /// 비교 키: 대소문자 무시(APFS 기본) + 유니코드 정규화
    static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    /// 파일 시스템을 보지 않는 어휘적 정규화: 빈·`.` 구성요소 제거, `..` 처리, 끝 슬래시 제거
    public static func normalize(_ path: String) -> String {
        var out: [Substring] = []
        for comp in path.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { if !out.isEmpty { out.removeLast() }; continue }
            out.append(comp)
        }
        return "/" + out.joined(separator: "/")
    }

    static func join(_ base: String, _ rel: String) -> String {
        if rel.isEmpty { return base }
        return base == "/" ? "/" + rel : base + "/" + rel
    }

    /// 어휘적 경로와 실제 경로(심볼릭 링크 해석) 두 가지 표기 (픽스처의 `/var` → `/private/var` 등)
    static func variants(of path: String) -> [String] {
        let lexical = normalize(path)
        let real = realpathOfExistingPrefix(lexical)
        return lexical == real ? [lexical] : [lexical, real]
    }

    /// 존재하는 가장 긴 접두사를 `realpath`로 해석하고 나머지 구성요소를 붙인다.
    public static func realpathOfExistingPrefix(_ path: String) -> String {
        let p = normalize(path)
        if let r = realpath(p) { return r }
        if p == "/" { return "/" }
        let parent = (p as NSString).deletingLastPathComponent
        let name = (p as NSString).lastPathComponent
        return join(realpathOfExistingPrefix(parent), name)
    }

    private static func realpath(_ path: String) -> String? {
        guard let ptr = Darwin.realpath(path, nil) else { return nil }
        defer { free(ptr) }
        return String(cString: ptr)
    }
}
