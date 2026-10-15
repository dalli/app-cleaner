import Foundation
import Testing
@testable import CleanerCore

/// Sentinel 메뉴·알림 문구 (`S("…")`)가 en·ja `Sentinel.strings`(+ `.stringsdict`)에 모두 있는지
@Suite struct SentinelLocalizationTests {
    @Test(arguments: [AppLanguage.en, .ja])
    func everyKeyIsTranslated(_ language: AppLanguage) throws {
        let keys = try Self.sourceKeys()
        #expect(keys.count > 15)
        let strings = try Self.load("strings", language) as? [String: String] ?? [:]
        // 단·복수 구별이 없는 언어(ja)는 .stringsdict 없이 .strings에 둔다
        let plurals = try Self.exists("stringsdict", language) ? Self.load("stringsdict", language) : [:]
        let missing = keys.subtracting(strings.keys).subtracting(plurals.keys).sorted()
        #expect(missing.isEmpty, "\(language) Sentinel에 없는 키: \(missing)")
        let unused = Set(strings.keys).union(plurals.keys).subtracting(keys).sorted()
        #expect(unused.isEmpty, "\(language) Sentinel에만 있는 키: \(unused)")
        #expect(Set(strings.keys).isDisjoint(with: plurals.keys))
        for (key, value) in strings {
            #expect(Self.specifiers(key) == Self.specifiers(value), "형식 불일치(\(language)): \(key) → \(value)")
            #expect(!Self.containsHangul(value), "번역에 한글이 남음(\(language)): \(key)")
        }
        for key in plurals.keys {
            func render(_ n: Int) -> String {
                SentinelStrings.format(key, Self.specifiers(key).map { $0 == "@" ? "X" as any CVarArg : n as any CVarArg },
                                       language: language)
            }
            #expect(!render(2).contains("%") && !Self.containsHangul(render(2)), "\(language) \(key) → \(render(2))")
            if language == .en { #expect(render(1) != render(2), "\(key)") }
        }
    }

    /// 한국어는 키가 원문이므로 표가 없어도 그대로 나온다
    @Test func koreanUsesKeys() throws {
        #expect(try !Self.exists("strings", .ko))
        #expect(SentinelStrings.format("휴지통 감시 중", [], language: .ko) == "휴지통 감시 중")
    }

    // MARK: 도우미

    static func sourceKeys() throws -> Set<String> {
        let dir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/AppCleanerSentinel")
        let regex = try NSRegularExpression(pattern: #"\bS\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                keys.insert(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: #"\""#, with: "\""))
            }
        }
        return keys
    }

    static func url(_ ext: String, _ language: AppLanguage) throws -> URL {
        let dir = try #require(Translations.directory())
        return dir.appendingPathComponent("\(language.rawValue).lproj/\(SentinelStrings.table).\(ext)")
    }

    static func exists(_ ext: String, _ language: AppLanguage) throws -> Bool {
        FileManager.default.fileExists(atPath: try url(ext, language).path)
    }

    static func load(_ ext: String, _ language: AppLanguage) throws -> [String: Any] {
        let u = try url(ext, language)
        return try #require(NSDictionary(contentsOf: u) as? [String: Any], "\(u.path)")
    }

    static func specifiers(_ s: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d)\$)?(lld|@|d)"#)
        let ns = s as NSString
        var ordered: [(Int, String)] = []
        for (i, m) in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).enumerated() {
            let pos = m.range(at: 1).location == NSNotFound ? i : Int(ns.substring(with: m.range(at: 1)))! - 1
            ordered.append((pos, ns.substring(with: m.range(at: 2))))
        }
        return ordered.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func containsHangul(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }
}
