import Foundation

/// launchd 레이블·패키지 ID·cfprefs 도메인·번들 ID 검증. 권한 스크립트(privileged-op.sh)와 같은 규칙:
/// `[A-Za-z0-9._-]`만, `-`·`.`로 시작하지 않음, 255자 이하.
public enum SafeIdentifier {
    public static func isValid(_ s: String) -> Bool {
        guard !s.isEmpty, s.utf8.count <= 255, let first = s.first, first != "-", first != "." else { return false }
        return s.unicodeScalars.allSatisfy { c in
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "." || c == "_" || c == "-"
        }
    }

    /// Apple 도메인·레이블 (보호 목록 — plan.md 5.1)
    public static func isApple(_ s: String) -> Bool {
        let l = s.lowercased()
        return l == "com.apple" || l.hasPrefix("com.apple.")
    }
}

/// 정리 실행 중 생기는 오류. 사용자 문구는 `text` (`description`은 한국어 문장).
public struct CleanupError: EngineTextError, Sendable, CustomStringConvertible, Hashable {
    public var text: EngineText
    public init(_ text: EngineText) { self.text = text }
    public init(_ key: EngineText.Key, _ args: String...) { self.text = EngineText(key, args: args) }
    public var description: String { text.text }
}
