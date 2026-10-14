import Foundation
import CleanerCore

/// CLI 출력 문구. 키는 한국어 원문(한국어 출력 그대로)이고, en·ja 번역은 CleanerCore 리소스
/// `Localization/<언어>.lproj/CLI.strings`(+ 복수형 `CLI.stringsdict`)에 있다 — CLI는 실행 파일과
/// `AppCleaner_CleanerCore.bundle`만 배포하므로 번역도 그 번들에 둔다. 사용법처럼 긴 문단은 영문 키("usage")를 쓰고
/// 한국어 문단은 `ko.lproj/CLI.strings`에 둔다.
/// `CLITests`가 소스의 모든 `t(키)`·`UsageError(키)` 키가 en·ja 파일에 있는지 검사한다.
struct CLIText: Sendable {
    var language: AppLanguage

    func callAsFunction(_ key: String, _ args: any CVarArg...) -> String {
        format(key, args)
    }

    func format(_ key: String, _ args: [any CVarArg]) -> String {
        Translations.format(key, table: "CLI", language: language, args)
    }
}

/// 출력 언어 고르기: `--lang <ko|en|ja>` → `APPCLEANER_LANG` → `LC_ALL`/`LC_MESSAGES`/`LANG` → 시스템 선호 언어 → 영어
enum CLILanguage {
    static let option = "--lang"

    /// 인자에서 `--lang <값>`·`--lang=<값>`을 빼고 언어를 정한다. 값이 없거나 지원하지 않으면 `UsageError`
    /// (오류 문구는 환경 변수·시스템 설정으로 고른 언어로 보여 준다 — `fallback`).
    static func extract(_ args: [String], environment: [String: String],
                        preferredLanguages: [String]) -> (language: AppLanguage, rest: [String], error: UsageError?) {
        let fallback = AppLanguage.resolve(environment: environment, preferredLanguages: preferredLanguages)
        var rest: [String] = []
        var chosen: AppLanguage?
        var i = 0
        while i < args.count {
            let a = args[i]
            var value: String?
            if a == option {
                guard i + 1 < args.count else { return (fallback, rest, UsageError("--lang 값이 필요합니다 (ko, en, ja)")) }
                value = args[i + 1]
                i += 2
            } else if a.hasPrefix(option + "=") {
                value = String(a.dropFirst(option.count + 1))
                i += 1
            } else {
                rest.append(a)
                i += 1
                continue
            }
            guard let v = value, let lang = AppLanguage(tag: v) else {
                return (fallback, rest, UsageError("--lang은 ko, en, ja 중 하나입니다: %@", value ?? ""))
            }
            chosen = lang
        }
        return (chosen ?? fallback, rest, nil)
    }
}
