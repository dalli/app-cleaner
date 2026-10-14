import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 앱 제거 탐지 테스트 공용 도구 (픽스처 전용)
enum ScanKit {
    static let bundled = BundledRuleData.load()

    static func rules(casks: [HomebrewCask] = []) -> RuleData {
        RuleData(version: "test-rules", commonNames: bundled.commonNames, exclusions: bundled.exclusions, casks: casks)
    }

    static func provider(casks: [HomebrewCask] = []) -> StaticRuleDataProvider {
        StaticRuleDataProvider(rules(casks: casks))
    }

    static func resolver(_ fx: Fixture, runner: StubCommandRunner = StubCommandRunner(),
                         signatures: StubSignatureReader = StubSignatureReader(),
                         casks: [HomebrewCask] = []) -> IdentityResolver {
        IdentityResolver(paths: fx.paths, runner: runner, signatureReader: signatures, rules: provider(casks: casks))
    }

    static func scanner(_ fx: Fixture, runner: StubCommandRunner = StubCommandRunner(),
                        signatures: StubSignatureReader = StubSignatureReader(), casks: [HomebrewCask] = [],
                        safety: any SafetyChecking = AllowAllSafety(), isRunning: @escaping @Sendable (String) -> Bool = { _ in false },
                        hasFullDiskAccess: @escaping @Sendable () -> Bool = { true }) -> AppScanner {
        AppScanner.standard(paths: fx.paths, runner: runner, signatureReader: signatures, rules: provider(casks: casks),
                            safety: safety, isRunning: isRunning, hasFullDiskAccess: hasFullDiskAccess)
    }

    static func inventoryApp(_ name: String, bundleID: String, teamID: String? = nil, groups: [String] = [],
                             embedded: [String] = [], in fx: Fixture) -> InventoryApp {
        InventoryApp(url: fx.root("Applications/\(name).app"), bundleID: bundleID, name: name, teamID: teamID,
                     appGroups: groups, embeddedBundleIDs: embedded)
    }
}

extension Array where Element == Candidate {
    func item(_ url: URL) -> Candidate? {
        let p = url.standardizedFileURL.path
        return flatMap(\.flattened).first { $0.url.standardizedFileURL.path == p }
    }

    func items(named lastComponent: String) -> [Candidate] {
        flatMap(\.flattened).filter { $0.url.lastPathComponent == lastComponent }
    }

    var paths: Set<String> { Set(flatMap(\.flattened).map { $0.url.standardizedFileURL.path }) }
}

@Suite struct ScanningSupportTests {
    @Test func externalPathMappingStaysInFixture() throws {
        let fx = try Fixture()
        #expect(fx.paths.mapExternalPath("/Library/Foo") == fx.root("Library/Foo"))
        #expect(fx.paths.mapExternalPath("~/Library/Foo") == fx.home("Library/Foo"))
        #expect(fx.paths.mapExternalPath(fx.home("x").path)?.path == fx.home("x").path)
        #expect(fx.paths.mapExternalPath("relative") == nil)
        #expect(fx.paths.logicalPath(of: fx.root("Applications/Foo.app")) == "/Applications/Foo.app")
    }

    @Test func bundleIDBoundaryMatching() {
        #expect(BundleIDRules.matches("com.foo.bar", bundleID: "com.foo.bar"))
        #expect(BundleIDRules.matches("com.foo.bar.ShipIt", bundleID: "com.foo.bar"))
        #expect(BundleIDRules.matches("COM.FOO.BAR.plist", bundleID: "com.foo.bar"))
        #expect(!BundleIDRules.matches("com.foo.barista", bundleID: "com.foo.bar"))
        #expect(!BundleIDRules.matches("com.foo", bundleID: "com.foo.bar"))
        #expect(BundleIDRules.looksLikeBundleID("com.example.helper"))
        #expect(!BundleIDRules.looksLikeBundleID("helper"))
        #expect(!BundleIDRules.looksLikeBundleID("~/Library/Foo"))
        #expect(!BundleIDRules.isSafeComponent("../etc"))
    }
}
