import Foundation
import AppKit

/// 휴지통 이동 (plan.md 6.1). 테스트는 실제 휴지통 대신 `DirectoryTrash(directory: paths.trash)`를 쓴다.
public protocol TrashProviding: Sendable {
    /// 항목을 휴지통으로 옮기고 실제 이동 위치를 돌려준다. 마지막 구성요소가 심볼릭 링크면 링크 자체를 옮긴다.
    func trash(_ url: URL) async throws -> URL
    /// root 소유 앱 번들을 Finder 인증 경로로 휴지통에 보낸다. 지원하지 않으면 nil.
    func recycleWithAuthorization(_ url: URL) async throws -> URL?
}

extension TrashProviding {
    public func recycleWithAuthorization(_ url: URL) async throws -> URL? { nil }
}

/// 실제 휴지통: `FileManager.trashItem(at:resultingItemURL:)` (외장 볼륨이면 그 볼륨의 `.Trashes/<uid>`),
/// 앱 번들은 `NSWorkspace.recycle`(필요 시 Finder가 관리자 인증을 요청).
public struct FileManagerTrash: TrashProviding {
    public init() {}

    public func trash(_ url: URL) async throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        guard let moved = resulting as URL? else { throw CleanupError(.trashLocationUnknown) }
        return moved
    }

    public func recycleWithAuthorization(_ url: URL) async throws -> URL? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL?, Error>) in
            NSWorkspace.shared.recycle([url]) { newURLs, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: newURLs[url] ?? newURLs.values.first)
            }
        }
    }
}

/// 지정한 폴더를 휴지통처럼 쓴다 (테스트·픽스처 전용). 이름이 겹치면 Finder처럼 " 2", " 3"을 붙인다.
public struct DirectoryTrash: TrashProviding {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func trash(_ url: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = Self.uniqueURL(for: url.lastPathComponent, in: directory)
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    static func uniqueURL(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        var n = 2
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        while fm.itemExists(candidate) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
