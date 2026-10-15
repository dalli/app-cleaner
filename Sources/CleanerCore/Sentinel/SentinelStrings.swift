import Foundation

/// Sentinel 메뉴·알림 문구 조회. 키는 한국어 원문이고 번역은 CleanerCore 리소스
/// `Localization/<언어>.lproj/Sentinel.strings` (+ 영어 복수형 `Sentinel.stringsdict`)에 있다.
/// Sentinel은 본 앱 번들 안의 별도 앱이므로 GUI의 `Localizable.strings`가 아니라 이 표를 쓴다 (CLI와 같은 방식).
public enum SentinelStrings {
    public static let table = "Sentinel"

    public static func format(_ key: String, _ args: [any CVarArg], language: AppLanguage) -> String {
        Translations.format(key, table: table, language: language, args)
    }

    /// 한국어에서만 받침에 따라 "을"/"를"을 붙인다 ("Slack을", "Zoom을", "메모를" …)
    public static func withObjectParticle(_ word: String, language: AppLanguage) -> String {
        guard language == .ko else { return word }
        return word + (hasFinalConsonant(word) ? "을" : "를")
    }

    /// 마지막 글자의 받침 여부. 영문은 한국어 발음을 어림한다 (GUI `Josa.hasFinalConsonant`와 같은 규칙).
    static func hasFinalConsonant(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard let last = trimmed.unicodeScalars.last else { return false }
        let v = last.value
        if (0xAC00...0xD7A3).contains(v) { return (v - 0xAC00) % 28 != 0 }
        if let digit = Int(String(last)) {
            // 영 일 이 삼 사 오 육 칠 팔 구
            return [true, true, false, true, false, false, true, true, true, false][digit]
        }
        var lower = trimmed.lowercased()
        // 묵음 e: Chrome → 크롬
        if lower.count > 2, lower.hasSuffix("e") {
            let beforeE = lower[lower.index(lower.endIndex, offsetBy: -2)]
            if "lmn".contains(beforeE) { lower.removeLast() }
        }
        if lower.hasSuffix("ng") || lower.hasSuffix("ck") { return true }
        guard let ch = lower.last else { return false }
        return "lmnkgbp".contains(ch)
    }
}
