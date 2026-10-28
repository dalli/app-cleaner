import CryptoKit
import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 테스트용 규칙 데이터 서명기 (scripts/sign-rule-data.swift와 같은 형식)
struct RuleUpdateSigner {
    let key = Curve25519.Signing.PrivateKey()
    var verifier: RuleDataVerifier { RuleDataVerifier(publicKey: key.publicKey) }

    /// 파일들과 서명된 manifest를 만들어 [파일명: 바이트]로 돌려준다
    func bundle(version: String, files: [String: Data], updatedAt: String? = "2026-10-14T00:00:00Z") throws -> [String: Data] {
        var hashes: [String: String] = [:]
        for (name, data) in files { hashes[name] = RuleDataVerifier.sha256Hex(data) }
        let manifest = try JSONEncoder().encode(RuleManifest(version: version, files: hashes, updatedAt: updatedAt))
        var out = files
        out[RuleDataVerifier.manifestName] = manifest
        out[RuleDataVerifier.signatureName] = Data(try key.signature(for: manifest).base64EncodedString().utf8)
        return out
    }

    func write(_ bundle: [String: Data], to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in bundle { try data.write(to: dir.appendingPathComponent(name)) }
    }
}

func ruleJSON<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

/// 메모리 내 "원격 서버"
final class RuleUpdateFakeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data]
    private var _requested: [URL] = []
    var requested: [URL] { lock.lock(); defer { lock.unlock() }; return _requested }

    init(_ files: [String: Data]) { self.files = files }

    func set(_ name: String, _ data: Data?) { lock.lock(); files[name] = data; lock.unlock() }

    private func serve(_ url: URL) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        _requested.append(url)
        guard let d = files[url.lastPathComponent] else { throw URLError(.fileDoesNotExist) }
        return d
    }

    var fetch: RuleDataStore.Fetcher {
        { [self] url in try self.serve(url) }
    }
}

@Suite struct RuleUpdateTests {
    let remoteExclusions = OrphanExclusions(appleSystemNames: ["NewAppleThing"], alwaysExcludedPaths: [".newsecret"],
                                            vendorFolders: [], securityDotfiles: [".vault"], nonAppBundleIDPrefixes: [])
    let remoteCasks = [HomebrewCask(token: "newapp", names: ["New App"], apps: ["New App.app"], bundleIDs: ["com.example.newapp"])]
    let remoteStandalone = [StandaloneTool(name: "newtool", executables: ["~/.local/bin/newtool"], dataPaths: ["~/.newtool"])]

    func remoteFiles() throws -> [String: Data] {
        [
            "orphan-exclusions.json": try ruleJSON(remoteExclusions),
            "homebrew-casks.json": try ruleJSON(remoteCasks),
            "common-names.json": try ruleJSON(["widget"]),
            "standalone-tools.json": try ruleJSON(remoteStandalone),
        ]
    }

    @Test func embeddedPublicKeyIsValid() throws {
        let v = try RuleDataVerifier(publicKeyBase64: RuleDataVerifier.embeddedPublicKeyBase64)
        #expect(v.publicKey.rawRepresentation.count == 32)
        _ = RuleDataVerifier.embedded
    }

    @Test func acceptsValidSignedDirectory() throws {
        let fx = try Fixture()
        let signer = RuleUpdateSigner()
        let dir = fx.home("rules")
        try signer.write(try signer.bundle(version: "2099.1.1", files: try remoteFiles()), to: dir)
        let manifest = try signer.verifier.verify(directory: dir)
        #expect(manifest.version == "2099.1.1")
        #expect(manifest.files.count == 4)
        #expect(manifest.updatedDate != nil)
    }

    @Test func rejectsTamperedFile() throws {
        let fx = try Fixture()
        let signer = RuleUpdateSigner()
        let dir = fx.home("rules")
        try signer.write(try signer.bundle(version: "2099.1.1", files: try remoteFiles()), to: dir)
        // 제외 목록을 비워 MobileSync 등을 지울 수 있게 하려는 변조
        try ruleJSON(OrphanExclusions()).write(to: dir.appendingPathComponent("orphan-exclusions.json"))
        #expect(throws: RuleDataError.hashMismatch("orphan-exclusions.json")) { try signer.verifier.verify(directory: dir) }
    }

    @Test func rejectsTamperedManifest() throws {
        let fx = try Fixture()
        let signer = RuleUpdateSigner()
        let dir = fx.home("rules")
        var bundle = try signer.bundle(version: "2099.1.1", files: try remoteFiles())
        // 매니페스트의 해시를 변조한 파일에 맞게 고쳐도 서명이 맞지 않는다
        let evil = try ruleJSON(OrphanExclusions())
        bundle["orphan-exclusions.json"] = evil
        var manifest = try JSONDecoder().decode(RuleManifest.self, from: bundle[RuleDataVerifier.manifestName]!)
        manifest.files["orphan-exclusions.json"] = RuleDataVerifier.sha256Hex(evil)
        bundle[RuleDataVerifier.manifestName] = try ruleJSON(manifest)
        try signer.write(bundle, to: dir)
        #expect(throws: RuleDataError.signatureMismatch) { try signer.verifier.verify(directory: dir) }
        // 다른 키로 서명한 것도 거부
        let other = RuleUpdateSigner()
        let otherDir = fx.home("rules-other")
        try other.write(try other.bundle(version: "2099.1.1", files: try remoteFiles()), to: otherDir)
        #expect(throws: RuleDataError.signatureMismatch) { try signer.verifier.verify(directory: otherDir) }
    }

    @Test func rejectsMissingPiecesAndBadNames() throws {
        let fx = try Fixture()
        let signer = RuleUpdateSigner()
        let dir = fx.home("rules")
        var bundle = try signer.bundle(version: "1", files: ["../escape.json": Data("[]".utf8)])
        bundle.removeValue(forKey: "../escape.json")
        try signer.write(bundle, to: dir)
        #expect(throws: RuleDataError.invalidFileName("../escape.json")) { try signer.verifier.verify(directory: dir) }

        let dir2 = fx.home("rules2")
        var b2 = try signer.bundle(version: "1", files: try remoteFiles())
        b2.removeValue(forKey: "homebrew-casks.json")
        try signer.write(b2, to: dir2)
        #expect(throws: RuleDataError.missingFile("homebrew-casks.json")) { try signer.verifier.verify(directory: dir2) }

        let dir3 = fx.home("rules3")
        var b3 = try signer.bundle(version: "1", files: try remoteFiles())
        b3.removeValue(forKey: RuleDataVerifier.signatureName)
        try signer.write(b3, to: dir3)
        #expect(throws: RuleDataError.missingSignature) { try signer.verifier.verify(directory: dir3) }
    }

    @Test func storeUsesBundledDataWithoutUpdate() throws {
        let fx = try Fixture()
        let store = RuleDataStore(paths: fx.paths, verifier: RuleUpdateSigner().verifier)
        let bundled = BundledRuleData.load()
        #expect(store.current().version == bundled.version)
        #expect(!store.hasVerifiedUpdate)
        #expect(store.info().signatureVerified)
        #expect(store.info().caskCount == bundled.casks.count)
    }

    @Test func storeOverlaysVerifiedUpdateAddingOnly() throws {
        let fx = try Fixture()
        let signer = RuleUpdateSigner()
        let bundled = BundledRuleData.load()
        try signer.write(try signer.bundle(version: "2099.1.1", files: try remoteFiles()),
                         to: fx.paths.appDataDir.appendingPathComponent("RuleData"))
        let store = RuleDataStore(paths: fx.paths, verifier: signer.verifier)
        let data = store.current()
        #expect(store.hasVerifiedUpdate)
        #expect(data.version == "2099.1.1")
        #expect(data.signatureVerified)
        #expect(data.updatedAt != nil)
        // 원격 제외 목록에 없어도 기존 제외는 그대로 (추가만 가능)
        #expect(data.exclusions.alwaysExcludedPaths.contains("Library/Application Support/MobileSync"))
        #expect(data.exclusions.alwaysExcludedPaths.contains("Library/Mobile Documents"))
        #expect(data.exclusions.alwaysExcludedPaths.contains(".newsecret"))
        #expect(data.exclusions.securityDotfiles.contains(".ssh"))
        #expect(data.exclusions.securityDotfiles.contains(".vault"))
        #expect(data.exclusions.appleSystemNames.contains("NewAppleThing"))
        #expect(Set(bundled.exclusions.vendorFolders).isSubset(of: Set(data.exclusions.vendorFolders)))
        #expect(Set(bundled.exclusions.nonAppBundleIDPrefixes).isSubset(of: Set(data.exclusions.nonAppBundleIDPrefixes)))
        // 흔한 이름도 합집합, cask 스냅샷은 교체
        #expect(data.commonNames.isSuperset(of: bundled.commonNames))
        #expect(data.commonNames.contains("widget"))
        #expect(data.casks.map(\.token) == ["newapp"])
        #expect(data.standaloneTools.map(\.name) == ["newtool"])
        #expect(store.info() == RuleDataInfo(version: "2099.1.1", updatedAt: data.updatedAt, signatureVerified: true, caskCount: 1))
    }

    /// 번들 스냅샷에 설치 스크립트 도구가 들어 있고, 항목 구조가 올바르다
    @Test func bundledStandaloneToolsAreUsable() throws {
        let tools = BundledRuleData.load().standaloneTools
        #expect(!tools.isEmpty)
        for tool in tools {
            if tool.executables.isEmpty { Issue.record("실행 파일 경로가 비어 있음: \(tool.name)") }
            if tool.name.isEmpty { Issue.record("이름이 비어 있음") }
            for path in tool.executables + tool.versionFiles + tool.dataPaths {
                if !path.hasPrefix("~") && !path.hasPrefix("/") {
                    Issue.record("경로에 `~` 없이 상대 경로 사용: \(tool.name) → \(path)")
                }
                if path.contains("..") { Issue.record("경로에 `..` 사용: \(tool.name) → \(path)") }
            }
        }
        #expect(Set(tools.map(\.name)).count == tools.count, "이름이 중복된 도구")
        #expect(tools.contains { $0.dataPaths.contains("~/.config/opencode") })
    }

    @Test func storeIgnoresTamperedOrOlderUpdateOnDisk() throws {
        let fx = try Fixture()
        let signer = RuleUpdateSigner()
        let dir = fx.paths.appDataDir.appendingPathComponent("RuleData")
        try signer.write(try signer.bundle(version: "2099.1.1", files: try remoteFiles()), to: dir)
        try ruleJSON(OrphanExclusions()).write(to: dir.appendingPathComponent("orphan-exclusions.json"))
        let tampered = RuleDataStore(paths: fx.paths, verifier: signer.verifier)
        #expect(!tampered.hasVerifiedUpdate)
        #expect(tampered.current().version == BundledRuleData.load().version)

        try FileManager.default.removeItem(at: dir)
        try signer.write(try signer.bundle(version: "1999.1.1", files: try remoteFiles()), to: dir)
        let older = RuleDataStore(paths: fx.paths, verifier: signer.verifier)
        #expect(!older.hasVerifiedUpdate)
    }

    @Test func updateDownloadsVerifiesAndSwaps() async throws {
        let fx = try Fixture()
        let signer = RuleUpdateSigner()
        let server = RuleUpdateFakeServer(try signer.bundle(version: "2099.1.1", files: try remoteFiles()))
        let store = RuleDataStore(paths: fx.paths, verifier: signer.verifier)
        let info = try await store.update(from: URL(string: "https://rules.example.com/v1")!, fetch: server.fetch)
        #expect(info.version == "2099.1.1")
        #expect(info.signatureVerified)
        #expect(store.current().casks.map(\.token) == ["newapp"])
        #expect(fx.exists(store.updateDirectory.appendingPathComponent("manifest.sig")))
        #expect(server.requested.allSatisfy { $0.scheme == "https" })
        // 임시 폴더가 남지 않는다
        let leftovers = FileManager.default.children(of: fx.paths.appDataDir).map(\.lastPathComponent).filter { $0.hasPrefix("RuleData.") }
        #expect(leftovers.isEmpty)

        // 두 번째 갱신으로 교체
        let server2 = RuleUpdateFakeServer(try signer.bundle(version: "2099.2.0", files: try remoteFiles()))
        _ = try await store.update(from: URL(string: "https://rules.example.com/v1")!, fetch: server2.fetch)
        #expect(store.current().version == "2099.2.0")
        #expect(RuleDataStore(paths: fx.paths, verifier: signer.verifier).current().version == "2099.2.0")
    }

    @Test func updateRejectsInsecureURL() async throws {
        let fx = try Fixture()
        let signer = RuleUpdateSigner()
        let server = RuleUpdateFakeServer(try signer.bundle(version: "2099.1.1", files: try remoteFiles()))
        let store = RuleDataStore(paths: fx.paths, verifier: signer.verifier)
        await #expect(throws: RuleDataError.insecureURL("http://rules.example.com/v1")) {
            try await store.update(from: URL(string: "http://rules.example.com/v1")!, fetch: server.fetch)
        }
        #expect(server.requested.isEmpty)
    }

    @Test func failedUpdateKeepsPreviousData() async throws {
        let fx = try Fixture()
        let signer = RuleUpdateSigner()
        let base = URL(string: "https://rules.example.com/v1")!
        let store = RuleDataStore(paths: fx.paths, verifier: signer.verifier)
        _ = try await store.update(from: base, fetch: RuleUpdateFakeServer(try signer.bundle(version: "2099.1.1", files: try remoteFiles())).fetch)

        // 파일 변조
        let tamperedServer = RuleUpdateFakeServer(try signer.bundle(version: "2099.3.0", files: try remoteFiles()))
        tamperedServer.set("orphan-exclusions.json", try ruleJSON(OrphanExclusions()))
        await #expect(throws: RuleDataError.hashMismatch("orphan-exclusions.json")) {
            try await store.update(from: base, fetch: tamperedServer.fetch)
        }
        // 매니페스트 변조
        let badManifest = RuleUpdateFakeServer(try signer.bundle(version: "2099.3.0", files: try remoteFiles()))
        badManifest.set(RuleDataVerifier.manifestName, try ruleJSON(RuleManifest(version: "2099.3.0", files: [:])))
        await #expect(throws: RuleDataError.signatureMismatch) { try await store.update(from: base, fetch: badManifest.fetch) }
        // 다운그레이드
        let downgrade = RuleUpdateFakeServer(try signer.bundle(version: "2099.0.1", files: try remoteFiles()))
        await #expect(throws: RuleDataError.downgrade(current: "2099.1.1", offered: "2099.0.1")) {
            try await store.update(from: base, fetch: downgrade.fetch)
        }
        // 내려받기 실패
        let missing = RuleUpdateFakeServer(try signer.bundle(version: "2099.3.0", files: try remoteFiles()))
        missing.set("homebrew-casks.json", nil)
        await #expect(throws: RuleDataError.self) { try await store.update(from: base, fetch: missing.fetch) }
        // 서명은 맞지만 내용이 해석되지 않음
        let garbage = RuleUpdateFakeServer(try signer.bundle(version: "2099.3.0", files: ["orphan-exclusions.json": Data("not json".utf8)]))
        await #expect(throws: RuleDataError.invalidContent("orphan-exclusions.json")) {
            try await store.update(from: base, fetch: garbage.fetch)
        }

        #expect(store.current().version == "2099.1.1")
        #expect(store.hasVerifiedUpdate)
        let reopened = RuleDataStore(paths: fx.paths, verifier: signer.verifier)
        #expect(reopened.current().version == "2099.1.1")
        #expect(reopened.current().exclusions.alwaysExcludedPaths.contains("Library/Application Support/MobileSync"))
        let leftovers = FileManager.default.children(of: fx.paths.appDataDir).map(\.lastPathComponent).filter { $0.hasPrefix("RuleData.") }
        #expect(leftovers.isEmpty)
    }

    @Test func addingOnlyCannotRemoveExclusions() {
        let base = BundledRuleData.load().exclusions
        let merged = base.addingOnly(OrphanExclusions())
        #expect(merged == base)
        let shrinking = OrphanExclusions(appleSystemNames: ["AddressBook"], alwaysExcludedPaths: [], vendorFolders: ["Adobe"],
                                         securityDotfiles: [], nonAppBundleIDPrefixes: [])
        let merged2 = base.addingOnly(shrinking)
        #expect(Set(base.alwaysExcludedPaths).isSubset(of: Set(merged2.alwaysExcludedPaths)))
        #expect(Set(base.securityDotfiles).isSubset(of: Set(merged2.securityDotfiles)))
        #expect(merged2.appleSystemNames.count == base.appleSystemNames.count)
        // 도구 데이터 소유 명령도 추가만: 기존 키의 명령은 남고 새 명령·새 키가 더해진다
        let tools = base.addingOnly(OrphanExclusions(toolDataOwners: ["Homebrew": ["brew2"], "newtool": ["nt"]])).toolDataOwners
        #expect(tools?["Homebrew"] == ["brew", "brew2"])
        #expect(tools?["newtool"] == ["nt"])
        #expect(base.addingOnly(OrphanExclusions()).toolDataOwners == base.toolDataOwners)
    }

    @Test func exclusionsWithoutToolDataOwnersStillDecode() throws {
        // `toolDataOwners`가 생기기 전의 원격 규칙 데이터도 읽을 수 있어야 한다
        let json = Data(#"{"appleSystemNames":[],"alwaysExcludedPaths":[],"vendorFolders":[],"securityDotfiles":[],"nonAppBundleIDPrefixes":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(OrphanExclusions.self, from: json)
        #expect(decoded.toolDataOwners == nil)
        #expect(BundledRuleData.load().exclusions.toolDataOwners?["Homebrew"] == ["brew"])
    }

    @Test func signScriptFormatMatchesVerifier() throws {
        // scripts/sign-rule-data.swift는 정렬된 키의 JSON(+updatedAt)을 쓰고 그 바이트에 서명한다 — 같은 형식을 검증기가 받는지
        let fx = try Fixture()
        let key = Curve25519.Signing.PrivateKey()
        let dir = fx.home("rules")
        try fx.dir(dir)
        let file = Data("[\"x\"]".utf8)
        try file.write(to: dir.appendingPathComponent("common-names.json"))
        let manifest: [String: Any] = ["version": "2099.9.9", "updatedAt": "2026-10-14T00:00:00Z",
                                       "files": ["common-names.json": RuleDataVerifier.sha256Hex(file)]]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("manifest.json"))
        try Data(try key.signature(for: data).base64EncodedString().utf8).write(to: dir.appendingPathComponent("manifest.sig"))
        let verified = try RuleDataVerifier(publicKey: key.publicKey).verify(directory: dir)
        #expect(verified.version == "2099.9.9")
    }
}
