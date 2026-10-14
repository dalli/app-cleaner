import Foundation

/// CleanerCore 리소스의 번역 표: `Resources/Localization/<언어>.lproj/<표>.strings` (+ 복수형 `<표>.stringsdict`).
///
/// - `Engine`: 엔진 문구(`EngineText`) — 키는 `EngineText.Key.rawValue`, 한국어 원문은 코드(`koreanFormat`)에 있다.
/// - `CLI`: 명령줄 출력 — 키는 한국어 원문이며 `ko.lproj`에는 키와 다른 문구(사용법)만 둔다.
///
/// CLI는 실행 파일과 `AppCleaner_CleanerCore.bundle`만 배포하므로(Homebrew 포함) CLI 번역도 이 번들에 둔다.
/// 번들 위치는 `BundledResources`로 찾는다 (심볼릭 링크로 실행돼도 동작). 없으면 `Bundle.module`.
public enum Translations {
    public static let directoryName = "Localization"

    /// 번역 폴더 위치
    public static func directory(resourceURL: URL? = Bundle.main.resourceURL,
                                 executableURL: URL? = Bundle.main.executableURL) -> URL? {
        let fm = FileManager.default
        if let found = BundledResources.locate(directoryName, resourceURL: resourceURL, executableURL: executableURL,
                                               where: { fm.isDirectory($0) }) { return found }
        return Bundle.module.url(forResource: directoryName, withExtension: nil)
    }

    /// 언어별 `.lproj` 폴더를 번들로 연다 (`localizedString`이 `.strings`와 `.stringsdict`를 함께 읽는다)
    static let tables: [AppLanguage: Bundle] = {
        guard let dir = directory() else { return [:] }
        var out: [AppLanguage: Bundle] = [:]
        for language in AppLanguage.allCases {
            if let bundle = Bundle(path: dir.appendingPathComponent("\(language.rawValue).lproj").path) {
                out[language] = bundle
            }
        }
        return out
    }()

    public static func table(_ language: AppLanguage) -> Bundle? { tables[language] }

    /// 번역 문자열. 표에 없으면 nil
    public static func string(_ key: String, table: String, language: AppLanguage) -> String? {
        let missing = "\u{1}"
        let value = tables[language]?.localizedString(forKey: key, value: missing, table: table) ?? missing
        return value == missing ? nil : value
    }

    /// 형식 문자열을 찾아 인자를 채운다 (`%lld`·`%@`, 복수형은 `.stringsdict`). 표에 없으면 키를 형식으로 쓴다.
    public static func format(_ key: String, table: String, language: AppLanguage, _ args: [any CVarArg]) -> String {
        let format = tables[language]?.localizedString(forKey: key, value: key, table: table) ?? key
        guard !args.isEmpty else { return format }
        return String(format: format, locale: language.locale(), arguments: args)
    }
}
