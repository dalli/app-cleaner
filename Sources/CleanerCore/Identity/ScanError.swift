import Foundation

/// 앱 제거 검사를 시작할 수 없는 이유 (plan.md 1.3, 4.1, 5.1)
public enum ScanError: EngineTextError, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    /// `.app` 번들이 아니거나 존재하지 않음
    case notAnApp(URL)
    /// Info.plist에 CFBundleIdentifier가 없음
    case missingBundleID(URL)
    /// Apple 앱(`com.apple.*`)은 v1 범위에서 제외 (plan.md 1.3, 5.1)
    case appleApp(bundleID: String)
    /// 본 앱 자신
    case selfApp(bundleID: String)

    /// 사용자 문구 (GUI·CLI는 `text.localized(_:)`로 표시)
    public var text: EngineText {
        switch self {
        case .notAnApp(let url): return EngineText(.notAnApp, url.lastPathComponent)
        case .missingBundleID(let url): return EngineText(.missingBundleID, url.lastPathComponent)
        case .appleApp(let bid): return EngineText(.appleApp, bid)
        case .selfApp: return EngineText(.cannotRemoveSelf)
        }
    }

    /// 한국어 문장
    public var description: String { text.text }

    public var errorDescription: String? { description }
}
