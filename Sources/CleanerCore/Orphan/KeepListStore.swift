import Foundation

/// 유지(무시) 목록 저장소 (plan.md 4.5.7, ui-ux.md S5·S7).
/// `paths.appDataDir/keep-list.json`에 JSON 배열로 저장한다. 스레드 안전.
public final class KeepListStore: KeepListStoring, @unchecked Sendable {
    public let fileURL: URL
    private let lock = NSLock()
    private var cache: [KeepEntry]?

    public init(paths: SystemPaths) {
        fileURL = paths.appDataDir.appendingPathComponent("keep-list.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func entries() -> [KeepEntry] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// 같은 id(종류 + 키)가 있으면 교체한다.
    public func add(_ entry: KeepEntry) {
        lock.lock(); defer { lock.unlock() }
        var list = loadLocked().filter { $0.id != entry.id }
        list.append(entry)
        saveLocked(list)
    }

    public func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        let list = loadLocked()
        let filtered = list.filter { $0.id != id }
        if filtered.count != list.count { saveLocked(filtered) }
    }

    private func loadLocked() -> [KeepEntry] {
        if let cache { return cache }
        var loaded: [KeepEntry] = []
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            loaded = (try? decoder.decode([KeepEntry].self, from: data)) ?? []
        }
        cache = loaded
        return loaded
    }

    private func saveLocked(_ list: [KeepEntry]) {
        cache = list
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(list) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 테스트·조립 전 기본값: 메모리에만 보관
public final class InMemoryKeepList: KeepListStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var list: [KeepEntry]

    public init(_ entries: [KeepEntry] = []) { list = entries }

    public func entries() -> [KeepEntry] {
        lock.lock(); defer { lock.unlock() }
        return list
    }

    public func add(_ entry: KeepEntry) {
        lock.lock(); defer { lock.unlock() }
        list.removeAll { $0.id == entry.id }
        list.append(entry)
    }

    public func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        list.removeAll { $0.id == id }
    }
}
