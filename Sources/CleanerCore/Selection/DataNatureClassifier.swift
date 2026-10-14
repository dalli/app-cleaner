import Foundation

/// 데이터 성격 분류 (plan.md 4.3.3)
///
/// | 대상 | 판정 |
/// |---|---|
/// | Container | `Data/` 아래(와 `Data/Library/` 아래) 항목을 `children`으로 펼친다. 비어 있지 않은 `Documents`·`Application Support` → 사용자 데이터 |
/// | Group Container | 최상위(와 `Library/` 아래) 항목을 펼친다. DB 파일(`*.sqlite`, `*.realm`, `*.db` …) → 사용자 데이터 |
/// | `Application Support/<NAME>` | 100 MB 이상이거나 문서 확장자 포함 → 사용자 데이터 |
/// | iCloud | 동기화 데이터 (선택 불가) |
///
/// 컨테이너는 하위 항목 중 하나라도 사용자 데이터면 자신도 사용자 데이터다. 심볼릭 링크(`Data/Desktop` 등)는 펼치지 않는다.
public struct DataNatureClassifier: DataNatureClassifying {
    /// 이 크기 이상이면 사용자 데이터로 본다 (기본 100 MB)
    public var largeDataThreshold: Int64
    /// 내용 검사 시 최대로 살펴볼 항목 수 (성능 상한)
    public var maxEntriesScanned: Int

    public static let databaseExtensions: Set<String> = [
        "sqlite", "sqlite3", "sqlite-wal", "sqlite-shm", "sqlitedb", "db", "db-wal", "db-shm", "db3", "realm", "store",
        "store-wal", "store-shm", "storedata", "fmp12", "mdb", "accdb",
    ]

    public static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "rtf", "rtfd", "txt", "md", "markdown",
        "odt", "ods", "odp", "csv", "tex", "epub", "psd", "ai", "indd", "sketch", "fig", "xd", "afdesign", "afphoto",
        "jpg", "jpeg", "png", "heic", "gif", "tif", "tiff", "raw", "dng", "cr2", "nef", "svg", "mov", "mp4", "m4v", "avi",
        "mkv", "mp3", "m4a", "wav", "aif", "aiff", "flac", "logicx", "band", "garageband", "als", "flp", "ptx", "graffle",
        "drawio", "xmind", "mm", "opml", "ipynb", "note", "enex", "bear", "ulysses", "scriv", "fdx", "highland", "vsdx",
    ]

    public init(largeDataThreshold: Int64 = 100 * 1024 * 1024, maxEntriesScanned: Int = 20_000) {
        self.largeDataThreshold = largeDataThreshold
        self.maxEntriesScanned = maxEntriesScanned
    }

    public func classify(_ candidate: Candidate) -> Candidate {
        var c = candidate
        switch c.category {
        case .iCloudContainer:
            c.nature = .synced
        case .container:
            let data = c.url.appendingPathComponent("Data", isDirectory: true)
            let base = FileManager.default.isDirectory(data) ? data : c.url
            c.children = expand(c, base: base, group: false)
            if c.children.contains(where: { $0.nature == .userData }) { c.nature = .userData }
        case .groupContainer:
            c.children = expand(c, base: c.url, group: true)
            if c.children.contains(where: { $0.nature == .userData }) { c.nature = .userData }
        case .applicationSupport:
            // `Application Support/<NAME>` (BID 형태가 아닌 폴더)만 내용으로 판정한다 (plan.md 4.3.3).
            if !BundleIDRules.looksLikeBundleID(c.url.lastPathComponent) {
                let probe = inspect(c.url, stopAtSize: true)
                if probe.hasDocuments || probe.size >= largeDataThreshold { c.nature = .userData }
            }
        default:
            break
        }
        return c
    }

    // MARK: - 컨테이너 펼치기

    func expand(_ parent: Candidate, base: URL, group: Bool) -> [Candidate] {
        let fm = FileManager.default
        var items: [(URL, String)] = []
        for child in visibleChildren(of: base) {
            let name = child.lastPathComponent
            if name == "Library", fm.isDirectory(child) {
                for sub in visibleChildren(of: child) { items.append((sub, "Library/" + sub.lastPathComponent)) }
            } else {
                items.append((child, name))
            }
        }
        return items.sorted { $0.1 < $1.1 }.map { url, rel in
            var child = Candidate(url: url, category: .containerItem, domain: parent.domain, confidence: parent.confidence,
                                  nature: group ? groupNature(url, rel) : containerNature(url, rel),
                                  share: parent.share, evidence: parent.evidence, protection: parent.protection)
            if rel == "Library/Preferences" { child.nature = .settings }
            return child
        }
    }

    /// 샌드박스 컨테이너 `Data/` 기준
    func containerNature(_ url: URL, _ rel: String) -> DataNature {
        switch rel {
        case "Documents", "Library/Application Support", "Desktop", "Downloads", "Movies", "Music", "Pictures":
            return isNonEmpty(url) ? .userData : .regenerable
        case "Library/Caches", "Library/HTTPStorages", "Library/WebKit", "Library/Saved Application State", "Library/Logs",
             "tmp", "SystemData":
            return .regenerable
        case "Library/Preferences", "Library/Cookies", "Library/Application Scripts", "Library/LaunchAgents":
            return .settings
        default:
            let probe = inspect(url, stopAtSize: true)
            return probe.hasDatabase || probe.hasDocuments || probe.size >= largeDataThreshold ? .userData : .settings
        }
    }

    /// Group Container 최상위 기준
    func groupNature(_ url: URL, _ rel: String) -> DataNature {
        switch rel {
        case "Library/Caches", "Library/HTTPStorages", "Library/WebKit", "Library/Logs", "tmp":
            return .regenerable
        case "Library/Preferences", "Library/Cookies":
            return .settings
        default:
            let probe = inspect(url, stopAtSize: true)
            return probe.hasDatabase || probe.hasDocuments || probe.size >= largeDataThreshold ? .userData : .settings
        }
    }

    // MARK: - 내용 검사

    struct Probe {
        var hasDatabase = false
        var hasDocuments = false
        var size: Int64 = 0
    }

    /// 경로 아래를 상한까지 살펴 DB·문서 확장자와 크기를 확인한다. 심볼릭 링크는 따라가지 않는다.
    func inspect(_ url: URL, stopAtSize: Bool) -> Probe {
        var probe = Probe()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        func visit(_ item: URL, _ v: URLResourceValues?) {
            let ext = item.pathExtension.lowercased()
            if Self.databaseExtensions.contains(ext) { probe.hasDatabase = true }
            if Self.documentExtensions.contains(ext) && v?.isDirectory != true { probe.hasDocuments = true }
            if ["rtfd", "pages", "numbers", "key", "logicx", "band", "scriv"].contains(ext) { probe.hasDocuments = true }
            probe.size += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        guard let top = try? url.resourceValues(forKeys: Set(keys)) else { return probe }
        if top.isSymbolicLink == true { return probe }
        if top.isDirectory != true {
            visit(url, top)
            return probe
        }
        let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        var n = 0
        while let item = e?.nextObject() as? URL {
            n += 1
            if n > maxEntriesScanned { break }
            let v = try? item.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }
            visit(item, v)
            if probe.hasDatabase && probe.hasDocuments { break }
            if stopAtSize && probe.size >= largeDataThreshold { break }
        }
        return probe
    }

    /// 숨김 항목(`.DS_Store` 등)을 제외하고 무언가 있는지
    func isNonEmpty(_ url: URL) -> Bool {
        if FileManager.default.isSymlink(url) { return false }
        if !FileManager.default.isDirectory(url) { return FileManager.default.itemExists(url) }
        return !visibleChildren(of: url).isEmpty
    }

    /// 숨김 항목과 심볼릭 링크를 제외한 바로 아래 항목
    func visibleChildren(of url: URL) -> [URL] {
        let fm = FileManager.default
        return fm.children(of: url).filter { !$0.lastPathComponent.hasPrefix(".") && !fm.isSymlink($0) }
    }
}
