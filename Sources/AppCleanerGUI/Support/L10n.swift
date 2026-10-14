import Foundation

/// 문구 조회. 키는 한국어 원문이며 `en.lproj/Localizable.strings`가 영어 번역을 갖는다.
///
/// Command Line Tools의 SwiftPM은 String Catalog(`.xcstrings`)를 컴파일하지 못하므로
/// (`xcstringstool` 없음) `ko.lproj` / `en.lproj`의 `Localizable.strings`를 쓴다.
/// 형식 인자가 있는 문구는 키에 `%lld`(정수) · `%@`(문자열)를 직접 쓴다 — `LocalizationTests`가
/// 소스의 모든 L 호출 키가 영어 파일에 있는지 검사한다.
enum L10n {
    static let bundle: Bundle = .module

    /// 실제로 선택된 UI 언어 ("ko" 또는 "en"). 사용자 선호 언어(`-AppleLanguages` 포함)에서 고른다.
    static let language: String = Bundle.preferredLocalizations(
        from: bundle.localizations.filter { $0 != "Base" },
        forPreferences: Locale.preferredLanguages
    ).first ?? "ko"

    /// 고른 언어의 `.lproj` (문자열은 항상 여기서 찾아 날짜·조사 처리와 언어가 어긋나지 않게 한다)
    static let table: Bundle = bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? bundle

    /// 날짜·숫자 형식에 쓰는 로케일 (UI 언어와 맞춘다)
    static let locale: Locale = {
        let region = Locale.current.region?.identifier
        if let region { return Locale(identifier: "\(language)_\(region)") }
        return Locale(identifier: language)
    }()

    static var isKorean: Bool { language.hasPrefix("ko") }
}

/// 한국어 원문 키로 현재 언어의 문구를 돌려준다.
func L(_ key: String) -> String {
    L10n.table.localizedString(forKey: key, value: nil, table: nil)
}

/// 형식 인자가 있는 문구 (`%lld`, `%@`).
func L(_ key: String, _ args: any CVarArg...) -> String {
    String(format: L(key), locale: L10n.locale, arguments: args)
}
