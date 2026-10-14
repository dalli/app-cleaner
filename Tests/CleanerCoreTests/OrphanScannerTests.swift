import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 고아 스캔 픽스처 하네스: 가짜 홈·루트 + 실제 AppInventory(StubCommandRunner) + OrphanScanner
final class OrphanHarness: @unchecked Sendable {
    let fx: Fixture
    let runner = StubCommandRunner()
    let keepList: KeepListStoring
    private let lock = NSLock()
    private var _packages: [String: [String]] = [:]
    private var _extraSpotlight: [URL] = []
    private var _hideFromSpotlight: Set<String> = []
    private var _indexing = "Indexing enabled."

    init(keepList: KeepListStoring = InMemoryKeepList()) throws {
        fx = try Fixture()
        self.keepList = keepList
        let paths = fx.paths
        runner.on("mdfind") { [unowned self] _ in
            let standard = [paths.system("Applications"), paths.home("Applications")].flatMap { AppInventory.findApps(in: $0) }
            self.lock.lock(); defer { self.lock.unlock() }
            let apps = (standard + self._extraSpotlight).filter { !self._hideFromSpotlight.contains($0.lastPathComponent) }
            return CommandOutput(status: 0, stdout: Data(apps.map(\.path).joined(separator: "\n").utf8))
        }
        runner.on("mdutil") { [unowned self] args in
            self.lock.lock(); defer { self.lock.unlock() }
            return CommandOutput(status: 0, stdout: Data("\(args.last ?? "/"):\n\t\(self._indexing) \n".utf8))
        }
        runner.on("pkgutil") { [unowned self] args in
            self.lock.lock(); defer { self.lock.unlock() }
            if args == ["--pkgs"] {
                return CommandOutput(status: 0, stdout: Data(self._packages.keys.sorted().joined(separator: "\n").utf8))
            }
            if args.first == "--files", let id = args.last, let files = self._packages[id] {
                return CommandOutput(status: 0, stdout: Data(files.joined(separator: "\n").utf8))
            }
            return CommandOutput(status: 1, stdout: Data())
        }
    }

    var indexing: String {
        get { lock.lock(); defer { lock.unlock() }; return _indexing }
        set { lock.lock(); _indexing = newValue; lock.unlock() }
    }

    /// 표준 위치 밖의 앱을 Spotlight 결과에 추가
    func addToSpotlight(_ url: URL) {
        lock.lock(); _extraSpotlight.append(url); lock.unlock()
    }

    func hideFromSpotlight(_ appFileName: String) {
        lock.lock(); _hideFromSpotlight.insert(appFileName); lock.unlock()
    }

    /// 설치 패키지 영수증 (pkgutil --pkgs / --files + 영수증 plist)
    func addPackage(_ id: String, files: [String], prefix: String = "/") throws {
        lock.lock(); _packages[id] = files; lock.unlock()
        try fx.plist(fx.root("private/var/db/receipts/\(id).plist"), ["PackageIdentifier": id, "InstallPrefixPath": prefix])
    }

    /// 앞으로 30일 뒤를 "현재"로 써서 픽스처 파일이 "최근 수정" 강등을 받지 않게 한다
    static let future: @Sendable () -> Date = { Date().addingTimeInterval(30 * 86400) }

    func scan(options: OrphanScanOptions = OrphanScanOptions(),
              rules: RuleData = BundledRuleData.load(),
              now: @escaping @Sendable () -> Date = OrphanHarness.future,
              launchServices: @escaping LaunchServicesLookup = LaunchServicesRegistry.none,
              signatures: CodeSignatureReading = StubSignatureReader(),
              safety: SafetyChecking = AllowAllSafety(),
              classifier: DataNatureClassifying = PassthroughNatureClassifier(),
              computeSizes: Bool = false,
              events: EventRecorder? = nil) async throws -> OrphanScanReport {
        let inventory = AppInventory(paths: fx.paths, runner: runner, signatureReader: signatures, isRunning: { _ in false },
                                     lastUsed: { _ in nil }, launchServices: launchServices, now: now)
        let scanner = OrphanScanner(paths: fx.paths, runner: runner, inventory: inventory, rules: StaticRuleDataProvider(rules),
                                    safety: safety, classifier: classifier, keepList: keepList, launchServices: launchServices,
                                    now: now, computeSizes: computeSizes)
        return try await scanner.scan(options: options) { event in events?.record(event) }
    }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [OrphanScanEvent] = []
    func record(_ e: OrphanScanEvent) { lock.lock(); _events.append(e); lock.unlock() }
    var phases: [OrphanScanPhase] {
        lock.lock(); defer { lock.unlock() }
        return _events.compactMap { if case .phase(let p) = $0 { return p }; return nil }
    }
    var groups: [OrphanGroup] {
        lock.lock(); defer { lock.unlock() }
        return _events.compactMap { if case .groupFound(let g) = $0 { return g }; return nil }
    }
}

extension OrphanScanReport {
    var allItems: [Candidate] { groups.flatMap(\.items) }

    func item(_ url: URL) -> Candidate? {
        let p = url.standardizedFileURL.path
        return allItems.first { $0.url.standardizedFileURL.path == p }
    }

    func group(containing url: URL) -> OrphanGroup? {
        let p = url.standardizedFileURL.path
        return groups.first { $0.items.contains { $0.url.standardizedFileURL.path == p } }
    }

    func contains(_ url: URL) -> Bool { item(url) != nil }
}

/// 컨테이너를 사용자 데이터로 분류하는 테스트용 분류기
struct ContainerIsUserData: DataNatureClassifying {
    func classify(_ candidate: Candidate) -> Candidate {
        var c = candidate
        if c.category == .container { c.nature = .userData }
        return c
    }
}

/// 특정 경로를 막는 SafetyChecking
struct BlockingSafety: SafetyChecking {
    let blocked: Set<String>
    func verdict(for url: URL, bundleID: String?) -> SafetyVerdict {
        blocked.contains(url.standardizedFileURL.path) ? .blocked(.protectedPath, "test") : .allowed(resolved: url)
    }
}

@Suite struct OrphanScannerTests {
    @Test func emitsPhasesAndGroupsProgressively() async throws {
        let h = try OrphanHarness()
        try h.fx.makeLaunchPlist(at: h.fx.home("Library/LaunchAgents/com.example.gone.agent.plist"), label: "com.example.gone.agent",
                                 arguments: ["/Applications/Gone.app/Contents/MacOS/agent"])
        try h.fx.file(h.fx.home("Library/Preferences/com.example.other.plist"))
        let recorder = EventRecorder()
        let report = try await h.scan(computeSizes: true, events: recorder)
        #expect(recorder.phases == [.buildingInventory, .collectingCandidates, .judging, .finished])
        #expect(Set(recorder.groups.map(\.id)) == Set(report.groups.map(\.id)))
        #expect(report.groups.count == 2)
        #expect(report.ruleDataVersion == BundledRuleData.load().version)
        #expect(report.spotlight.isReliable)
        // 크기는 결과를 보낸 뒤 계산해 최종 보고서에만 채운다
        #expect(report.allItems.allSatisfy { $0.size != nil })
        #expect(report.duration >= 0)
    }

    @Test func reportsInventoryAppCount() async throws {
        let h = try OrphanHarness()
        try h.fx.makeApp(name: "One", bundleID: "com.example.one")
        try h.fx.makeApp(name: "Two", bundleID: "com.example.two", in: h.fx.home("Applications"))
        let report = try await h.scan()
        #expect(report.inventoryAppCount == 2)
        #expect(report.groups.isEmpty)
    }

    @Test func minimumConfidenceFilter() async throws {
        let h = try OrphanHarness()
        try h.fx.makeLaunchPlist(at: h.fx.home("Library/LaunchAgents/com.example.gone.agent.plist"), label: "com.example.gone.agent",
                                 arguments: ["/Applications/Gone.app/Contents/MacOS/agent"])
        try h.fx.file(h.fx.home("Library/Preferences/com.example.medium.plist"))
        try h.fx.dir(h.fx.home("Library/Application Support/Lowname"))
        let all = try await h.scan()
        #expect(Set(all.allItems.map(\.confidence)) == [.high, .medium, .low])
        let high = try await h.scan(options: OrphanScanOptions(minimumConfidence: .high))
        #expect(high.allItems.allSatisfy { $0.confidence == .high })
        #expect(high.groups.count == 1)
        let medium = try await h.scan(options: OrphanScanOptions(minimumConfidence: .medium))
        #expect(Set(medium.allItems.map(\.confidence)) == [.high, .medium])
    }

    @Test func userDataIsNeverSelectedByDefault() async throws {
        let h = try OrphanHarness()
        let container = try h.fx.makeContainer(bundleID: "com.example.notes.gone", documents: 2)
        let report = try await h.scan(classifier: ContainerIsUserData())
        let item = try #require(report.item(container))
        #expect(item.confidence == .high)
        #expect(item.nature == .userData)
        #expect(!item.isSelected)
    }

    @Test func safetyBlockedItemsAreDropped() async throws {
        let h = try OrphanHarness()
        let blocked = try h.fx.file(h.fx.home("Library/Preferences/com.example.blocked.plist"))
        let allowed = try h.fx.file(h.fx.home("Library/Preferences/com.example.allowed.plist"))
        let report = try await h.scan(safety: BlockingSafety(blocked: [blocked.standardizedFileURL.path]))
        #expect(!report.contains(blocked))
        #expect(report.contains(allowed))
    }

    @Test func unreadableRootProducesWarning() async throws {
        let h = try OrphanHarness()
        let root = try h.fx.dir(h.fx.home("Library/Group Containers"))
        try h.fx.dir(root.appendingPathComponent("group.com.example.x"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        let report = try await h.scan()
        let unreadable = report.warnings.flatMap { w -> [String] in
            if case .unreadable(let urls) = w { return urls.map(\.standardizedFileURL.path) }
            return []
        }
        #expect(unreadable == [root.standardizedFileURL.path])
    }

    @Test func usesFreshCachedInventoryOnlyWhenUnchanged() async throws {
        let h = try OrphanHarness()
        try h.fx.file(h.fx.home("Library/Preferences/com.example.late.plist"))
        func mdfindCalls() -> Int { h.runner.calls.filter { $0.executable.hasSuffix("mdfind") }.count }
        let first = try await h.scan(now: { Date() })
        #expect(first.allItems.contains { $0.url.lastPathComponent == "com.example.late.plist" })
        #expect(mdfindCalls() == 1)
        // 바뀐 것이 없으면 캐시 사용
        _ = try await h.scan(options: OrphanScanOptions(useCachedInventory: true), now: { Date() })
        #expect(mdfindCalls() == 1)
        // 캐시 이후 표준 위치에 앱이 설치되면 캐시를 버리고 다시 구축 (새 앱의 데이터를 고아로 오판하지 않음)
        try h.fx.makeApp(name: "Late", bundleID: "com.example.late")
        let afterInstall = try await h.scan(options: OrphanScanOptions(useCachedInventory: true), now: { Date() })
        #expect(mdfindCalls() == 2)
        #expect(!afterInstall.allItems.contains { $0.url.lastPathComponent == "com.example.late.plist" })
        // 캐시를 허용하지 않으면 항상 구축
        _ = try await h.scan(options: OrphanScanOptions(useCachedInventory: false), now: { Date() })
        #expect(mdfindCalls() == 3)
        // 오래된 캐시는 쓰지 않는다
        _ = try await h.scan(options: OrphanScanOptions(useCachedInventory: true), now: OrphanHarness.future)
        #expect(mdfindCalls() == 4)
    }

    @Test func groupKeysAreStable() async throws {
        let h = try OrphanHarness()
        try h.fx.file(h.fx.home("Library/Preferences/com.acme.widget.plist"))
        try h.fx.dir(h.fx.home("Library/Caches/com.acme.widget"))
        try h.fx.dir(h.fx.home("Library/Saved Application State/com.acme.widget.savedState"))
        let a = try await h.scan()
        let b = try await h.scan()
        #expect(a.groups.map(\.id) == b.groups.map(\.id))
        let g = try #require(a.groups.first)
        #expect(a.groups.count == 1)
        #expect(g.id == "bid:com.acme.widget")
        #expect(g.displayName == "Widget")
        #expect(g.nameIsGuess)
        #expect(g.items.count == 3)
    }
}
