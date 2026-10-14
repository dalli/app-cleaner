import Foundation

/// Homebrew Caskroom의 설치 기록 1개 (plan.md 4.5.2 "Caskroom 메타데이터")
public struct CaskRecord: Sendable, Hashable {
    public var token: String
    /// `<prefix>/Caskroom/<token>`
    public var caskroomURL: URL
    /// cask가 설치한 `.app` 파일명 (예: "Slack.app")
    public var appNames: [String]
    /// 설치 위치 기록 (Caskroom 버전 폴더의 심볼릭 링크 대상, 주입 루트 기준)
    public var appLocations: [URL]
    /// uninstall stanza의 `quit`·`launchctl`·`signal`·`login_item` 등에 나오는 BID
    public var bundleIDs: [String]
    /// zap `trash:`/`delete:` 경로 (`~` 포함, 와일드카드 가능)
    public var zap: [String]

    public init(token: String, caskroomURL: URL, appNames: [String] = [], appLocations: [URL] = [],
                bundleIDs: [String] = [], zap: [String] = []) {
        self.token = token
        self.caskroomURL = caskroomURL
        self.appNames = appNames
        self.appLocations = appLocations
        self.bundleIDs = bundleIDs
        self.zap = zap
    }
}

/// Caskroom 읽기 (외부 명령 없이 파일만 읽는다)
public enum Caskroom {
    /// Apple Silicon(`/opt/homebrew`)과 Intel(`/usr/local`) 접두사
    public static func roots(paths: SystemPaths) -> [URL] {
        ["opt/homebrew/Caskroom", "usr/local/Caskroom"].map { paths.system($0) }
            .filter { FileManager.default.isDirectory($0) }
    }

    public static func brewExecutable(paths: SystemPaths) -> URL? {
        ["opt/homebrew/bin/brew", "usr/local/bin/brew"].map { paths.system($0) }
            .first { FileManager.default.itemExists($0) }
    }

    public static func tokens(paths: SystemPaths) -> [String] {
        roots(paths: paths).flatMap { root in
            FileManager.default.children(of: root).filter { !$0.lastPathComponent.hasPrefix(".") && FileManager.default.isDirectory($0) }
                .map(\.lastPathComponent)
        }
    }

    /// Caskroom의 모든 기록. 메타데이터가 없으면 규칙 데이터(cask 스냅샷)로 보충한다.
    public static func records(paths: SystemPaths, fallback: [HomebrewCask] = []) -> [CaskRecord] {
        var out: [CaskRecord] = []
        for root in roots(paths: paths) {
            for dir in FileManager.default.children(of: root) where !dir.lastPathComponent.hasPrefix(".") {
                guard FileManager.default.isDirectory(dir) else { continue }
                out.append(record(at: dir, paths: paths, fallback: fallback))
            }
        }
        return out
    }

    static func record(at dir: URL, paths: SystemPaths, fallback: [HomebrewCask]) -> CaskRecord {
        let token = dir.lastPathComponent
        var rec = CaskRecord(token: token, caskroomURL: dir.standardizedFileURL)
        let receipt = dir.appendingPathComponent(".metadata/INSTALL_RECEIPT.json")
        if let data = try? Data(contentsOf: receipt),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let artifacts = json["uninstall_artifacts"] as? [Any] {
            parse(artifacts: artifacts, into: &rec)
        }
        // 버전 폴더의 `*.app` 심볼릭 링크 → 실제 설치 위치
        for version in FileManager.default.children(of: dir) where !version.lastPathComponent.hasPrefix(".") {
            for item in FileManager.default.children(of: version) where item.pathExtension == "app" {
                if !rec.appNames.contains(item.lastPathComponent) { rec.appNames.append(item.lastPathComponent) }
                if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: item.path) {
                    rec.appLocations.append(paths.resolveRecorded(dest))
                }
            }
        }
        if let snap = fallback.first(where: { $0.token == token }) {
            for a in snap.apps where !rec.appNames.contains(a) { rec.appNames.append(a) }
            for b in snap.bundleIDs where !rec.bundleIDs.contains(b) { rec.bundleIDs.append(b) }
            if rec.zap.isEmpty { rec.zap = snap.zap }
        }
        return rec
    }

    /// `uninstall_artifacts` 해석: `[{"app": [...]}, {"uninstall": [{"quit": ...}]}, {"zap": [{"trash": [...]}]}]`
    static func parse(artifacts: [Any], into rec: inout CaskRecord) {
        func strings(_ any: Any?) -> [String] {
            switch any {
            case let s as String: return [s]
            case let a as [Any]: return a.flatMap { strings($0) }
            case let d as [String: Any]: return strings(d["target"])
            default: return []
            }
        }
        for case let artifact as [String: Any] in artifacts {
            for (kind, value) in artifact {
                switch kind {
                case "app":
                    for a in strings(value) {
                        let name = URL(fileURLWithPath: a).lastPathComponent
                        if !rec.appNames.contains(name) { rec.appNames.append(name) }
                    }
                case "uninstall":
                    for case let stanza as [String: Any] in (value as? [Any] ?? []) {
                        for key in ["quit", "launchctl", "signal", "login_item"] {
                            for s in strings(stanza[key]) where BundleIDHeuristics.isBundleIDShaped(s) && !rec.bundleIDs.contains(s) {
                                rec.bundleIDs.append(s)
                            }
                        }
                    }
                case "zap":
                    for case let stanza as [String: Any] in (value as? [Any] ?? []) {
                        for key in ["trash", "delete", "rmdir"] { rec.zap.append(contentsOf: strings(stanza[key])) }
                    }
                default:
                    continue
                }
            }
        }
    }
}

/// zap 경로 패턴 매칭 (`~` 확장, `*` 와일드카드는 fnmatch)
struct ZapPattern: Sendable {
    let pattern: String

    init(_ raw: String, paths: SystemPaths) {
        let expanded: String
        if raw.hasPrefix("~/") {
            expanded = paths.home.standardizedFileURL.path + "/" + raw.dropFirst(2)
        } else if raw.hasPrefix("/") {
            expanded = paths.resolveRecorded(raw).path
        } else {
            expanded = raw
        }
        pattern = expanded
    }

    func matches(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if !pattern.contains("*") && !pattern.contains("?") && !pattern.contains("[") { return pattern == path }
        return fnmatch(pattern, path, FNM_PATHNAME) == 0
    }
}
