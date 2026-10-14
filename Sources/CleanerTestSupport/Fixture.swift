import Foundation
import CleanerCore

/// 임시 디렉토리에 가짜 홈 + 가짜 루트 + 가짜 앱 + 가짜 잔여물 트리를 만든다 (plan.md 9장 픽스처 테스트).
/// 실제 사용자 환경을 절대 건드리지 않는다.
public final class Fixture: @unchecked Sendable {
    public let base: URL
    public let paths: SystemPaths
    private let fm = FileManager.default

    public init(uid: UInt32 = getuid()) throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .appendingPathComponent("appcleaner-fixture-\(UUID().uuidString)", isDirectory: true)
        base = tmp
        paths = SystemPaths.fake(base: tmp, uid: uid)
        for dir in [paths.home, paths.root, paths.userCacheDir, paths.userTempDir, paths.appDataDir, paths.trash,
                    paths.home.appendingPathComponent("Applications"), paths.system("Applications"),
                    paths.userLibrary, paths.systemLibrary] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    deinit { try? fm.removeItem(at: base) }

    public func home(_ relative: String) -> URL { paths.home(relative) }
    public func root(_ path: String) -> URL { paths.system(path) }

    // MARK: 파일

    @discardableResult
    public func dir(_ url: URL) throws -> URL {
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    public func file(_ url: URL, bytes: Int = 16, modified: Date? = nil) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        if let modified { try setModified(url, modified) }
        return url
    }

    @discardableResult
    public func file(_ url: URL, text: String) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    @discardableResult
    public func plist(_ url: URL, _ dict: [String: Any]) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    @discardableResult
    public func symlink(_ url: URL, to destination: URL) throws -> URL {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: url, withDestinationURL: destination)
        return url
    }

    public func setModified(_ url: URL, _ date: Date) throws {
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    public func exists(_ url: URL) -> Bool { fm.itemExists(url) }

    // MARK: 앱

    public struct EmbeddedBundle: Sendable {
        /// 앱 기준 상대 경로 (예: "Contents/PlugIns/Share.appex", "Contents/Library/LoginItems/Helper.app")
        public var relativePath: String
        public var bundleID: String
        public var name: String

        public init(_ relativePath: String, bundleID: String, name: String? = nil) {
            self.relativePath = relativePath
            self.bundleID = bundleID
            self.name = name ?? URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        }
    }

    /// 가짜 `.app` 번들 생성. `in`은 앱이 놓일 디렉토리 (기본: 가짜 `/Applications`).
    @discardableResult
    public func makeApp(
        name: String,
        bundleID: String,
        in directory: URL? = nil,
        displayName: String? = nil,
        executable: String? = nil,
        version: String = "1.0",
        embedded: [EmbeddedBundle] = [],
        launchPlists: [(relativePath: String, label: String, bundleProgram: String)] = [],
        wrappedBundleID: String? = nil,
        extraInfo: [String: Any] = [:]
    ) throws -> URL {
        let parent = directory ?? root("Applications")
        let app = parent.appendingPathComponent("\(name).app", isDirectory: true)
        let exe = executable ?? name
        var info: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleExecutable": exe,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": version,
            "CFBundlePackageType": "APPL",
        ]
        if let displayName { info["CFBundleDisplayName"] = displayName }
        for (k, v) in extraInfo { info[k] = v }
        try plist(app.appendingPathComponent("Contents/Info.plist"), info)
        try file(app.appendingPathComponent("Contents/MacOS/\(exe)"), bytes: 64)
        for e in embedded {
            let b = app.appendingPathComponent(e.relativePath, isDirectory: true)
            try plist(b.appendingPathComponent("Contents/Info.plist"), [
                "CFBundleIdentifier": e.bundleID, "CFBundleName": e.name, "CFBundleExecutable": e.name,
            ])
            try file(b.appendingPathComponent("Contents/MacOS/\(e.name)"), bytes: 32)
        }
        for lp in launchPlists {
            try plist(app.appendingPathComponent(lp.relativePath), [
                "Label": lp.label, "BundleProgram": lp.bundleProgram,
            ])
        }
        if let wrappedBundleID {
            let inner = app.appendingPathComponent("Wrapper/\(name).app", isDirectory: true)
            try plist(inner.appendingPathComponent("Info.plist"), [
                "CFBundleIdentifier": wrappedBundleID, "CFBundleName": name, "CFBundleExecutable": exe,
            ])
            try symlink(app.appendingPathComponent("WrappedBundle"), to: URL(fileURLWithPath: "Wrapper/\(name).app"))
        }
        return app
    }

    /// 샌드박스 컨테이너 + 메타데이터 plist
    @discardableResult
    public func makeContainer(bundleID: String, documents: Int = 0, appSupportBytes: Int = 0, cacheBytes: Int = 128) throws -> URL {
        let c = home("Library/Containers/\(bundleID)")
        try plist(c.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"), [
            "MCMMetadataIdentifier": bundleID, "MCMMetadataUUID": UUID().uuidString,
        ])
        let data = c.appendingPathComponent("Data")
        try file(data.appendingPathComponent("Library/Caches/cache.db"), bytes: cacheBytes)
        try file(data.appendingPathComponent("Library/Preferences/\(bundleID).plist"), bytes: 64)
        for i in 0..<documents {
            try file(data.appendingPathComponent("Documents/doc\(i).txt"), bytes: 256)
        }
        if appSupportBytes > 0 {
            try file(data.appendingPathComponent("Library/Application Support/store.sqlite"), bytes: appSupportBytes)
        }
        return c
    }

    /// LaunchAgent/Daemon plist
    @discardableResult
    public func makeLaunchPlist(at url: URL, label: String, program: String? = nil, arguments: [String]? = nil,
                                keepAlive: Bool = false) throws -> URL {
        var dict: [String: Any] = ["Label": label]
        if let program { dict["Program"] = program }
        if let arguments { dict["ProgramArguments"] = arguments }
        if keepAlive { dict["KeepAlive"] = true; dict["RunAtLoad"] = true }
        return try plist(url, dict)
    }
}
