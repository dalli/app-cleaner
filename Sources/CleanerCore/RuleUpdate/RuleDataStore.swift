import Foundation

/// 규칙 데이터 저장소 (plan.md 4.6).
///
/// - 앱 번들의 기본 스냅샷(`BundledRuleData`)을 읽고, `paths.appDataDir/RuleData/`에 **서명 검증된** 갱신본이 있으면 덮어쓴다.
/// - 고아 제외 목록은 `addingOnly`로만 합친다 — 원격 데이터는 제외를 해제할 수 없다. 흔한 이름 목록도 합집합.
///   (보호 목록은 코드에 하드코딩되어 있으며 규칙 데이터로 바꿀 수 없다.)
/// - 갱신은 HTTPS로만, 임시 폴더에 받아 검증한 뒤 원자적으로 교체한다. 어떤 단계든 실패하면 이전 데이터를 유지한다.
public final class RuleDataStore: RuleDataProviding, @unchecked Sendable {
    public typealias Fetcher = @Sendable (URL) async throws -> Data

    /// 갱신본 위치 (`appDataDir/RuleData`)
    public let updateDirectory: URL
    private let bundledDirectory: URL?
    private let verifier: RuleDataVerifier
    private let lock = NSLock()
    private var data: RuleData
    private var verifiedUpdate: Bool

    static let commonNamesFile = "common-names.json"
    static let exclusionsFile = "orphan-exclusions.json"
    static let casksFile = "homebrew-casks.json"

    public init(paths: SystemPaths, bundledDirectory: URL? = BundledRuleData.resourceDirectory(),
                verifier: RuleDataVerifier = .embedded) {
        updateDirectory = paths.appDataDir.appendingPathComponent("RuleData", isDirectory: true)
        self.bundledDirectory = bundledDirectory
        self.verifier = verifier
        (data, verifiedUpdate) = Self.load(bundled: bundledDirectory, update: updateDirectory, verifier: verifier)
    }

    public func current() -> RuleData {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    /// 설정 화면(S7) 표시용
    public func info() -> RuleDataInfo {
        let d = current()
        return RuleDataInfo(version: d.version, updatedAt: d.updatedAt, signatureVerified: d.signatureVerified, caskCount: d.casks.count)
    }

    /// 갱신본이 적용돼 있는지
    public var hasVerifiedUpdate: Bool {
        lock.lock(); defer { lock.unlock() }
        return verifiedUpdate
    }

    /// 디스크에서 다시 읽는다 (갱신본 검증 포함)
    public func reload() {
        let loaded = Self.load(bundled: bundledDirectory, update: updateDirectory, verifier: verifier)
        lock.lock()
        (data, verifiedUpdate) = loaded
        lock.unlock()
    }

    // MARK: - 로드

    static func load(bundled: URL?, update: URL, verifier: RuleDataVerifier) -> (RuleData, Bool) {
        let base = BundledRuleData.load(from: bundled)
        guard FileManager.default.isDirectory(update),
              let manifest = try? verifier.verify(directory: update),
              // 앱 업데이트로 번들 데이터가 더 새로우면 예전 갱신본은 쓰지 않는다
              compareVersions(manifest.version, base.version) != .orderedAscending,
              let overlaid = try? overlay(base: base, directory: update, manifest: manifest) else {
            return (base, false)
        }
        return (overlaid, true)
    }

    /// 검증된 갱신본을 번들 데이터 위에 덮어쓴다.
    static func overlay(base: RuleData, directory: URL, manifest: RuleManifest) throws -> RuleData {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T? {
            guard manifest.files[name] != nil else { return nil }
            guard let raw = try? Data(contentsOf: directory.appendingPathComponent(name)) else { throw RuleDataError.missingFile(name) }
            do { return try decoder.decode(type, from: raw) } catch { throw RuleDataError.invalidContent(name) }
        }
        var result = base
        result.version = manifest.version
        if let names = try decode([String].self, commonNamesFile) {
            result.commonNames = base.commonNames.union(names.map { $0.lowercased() })
        }
        if let remote = try decode(OrphanExclusions.self, exclusionsFile) {
            // 원격 데이터는 제외 항목을 추가만 할 수 있다 (plan.md 4.6)
            result.exclusions = base.exclusions.addingOnly(remote)
        }
        if let casks = try decode([HomebrewCask].self, casksFile) {
            result.casks = casks
        }
        result.signatureVerified = true
        result.updatedAt = manifest.updatedDate ?? FileDates.modified(directory.appendingPathComponent(RuleDataVerifier.manifestName))
        return result
    }

    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }

    // MARK: - 갱신

    /// `baseURL`(HTTPS)에서 `manifest.json`·`manifest.sig`와 매니페스트의 파일을 받아 검증 후 원자적으로 교체한다.
    /// 실패하면 예외를 던지고 이전 데이터를 그대로 유지한다.
    @discardableResult
    public func update(from baseURL: URL, fetch: @escaping Fetcher = RuleDataStore.urlSessionFetch) async throws -> RuleDataInfo {
        guard baseURL.scheme?.lowercased() == "https" else { throw RuleDataError.insecureURL(baseURL.absoluteString) }
        func get(_ name: String) async throws -> Data {
            do { return try await fetch(baseURL.appendingPathComponent(name)) } catch let e as RuleDataError { throw e } catch {
                throw RuleDataError.download("\(name): \(error.localizedDescription)")
            }
        }
        let manifestData = try await get(RuleDataVerifier.manifestName)
        let signature = try await get(RuleDataVerifier.signatureName)
        let manifest = try verifier.verifyManifest(manifestData, signature: signature)
        let currentVersion = current().version
        if Self.compareVersions(manifest.version, currentVersion) == .orderedAscending {
            throw RuleDataError.downgrade(current: currentVersion, offered: manifest.version)
        }

        let fm = FileManager.default
        let parent = updateDirectory.deletingLastPathComponent()
        let staging = parent.appendingPathComponent("RuleData.staging-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try manifestData.write(to: staging.appendingPathComponent(RuleDataVerifier.manifestName))
            try signature.write(to: staging.appendingPathComponent(RuleDataVerifier.signatureName))
        } catch {
            throw RuleDataError.install(error.localizedDescription)
        }
        for (name, hash) in manifest.files.sorted(by: { $0.key < $1.key }) {
            let body = try await get(name)
            guard RuleDataVerifier.sha256Hex(body) == hash.lowercased() else { throw RuleDataError.hashMismatch(name) }
            do { try body.write(to: staging.appendingPathComponent(name)) } catch { throw RuleDataError.install(error.localizedDescription) }
        }
        // 디스크에 쓴 그대로 다시 검증하고, 내용이 해석되는지도 확인
        let verified = try verifier.verify(directory: staging)
        _ = try Self.overlay(base: BundledRuleData.load(from: bundledDirectory), directory: staging, manifest: verified)

        try swapInto(staging)
        reload()
        return info()
    }

    /// staging → updateDirectory 교체. 실패 시 이전 폴더를 되돌린다.
    private func swapInto(_ staging: URL) throws {
        let fm = FileManager.default
        let backup = updateDirectory.deletingLastPathComponent()
            .appendingPathComponent("RuleData.old-\(UUID().uuidString)", isDirectory: true)
        let hadPrevious = fm.itemExists(updateDirectory)
        do {
            if hadPrevious { try fm.moveItem(at: updateDirectory, to: backup) }
            do {
                try fm.moveItem(at: staging, to: updateDirectory)
            } catch {
                if hadPrevious { try? fm.moveItem(at: backup, to: updateDirectory) }
                throw error
            }
            if hadPrevious { try? fm.removeItem(at: backup) }
        } catch {
            throw RuleDataError.install(error.localizedDescription)
        }
    }

    /// URLSession 기반 기본 내려받기 (HTTPS 응답·상태 코드 200 확인, 리디렉션 후에도 HTTPS여야 함)
    public static let urlSessionFetch: Fetcher = { url in
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw RuleDataError.download("\(url.lastPathComponent): 응답 코드 \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        guard http.url?.scheme?.lowercased() == "https" else { throw RuleDataError.insecureURL(http.url?.absoluteString ?? "") }
        return data
    }
}
