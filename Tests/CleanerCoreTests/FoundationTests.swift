import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct FoundationTests {
    @Test func confidenceOrderingAndDemotion() {
        #expect(Confidence.high > .medium)
        #expect(Confidence.high.demoted() == .medium)
        #expect(Confidence.low.demoted() == .low)
        #expect(Confidence.medium.capped(at: .low) == .low)
    }

    @Test func candidatesMergeByPath() {
        let url = URL(fileURLWithPath: "/tmp/x/com.foo.bar")
        let a = Candidate(url: url, category: .caches, confidence: .medium, evidence: [Evidence(.homebrewZap, .verbatim("zap"))])
        let b = Candidate(url: url, category: .caches, confidence: .high, evidence: [Evidence(.bundleIdentifier, .verbatim("bid"))])
        let merged = [a, b].mergedByPath()
        #expect(merged.count == 1)
        #expect(merged[0].confidence == .high)
        #expect(merged[0].evidence.count == 2)
    }

    @Test func fixtureStaysInsideTemporaryTree() throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Foo", bundleID: "com.example.foo",
                                 embedded: [.init("Contents/PlugIns/Share.appex", bundleID: "com.example.foo.share")])
        #expect(app.path.hasPrefix(fx.base.path))
        let info = try #require(BundleInfo.read(bundleAt: app))
        #expect(info.bundleID == "com.example.foo")
        #expect(info.executable == "Foo")
        #expect(!fx.paths.home.path.hasPrefix(NSHomeDirectory() + "/Library"))
    }

    @Test func bundledRuleDataLoads() {
        let rules = BundledRuleData.load()
        #expect(rules.version != "unknown")
        #expect(rules.isWeakName("Go"))
        #expect(rules.isWeakName("Code"))
        #expect(!rules.isWeakName("Slack"))
        #expect(rules.exclusions.alwaysExcludedPaths.contains("Library/Application Support/MobileSync"))
    }

    @Test func stubRunnerRecordsCalls() throws {
        let stub = StubCommandRunner()
        stub.on("pkgutil", stdout: "com.example.pkg\n")
        let out = try stub.run("/usr/sbin/pkgutil", ["--pkgs"])
        #expect(out.lines == ["com.example.pkg"])
        #expect(stub.calls.first?.arguments == ["--pkgs"])
    }

    @Test func planStepsSkipIrrelevant() {
        let plan = CleanupPlan(kind: .orphanCleanup, targetName: "x",
                               items: [Candidate(url: URL(fileURLWithPath: "/tmp/a"), category: .caches, confidence: .high, isSelected: true)],
                               ruleDataVersion: "t")
        #expect(plan.steps == [.moveItems])
        #expect(!plan.requiresAdmin)
    }
}
