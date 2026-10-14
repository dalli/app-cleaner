import CleanerCore
import Foundation
import Testing
@testable import AppCleanerGUI

@Suite("Localization")
struct LocalizationTests {
    /// 소스의 모든 `L("…")` 키가 영어 문자열 파일에 있어야 한다
    @Test func everyKeyHasEnglishTranslation() throws {
        let sources = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/AppCleanerGUI")
        let keys = try Self.collectKeys(in: sources)
        #expect(keys.count > 100)

        let enURL = try #require(L10n.bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en"))
        let en = try #require(NSDictionary(contentsOf: enURL) as? [String: String])
        let plurals = try Self.englishPlurals()
        let missing = keys.subtracting(en.keys).subtracting(plurals.keys).sorted()
        #expect(missing.isEmpty, "en.lproj에 없는 키: \(missing)")
        // 복수형 키는 .strings와 .stringsdict 중 한 곳에만 둔다
        #expect(Set(en.keys).isDisjoint(with: plurals.keys))

        // 형식 지정자 개수가 같아야 한다
        for key in keys {
            guard let value = en[key] else { continue }
            #expect(Self.specifiers(key) == Self.specifiers(value), "형식 불일치: \(key) → \(value)")
        }
    }

    @Test func koreanIsDevelopmentLanguage() {
        #expect(L10n.bundle.localizations.contains("ko"))
        #expect(L10n.bundle.localizations.contains("en"))
    }

    // MARK: 영어 복수형 (Localizable.stringsdict)

    /// SwiftPM `.process("Resources")`가 stringsdict를 번들에 넣고, `L`의 형식 처리가 복수 규칙을 따른다
    @Test func englishPluralsResolveFromBundle() throws {
        let en = try #require(L10n.lproj("en"))
        let ko = try #require(L10n.lproj("ko"))
        let enUS = Locale(identifier: "en_US")
        let koKR = Locale(identifier: "ko_KR")
        func english(_ key: String, _ args: any CVarArg...) -> String { L10n.format(key, args, table: en, locale: enUS) }
        func korean(_ key: String, _ args: any CVarArg...) -> String { L10n.format(key, args, table: ko, locale: koKR) }

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
    }

    /// 모든 복수형 문구가 1과 2에서 다른 영어 문장이 되고 형식 지정자가 남지 않는다
    @Test func everyPluralEntryVariesByCount() throws {
        let en = try #require(L10n.lproj("en"))
        for key in try Self.englishPlurals().keys {
            func render(_ count: Int) -> String {
                let args: [any CVarArg] = Self.specifiersInOrder(key).map { $0 == "@" ? "X" as any CVarArg : count as any CVarArg }
                return L10n.format(key, args, table: en, locale: Locale(identifier: "en_US"))
            }
            let one = render(1), two = render(2)
            #expect(one != two, "\(key)")
            #expect(!one.contains("%") && !two.contains("%"), "\(key): \(one) / \(two)")
        }
    }

    // MARK: 엔진 문구 (Engine.strings)

    @Test func everyEngineKeyHasEnglishTranslation() throws {
        let url = try #require(L10n.bundle.url(forResource: "Engine", withExtension: "strings", subdirectory: nil, localization: "en"))
        let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
        for key in EngineText.Key.allCases where key != .verbatim {
            let value = try #require(table[key.rawValue], "Engine.strings에 없는 키: \(key.rawValue)")
            #expect(Self.specifiers(value) == Self.specifiers(key.koreanFormat), "형식 불일치: \(key.rawValue) → \(value)")
        }
        let known = Set(EngineText.Key.allCases.map(\.rawValue))
        #expect(Set(table.keys).subtracting(known).isEmpty, "엔진에 없는 키: \(Set(table.keys).subtracting(known))")
    }

    @Test func engineTextRendersPerLanguage() {
        let missing = EngineText(.executableMissing, "/Applications/Gone.app")
        #expect(missing.localized(language: "en") == "Executable /Applications/Gone.app is missing")
        #expect(missing.localized(language: "ko") == "실행 파일 /Applications/Gone.app 없음")

        let usage = EngineText(.usedBy, "Excel")
        #expect(usage.localized(language: "en") == "Also used by Excel")
        #expect(usage.localized(language: "ko") == "Excel이 함께 사용 중")

        // 위치 지정 인자
        let pkg = EngineText(.packageAppMissing, "com.example.pkg", "/Applications/Tool.app")
        #expect(pkg.localized(language: "en") == "App /Applications/Tool.app from installer package com.example.pkg is missing")

        // 키 없는 문구(이전 삭제 기록 등)는 그대로
        #expect(EngineText.verbatim("보호된 위치: /System").localized(language: "en") == "보호된 위치: /System")
    }

    @Test func protectedCandidatePrefersLocalizedExplanationOverSafetyMessage() {
        var c = candidate("/System/Library/Foo", protection: .protectedPath)
        c.notes = [.verbatim("보호된 위치: /System")]
        #expect(c.secondaryText == ProtectionReason.protectedPath.explanation)
        c.notes = [.verbatim("보호된 위치: /System"), EngineText(.syncedData)]
        #expect(c.secondaryText == EngineText(.syncedData).localized)
    }

    /// en.lproj/Localizable.stringsdict의 키 → 항목
    static func englishPlurals() throws -> [String: Any] {
        let url = try #require(L10n.bundle.url(forResource: "Localizable", withExtension: "stringsdict", subdirectory: nil, localization: "en"))
        return try #require(NSDictionary(contentsOf: url) as? [String: Any])
    }

    /// 키의 형식 지정자를 인자 순서대로 ("lld" / "@")
    static func specifiersInOrder(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d)\$)?(lld|@)"#)
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        var ordered: [(Int, String)] = []
        for (i, m) in matches.enumerated() {
            let pos = m.range(at: 1).location == NSNotFound ? i : Int(ns.substring(with: m.range(at: 1)))! - 1
            ordered.append((pos, ns.substring(with: m.range(at: 2))))
        }
        return ordered.sorted { $0.0 < $1.0 }.map(\.1)
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
                keys.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return keys
    }

    /// "%lld", "%@", "%1$@" 등을 순서 무관하게 센다
    static func specifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d\$)?(lld|@|d|%)"#)
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .filter { $0 != "%" }
            .sorted()
    }
}
