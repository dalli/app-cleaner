import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 패키지 매니저로 설치한 CLI 도구 (docs/packages.md). 모든 파일은 픽스처 안에서만 만든다.
@Suite struct PackageTests {
    let fx: Fixture
    let rules = StaticRuleDataProvider(BundledRuleData.load())

    init() throws {
        fx = try Fixture()
    }

    func scanner() -> PackageScanner {
        PackageScanner(paths: fx.paths, rules: rules, safety: SafetyGuard(paths: fx.paths))
    }

    func scan(_ options: PackageScanOptions = PackageScanOptions()) async -> PackageScanReport {
        await scanner().scan(options: options)
    }

    /// `<prefix>/lib/node_modules/<name>` + `<prefix>/bin/<exe>` 링크
    @discardableResult
    func npmPackage(prefix: URL, name: String, version: String = "1.0.0", bins: [String] = []) throws -> URL {
        let dir = prefix.appendingPathComponent("lib/node_modules/\(name)")
        try fx.file(dir.appendingPathComponent("package.json"), text: #"{"name": "\#(name)", "version": "\#(version)"}"#)
        for bin in bins {
            try fx.file(dir.appendingPathComponent("bin/\(bin).js"), text: "#!/usr/bin/env node")
            let link = prefix.appendingPathComponent("bin/\(bin)")
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../lib/node_modules/\(name)/bin/\(bin).js")
        }
        return dir
    }

    func package(_ report: PackageScanReport, _ name: String) -> PackageReport? {
        report.packages.first { $0.package.name == name }
    }

    /// 픽스처(`/var`)와 엔진(`/private/var`) 표기 차이를 없앤 경로 — 마지막 구성요소(링크)는 따라가지 않는다
    func canon(_ urls: [URL]) -> [String] {
        urls.map { url in
            let p = SafetyGuard.normalize(url.path)
            return SafetyGuard.realpathOfExistingPrefix((p as NSString).deletingLastPathComponent) + "/" + (p as NSString).lastPathComponent
        }
    }

    // MARK: npm

    @Test func npmGlobalPackagesWithLinks() async throws {
        let node = fx.home(".nvm/versions/node/v22.0.0")
        try npmPackage(prefix: node, name: "@acme/tool-cli", version: "2.1.0", bins: ["acme"])
        try npmPackage(prefix: node, name: "npm", bins: ["npm"])
        try npmPackage(prefix: node, name: "corepack", bins: ["corepack"])
        try npmPackage(prefix: fx.root("opt/homebrew"), name: "brewed", bins: ["brewed"])
        // 다른 패키지를 가리키는 링크는 이 패키지의 것이 아니다
        try fx.symlink(node.appendingPathComponent("bin/stray"), to: fx.home("elsewhere/stray.js"))

        let report = await scan(PackageScanOptions(includeData: false, computeSizes: false))
        #expect(report.packages.map(\.package.name).sorted() == ["@acme/tool-cli", "brewed"])
        let tool = try #require(package(report, "@acme/tool-cli"))
        #expect(tool.package.version == "2.1.0")
        #expect(tool.package.rootLabel == "node v22.0.0")
        #expect(tool.package.executables == ["acme"])
        #expect(tool.package.installPaths.map(\.lastPathComponent) == ["tool-cli", "acme"])
        #expect(tool.isRemovable)
        #expect(tool.candidates.allSatisfy { $0.category == .package && $0.confidence == .high && $0.isSelected })
        #expect(package(report, "brewed")?.package.rootLabel == "Homebrew")
    }

    @Test func npmrcPrefixIsRead() async throws {
        try fx.file(fx.home(".npmrc"), text: "registry=https://example.invalid\nprefix=~/my-global\n")
        try npmPackage(prefix: fx.home("my-global"), name: "custom", bins: ["custom"])
        let report = await scan(PackageScanOptions(includeData: false, computeSizes: false))
        #expect(package(report, "custom")?.package.rootLabel == "~/my-global")
    }

    // MARK: cargo

    @Test func cargoInstallsFromCrates2() async throws {
        let json = #"""
        {"installs": {
          "ripgrep 14.1.0 (registry+https://github.com/rust-lang/crates.io-index)": {"bins": ["rg"]},
          "gone 1.0.0 (registry+https://github.com/rust-lang/crates.io-index)": {"bins": ["gone"]},
          "evil 0.1.0 (path+file:///x)": {"bins": ["../../outside"]}
        }}
        """#
        try fx.file(fx.home(".cargo/.crates2.json"), text: json)
        try fx.file(fx.home(".cargo/bin/rg"), bytes: 64)
        try fx.file(fx.home(".cargo/bin/cargo"), bytes: 64)   // rustup 프록시 — 설치 기록에 없음
        try fx.file(fx.home("outside"), bytes: 8)

        let report = await scan(PackageScanOptions(managers: [.cargo], includeData: false, computeSizes: false))
        #expect(report.packages.map(\.package.name) == ["ripgrep"])
        let rg = try #require(report.packages.first)
        #expect(rg.package.version == "14.1.0")
        #expect(canon(rg.package.installPaths) == canon([fx.home(".cargo/bin/rg")]))
        #expect(rg.notes.map(\.key) == [.cargoRecordRemains])
    }

    @Test func cargoLegacyCratesToml() {
        let parsed = PackageInventory.parseCratesToml("""
        [v1]
        "bat 0.24.0 (registry+https://github.com/rust-lang/crates.io-index)" = ["bat"]
        "multi 1.0.0 (registry+https://x)" = ["a", "b"]
        """)
        #expect(parsed.map(\.spec) == ["bat 0.24.0 (registry+https://github.com/rust-lang/crates.io-index)", "multi 1.0.0 (registry+https://x)"])
        #expect(parsed.map(\.bins) == [["bat"], ["a", "b"]])
    }

    // MARK: pipx · uv

    @Test func pipxVenvWithAppAndManPage() async throws {
        let venv = fx.home(".local/pipx/venvs/httpie")
        try fx.file(venv.appendingPathComponent("pipx_metadata.json"), text: #"""
        {"main_package": {"package": "httpie", "package_version": "3.2.2", "apps": ["http"], "man_pages": ["man1/http.1", "../../etc/passwd"]}}
        """#)
        try fx.file(venv.appendingPathComponent("bin/http"), text: "#!/bin/sh")
        try fx.file(venv.appendingPathComponent("share/man/man1/http.1"), text: ".TH")
        try fx.symlink(fx.home(".local/bin/http"), to: venv.appendingPathComponent("bin/http"))
        try fx.symlink(fx.home(".local/share/man/man1/http.1"), to: venv.appendingPathComponent("share/man/man1/http.1"))
        try fx.symlink(fx.home(".local/bin/unrelated"), to: fx.home("somewhere/else"))

        let report = await scan(PackageScanOptions(managers: [.pipx], includeData: false, computeSizes: false))
        let p = try #require(report.packages.first)
        #expect(p.package.name == "httpie")
        #expect(p.package.version == "3.2.2")
        #expect(p.package.executables == ["http"])
        #expect(canon(p.package.installPaths) == canon([venv, fx.home(".local/bin/http"), fx.home(".local/share/man/man1/http.1")]))
    }

    @Test func uvToolReceiptOnlyTakesLinksIntoToolDir() async throws {
        let tool = fx.home(".local/share/uv/tools/ruff-lsp")
        let site = tool.appendingPathComponent("lib/python3.12/site-packages")
        try fx.dir(site.appendingPathComponent("ruff_lsp-0.0.62.dist-info"))
        try fx.file(tool.appendingPathComponent("bin/ruff-lsp"), text: "#!/bin/sh")
        try fx.symlink(fx.home(".local/bin/ruff-lsp"), to: tool.appendingPathComponent("bin/ruff-lsp"))
        try fx.file(fx.home(".zshrc"), text: "# 사용자 파일")
        try fx.file(tool.appendingPathComponent("uv-receipt.toml"), text: """
        [tool]
        requirements = [{ name = "ruff-lsp" }]
        entrypoints = [
            { name = "ruff-lsp", install-path = "\(fx.home(".local/bin/ruff-lsp").path)", from = "ruff-lsp" },
            { name = "x", install-path = "\(fx.home(".zshrc").path)", from = "ruff-lsp" },
            { name = "gone", install-path = "\(fx.home(".local/bin/gone").path)", from = "ruff-lsp" },
        ]
        """)

        let report = await scan(PackageScanOptions(managers: [.uv], includeData: false, computeSizes: false))
        let p = try #require(report.packages.first)
        #expect(p.package.name == "ruff-lsp")
        #expect(p.package.version == "0.0.62")
        #expect(canon(p.package.installPaths) == canon([tool, fx.home(".local/bin/ruff-lsp")]))
    }

    // MARK: 데이터

    @Test func sameNameDataIsLowAndUnselected() async throws {
        let node = fx.home(".nvm/versions/node/v22.0.0")
        try npmPackage(prefix: node, name: "@acme/widget", bins: ["widget"])
        try npmPackage(prefix: node, name: "aws", bins: ["aws"])        // 보안 폴더 이름
        try npmPackage(prefix: node, name: "gh", bins: ["gh"])          // 짧은 이름
        try fx.file(fx.home(".widget/state.json"), bytes: 100)
        try fx.file(fx.home(".config/widget/config.toml"), bytes: 10)
        try fx.file(fx.home(".local/state/widget/log"), bytes: 10)
        try fx.file(fx.home(".cache/widget/blob"), bytes: 10)
        try fx.file(fx.home(".aws/credentials"), bytes: 10)
        try fx.file(fx.home(".config/gh/hosts.yml"), bytes: 10)

        let report = await scan()
        let widget = try #require(package(report, "@acme/widget"))
        let data = widget.dataCandidates
        #expect(Set(data.map(\.url.lastPathComponent)) == [".widget", "widget"])
        #expect(Set(data.map { $0.url.deletingLastPathComponent().lastPathComponent }) == ["home", ".config", "state", ".cache"])
        #expect(data.allSatisfy { $0.confidence == .low && !$0.isSelected && $0.evidence.first?.source == .name })
        #expect(data.first { $0.path.hasSuffix(".cache/widget") }?.category == .caches)
        #expect(package(report, "aws")?.dataCandidates.isEmpty == true)
        #expect(package(report, "gh")?.dataCandidates.isEmpty == true)
    }

    @Test func dataFoundByTwoInstallsIsShared() async throws {
        try npmPackage(prefix: fx.home(".nvm/versions/node/v20.0.0"), name: "widget", bins: ["widget"])
        try npmPackage(prefix: fx.home(".nvm/versions/node/v22.0.0"), name: "widget", bins: ["widget"])
        try fx.file(fx.home(".widget/x"), bytes: 10)
        let report = await scan()
        #expect(report.packages.count == 2)
        for r in report.packages {
            let c = try #require(r.dataCandidates.first)
            #expect(c.share.isShared)
        }
        #expect(report.packages(matching: report.packages[0].dataCandidates[0].path).count == 2)
        #expect(report.dataSize == report.packages[0].dataSize)
    }

    @Test func managerFoldersAreNeverData() async throws {
        // `local`이라는 패키지가 있어도 npm prefix인 ~/.local을 데이터로 보지 않는다
        try npmPackage(prefix: fx.home(".local"), name: "local-tool", bins: ["local"])
        try npmPackage(prefix: fx.home(".local"), name: "cargo-helper", bins: ["cargo"])
        try fx.file(fx.home(".cargo/bin/rustc"), bytes: 1)
        let report = await scan()
        #expect(report.packages.flatMap(\.dataCandidates).isEmpty)
        #expect(report.packages.first?.package.rootLabel == "~/.local")
    }

    // MARK: 권한·안전

    @Test func readOnlyPrefixIsDetectOnly() async throws {
        let prefix = fx.root("usr/local")
        let dir = try npmPackage(prefix: prefix, name: "rooted", bins: ["rooted"])
        let lib = dir.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lib.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lib.path) }

        let report = await scan(PackageScanOptions(includeData: false, computeSizes: false))
        let p = try #require(package(report, "rooted"))
        #expect(!p.isRemovable)
        #expect(p.installCandidates.allSatisfy { $0.protection == .detectOnly && !$0.isSelected })
        #expect(p.installCandidates.first?.notes.contains { $0.key == .packageNeedsAdmin && $0.args == ["npm uninstall -g rooted"] } == true)
        let plan = CleanupPlanner.plan(for: report, selectedPaths: Set(p.installCandidates.map(\.path)))
        #expect(plan.items.isEmpty)
    }

    @Test func containerFoldersAreProtected() {
        let guardian = SafetyGuard(paths: fx.paths)
        for rel in [".local/bin", ".local/state", ".local/pipx/venvs", ".local/share/uv/tools", ".cargo/bin"] {
            if case .allowed = guardian.verdict(for: fx.home(rel), bundleID: nil) { Issue.record("보호되지 않음: \(rel)") }
        }
        if case .blocked = guardian.verdict(for: fx.home(".local/bin/tool"), bundleID: nil) { Issue.record("링크는 옮길 수 있어야 함") }
    }

    // MARK: 캐시

    @Test func packageManagerCaches() async throws {
        try fx.file(fx.home(".npm/_cacache/index-v5/aa"), bytes: 1000)
        try fx.file(fx.home(".cargo/registry/cache/x.crate"), bytes: 500)
        try fx.file(fx.home(".cache/uv/wheels/y"), bytes: 10)
        let all = await scan()
        #expect(Set(all.caches.map { $0.url.lastPathComponent }) == ["_cacache", "cache", "uv"])
        #expect(all.caches.allSatisfy { $0.isSelected && $0.nature == .regenerable && $0.category == .caches })
        let npmOnly = await scan(PackageScanOptions(managers: [.npm]))
        #expect(npmOnly.caches.map(\.url.lastPathComponent) == ["_cacache"])
        #expect((npmOnly.caches.first?.size ?? 0) > 0)
    }

    // MARK: 계획 · 실행 · 되돌리기

    @Test func planNamesPackagesOrCaches() async throws {
        try npmPackage(prefix: fx.home(".nvm/versions/node/v22.0.0"), name: "widget", bins: ["widget"])
        try fx.file(fx.home(".npm/_cacache/a"), bytes: 10)
        let report = await scan()
        let w = try #require(package(report, "widget"))
        let plan = CleanupPlanner.plan(for: report, selectedPaths: Set(w.installCandidates.map(\.path)))
        #expect(plan.kind == .packageRemoval)
        #expect(plan.targetName == "widget")
        #expect(plan.items.count == 2)
        #expect(plan.steps == [.moveItems])
        #expect(!plan.requiresAdmin)

        let cachePlan = CleanupPlanner.plan(for: report, selectedPaths: Set(report.caches.map(\.path)))
        #expect(cachePlan.targetName == CleanupPlanner.packageCacheTargetName)
        #expect(cachePlan.items.map(\.category) == [.caches])
    }

    @Test func removeAndRestoreKeepsLinks() async throws {
        let h = try Harness(fx: fx)
        let node = fx.home(".nvm/versions/node/v22.0.0")
        let dir = try npmPackage(prefix: node, name: "widget", bins: ["widget"])
        let link = node.appendingPathComponent("bin/widget")
        try fx.file(fx.home(".widget/data"), bytes: 10)

        let report = await scan()
        let w = try #require(package(report, "widget"))
        let plan = CleanupPlanner.plan(for: report, selectedPaths: Set(w.candidates.map(\.path)))
        #expect(plan.items.count == 3)
        let result = await h.executor.execute(plan, progress: { _ in }, onUnresponsive: { _ in .skip })
        #expect(result.failures.isEmpty, "\(result.failures)")
        #expect(result.movedCount == 3)
        #expect(!fx.exists(dir) && !fx.exists(link) && !fx.exists(fx.home(".widget")))
        let session = try #require(await h.journal.sessions().first)
        #expect(session.kind == .packageRemoval)
        #expect(session.targetName == "widget")

        let restore = await h.journal.restore(sessionID: result.sessionID, itemPaths: nil, options: RestoreOptions(reregisterServices: false))
        #expect(restore.failures.isEmpty, "\(restore.failures)")
        #expect(fx.exists(dir) && fx.exists(fx.home(".widget/data")))
        #expect(FileManager.default.isSymlink(link))
        #expect(FileManager.default.fileExists(atPath: link.path))   // 링크 대상도 되살아남
    }
}
