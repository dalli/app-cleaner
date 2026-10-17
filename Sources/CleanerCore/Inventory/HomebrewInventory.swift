import Foundation

/// Homebrew로 설치한 formula·cask 목록을 설치 기록 파일로 읽는다 (`brew` 명령은 실행하지 않는다).
///
/// | 종류 | 설치 기록 |
/// |---|---|
/// | formula | `<prefix>/Cellar/<name>/<version>/INSTALL_RECEIPT.json` (`installed_on_request`, `time`) |
/// | cask | `<prefix>/Caskroom/<token>/.metadata/INSTALL_RECEIPT.json` (`uninstall_artifacts`, `source.version`) |
///
/// 접두사는 Apple Silicon(`/opt/homebrew`)과 Intel(`/usr/local`) 둘 다 본다.
public struct HomebrewInventory: Sendable {
    public let paths: SystemPaths

    static let prefixes = ["opt/homebrew", "usr/local"]

    public init(paths: SystemPaths) {
        self.paths = paths
    }

    public func items() -> [HomebrewItem] {
        var out: [HomebrewItem] = []
        for p in Self.prefixes {
            let prefix = paths.system(p)
            out += formulae(in: prefix)
            out += casks(in: prefix)
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: formula

    func formulae(in prefix: URL) -> [HomebrewItem] {
        Self.entries(in: prefix.appendingPathComponent("Cellar")).compactMap { dir in
            guard let latest = Self.versionDirectories(in: dir).last else { return nil }
            let receipt = PackageInventory.readJSON(latest.appendingPathComponent("INSTALL_RECEIPT.json"))
            return HomebrewItem(kind: .formula, name: dir.lastPathComponent, version: latest.lastPathComponent, location: dir,
                                installedOnRequest: Self.installedOnRequest(receipt), installedAt: Self.date(receipt?["time"]))
        }
    }

    // MARK: cask

    func casks(in prefix: URL) -> [HomebrewItem] {
        let fm = FileManager.default
        return Self.entries(in: prefix.appendingPathComponent("Caskroom")).map { dir in
            let record = Caskroom.record(at: dir, paths: paths, fallback: [])
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
            return HomebrewItem(kind: .cask, name: dir.lastPathComponent, version: version, location: dir,
                                installedOnRequest: Self.installedOnRequest(receipt), installedAt: Self.date(receipt?["time"]),
                                contentPaths: [dir] + appURLs, apps: record.appNames)
        }
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
