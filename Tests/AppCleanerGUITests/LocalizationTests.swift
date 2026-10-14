import CleanerCore
import Foundation
import Testing
@testable import AppCleanerGUI

@Suite("Localization")
struct LocalizationTests {
    /// 번역 언어 (ko는 키가 원문)
    static let translated: [AppLanguage] = AppLanguage.allCases.filter { $0 != .ko }

    /// 소스의 모든 `L("…")` 키가 en·ja 문자열 파일(.strings 또는 .stringsdict)에 있어야 하고,
    /// 형식 지정자의 개수·종류·인자 순서가 원문(키)과 같아야 한다
    @Test(arguments: translated)
    func everyKeyIsTranslated(_ language: AppLanguage) throws {
        let keys = try Self.sourceKeys()
        #expect(keys.count > 100)

        let strings = try Self.strings(language)
        let plurals = try Self.plurals(language)
        let missing = keys.subtracting(strings.keys).subtracting(plurals.keys).sorted()
        #expect(missing.isEmpty, "\(language).lproj에 없는 키: \(missing)")
        // 쓰지 않는 번역이 남아 있지 않아야 한다
        let unused = Set(strings.keys).union(plurals.keys).subtracting(keys).sorted()
        #expect(unused.isEmpty, "\(language).lproj에만 있는 키: \(unused)")
        // 복수형 키는 .strings와 .stringsdict 중 한 곳에만 둔다
        #expect(Set(strings.keys).isDisjoint(with: plurals.keys))

        for (key, value) in strings {
            #expect(Self.specifiersInOrder(key) == Self.specifiersInOrder(value), "형식 불일치(\(language)): \(key) → \(value)")
            #expect(!Self.containsHangul(value), "번역에 한글이 남음(\(language)): \(key) → \(value)")
        }
    }

    /// 복수형 항목: 모든 변수에 `other`가 있고, 원문 키의 인자로 채웠을 때 형식 지정자가 남지 않는다
    @Test(arguments: translated)
    func everyPluralEntryRendersWithKeyArguments(_ language: AppLanguage) throws {
        let table = try #require(L10n.lproj(language.rawValue))
        for (key, entry) in try Self.plurals(language) {
            let dict = try #require(entry as? [String: Any], "\(key)")
            for (name, value) in dict where name != "NSStringLocalizedFormatKey" {
                let variable = try #require(value as? [String: Any])
                #expect(variable["other"] != nil, "\(language) \(key): \(name)에 other 없음")
            }
            let args: [any CVarArg] = Self.specifiersInOrder(key).map { $0 == "@" ? "X" as any CVarArg : 3 as any CVarArg }
            let rendered = L10n.format(key, args, table: table, locale: language.locale(region: nil))
            #expect(!rendered.contains("%") && !Self.containsHangul(rendered), "\(language) \(key) → \(rendered)")
        }
    }

    @Test func everyLanguageHasBundleTable() {
        for language in AppLanguage.allCases {
            #expect(L10n.bundle.localizations.contains(language.rawValue), "\(language)")
            #expect(L10n.lproj(language.rawValue) != nil, "\(language)")
        }
    }

    // MARK: 언어 선택

    /// 지원하지 않는 언어만 고른 사용자는 개발 언어(ko)가 아니라 영어를 본다
    @Test func unsupportedPreferredLanguagesFallBackToEnglish() {
        #expect(AppLanguage.preferred(from: ["fr-FR"]) == .en)
        #expect(AppLanguage.preferred(from: ["fr-FR", "de-DE"]) == .en)
        #expect(AppLanguage.preferred(from: []) == .en)
        #expect(AppLanguage.preferred(from: ["fr-FR", "ja-JP", "ko-KR"]) == .ja)
        #expect(AppLanguage.preferred(from: ["ko-KR", "en-US"]) == .ko)
        #expect(AppLanguage.preferred(from: ["en-GB"]) == .en)
        #expect(AppLanguage.preferred(from: ["zh-Hans-CN", "ja"]) == .ja)
    }

    /// 날짜·숫자·크기 형식은 UI 언어 + 시스템 지역
    @Test func formattingLocaleFollowsLanguage() {
        #expect(AppLanguage.ja.locale(region: "KR").identifier == "ja_KR")
        #expect(AppLanguage.en.locale(region: nil).identifier == "en")
        #expect(L10n.locale.language.languageCode?.identifier == L10n.language)
    }

    /// 한국어 조사 처리는 한국어 UI에서만 붙는다
    @Test func koreanParticlesNeverLeakIntoOtherLanguages() {
        #expect(Josa.iGa("Excel", language: .ko) == "Excel이")
        #expect(Josa.eulReul("Word", language: .ko) == "Word를")
        for language in Self.translated {
            #expect(Josa.iGa("Excel", language: language) == "Excel")
            #expect(Josa.eulReul("Word", language: language) == "Word")
            #expect(Josa.eunNeun("Slack", language: language) == "Slack")
            #expect(Josa.euRo("Zoom", language: language) == "Zoom")
        }
    }

    // MARK: 복수형 (Localizable.stringsdict)

    /// SwiftPM `.process("Resources")`가 stringsdict를 번들에 넣고, `L`의 형식 처리가 복수 규칙을 따른다
    @Test func pluralsResolveFromBundle() throws {
        let en = try #require(L10n.lproj("en"))
        let ko = try #require(L10n.lproj("ko"))
        let ja = try #require(L10n.lproj("ja"))
        let enUS = Locale(identifier: "en_US")
        let koKR = Locale(identifier: "ko_KR")
        let jaJP = Locale(identifier: "ja_JP")
        func english(_ key: String, _ args: any CVarArg...) -> String { L10n.format(key, args, table: en, locale: enUS) }
        func korean(_ key: String, _ args: any CVarArg...) -> String { L10n.format(key, args, table: ko, locale: koKR) }
        func japanese(_ key: String, _ args: any CVarArg...) -> String { L10n.format(key, args, table: ja, locale: jaJP) }

        #expect(english("%lld개 항목", 1) == "1 item")
        #expect(english("%lld개 항목", 2) == "2 items")
        #expect(english("%lld개 항목", 0) == "0 items")
        #expect(korean("%lld개 항목", 1) == "1개 항목")
        #expect(english("%lld일", 1) == "1 day")
        #expect(english("%lld일", 30) == "30 days")
        #expect(english("파일 %lld개", 1_234) == "1,234 files")
        #expect(korean("파일 %lld개", 1_234) == "파일 1,234개")
        // 개수에 따라 동사·대명사도 바뀐다
        #expect(english("원래 위치에 같은 이름이 이미 있는 항목 %lld개", 1) == "1 item already exists at its original location")
        #expect(english("원래 위치에 같은 이름이 이미 있는 항목 %lld개", 3) == "3 items already exist at their original location")
        // 다른 인자와 섞인 문구 (위치 지정 인자)
        #expect(english("%lld개 항목, %@를 휴지통으로 옮겼습니다. 휴지통을 비우기 전까지 되돌릴 수 있습니다.", 1, "5 MB")
                == "Moved 1 item (5 MB) to the Trash. You can restore it until you empty the Trash.")
        #expect(english("지난 스캔에서 앱 %lld개의 잔여물 %@를 찾았습니다.", 1, "3 GB") == "The last scan found 3 GB of leftovers from 1 app.")
        #expect(english("보관 기간(%lld일)이 지난 보류 항목이 작업 %lld개에 있습니다.", 1, 2)
                == "Held items older than the retention period (1 day) exist in 2 cleanups.")
        #expect(english("선택 · 그룹 %lld개, 항목 %lld개", 2, 1) == "selected · 2 groups, 1 item")

        // 일본어는 단·복수 구별이 없다 (other만)
        #expect(japanese("%lld개 항목", 1) == japanese("%lld개 항목", 2).replacingOccurrences(of: "2", with: "1"))
        #expect(japanese("%lld개 항목", 1).contains("1"))
        #expect(japanese("파일 %lld개", 1_234).contains("1,234"))
        #expect(japanese("%@ 선택 · %lld개", "Slack", 3).hasPrefix("Slack"))
    }

    /// 영어 복수형 문구는 1과 2에서 다른 문장이 된다
    @Test func everyEnglishPluralEntryVariesByCount() throws {
        let en = try #require(L10n.lproj("en"))
        for key in try Self.plurals(.en).keys {
            func render(_ count: Int) -> String {
                let args: [any CVarArg] = Self.specifiersInOrder(key).map { $0 == "@" ? "X" as any CVarArg : count as any CVarArg }
                return L10n.format(key, args, table: en, locale: Locale(identifier: "en_US"))
            }
            let one = render(1), two = render(2)
            #expect(one != two, "\(key)")
            #expect(!one.contains("%") && !two.contains("%"), "\(key): \(one) / \(two)")
        }
    }

    // MARK: 엔진 문구 (CleanerCore Engine.strings)

    @Test func engineTextRendersPerLanguage() {
        let missing = EngineText(.executableMissing, "/Applications/Gone.app")
        #expect(missing.localized(.en) == "Executable /Applications/Gone.app is missing")
        #expect(missing.localized(.ja) == "実行ファイル /Applications/Gone.app がない")
        #expect(missing.localized(.ko) == "실행 파일 /Applications/Gone.app 없음")

        let usage = EngineText(.usedBy, "Excel")
        #expect(usage.localized(.en) == "Also used by Excel")
        #expect(usage.localized(.ja) == "Excel も使用中")
        #expect(usage.localized(.ko) == "Excel이 함께 사용 중")

        // 위치 지정 인자
        let pkg = EngineText(.packageAppMissing, "com.example.pkg", "/Applications/Tool.app")
        #expect(pkg.localized(.en) == "App /Applications/Tool.app from installer package com.example.pkg is missing")

        // 키 없는 문구(이전 삭제 기록 등)는 그대로
        #expect(EngineText.verbatim("보호된 위치: /System").localized(.en) == "보호된 위치: /System")
    }

    @Test func protectedCandidatePrefersLocalizedExplanationOverSafetyMessage() {
        var c = candidate("/System/Library/Foo", protection: .protectedPath)
        c.notes = [EngineText(.protectedLocation, "/System")]
        #expect(c.secondaryText == ProtectionReason.protectedPath.explanation)
        c.notes = [.verbatim("보호된 위치: /System")]
        #expect(c.secondaryText == ProtectionReason.protectedPath.explanation)
        c.notes = [EngineText(.protectedLocation, "/System"), EngineText(.syncedData)]
        #expect(c.secondaryText == EngineText(.syncedData).localized)
    }

    /// 엔진이 만든 고아 그룹 이름·고아 정리 대상 이름도 UI 언어로 보인다
    @Test func engineNamesUseUILanguage() {
        let group = OrphanGroup(id: "team:ABC", displayName: "개발자 ABC", nameIsGuess: true, items: [], confidence: .low,
                                nameText: EngineText(.developerGroup, "ABC"))
        #expect(group.title(.en) == "Developer ABC")
        #expect(group.title(.ja) == "開発元 ABC")
        #expect(group.title(.ko) == "개발자 ABC")
        let named = OrphanGroup(id: "bid:x", displayName: "Slack", nameIsGuess: false, items: [], confidence: .high)
        #expect(named.title(.ja) == "Slack")

        let session = JournalSession(kind: .orphanCleanup, targetName: CleanupPlanner.orphanTargetName, ruleDataVersion: "t")
        #expect(session.targetTitle == L("고아 잔여물"))
        let app = JournalSession(kind: .appRemoval, targetName: "고아 잔여물", ruleDataVersion: "t")
        #expect(app.targetTitle == "고아 잔여물")
    }

    // MARK: 도우미

    static var sourcesDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/AppCleanerGUI")
    }

    static func sourceKeys() throws -> Set<String> {
        try collectKeys(in: sourcesDirectory)
    }

    /// `<언어>.lproj/Localizable.strings`의 키 → 번역
    static func strings(_ language: AppLanguage) throws -> [String: String] {
        let url = try #require(L10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil,
                                               localization: language.rawValue))
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    /// `<언어>.lproj/Localizable.stringsdict`의 키 → 항목
    static func plurals(_ language: AppLanguage) throws -> [String: Any] {
        let url = try #require(L10n.bundle.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil,
                                               localization: language.rawValue))
        return try #require(NSDictionary(contentsOf: url) as? [String: Any])
    }

    /// 형식 지정자를 인자 순서대로 ("lld" / "@"). `%1$@`처럼 위치를 지정하면 그 위치로 정렬한다.
    static func specifiersInOrder(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d)\$)?(lld|@|d)"#)
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var ordered: [(Int, String)] = []
        for (i, m) in matches.enumerated() {
            let pos = m.range(at: 1).location == NSNotFound ? i : Int(ns.substring(with: m.range(at: 1)))! - 1
            ordered.append((pos, ns.substring(with: m.range(at: 2))))
        }
        return ordered.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func containsHangul(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }
    }

    static func collectKeys(in dir: URL) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                // 소스의 이스케이프(\" \n)를 실제 문자로
                keys.insert(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: #"\""#, with: "\"")
                    .replacingOccurrences(of: #"\n"#, with: "\n"))
            }
        }
        return keys
    }
}
