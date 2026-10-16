import CleanerCore
import Foundation

/// 문구 조회. 키는 한국어 원문이며 `en.lproj`·`ja.lproj`의 `Localizable.strings`가 번역을 갖는다.
///
/// Command Line Tools의 SwiftPM은 String Catalog(`.xcstrings`)를 컴파일하지 못하므로
/// (`xcstringstool` 없음) `<언어>.lproj/Localizable.strings`를 쓴다.
/// 개수에 따라 형태가 바뀌는 문구는 `<언어>.lproj/Localizable.stringsdict`(일본어는 `other`만),
/// 엔진 문구(`EngineText`)는 CleanerCore 리소스(`Localization/<언어>.lproj/Engine.strings`)가 맡는다.
/// 형식 인자가 있는 문구는 키에 `%lld`(정수) · `%@`(문자열)를 직접 쓴다 — `LocalizationTests`가
/// 소스의 모든 L 호출 키가 en·ja 파일에 있고 형식 지정자가 원문과 맞는지 검사한다.
enum L10n {
    /// GUI 리소스 번들. 배포 앱은 `Contents/Resources`에서 직접 찾는다 — 릴리즈 빌드의 `Bundle.module`은 그 위치를 보지 않아
    /// 앱이 시작하자마자 종료됐다 (`BundledResources.bundleURL(named:)`). `swift test`·`swift run`은 `.module`로 찾는다.
    static let bundleName = "AppCleaner_AppCleanerGUI.bundle"
    static let bundle: Bundle = BundledResources.bundleURL(named: bundleName).flatMap(Bundle.init(url:)) ?? .module

    /// 실제로 선택된 UI 언어. 사용자 선호 언어(`-AppleLanguages` 포함)에서 처음 지원하는 언어,
    /// 하나도 없으면 영어 (`Bundle.preferredLocalizations`는 개발 언어 ko를 돌려주므로 쓰지 않는다).
    static let appLanguage: AppLanguage = .preferred(from: Locale.preferredLanguages)

    /// UI 언어 코드 ("ko", "en", "ja")
    static var language: String { appLanguage.rawValue }

    /// 고른 언어의 `.lproj` (문자열은 항상 여기서 찾아 날짜·조사 처리와 언어가 어긋나지 않게 한다)
    static let table: Bundle = lproj(language) ?? bundle

    /// 언어별 `.lproj` 번들 (테스트는 이것으로 언어를 고정해 확인한다)
    static func lproj(_ language: String) -> Bundle? {
        bundle.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// 날짜·숫자·크기 형식에 쓰는 로케일 (UI 언어 + 시스템 지역)
    static let locale: Locale = appLanguage.locale()

    /// 오류 설명: 엔진 오류(검사 불가 사유 등)는 UI 언어의 문장, 그 밖에는 시스템 설명
    static func describe(_ error: any Error) -> String {
        EngineText.describing(error).localized
    }
}

/// 한국어 원문 키로 현재 언어의 문구를 돌려준다.
func L(_ key: String) -> String {
    L10n.table.localizedString(forKey: key, value: nil, table: nil)
}

/// 형식 인자가 있는 문구 (`%lld`, `%@`).
/// 개수에 따라 형태가 갈리는 문구는 `<언어>.lproj/Localizable.stringsdict`가 `.strings`보다 우선한다.
func L(_ key: String, _ args: any CVarArg...) -> String {
    L10n.format(key, args)
}

extension L10n {
    /// `L(_:_:)`의 본체. 테스트는 `table`·`locale`을 바꿔 다른 언어의 결과를 확인한다.
    static func format(_ key: String, _ args: [any CVarArg], table: Bundle = L10n.table, locale: Locale = L10n.locale) -> String {
        String(format: table.localizedString(forKey: key, value: nil, table: nil), locale: locale, arguments: args)
    }
}
