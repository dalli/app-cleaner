import AppKit
import CoreServices
import Foundation

/// BID로 LaunchServices에 등록된 앱 URL을 찾는다 (plan.md 4.5.2 "LaunchServices 등록 앱").
/// 반환된 URL은 삭제 후에도 잠시 남으므로 호출하는 쪽에서 존재 여부를 다시 확인한다.
public typealias LaunchServicesLookup = @Sendable (String) -> [URL]

public enum LaunchServicesRegistry {
    /// `NSWorkspace.urlsForApplications(withBundleIdentifier:)`
    public static let live: LaunchServicesLookup = { bid in
        NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bid)
    }

    /// 아무것도 등록돼 있지 않음 (테스트 기본값)
    public static let none: LaunchServicesLookup = { _ in [] }

    public enum Registration: Sendable, Hashable {
        /// 존재하는 앱 번들이 등록돼 있음
        case installed(URL)
        /// 연결 해제된 외장 볼륨의 앱이 등록돼 있음
        case offlineVolume(URL)
        case notRegistered
    }

    /// 등록 URL을 주입 루트 기준으로 옮기고 존재 여부를 재확인한다.
    public static func registration(for bid: String, lookup: LaunchServicesLookup, paths: SystemPaths,
                                    isMounted: @Sendable (URL) -> Bool = VolumePaths.defaultIsMounted) -> Registration {
        var offline: URL?
        for raw in lookup(bid) {
            let url = paths.resolveRecorded(raw.path)
            if FileManager.default.itemExists(url) { return .installed(url) }
            if let vol = VolumePaths.volumeRoot(of: url, paths: paths), !isMounted(vol) { offline = offline ?? url }
        }
        return offline.map(Registration.offlineVolume) ?? .notRegistered
    }
}

/// 실제 환경 훅 (GUI·CLI 조립용). 테스트에서는 주입값을 쓴다.
public enum LiveAppHooks {
    /// `NSRunningApplication`으로 실행 중인지 확인
    public static let isRunning: @Sendable (String) -> Bool = { bid in
        !NSRunningApplication.runningApplications(withBundleIdentifier: bid).isEmpty
    }

    /// 그 경로의 앱 번들이 실행 중인지 (같은 번들 ID의 사본이 여럿일 때 구분)
    public static let isRunningAt: @Sendable (URL) -> Bool = { url in
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == target
        }
    }

    /// Spotlight 메타데이터 `kMDItemLastUsedDate` (프로세스 실행 없이 MDItem API로 읽는다 — 앱당 1ms 미만)
    public static let lastUsed: @Sendable (URL) -> Date? = { url in
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}
