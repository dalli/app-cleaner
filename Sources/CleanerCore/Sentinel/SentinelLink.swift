import Foundation

/// Sentinel → 본 앱 화면 연결 (ui-ux.md S10 "본 앱으로 넘기기").
///
/// URL 스킴 `com.dallisoft.appcleaner://`. 링크는 검사 화면만 열고 아무것도 바꾸지 않는다.
/// - `inspect?path=<.app 경로>` → S2 (휴지통에 있는 앱 검사)
/// - `orphans` → S5 + 스캔
/// - `settings` → S7
public enum SentinelLink: Sendable, Hashable {
    case inspect(path: String)
    case orphans
    case settings

    /// 다른 앱("AppCleaner" 등)과 겹치지 않도록 역 DNS 형태
    public static let scheme = "com.dallisoft.appcleaner"

    public var url: URL {
        var c = URLComponents()
        c.scheme = Self.scheme
        switch self {
        case .inspect(let path):
            c.host = "inspect"
            c.queryItems = [URLQueryItem(name: "path", value: path)]
        case .orphans:
            c.host = "orphans"
        case .settings:
            c.host = "settings"
        }
        return c.url!
    }

    /// 스킴이 다르거나 알 수 없는 동작이면 nil. `inspect`는 절대 경로의 `.app`만 받는다.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch c.host?.lowercased() {
        case "inspect":
            guard let path = c.queryItems?.first(where: { $0.name == "path" })?.value, path.hasPrefix("/"),
                  URL(fileURLWithPath: path).pathExtension.lowercased() == "app" else { return nil }
            self = .inspect(path: URL(fileURLWithPath: path).standardizedFileURL.path)
        case "orphans":
            self = .orphans
        case "settings":
            self = .settings
        default:
            return nil
        }
    }
}
