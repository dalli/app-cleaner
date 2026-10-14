import Foundation
import Testing
@testable import appcleaner
import CleanerCore

/// CLI 출력 언어 (ko·en·ja)와 번역 표
@Suite struct CLILocalizationTests {
    private func run(_ command: Command, _ language: AppLanguage, engine: RecordingEngine = sampleEngine()) async -> String {
        var output = ""
        let cli = CLI(engine: engine, language: language, out: { output += $0 + "\n" }, err: { output += $0 + "\n" })
        _ = await cli.run(command)
        return output
    }

    @Test func versionPrintsInEachLanguage() async {
        #expect(await run(.version, .ko) == "appcleaner \(CLIVersion.current) (규칙 데이터 t)\n")
        #expect(await run(.version, .en) == "appcleaner \(CLIVersion.current) (rule data t)\n")
        #expect(await run(.version, .ja) == "appcleaner \(CLIVersion.current) (ルールデータ t)\n")
    }

    @Test func scanPrintsInEachLanguage() async {
        let engine = sampleEngine()
        engine.report.candidates[2].notes = [EngineText(.usedBy, "Bar")]
        let ko = await run(.scan(app: "Foo", json: false, showAll: true), .ko, engine: engine)
        #expect(ko.contains("선택 2개 · "))
        #expect(ko.contains("/ 찾은 항목 4개\n"))
        #expect(ko.contains("[신뢰도 높음 · 재생성 가능]"))
        #expect(ko.contains("      Bar가 함께 사용 중\n"))
        #expect(ko.contains("Bar이(가) 함께 사용 중]"))
        #expect(ko.contains("아무것도 지우지 않았습니다."))

        let en = await run(.scan(app: "Foo", json: false, showAll: true), .en, engine: engine)
        #expect(en.contains("Selected 2 · "))
        #expect(en.contains("/ found 4 items\n"))
        #expect(en.contains("[confidence high · regenerable]"))
        #expect(en.contains("      Also used by Bar\n"))
        #expect(en.contains("also used by Bar]"))
        #expect(en.contains("Nothing was removed."))
        #expect(!LocalizationTables.containsHangul(en))

        let ja = await run(.scan(app: "Foo", json: false, showAll: true), .ja, engine: engine)
        #expect(ja.contains("選択 2 個 · "))
        #expect(ja.contains("[信頼度 高 · 再生成可能]"))
        #expect(ja.contains("      Bar も使用中\n"))
        #expect(ja.contains("何も削除していません。"))
        #expect(!LocalizationTables.containsHangul(ja))
    }

    @Test func orphansAndErrorsPrintInEachLanguage() async {
        let engine = sampleEngine()
        engine.orphanReport.groups[0].items[0].evidence = [Evidence(.inventory, EngineText(.bundleIDAppNotInstalled, "com.gone"))]
        let en = await run(.orphans(options: OrphanScanOptions(), json: false), .en, engine: engine)
        #expect(en.contains("Gone (deleted) — "))
        #expect(en.contains("3 items, confidence high"))
        #expect(en.contains("Evidence: No installed app has bundle ID com.gone"))
        #expect(!LocalizationTables.containsHangul(en))
        let ja = await run(.orphans(options: OrphanScanOptions(), json: false), .ja, engine: engine)
        #expect(ja.contains("Gone (削除済み) — "))
        #expect(ja.contains("根拠: バンドル ID com.gone の App がインストールされていない"))
        #expect(!LocalizationTables.containsHangul(ja))

        // 사용법 오류도 출력 언어로
        #expect(await run(.scan(app: "Nope", json: false, showAll: false), .en).contains("Couldn't find 'Nope' among installed apps."))
        #expect(UsageError("알 수 없는 명령: %@", "rm").message(.ja) == "不明なコマンド: rm")
        #expect(UsageError("알 수 없는 명령: %@", "rm").message(.ko) == "알 수 없는 명령: rm")
    }

    /// `--json`(과 `--dry-run` JSON)은 언어와 무관하게 같다
    @Test func jsonOutputIsLanguageIndependent() async {
        let engine = sampleEngine()
        engine.report.candidates[2].notes = [EngineText(.usedBy, "Bar")]
        let commands: [Command] = [.scan(app: "Foo", json: true, showAll: false), .orphans(options: OrphanScanOptions(), json: true),
                                   .remove(app: "Foo", dryRun: true, yes: false, json: false, resetPrivacy: false), .history(json: true)]
        for command in commands {
            let ko = await run(command, .ko, engine: engine)
            #expect(!ko.isEmpty)
            #expect(await run(command, .en, engine: engine) == ko)
            #expect(await run(command, .ja, engine: engine) == ko)
        }
    }

    // MARK: 언어 선택

    @Test func langOptionIsExtractedAnywhere() throws {
        let env = ["LANG": "ko_KR.UTF-8"]
        var r = CLILanguage.extract(["--lang", "ja", "scan", "Foo"], environment: env, preferredLanguages: [])
        #expect(r.language == .ja && r.rest == ["scan", "Foo"] && r.error == nil)
        r = CLILanguage.extract(["scan", "Foo", "--lang=en", "--json"], environment: env, preferredLanguages: [])
        #expect(r.language == .en && r.rest == ["scan", "Foo", "--json"])
        r = CLILanguage.extract(["version"], environment: env, preferredLanguages: [])
        #expect(r.language == .ko && r.rest == ["version"])
        // 잘못된 값: 오류는 환경으로 고른 언어로 보여 준다
        r = CLILanguage.extract(["--lang", "fr", "version"], environment: env, preferredLanguages: [])
        #expect(r.error != nil && r.language == .ko)
        r = CLILanguage.extract(["version", "--lang"], environment: env, preferredLanguages: [])
        #expect(r.error != nil)
        // 파서는 --lang을 보지 않는다
        let rest = CLILanguage.extract(["--lang", "en", "history", "--json"], environment: [:], preferredLanguages: []).rest
        #expect(try ArgumentParser.parse(rest) == .history(json: true))
    }

    @Test func environmentChoosesLanguageWithEnglishFallback() {
        func lang(_ env: [String: String], _ preferred: [String] = ["ko-KR"]) -> AppLanguage {
            CLILanguage.extract(["version"], environment: env, preferredLanguages: preferred).language
        }
        #expect(lang(["APPCLEANER_LANG": "ja"]) == .ja)
        #expect(lang(["APPCLEANER_LANG": "ja", "LANG": "en_US.UTF-8"]) == .ja)
        #expect(lang(["LANG": "fr_FR.UTF-8"]) == .en)
        #expect(lang(["LC_ALL": "ja_JP.UTF-8", "LANG": "ko_KR.UTF-8"]) == .ja)
        #expect(lang([:]) == .ko)
        #expect(lang([:], ["fr-FR", "de-DE"]) == .en)
        // --lang이 환경보다 우선
        #expect(CLILanguage.extract(["--lang", "ko"], environment: ["APPCLEANER_LANG": "ja"], preferredLanguages: []).language == .ko)
    }

    // MARK: 번역 표

    /// 소스의 모든 CLI 문구 키가 en·ja 번역(.strings 또는 .stringsdict)에 있고 형식 지정자가 원문과 맞는다
    @Test(arguments: [AppLanguage.en, .ja])
    func everyKeyIsTranslated(_ language: AppLanguage) throws {
        let keys = try LocalizationTables.sourceKeys()
        #expect(keys.count > 50)
        let strings = try LocalizationTables.load("CLI", "strings", language) as? [String: String] ?? [:]
        // 단·복수 구별이 없는 언어(ja)는 .stringsdict 없이 .strings에 둔다
        let plurals = try LocalizationTables.exists("CLI", "stringsdict", language) ? LocalizationTables.load("CLI", "stringsdict", language) : [:]
        let missing = keys.subtracting(strings.keys).subtracting(plurals.keys).sorted()
        #expect(missing.isEmpty, "\(language) CLI에 없는 키: \(missing)")
        let unused = Set(strings.keys).union(plurals.keys).subtracting(keys).subtracting(["usage"]).sorted()
        #expect(unused.isEmpty, "\(language) CLI에만 있는 키: \(unused)")
        #expect(Set(strings.keys).isDisjoint(with: plurals.keys))
        #expect(strings["usage"]?.contains("--lang") == true)
        for (key, value) in strings where key != "usage" {
            #expect(LocalizationTables.specifiersInOrder(key) == LocalizationTables.specifiersInOrder(value),
                    "형식 불일치(\(language)): \(key) → \(value)")
            #expect(!LocalizationTables.containsHangul(value), "번역에 한글이 남음(\(language)): \(key)")
        }
        // 복수형 항목: 원문 키의 인자로 채우면 지정자가 남지 않고, 영어는 1과 2가 다르다
        let t = CLIText(language: language)
        for key in plurals.keys {
            func render(_ n: Int) -> String {
                t.format(key, LocalizationTables.specifiersInOrder(key).map { $0 == "@" ? "X" as any CVarArg : n as any CVarArg })
            }
            #expect(!render(2).contains("%") && !LocalizationTables.containsHangul(render(2)), "\(language) \(key) → \(render(2))")
            if language == .en { #expect(render(1) != render(2), "\(key)") }
        }
    }

    @Test func usageIsTranslated() throws {
        let ko = try LocalizationTables.load("CLI", "strings", .ko) as? [String: String] ?? [:]
        #expect(ko.keys.sorted() == ["usage"])
        #expect(ArgumentParser.usage(.ko).hasPrefix("사용법: appcleaner"))
        #expect(ArgumentParser.usage(.en).hasPrefix("Usage: appcleaner"))
        #expect(ArgumentParser.usage(.ja).hasPrefix("使い方: appcleaner"))
    }
}

enum LocalizationTables {
    /// 소스의 CLI 문구 키 (`t("…")`, `outputText("…")`, `UsageError("…")`)
    static func sourceKeys() throws -> Set<String> {
        let dir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/appcleaner")
        let regex = try NSRegularExpression(pattern: #"\b(?:t|outputText|UsageError)\("((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                keys.insert(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: #"\""#, with: "\"")
                    .replacingOccurrences(of: #"\n"#, with: "\n"))
            }
        }
        return keys
    }

    static func exists(_ table: String, _ ext: String, _ language: AppLanguage) throws -> Bool {
        let dir = try #require(Translations.directory())
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(language.rawValue).lproj/\(table).\(ext)").path)
    }

    static func load(_ table: String, _ ext: String, _ language: AppLanguage) throws -> [String: Any] {
        let dir = try #require(Translations.directory())
        let url = dir.appendingPathComponent("\(language.rawValue).lproj/\(table).\(ext)")
        return try #require(NSDictionary(contentsOf: url) as? [String: Any], "\(url.path)")
    }

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
        s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }
}
