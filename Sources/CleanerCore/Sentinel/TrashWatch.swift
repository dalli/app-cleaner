import Foundation

/// 휴지통 바로 아래의 `.app` 목록 (ui-ux.md S10 "휴지통 유입 판단").
///
/// FSEvents는 "무언가 바뀌었다"는 신호로만 쓰고, 실제 판단은 이전 목록과 지금 목록을 **파일 식별자(볼륨 + inode)** 로 비교한다.
/// 그래서 휴지통 안에서 이름만 바뀐 항목, 같은 변경에 대한 중복 이벤트, 이미 있던 항목은 새로 들어온 것으로 보지 않는다.
public struct TrashSnapshot: Sendable, Hashable {
    public struct FileKey: Sendable, Hashable {
        public var device: UInt64
        public var inode: UInt64

        public init(device: UInt64, inode: UInt64) {
            self.device = device
            self.inode = inode
        }
    }

    public private(set) var apps: [FileKey: URL]

    public init(apps: [FileKey: URL] = [:]) {
        self.apps = apps
    }

    /// `trash` 바로 아래의 `.app` 폴더 (심볼릭 링크·하위 폴더 안의 앱은 제외). 휴지통을 읽을 수 없으면 오류.
    public static func read(trash: URL) throws -> TrashSnapshot {
        let names = try FileManager.default.contentsOfDirectory(atPath: trash.path)
        var apps: [FileKey: URL] = [:]
        for name in names where (name as NSString).pathExtension.lowercased() == "app" {
            let url = trash.appendingPathComponent(name, isDirectory: true)
            guard let key = fileKey(url) else { continue }
            apps[key] = url
        }
        return TrashSnapshot(apps: apps)
    }

    /// 실제 폴더(링크 아님)의 볼륨·inode
    static func fileKey(_ url: URL) -> FileKey? {
        var st = stat()
        guard lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return FileKey(device: UInt64(bitPattern: Int64(st.st_dev)), inode: UInt64(st.st_ino))
    }

    /// `previous` 이후 새로 들어온 앱 (경로 순)
    public func arrivals(since previous: TrashSnapshot) -> [URL] {
        apps.filter { previous.apps[$0.key] == nil }.map(\.value).sorted { $0.path < $1.path }
    }
}

/// 휴지통에 들어온 앱의 식별 정보 (휴지통 안의 `Info.plist`에서 읽는다)
public struct TrashedApp: Sendable, Hashable {
    public var url: URL
    public var bundleID: String?
    /// 표시 이름 (`CFBundleDisplayName` → `CFBundleName` → 파일 이름). 휴지통이 붙인 "Slack 12.03.11"이 아니라 원래 이름.
    public var name: String

    public init(url: URL, bundleID: String?, name: String) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
    }

    /// 알리지 않는 이유
    public enum SkipReason: Sendable, Hashable {
        case noBundleID
        case appleApp
        case selfApp
        /// App Cleaner가 방금 직접 제거한 앱
        case removedByAppCleaner
    }

    public static func read(at url: URL) -> TrashedApp {
        let info = BundleInfo.read(bundleAt: url)
        let bid = info?.bundleID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = info.map { $0.displayName ?? $0.name ?? url.deletingPathExtension().lastPathComponent }
            ?? url.deletingPathExtension().lastPathComponent
        return TrashedApp(url: url, bundleID: (bid?.isEmpty ?? true) ? nil : bid,
                          name: name.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func skipReason(removals: RecentRemovals, now: Date,
                           selfBundleID: String = SentinelIdentity.mainBundleID) -> SkipReason? {
        guard let bid = bundleID, BundleIDRules.isSafeComponent(bid) else { return .noBundleID }
        let lower = bid.lowercased()
        if lower == "com.apple" || lower.hasPrefix("com.apple.") { return .appleApp }
        let me = selfBundleID.lowercased()
        if lower == me || lower.hasPrefix(me + ".") { return .selfApp }
        if removals.contains(bid, now: now) { return .removedByAppCleaner }
        return nil
    }

    /// 새로 들어온 앱 중 알릴 것만
    public static func notifiable(_ arrivals: [URL], removals: RecentRemovals, now: Date,
                                  read: (URL) -> TrashedApp = TrashedApp.read(at:)) -> [TrashedApp] {
        arrivals.map(read).filter { $0.skipReason(removals: removals, now: now) == nil }
    }

    /// 휴지통(`~/.Trash`, 외장 볼륨 `.Trashes`) 안의 경로인지
    public static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}

/// App Cleaner가 직접 제거를 시작한 앱 (`SentinelSignal.appRemovalStarted`) — 일정 시간 동안 휴지통 알림에서 뺀다
public struct RecentRemovals: Sendable, Hashable {
    /// 관리자 암호 입력·앱 종료 대기까지 고려한 넉넉한 시간
    public static let defaultLifetime: TimeInterval = 600

    private var recorded: [String: Date] = [:]
    public let lifetime: TimeInterval

    public init(lifetime: TimeInterval = RecentRemovals.defaultLifetime) {
        self.lifetime = lifetime
    }

    public mutating func record(_ bundleIDs: [String], at date: Date) {
        for bid in bundleIDs { recorded[bid.lowercased()] = date }
        prune(now: date)
    }

    public func contains(_ bundleID: String, now: Date) -> Bool {
        guard let at = recorded[bundleID.lowercased()] else { return false }
        return now.timeIntervalSince(at) <= lifetime
    }

    public mutating func prune(now: Date) {
        recorded = recorded.filter { now.timeIntervalSince($0.value) <= lifetime }
    }
}
