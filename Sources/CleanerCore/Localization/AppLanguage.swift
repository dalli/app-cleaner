import Foundation
import os

/// 지원하는 UI 언어. 새 언어는 여기에 case를 더하고 번역 파일(`<언어>.lproj`)을 추가한다 (docs/development.md "번역 추가 절차").
public enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case ko
    case en
    case ja

    /// 선호 언어 중 지원하는 언어가 없을 때 쓰는 언어. 개발 언어(ko)가 아니라 영어다.
    public static let fallback: AppLanguage = .en

    /// 언어 태그("ja-JP", "ko_KR.UTF-8", "en", "zh-Hant-TW")의 언어 부분이 지원 언어이면 그 언어, 아니면 nil
    public init?(tag: String) {
        guard let code = Self.languageCode(of: tag) else { return nil }
        self.init(rawValue: code)
    }

    /// "ko_KR.UTF-8" → "ko". 빈 값·"C"·"POSIX"는 언어가 아니므로 nil
    static func languageCode(of tag: String) -> String? {
        let code = tag.trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { "-_.@".contains($0) }).first.map(String.init) ?? ""
        return code.isEmpty || code == "c" || code == "posix" ? nil : code
    }

    /// 선호 언어 목록(`Locale.preferredLanguages`)에서 처음으로 지원하는 언어. 하나도 없으면 영어.
    /// `Bundle.preferredLocalizations`는 맞는 언어가 없으면 개발 언어(ko)를 돌려주므로 쓰지 않는다.
    public static func preferred(from languages: [String]) -> AppLanguage {
        languages.lazy.compactMap(AppLanguage.init(tag:)).first ?? fallback
    }

    /// 명령줄 도구의 언어: `APPCLEANER_LANG` → `LC_ALL` → `LC_MESSAGES` → `LANG` → 시스템 선호 언어 → 영어.
    /// - `APPCLEANER_LANG`이 지원하지 않는 값이면 무시하고 다음 단계로 간다.
    /// - `LC_ALL`·`LC_MESSAGES`·`LANG`은 비어 있거나 `C`/`POSIX`이면 건너뛰고, 지원하지 않는 언어(fr_FR 등)를 가리키면 영어.
    public static func resolve(environment: [String: String], preferredLanguages: [String]) -> AppLanguage {
        if let forced = environment["APPCLEANER_LANG"].flatMap(AppLanguage.init(tag:)) { return forced }
        for name in ["LC_ALL", "LC_MESSAGES", "LANG"] {
            guard let value = environment[name], Self.languageCode(of: value) != nil else { continue }
            return AppLanguage(tag: value) ?? fallback
        }
        return preferred(from: preferredLanguages)
    }

    private static let currentState = OSAllocatedUnfairLock(initialState: preferred(from: Locale.preferredLanguages))

    /// 엔진이 시스템에 넘기는 문구(관리자 인증 안내, 이름을 바꿔 복원할 때 붙이는 표시)의 언어.
    /// 기본은 시스템 선호 언어이고, CLI는 `--lang`·환경 변수로 고른 언어로 시작할 때 바꾼다.
    public static var current: AppLanguage {
        get { currentState.withLock { $0 } }
        set { currentState.withLock { $0 = newValue } }
    }

    /// 날짜·숫자·크기 형식에 쓰는 로케일: 이 언어 + 시스템 지역 ("ja_KR"처럼 언어는 UI를, 지역은 시스템을 따른다)
    public func locale(region: String? = Locale.current.region?.identifier) -> Locale {
        guard let region else { return Locale(identifier: rawValue) }
        return Locale(identifier: "\(rawValue)_\(region)")
    }
}
