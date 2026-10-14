import Foundation

public struct FileStats: Sendable, Hashable {
    public var size: Int64
    public var fileCount: Int
    public var lastModified: Date?
}

/// 크기·파일 수·마지막 수정일 계산 (plan.md 8.3: totalFileAllocatedSize)
public enum FileStatsCalculator {
    private static let keys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey,
    ]

    /// 심볼릭 링크는 따라가지 않는다.
    public static func stats(at url: URL) -> FileStats? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if values.isSymbolicLink == true || values.isDirectory != true {
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            return FileStats(size: size, fileCount: 1, lastModified: values.contentModificationDate)
        }
        var size: Int64 = 0
        var count = 0
        var latest = values.contentModificationDate
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [],
                                                        errorHandler: { _, _ in true })
        while let item = enumerator?.nextObject() as? URL {
            guard let v = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isDirectory != true { count += 1 }
            size += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
            if let m = v.contentModificationDate, latest.map({ m > $0 }) ?? true { latest = m }
        }
        return FileStats(size: size, fileCount: count, lastModified: latest)
    }

    /// 여러 후보의 크기를 병렬 계산해 채운다.
    public static func fill(_ candidates: [Candidate]) async -> [Candidate] {
        await withTaskGroup(of: (Int, Candidate).self) { group in
            for (i, c) in candidates.enumerated() {
                group.addTask {
                    var c = c
                    if c.size == nil, let s = stats(at: c.url) {
                        c.size = s.size
                        c.fileCount = s.fileCount
                        c.lastModified = c.lastModified ?? s.lastModified
                    }
                    if !c.children.isEmpty { c.children = await fill(c.children) }
                    return (i, c)
                }
            }
            var out = candidates
            for await (i, c) in group { out[i] = c }
            return out
        }
    }
}

extension FileManager {
    public func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 심볼릭 링크 자체도 "존재"로 본다
    public func itemExists(_ url: URL) -> Bool {
        (try? attributesOfItem(atPath: url.path)) != nil
    }

    /// 디렉토리 바로 아래 항목 (없거나 읽지 못하면 빈 배열)
    public func children(of url: URL) -> [URL] {
        (try? contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }
}
