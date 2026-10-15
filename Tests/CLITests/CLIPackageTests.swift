import Foundation
import Testing
@testable import appcleaner
import CleanerCore

private func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

/// 설치 항목(높음·선택) + 데이터(낮음·미선택). `sharedWith`가 있으면 그 설치도 같은 데이터를 찾은 것으로 만든다.
private func npm(_ name: String, prefix: String, label: String, bins: [String], data: [String] = [], shared: Bool = false) -> PackageReport {
    let dir = url("\(prefix)/lib/node_modules/\(name)")
    let links = bins.map { url("\(prefix)/bin/\($0)") }
    let package = InstalledPackage(manager: .npm, name: name, version: "1.0.0", root: url(prefix), rootLabel: label,
                                   installPaths: [dir] + links, executables: bins)
    var candidates = ([dir] + links).map {
        Candidate(url: $0, category: .package, confidence: .high, isSelected: true, size: 10)
    }
    candidates += data.map {
        Candidate(url: url($0), category: .dotfile, confidence: .low,
                  share: shared ? .shared(usedBy: ["x"], reason: .verbatim("x")) : .exclusive, isSelected: false, size: 5)
    }
    return PackageReport(package: package, candidates: candidates)
}

private func packageEngine() -> RecordingEngine {
    let engine = sampleEngine()
    engine.packageReport = PackageScanReport(packages: [
        npm("@acme/widget", prefix: "/u/.nvm/versions/node/v22", label: "node v22", bins: ["widget"], data: ["/u/.widget"], shared: true),
        npm("@acme/widget", prefix: "/u/.local", label: "~/.local", bins: ["widget"], data: ["/u/.widget"], shared: true),
        npm("solo", prefix: "/u/.local", label: "~/.local", bins: ["solo"], data: ["/u/.solo", "/u/.config/solo"]),
    ], caches: [
        Candidate(url: url("/u/.npm/_cacache"), category: .caches, confidence: .high, nature: .regenerable, isSelected: true, size: 100),
    ], ruleDataVersion: "t")
    return engine
}

@Suite struct CLIPackageTests {
    @Test func parsesPackageCommands() throws {
        if case let .packages(opts, json) = try ArgumentParser.parse(["packages", "--manager", "npm,cargo", "--json"]) {
            #expect(opts.managers == [.npm, .cargo])
            #expect(json)
        } else { Issue.record("packages not parsed") }
        if case let .packagesRemove(targets, opts, withData, dryRun, yes, _) =
            try ArgumentParser.parse(["packages", "remove", "a", "b", "--with-data", "--dry-run", "--manager", "uv"]) {
            #expect(targets == ["a", "b"])
            #expect(opts.managers == [.uv] && opts.includeData)
            #expect(withData && dryRun && !yes)
        } else { Issue.record("packages remove not parsed") }
        if case let .packagesRemove(_, opts, withData, _, _, _) = try ArgumentParser.parse(["packages", "remove", "a"]) {
            #expect(!withData && !opts.includeData)
        } else { Issue.record("packages remove not parsed") }
        if case .packageCaches = try ArgumentParser.parse(["packages", "caches"]) {} else { Issue.record("caches") }
        if case let .packageCachesClean(_, dryRun, _, _) = try ArgumentParser.parse(["packages", "caches", "clean", "--dry-run"]) {
            #expect(dryRun)
        } else { Issue.record("caches clean") }
    }

    @Test func rejectsInvalidPackageArguments() {
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["packages", "remove"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["packages", "--manager", "brew"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["packages", "--manager"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["packages", "purge"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["packages", "caches", "nuke"]) }
        #expect(throws: UsageError.self) { try ArgumentParser.parse(["packages", "remove", "a", "--all"]) }
    }

    @Test func resolvesByNameManagerOrPath() throws {
        let engine = packageEngine()
        let cli = CLI(engine: engine, language: .ko, out: { _ in }, err: { _ in })
        let all = engine.packageReport.packages
        #expect(try cli.resolvePackage("solo", in: all).count == 1)
        #expect(try cli.resolvePackage("npm:SOLO", in: all).count == 1)
        #expect(throws: UsageError.self) { try cli.resolvePackage("cargo:solo", in: all) }
        // 이름이 같은 설치가 둘이면 경로로 지정하게 한다
        #expect(throws: UsageError.self) { try cli.resolvePackage("widget", in: all) }
        #expect(throws: UsageError.self) { try cli.resolvePackage("@acme/widget", in: all) }
        let byPath = try cli.resolvePackage("/u/.local/lib/node_modules/@acme/widget", in: all)
        #expect(byPath.map(\.package.rootLabel) == ["~/.local"])
        #expect(try cli.resolvePackage("/u/.local/bin/solo", in: all).first?.package.name == "solo")
        #expect(throws: UsageError.self) { try cli.resolvePackage("sol", in: all) }
    }

    @Test func removeMovesInstallFilesOnlyByDefault() async {
        let engine = packageEngine()
        let cli = CLI(engine: engine, language: .ko, out: { _ in }, err: { _ in }, confirm: { _ in true })
        let status = await cli.run(.packagesRemove(targets: ["solo"], options: PackageScanOptions(includeData: false), withData: false,
                                                   dryRun: false, yes: true, json: true))
        #expect(status == 0)
        let plan = engine.executedPlans.last
        #expect(plan?.kind == .packageRemoval)
        #expect(plan?.targetName == "solo")
        #expect(Set(plan?.items.map(\.path) ?? []) == ["/u/.local/lib/node_modules/solo", "/u/.local/bin/solo"])
        #expect(engine.packageScanOptions.last?.computeSizes == false)
    }

    @Test func withDataSkipsDataSharedWithAnotherInstall() async {
        let engine = packageEngine()
        var errors = ""
        let cli = CLI(engine: engine, language: .ko, out: { _ in }, err: { errors += $0 + "\n" }, confirm: { _ in true })
        _ = await cli.run(.packagesRemove(targets: ["solo", "/u/.local/lib/node_modules/@acme/widget"], options: PackageScanOptions(),
                                          withData: true, dryRun: false, yes: true, json: false))
        let moved = Set(engine.executedPlans.last?.items.map(\.path) ?? [])
        #expect(moved.isSuperset(of: ["/u/.solo", "/u/.config/solo", "/u/.local/lib/node_modules/@acme/widget"]))
        #expect(!moved.contains("/u/.widget"))
        #expect(errors.contains("다른 설치와 함께 쓰는 데이터라 남겨둡니다: /u/.widget"))

        // 같은 데이터를 찾은 설치를 모두 지우면 함께 옮긴다
        _ = await cli.run(.packagesRemove(targets: ["/u/.local/bin/widget", "/u/.nvm/versions/node/v22/bin/widget"],
                                          options: PackageScanOptions(), withData: true, dryRun: false, yes: true, json: true))
        #expect(engine.executedPlans.last?.items.map(\.path).contains("/u/.widget") == true)
    }

    @Test func dryRunPrintsOnlyJSON() async throws {
        let engine = packageEngine()
        var output = ""
        let cli = CLI(engine: engine, language: .ko, out: { output += $0 + "\n" }, err: { _ in })
        _ = await cli.run(.packagesRemove(targets: ["/u/.local/bin/widget"], options: PackageScanOptions(), withData: true,
                                          dryRun: true, yes: false, json: false))
        #expect(engine.executedPlans.isEmpty)
        let json = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        #expect((json?["summary"] as? [String: Any])?["itemCount"] as? Int == 2)
    }

    @Test func cachesCleanUsesCachesOnly() async {
        let engine = packageEngine()
        let cli = CLI(engine: engine, language: .ko, out: { _ in }, err: { _ in })
        _ = await cli.run(.packageCachesClean(options: PackageScanOptions(includeData: false), dryRun: false, yes: true, json: true))
        let plan = engine.executedPlans.last
        #expect(plan?.items.map(\.path) == ["/u/.npm/_cacache"])
        #expect(plan?.targetName == CleanupPlanner.packageCacheTargetName)
    }

    @Test func listsPackagesInEachLanguage() async {
        for language in AppLanguage.allCases {
            var output = ""
            let cli = CLI(engine: packageEngine(), language: language, out: { output += $0 + "\n" }, err: { _ in })
            _ = await cli.run(.packages(options: PackageScanOptions(), json: false))
            _ = await cli.run(.packageCaches(options: PackageScanOptions(), json: false))
            #expect(output.contains("@acme/widget 1.0.0"))
            #expect(output.contains("npm (~/.local)"))
            #expect(output.contains("/u/.npm/_cacache"))
            if language != .ko { #expect(!LocalizationTables.containsHangul(output), "\(language): \(output)") }
        }
    }
}
