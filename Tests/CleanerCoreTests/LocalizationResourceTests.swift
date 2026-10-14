import Foundation
import Testing
@testable import CleanerCore

/// CleanerCore 리소스의 번역 표(`Localization/<언어>.lproj`)와 언어 선택
@Suite struct LocalizationResourceTests {
    static let translated: [AppLanguage] = AppLanguage.allCases.filter { $0 != .ko }

    @Test func translationDirectoryHasEveryLanguage() throws {
        let dir = try #require(Translations.directory())
        for language in AppLanguage.allCases {
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(language.rawValue).lproj").path), "\(language)")
            #expect(Translations.table(language) != nil, "\(language)")
        }
    }

    /// 모든 엔진 문구 키가 en·ja `Engine.strings`에 있고, `%@` 개수가 한국어 원문과 같다
    @Test(arguments: translated)
    func everyEngineKeyIsTranslated(_ language: AppLanguage) throws {
        let table = try Self.table("Engine", language)
        for key in EngineText.Key.allCases where key != .verbatim {
            let value = try #require(table[key.rawValue], "\(language) Engine.strings에 없는 키: \(key.rawValue)")
            #expect(Self.specifiers(value) == Self.specifiers(key.koreanFormat), "형식 불일치(\(language)): \(key.rawValue) → \(value)")
            #expect(!Self.containsHangul(value), "번역에 한글이 남음(\(language)): \(key.rawValue)")
        }
        let known = Set(EngineText.Key.allCases.map(\.rawValue))
        #expect(Set(table.keys).subtracting(known).isEmpty, "엔진에 없는 키: \(Set(table.keys).subtracting(known))")
    }

    // MARK: 언어 선택

    @Test func languageTagsMapToSupportedLanguages() {
        #expect(AppLanguage(tag: "ja-JP") == .ja)
        #expect(AppLanguage(tag: "ko_KR.UTF-8") == .ko)
        #expect(AppLanguage(tag: "en") == .en)
        #expect(AppLanguage(tag: "EN_us") == .en)
        #expect(AppLanguage(tag: "fr_FR.UTF-8") == nil)
        #expect(AppLanguage(tag: "C") == nil)
        #expect(AppLanguage(tag: "") == nil)
    }

    /// APPCLEANER_LANG → LC_ALL → LC_MESSAGES → LANG → 시스템 선호 언어 → 영어
    @Test func commandLineLanguageResolutionOrder() {
        func resolve(_ env: [String: String], _ preferred: [String] = ["ko-KR"]) -> AppLanguage {
            AppLanguage.resolve(environment: env, preferredLanguages: preferred)
        }
        #expect(resolve([:]) == .ko)
        #expect(resolve([:], ["fr-FR"]) == .en)
        #expect(resolve([:], []) == .en)
        #expect(resolve(["LANG": "ja_JP.UTF-8"]) == .ja)
        // 지원하지 않는 언어를 가리키는 LANG은 영어 (시스템 언어로 내려가지 않는다)
        #expect(resolve(["LANG": "fr_FR.UTF-8"]) == .en)
        // C/POSIX/빈 값은 언어 지정이 아니다
        #expect(resolve(["LANG": "C"]) == .ko)
        #expect(resolve(["LANG": "C.UTF-8"]) == .ko)
        #expect(resolve(["LANG": ""]) == .ko)
        #expect(resolve(["LC_ALL": "en_US.UTF-8", "LANG": "ja_JP.UTF-8"]) == .en)
        #expect(resolve(["LC_MESSAGES": "ja_JP.UTF-8", "LANG": "en_US.UTF-8"]) == .ja)
        #expect(resolve(["APPCLEANER_LANG": "ja", "LC_ALL": "en_US.UTF-8"]) == .ja)
        // 지원하지 않는 APPCLEANER_LANG은 무시
        #expect(resolve(["APPCLEANER_LANG": "fr", "LANG": "ja_JP.UTF-8"]) == .ja)
    }

    // MARK: 엔진 문구

    /// 안에 든 문구(`parts`)도 같은 언어로 번역되고, JSON에 함께 저장된다
    @Test func nestedPartsAreLocalizedAndStored() throws {
        let failure = EngineText(.holdingMoveFailed, parts: [PrivilegedScript.reason("auth-cancelled")])
        #expect(failure.text == "보류 폴더로 옮기지 못했습니다: 관리자 인증이 취소되었습니다")
        #expect(failure.localized(.en) == "Couldn't move to the holding folder: Administrator authentication was canceled")
        #expect(failure.localized(.ja) == "保留フォルダに移動できませんでした: 管理者認証がキャンセルされました")

        let symlink = EngineText(.symlinkToProtected, "/private/etc/x", parts: [EngineText(.protectedLocation, "/private/etc")])
        #expect(symlink.text == "심볼릭 링크를 따라가면 보호된 위치입니다: /private/etc/x (보호된 위치: /private/etc)")
        #expect(symlink.localized(.en) == "Following the symbolic link leads to a protected location: /private/etc/x (Protected location: /private/etc)")

        let data = try JSONEncoder().encode(failure)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["key"] as? String == "holdingMoveFailed")
        #expect((object["parts"] as? [[String: Any]])?.first?["key"] as? String == "adminAuthCancelled")
        #expect(try JSONDecoder().decode(EngineText.self, from: data) == failure)
        // parts가 없으면 저장하지 않는다 (#22 형식 그대로)
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EngineText(.itemMissing))) as? [String: Any]
        #expect(plain?["parts"] == nil)
    }

    /// 실패 사유: `reason`은 예전처럼 한국어 문자열, 키 문구는 `reasonText`에 함께 저장
    @Test func cleanupFailureStaysBackwardCompatible() throws {
        let keyed = CleanupFailure(path: "/x", reason: EngineText(.itemMissing))
        let data = try JSONEncoder().encode(keyed)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["reason"] as? String == "항목을 찾을 수 없습니다")
        #expect((object["reasonText"] as? [String: Any])?["key"] as? String == "itemMissing")
        #expect(try JSONDecoder().decode(CleanupFailure.self, from: data) == keyed)

        // 이전 버전 기록
        let legacy = try JSONDecoder().decode(CleanupFailure.self, from: Data(#"{"path":"/y","reason":"실패"}"#.utf8))
        #expect(legacy.reason == .verbatim("실패"))
        // 평문 사유는 예전과 똑같이 저장
        let verbatim = try JSONSerialization.jsonObject(with: JSONEncoder().encode(CleanupFailure(path: "/z", reason: .verbatim("오류"))))
        #expect((verbatim as? [String: Any])?.keys.sorted() == ["path", "reason"])
    }

    @Test func engineErrorsCarryLocalizableText() {
        let error = ScanError.appleApp(bundleID: "com.apple.Safari")
        #expect(error.description == "Apple 앱(com.apple.Safari)은 제거 대상에서 제외됩니다.")
        #expect(EngineText.describing(error).localized(.en) == "Apple apps (com.apple.Safari) can't be removed.")
        #expect(EngineText.describing(error).localized(.ja) == "Apple の App (com.apple.Safari) は削除の対象外です。")
        #expect(ScanError.notAnApp(URL(fileURLWithPath: "/tmp/Foo")).description == "Foo은(는) 앱 번들(.app)이 아니거나 찾을 수 없습니다.")
        #expect(EngineText.describing(CleanupError(.prefsDomainProtected, "com.apple.x")).localized(.en) == "Protected preferences domain: com.apple.x")
        #expect(EngineText.describing(CommandError.nonZeroExit("/bin/launchctl", 5, "boom")).text == "/bin/launchctl 종료 코드 5: boom")
    }

    /// 관리자 스크립트의 모든 사유 코드가 키 문구가 된다 (모르는 코드는 코드를 그대로 보여 준다)
    @Test func adminReasonCodesAreKeyed() {
        let codes = ["outside-allowed-root", "dotdot", "bad-path", "not-absolute", "bad-char", "symlink", "protected", "missing",
                     "exists", "bad-identifier", "bad-session", "holding-unsafe", "script-hash-mismatch", "auth-cancelled",
                     "not-root", "launch-failed", "ops-file-failed", "move-failed", "no-result", "launchctl-5", "pkgutil-1", "weird"]
        for code in codes {
            #expect(!PrivilegedScript.reason(code).isVerbatim, "\(code)")
        }
        #expect(PrivilegedScript.reason("launchctl-5").localized(.en) == "launchctl failed (5)")
        #expect(PrivilegedScript.reason("weird").text == "관리자 작업에 실패했습니다 (weird)")
        #expect(PrivilegedScript.authorizationPrompt(.ko) == "App Cleaner가 변경하려고 합니다.")
        #expect(PrivilegedScript.authorizationPrompt(.en) == "App Cleaner wants to make changes.")
        #expect(PrivilegedScript.authorizationPrompt(.ja) == "App Cleaner が変更を加えようとしています。")
    }

    @Test func orphanGroupNameFollowsLanguage() {
        let g = OrphanGroup(id: "team:T", displayName: "개발자 T", nameIsGuess: true, items: [], confidence: .low,
                            nameText: EngineText(.developerGroup, "T"))
        #expect(g.title(.ko) == "개발자 T")
        #expect(g.title(.en) == "Developer T")
        #expect(g.title(.ja) == "開発元 T")
    }

    // MARK: 도우미

    static func table(_ name: String, _ language: AppLanguage) throws -> [String: String] {
        let dir = try #require(Translations.directory())
        let url = dir.appendingPathComponent("\(language.rawValue).lproj/\(name).strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String], "\(url.path)")
    }

    /// "%@"·"%1$@" 개수 (순서 무관)
    static func specifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d\$)?(lld|@|d|%)"#)
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .filter { $0 != "%" }
            .sorted()
    }

    static func containsHangul(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }
}
