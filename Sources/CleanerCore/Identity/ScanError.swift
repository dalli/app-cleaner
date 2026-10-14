import Foundation

/// 앱 제거 검사를 시작할 수 없는 이유 (plan.md 1.3, 4.1, 5.1)
public enum ScanError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    /// `.app` 번들이 아니거나 존재하지 않음
    case notAnApp(URL)
    /// Info.plist에 CFBundleIdentifier가 없음
    case missingBundleID(URL)
    /// Apple 앱(`com.apple.*`)은 v1 범위에서 제외 (plan.md 1.3, 5.1)
    case appleApp(bundleID: String)
    /// 본 앱 자신
    case selfApp(bundleID: String)

    public var description: String {
        switch self {
        case .notAnApp(let url):
            return "\(url.lastPathComponent)은(는) 앱 번들(.app)이 아니거나 찾을 수 없습니다."
        case .missingBundleID(let url):
            return "\(url.lastPathComponent)의 번들 ID를 읽을 수 없어 검사할 수 없습니다."
        case .appleApp(let bid):
            return "Apple 앱(\(bid))은 제거 대상에서 제외됩니다."
        case .selfApp:
            return "App Cleaner 자신은 제거할 수 없습니다."
        }
    }

    public var errorDescription: String? { description }
}
