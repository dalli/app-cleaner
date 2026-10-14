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

    /// Homebrew 배치: `libexec/appcleaner` + `libexec/AppCleaner_CleanerCore.bundle`, `bin/appcleaner -> ../libexec/appcleaner`
    @Test func symlinkedExecutableFindsBundleNextToRealBinary() throws {
        let fx = try Fixture()
        let libexec = fx.base.appendingPathComponent("prefix/libexec")
        let bin = try fx.dir(fx.base.appendingPathComponent("prefix/bin"))
        let realExe = try fx.file(libexec.appendingPathComponent("appcleaner"))
        let bundle = libexec.appendingPathComponent(BundledResources.bundleName)
        try fx.file(bundle.appendingPathComponent("RuleData/manifest.json"), text: #"{"version":"2001.2.3"}"#)
        try fx.file(bundle.appendingPathComponent("Scripts/\(PrivilegedScript.fileName)"), text: "#!/bin/sh\n")
        let link = bin.appendingPathComponent("appcleaner")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../libexec/appcleaner")

        // CLI의 Bundle.main은 링크가 있는 bin/을 기준으로 한다 — 그 옆에는 번들이 없다
        let dir = try #require(BundledRuleData.resourceDirectory(resourceURL: bin, executableURL: link))
        #expect(dir.path == BundledResources.resolvingSymlinks(bundle.appendingPathComponent("RuleData")).path)
        #expect(BundledRuleData.load(from: dir).version == "2001.2.3")
        let script = try #require(PrivilegedScript.bundledURL(resourceURL: bin, executableURL: link))
        #expect(script.path == BundledResources.resolvingSymlinks(
            bundle.appendingPathComponent("Scripts/\(PrivilegedScript.fileName)")).path)

        // 링크를 거치지 않은 실행은 실행 파일 폴더 그대로, 후보도 중복되지 않는다
        let direct = BundledResources.candidates("RuleData", resourceURL: nil, executableURL: BundledResources.resolvingSymlinks(realExe))
        #expect(direct.count == 2)
        let viaLink = BundledResources.candidates("RuleData", resourceURL: nil, executableURL: link)
        #expect(viaLink.count == 4)
        #expect(viaLink.prefix(2).allSatisfy { $0.path.hasPrefix(bin.path + "/") })
    }

    @Test func resolvingSymlinksFollowsChainsAndKeepsMissingPaths() throws {
        let fx = try Fixture()
        let real = try fx.file(fx.base.appendingPathComponent("real/tool"))
        let hop = try fx.symlink(fx.base.appendingPathComponent("hop/tool"), to: real)
        let outer = try fx.symlink(fx.base.appendingPathComponent("outer"), to: hop.deletingLastPathComponent())
        let resolved = BundledResources.resolvingSymlinks(outer.appendingPathComponent("tool"))
        #expect(resolved.path.hasSuffix("/real/tool"))
        #expect(resolved.path == BundledResources.resolvingSymlinks(real).path)
        let missing = fx.base.appendingPathComponent("nope/tool")
        #expect(BundledResources.resolvingSymlinks(missing) == missing)
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
