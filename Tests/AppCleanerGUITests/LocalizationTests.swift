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
        let missing = keys.subtracting(en.keys).sorted()
        #expect(missing.isEmpty, "en.lproj에 없는 키: \(missing)")

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
