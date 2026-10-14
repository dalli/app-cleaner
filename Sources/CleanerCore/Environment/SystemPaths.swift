import Foundation

/// 엔진이 사용하는 모든 루트 경로. 테스트에서는 가짜 홈/루트를 주입한다 (plan.md 8.2).
/// 엔진 코드는 `/`, `NSHomeDirectory()`, `FileManager.default.homeDirectoryForCurrentUser`를 직접 쓰지 않는다.
public struct SystemPaths: Codable, Sendable, Hashable {
    /// 사용자 홈 (`~`)
    public var home: URL
    /// 시스템 루트 (`/`)
    public var root: URL
    /// `getconf DARWIN_USER_CACHE_DIR`
    public var userCacheDir: URL
    /// `getconf DARWIN_USER_TEMP_DIR`
    public var userTempDir: URL
    /// 본 앱의 데이터 폴더 (삭제 기록, 인벤토리 캐시, 유지 목록, 규칙 데이터 갱신본)
    public var appDataDir: URL
    /// 관리자 보류 폴더 (`/Library/Application Support/<OurApp>/Holding`)
    public var holdingDir: URL
    public var uid: UInt32
    /// 본 앱의 BID (보호 목록)
    public var selfBundleID: String

    public static let ourAppFolderName = "AppCleaner"
    public static let defaultSelfBundleID = "com.dallisoft.AppCleaner"

    public init(home: URL, root: URL, userCacheDir: URL, userTempDir: URL, appDataDir: URL, holdingDir: URL,
                uid: UInt32, selfBundleID: String = SystemPaths.defaultSelfBundleID) {
        self.home = home
        self.root = root
        self.userCacheDir = userCacheDir
        self.userTempDir = userTempDir
        self.appDataDir = appDataDir
        self.holdingDir = holdingDir
        self.uid = uid
        self.selfBundleID = selfBundleID
    }

    public var userLibrary: URL { home.appendingPathComponent("Library", isDirectory: true) }
    public var systemLibrary: URL { root.appendingPathComponent("Library", isDirectory: true) }
    public var trash: URL { home.appendingPathComponent(".Trash", isDirectory: true) }

    /// `~/` 기준 상대 경로
    public func home(_ relative: String) -> URL { home.appendingPathComponent(relative) }
    /// `/` 기준 상대 경로 (선행 `/` 허용)
    public func system(_ path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return root.appendingPathComponent(trimmed)
    }

    /// 실제 환경
    public static func live() -> SystemPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        let cache = confstrPath(_CS_DARWIN_USER_CACHE_DIR) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let temp = confstrPath(_CS_DARWIN_USER_TEMP_DIR) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let appData = home.appendingPathComponent("Library/Application Support/\(ourAppFolderName)", isDirectory: true)
        let holding = root.appendingPathComponent("Library/Application Support/\(ourAppFolderName)/Holding", isDirectory: true)
        return SystemPaths(home: home, root: root, userCacheDir: cache, userTempDir: temp, appDataDir: appData,
                           holdingDir: holding, uid: getuid())
    }

    /// 픽스처용: `base/home`, `base/root` 등 임시 트리 안에서만 동작
    public static func fake(base: URL, uid: UInt32 = getuid()) -> SystemPaths {
        let home = base.appendingPathComponent("home", isDirectory: true)
        let root = base.appendingPathComponent("root", isDirectory: true)
        return SystemPaths(
            home: home,
            root: root,
            userCacheDir: base.appendingPathComponent("var/folders/xx/C", isDirectory: true),
            userTempDir: base.appendingPathComponent("var/folders/xx/T", isDirectory: true),
            appDataDir: home.appendingPathComponent("Library/Application Support/\(ourAppFolderName)", isDirectory: true),
            holdingDir: root.appendingPathComponent("Library/Application Support/\(ourAppFolderName)/Holding", isDirectory: true),
            uid: uid
        )
    }

    private static func confstrPath(_ name: Int32) -> URL? {
        let len = confstr(name, nil, 0)
        guard len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len)
        guard confstr(name, &buf, len) > 0 else { return nil }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
    }
}
