import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct EngineTextTests {
    @Test func koreanTextKeepsPreviousWording() {
        #expect(EngineText(.executableMissing, "/Applications/Gone.app").text == "실행 파일 /Applications/Gone.app 없음")
        #expect(EngineText(.nameMatchInVendorFolder, "Google", "Chrome").text == "Google 폴더 안 이름 'Chrome' 일치")
        #expect(EngineText(.usedBy, "Excel").text == "Excel이 함께 사용 중")
        #expect(EngineText(.usedBy, "Google Drive").text == "Google Drive가 함께 사용 중")
        #expect(EngineText(.vendorAppsInstalledMore, "A", "2").text == "같은 개발사의 앱(A 외 2개)이 설치되어 있음")
        #expect(EngineText.verbatim("보호된 위치: /System").text == "보호된 위치: /System")
        #expect("\(EngineText(.maybeOnExternalVolume))" == "앱이 외장 볼륨에 있을 수 있음")
    }

    @Test func formatHandlesPositionsAndBadInput() {
        #expect(EngineText.format("%2$@ of %1$@", ["a", "b"]) == "b of a")
        #expect(EngineText.format("%@ and %@", ["a"]) == "a and ")
        #expect(EngineText.format("100%% %@", ["x"]) == "100% x")
        #expect(EngineText.format("%d %@", ["x"]) == "%d x")
        // 인자 안의 `%`는 해석하지 않는다
        #expect(EngineText.format("경로 %@", ["/tmp/%@"]) == "경로 /tmp/%@")
    }

    @Test func everyKeyHasKoreanFormat() {
        for key in EngineText.Key.allCases {
            #expect(!key.koreanFormat.isEmpty, "\(key)")
        }
    }

    @Test func codableRoundTripKeepsKeyAndArguments() throws {
        let keyed = EngineText(.bundleIDMatch, "com.example.foo")
        let data = try JSONEncoder().encode(keyed)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["key"] as? String == "bundleIDMatch")
        #expect(object["args"] as? [String] == ["com.example.foo"])
        #expect(object["text"] as? String == "번들 ID com.example.foo 일치")
        #expect(try JSONDecoder().decode(EngineText.self, from: data) == keyed)

        // verbatim은 평문 문자열로 저장한다 (이전 버전도 읽을 수 있게)
        let plain = try JSONEncoder().encode([EngineText.verbatim("메모")])
        #expect(String(decoding: plain, as: UTF8.self) == #"["메모"]"#)
        #expect(try JSONDecoder().decode([EngineText].self, from: plain) == [.verbatim("메모")])
    }

    @Test func unknownKeyFallsBackToStoredKoreanText() throws {
        let json = Data(#"{"key":"futureKey","args":["x"],"text":"새 문구 x"}"#.utf8)
        #expect(try JSONDecoder().decode(EngineText.self, from: json) == .verbatim("새 문구 x"))
    }

    /// 이전 버전 삭제 기록: 공유 사유가 평문 문자열
    @Test func legacyJournalWithPlainShareReasonStillLoads() async throws {
        let fx = try Fixture()
        let store = JournalStore(paths: fx.paths)
        let id = UUID()
        let legacy = """
        {
          "failures" : [ { "path" : "/x", "reason" : "실패" } ],
          "finishedAt" : "2026-09-01T10:00:05Z",
          "id" : "\(id.uuidString)",
          "items" : [
            {
              "category" : "groupContainer",
              "confidence" : 2,
              "destination" : "trash",
              "movedTo" : "/nonexistent/Trash/T.shared",
              "nature" : "settings",
              "originalPath" : "/u/Library/Group Containers/T.shared",
              "share" : { "shared" : { "reason" : "같은 App Group(T.shared)을 다른 앱도 사용", "usedBy" : [ "Excel" ] } },
              "size" : 10,
              "sources" : [ "appGroup" ]
            },
            {
              "category" : "caches",
              "confidence" : 2,
              "destination" : "trash",
              "movedTo" : "/nonexistent/Trash/com.example.foo",
              "nature" : "regenerable",
              "originalPath" : "/u/Library/Caches/com.example.foo",
              "share" : { "exclusive" : { } },
              "sources" : [ "bundleIdentifier" ]
            }
          ],
          "kind" : "appRemoval",
          "missingItems" : [ ],
          "preferencesBackups" : [ ],
          "ruleDataVersion" : "2026.09.1",
          "startedAt" : "2026-09-01T10:00:00Z",
          "status" : "restorable",
          "steps" : [ "moveItems" ],
          "stoppedServices" : [ ],
          "targetBundleID" : "com.example.foo",
          "targetName" : "Foo"
        }
        """
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: store.fileURL(for: id))

        let session = try #require(await store.session(id: id))
        #expect(session.items.count == 2)
        #expect(session.items[0].share == .shared(usedBy: ["Excel"], reason: .verbatim("같은 App Group(T.shared)을 다른 앱도 사용")))
        #expect(session.items[1].share == .exclusive)

        // 새로 쓰는 기록은 키로 저장하고 다시 읽힌다
        var updated = session
        updated.items[0].share = .shared(usedBy: ["Excel"], reason: EngineText(.sharedAppGroup, "T.shared"))
        try await store.record(updated)
        let reloaded = try #require(await store.session(id: id))
        #expect(reloaded.items[0].share == .shared(usedBy: ["Excel"], reason: EngineText(.sharedAppGroup, "T.shared")))
    }
}
