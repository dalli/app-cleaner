import Foundation

/// 설치 영수증 (plan.md 3.2, 4.2 #1).
///
/// `pkgutil --pkg-info <id>`의 `volume`+`location`과 `pkgutil --files <id>`의 상대 경로를 결합해
/// **해당 패키지만 소유한** 파일·폴더를 후보로 등록한다.
/// - 공용 디렉토리(`/Library/Application Support` 자체 등)는 후보가 되지 않고, 그 아래 항목만 검사한다.
/// - 다른 영수증도 소유한 항목(`pkgutil --file-info`)은 후보에서 제외하고, 폴더면 그 아래 항목을 다시 검사한다.
/// - 영수증 파일 자체(`/private/var/db/receipts/<id>.{bom,plist}`)도 후보 (`pkgutil --forget` 대상).
public struct ReceiptSource: CandidateSource {
    public let paths: SystemPaths
    public let runner: any CommandRunning

    public var sourceName: String { "receipts" }

    static let pkgutil = "/usr/sbin/pkgutil"

    /// 여러 패키지·시스템이 함께 쓰는 디렉토리 (볼륨 루트 기준). 이 자체는 절대 후보가 되지 않는다.
    static let sharedDirectories: Set<String> = [
        "Applications", "Applications/Utilities", "Library", "Users", "Users/Shared", "System", "private", "private/etc",
        "private/var", "private/tmp", "var", "etc", "tmp", "opt", "opt/local", "opt/homebrew", "usr", "usr/local",
        "usr/local/bin", "usr/local/sbin", "usr/local/lib", "usr/local/libexec", "usr/local/include", "usr/local/share",
        "usr/local/share/man", "usr/local/share/doc", "usr/local/etc", "usr/local/opt", "bin", "sbin",
        "Library/Application Support", "Library/Audio", "Library/Audio/Plug-Ins", "Library/Audio/Plug-Ins/Components",
        "Library/Audio/Plug-Ins/HAL", "Library/Audio/Plug-Ins/VST", "Library/Audio/Plug-Ins/VST3", "Library/Audio/MIDI Drivers",
        "Library/Caches", "Library/ColorSync", "Library/ColorSync/Profiles", "Library/Components", "Library/Contextual Menu Items",
        "Library/CoreMediaIO", "Library/CoreMediaIO/Plug-Ins", "Library/CoreMediaIO/Plug-Ins/DAL", "Library/DirectoryServices",
        "Library/Documentation", "Library/DriverExtensions", "Library/Extensions", "Library/Filesystems", "Library/Fonts",
        "Library/Frameworks", "Library/Graphics", "Library/Image Capture", "Library/Input Methods", "Library/Internet Plug-Ins",
        "Library/Java", "Library/Java/Extensions", "Library/Java/JavaVirtualMachines", "Library/Keyboard Layouts",
        "Library/LaunchAgents", "Library/LaunchDaemons", "Library/Logs", "Library/Modem Scripts", "Library/PDF Services",
        "Library/Perl", "Library/PreferencePanes", "Library/Preferences", "Library/Printers", "Library/Printers/PPDs",
        "Library/PrivilegedHelperTools", "Library/Python", "Library/QuickLook", "Library/Receipts", "Library/Screen Savers",
        "Library/ScriptingAdditions", "Library/Scripts", "Library/Security", "Library/Services", "Library/Sounds",
        "Library/Speech", "Library/Spotlight", "Library/StartupItems", "Library/SystemExtensions", "Library/User Pictures",
        "Library/Video", "Library/WebServer", "Library/Widgets", "Library/Workflows",
    ]

    public init(paths: SystemPaths, runner: any CommandRunning) {
        self.paths = paths
        self.runner = runner
    }

    public func candidates(for identity: AppIdentity) throws -> [Candidate] {
        var out: [Candidate] = []
        for id in identity.packageIDs where BundleIDRules.isSafeComponent(id) {
            out += candidates(forPackage: id, identity: identity)
        }
        return out.mergedByPath()
    }

    func candidates(forPackage id: String, identity: AppIdentity) -> [Candidate] {
        let fm = FileManager.default
        let categorizer = PathCategorizer(paths: paths)
        var out: [Candidate] = []

        // 영수증 파일
        let receipts = paths.system("private/var/db/receipts")
        for ext in ["bom", "plist"] {
            let url = receipts.appendingPathComponent("\(id).\(ext)")
            guard fm.itemExists(url) else { continue }
            out.append(Candidate(url: url, category: .receipt, domain: .system, confidence: .high,
                                 evidence: [Evidence(.receipt, "설치 영수증 \(id)")]))
        }

        guard let base = installBase(forPackage: id),
              let files = runner.output(Self.pkgutil, ["--files", id])?.lines else { return out }

        // 볼륨 루트 기준 상대 경로 집합과 부모 → 자식 맵
        var all = Set<String>()
        for raw in files {
            guard let rel = Self.join(base, raw) else { continue }
            all.insert(rel)
        }
        var children: [String: [String]] = [:]
        var tops: [String] = []
        for p in all {
            let parent = Self.parent(of: p)
            if let parent, all.contains(parent) { children[parent, default: []].append(p) } else { tops.append(p) }
        }

        var ownersCache: [String: [String]] = [:]
        func owners(_ rel: String) -> [String] {
            if let c = ownersCache[rel] { return c }
            let r = runner.output(Self.pkgutil, ["--file-info", "/" + rel]).map { IdentityResolver.parsePackageIDs($0.string) } ?? []
            ownersCache[rel] = r
            return r
        }

        var accepted: [String] = []
        func consider(_ rel: String, depth: Int) {
            guard depth < 64 else { return }
            let url = paths.system(rel)
            guard fm.itemExists(url) else { return }
            let isDir = fm.isDirectory(url) && !fm.isSymlink(url)
            if Self.sharedDirectories.contains(rel) || !rel.contains("/") {
                for c in (children[rel] ?? []).sorted() { consider(c, depth: depth + 1) }
                return
            }
            let others = owners(rel).filter { $0 != id }
            if !others.isEmpty {
                // 다른 패키지와 공유 → 제외. 폴더면 그 아래 단독 소유 항목을 찾는다.
                if isDir { for c in (children[rel] ?? []).sorted() { consider(c, depth: depth + 1) } }
                return
            }
            accepted.append(rel)
        }
        for t in tops.sorted() { consider(t, depth: 0) }

        let bundle = identity.bundleURL
        for rel in accepted {
            let url = paths.system(rel)
            // 앱 번들 내부 파일은 앱 본체 후보가 대신한다.
            if url.isStrictlyInside(bundle) { continue }
            var c = categorizer.candidate(url, confidence: .high, evidence: [Evidence(.receipt, "설치 영수증 \(id)이(가) 단독 소유")])
            if c.category == .other && rel.hasPrefix("Applications/") && url.pathExtension == "app" { c.category = .appBundle }
            out.append(c)
        }
        return out
    }

    /// `pkgutil --pkg-info`의 `volume` + `location` (볼륨 루트 기준 상대 경로, 루트면 "")
    func installBase(forPackage id: String) -> String? {
        guard let info = runner.output(Self.pkgutil, ["--pkg-info", id]) else { return nil }
        var volume = "/"
        var location = ""
        for line in info.lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("volume:") { volume = t.dropFirst("volume:".count).trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("location:") { location = t.dropFirst("location:".count).trimmingCharacters(in: .whitespaces) }
        }
        guard let v = Self.join(nil, volume) else { return nil }
        return Self.join(v, location)
    }

    /// 경로 조각을 결합해 정규화된 상대 경로로 만든다. `..`가 있으면 nil (루트 밖으로 나가지 못하게).
    static func join(_ base: String?, _ rel: String) -> String? {
        var comps: [String] = []
        for part in [base ?? "", rel] {
            for c in part.split(separator: "/") {
                if c == "." || c.isEmpty { continue }
                if c == ".." { return nil }
                comps.append(String(c))
            }
        }
        return comps.joined(separator: "/")
    }

    static func parent(of rel: String) -> String? {
        guard let i = rel.lastIndex(of: "/") else { return nil }
        return String(rel[..<i])
    }
}
