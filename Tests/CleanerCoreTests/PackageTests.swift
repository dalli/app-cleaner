import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 패키지 매니저로 설치한 CLI 도구 (docs/packages.md). 모든 파일은 픽스처 안에서만 만든다.
@Suite struct PackageTests {
    let fx: Fixture
    let rules = StaticRuleDataProvider(BundledRuleData.load())
    let fm = FileManager.default

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

    // MARK: 설치 스크립트 도구 (standalone)

    /// 설치 스크립트 도구 규칙 데이터. 번들 스냅샷에 의존하지 않도록 테스트에서 직접 준다
    let standaloneTools = [
        StandaloneTool(name: "omo", executables: ["~/.local/bin/omo", "~/.omo/bin/omo"],
                       versionFiles: ["~/.omo/VERSION"], dataPaths: ["~/.omo", "~/.config/omo"],
                       reinstall: "curl -fsSL https://example.invalid | bash"),
        StandaloneTool(name: "bun", executables: ["~/.bun/bin/bun"], dataPaths: ["~/.bun"]),
    ]

    func standaloneScanner() -> PackageScanner {
        var data = BundledRuleData.load()
        data.standaloneTools = standaloneTools
        return PackageScanner(paths: fx.paths, rules: StaticRuleDataProvider(data), safety: SafetyGuard(paths: fx.paths))
    }

    func standaloneScan(_ options: PackageScanOptions = PackageScanOptions(managers: [.standalone])) async -> PackageScanReport {
        await standaloneScanner().scan(options: options)
    }

    @Test func ruleDataToolIsHighAndSelected() async throws {
        try fx.file(fx.home(".local/bin/omo"), bytes: 2048)
        try fx.file(fx.home(".omo/VERSION"), text: "3.1.0\n")
        try fx.file(fx.home(".omo/state.json"), bytes: 100)
        try fx.file(fx.home(".config/omo/config.toml"), bytes: 10)

        let report = await standaloneScan()
        let p = try #require(report.packages.first { $0.package.name == "omo" })
        #expect(p.package.manager == .standalone)
        #expect(!p.package.isGuessed)
        #expect(p.package.version == "3.1.0")
        #expect(p.package.reinstallHint == "curl -fsSL https://example.invalid | bash")
        #expect(p.package.executables == ["omo"])
        #expect(canon(p.package.installPaths) == canon([fx.home(".local/bin/omo")]))
        #expect(p.installCandidates.allSatisfy { $0.confidence == .high && $0.isSelected })
        #expect(p.notes.map(\.key) == [.standaloneNoRecord, .standaloneReinstall])
        // 규칙 데이터가 정한 데이터 폴더만 — 이름이 같은 다른 폴더는 건드리지 않는다
        #expect(Set(p.dataCandidates.map(\.url.lastPathComponent)) == [".omo", "omo"])
        #expect(p.dataCandidates.allSatisfy { $0.confidence == .low && !$0.isSelected
            && $0.evidence.first?.source == .standaloneScript })
    }

    @Test func missingExecutableMeansNotInstalled() async throws {
        // 데이터만 있고 실행 파일이 없으면 설치된 도구가 아니다 (고아 스캔 영역)
        try fx.file(fx.home(".omo/state.json"), bytes: 100)
        let report = await standaloneScan()
        #expect(report.packages.isEmpty)
    }

    /// 규칙 데이터가 정한 데이터 폴더 안쪽에 실행 파일이 있어도 (`~/.omo/bin/omo` + `~/.omo`) 둘 다 보여 준다
    @Test func ruleDataPathInsideInstallLocationIsStillShown() async throws {
        try fx.file(fx.home(".omo/bin/omo"), bytes: 512)
        try fx.file(fx.home(".omo/cache/x"), bytes: 10)
        let report = await standaloneScan()
        let p = try #require(report.packages.first { $0.package.name == "omo" })
        #expect(p.dataCandidates.map(\.url.lastPathComponent) == [".omo"])
        #expect(canon(p.package.installPaths) == canon([fx.home(".omo/bin/omo")]))
    }

    /// 매니저 폴더(bun 전역 설치 루트 등)는 이름이 맞아도 데이터가 아니다 — 옮기면 매니저 구조째 사라진다
    @Test func managerRootIsNeverData() async throws {
        try fx.file(fx.home(".bun/install/global/node_modules/widget/package.json"),
                    text: #"{"name": "widget", "version": "1.0.0"}"#)
        let report = await standaloneScan()
        #expect(report.packages.flatMap(\.dataCandidates).isEmpty)
        // bun 전역 설치 목록에는 직접 의존성만 나온다
        let bun = try #require(PackageInventory(paths: fx.paths).packages(PackageScanOptions(managers: [.bun]))
            .first { $0.name == "widget" })
        #expect(bun.installPaths.map(\.lastPathComponent) == ["widget"])
    }

    @Test func unmanagedExecutableIsLowAndUnselected() async throws {
        try fx.file(fx.home(".local/bin/omo"), bytes: 64)
        // 실행 파일만 있고 규칙 데이터에 없는 이름
        let exe = fx.home(".local/bin/agy")
        try fx.file(exe, bytes: 128)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        // 링크는 짐작하지 않는다 (대상만 옮기면 다른 프로그램을 망가뜨릴 수 있다)
        try fx.file(fx.home("elsewhere/thing"), bytes: 8)
        try fx.symlink(fx.home(".local/bin/linked"), to: fx.home("elsewhere/thing"))
        // 디렉터리·숨김 파일·실행 권한 없는 파일은 제외
        try fx.dir(fx.home(".local/bin/subdir"))
        try fx.file(fx.home(".local/bin/plain"), bytes: 8)

        let report = await standaloneScan()
        let names = Set(report.packages.map(\.package.name))
        #expect(names == ["omo", "agy"])
        let guessed = try #require(report.packages.first { $0.package.name == "agy" })
        #expect(guessed.package.isGuessed)
        #expect(guessed.installCandidates.allSatisfy { $0.confidence == .low && !$0.isSelected })
        #expect(guessed.installCandidates.first?.evidence.first?.detail.key == .standaloneGuessed)
        // 짐작한 항목은 이름 추측 데이터가 붙는다
        #expect(guessed.dataCandidates.allSatisfy { !$0.isSelected })
    }

    /// 다른 매니저가 이미 설명하는 실행 파일 링크는 자동 탐지에서 다시 나오지 않는다
    @Test func guessedStandaloneSkipsManagerLinks() async throws {
        try npmPackage(prefix: fx.home(".local"), name: "widget", bins: ["widget"])
        try fx.file(fx.home(".cargo/bin/rg"), bytes: 64)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.home(".cargo/bin/rg").path)

        let report = await standaloneScan()
        #expect(report.packages.map(\.package.name).isEmpty)
    }

    /// 관리자 소유 bin 폴더의 실행 파일은 옮길 수 없으므로 자동 탐지하지 않는다 (규칙 데이터로만 잡힌다)
    @Test func readOnlyBinDirIsNotAutoDetected() async throws {
        let bin = try fx.dir(fx.root("usr/local/bin"))
        let tool = bin.appendingPathComponent("kind")
        try fx.file(tool, bytes: 64)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bin.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path) }

        let report = await standaloneScan()
        #expect(report.packages.isEmpty)
    }

    /// 설치 항목·데이터를 휴지통으로 옮겼다가 되돌렸을 때 그대로 돌아온다
    @Test func standaloneRemoveAndRestoreRoundTrip() async throws {
        let h = try Harness(fx: fx)
        try fx.file(fx.home(".local/bin/omo"), bytes: 512)
        try fx.file(fx.home(".omo/state.json"), bytes: 64)

        let report = await standaloneScan(PackageScanOptions(managers: [.standalone]))
        let p = try #require(report.packages.first)
        let plan = CleanupPlanner.plan(for: report, selectedPaths: Set(p.candidates.map(\.path)))
        #expect(Set(plan.items.map(\.path)) == [fx.home(".local/bin/omo").path, fx.home(".omo").path])

        let result = await h.executor.execute(plan, progress: { _ in }, onUnresponsive: { _ in .skip })
        #expect(result.failures.isEmpty, "\(result.failures)")
        #expect(!fx.exists(fx.home(".local/bin/omo")) && !fx.exists(fx.home(".omo")))

        let restore = await h.journal.restore(sessionID: result.sessionID, itemPaths: nil,
                                             options: RestoreOptions(reregisterServices: false))
        #expect(restore.failures.isEmpty, "\(restore.failures)")
        #expect(fx.exists(fx.home(".local/bin/omo")) && fx.exists(fx.home(".omo/state.json")))
    }

    @Test func standaloneManagerFilterIsHonored() async throws {
        try fx.file(fx.home(".local/bin/omo"), bytes: 64)
        try npmPackage(prefix: fx.home(".nvm/versions/node/v22.0.0"), name: "widget", bins: ["widget"])
        let onlyNpm = await standaloneScan(PackageScanOptions(managers: [.npm], computeSizes: false))
        #expect(onlyNpm.packages.map(\.package.name) == ["widget"])
        let all = await standaloneScan()
        #expect(all.packages.map(\.package.name).contains("omo"))
    }

// MARK: bun · pnpm

    /// `~/.bun/install/global` 구조 — 직접 의존성만, 실행 파일 링크는 `~/.bun/bin`
    @discardableResult
    func bunPackage(name: String, version: String = "1.0.0", bins: [String] = [], record: Bool = true) throws -> URL {
        let dir = fx.home(".bun/install/global/node_modules/\(name)")
        try fx.file(dir.appendingPathComponent("package.json"), text: #"{"name": "\#(name)", "version": "\#(version)"}"#)
        for bin in bins {
            try fx.file(dir.appendingPathComponent("bin/\(bin).js"), text: "#!/usr/bin/env node")
            try fx.symlink(fx.home(".bun/bin/\(bin)"), to: dir.appendingPathComponent("bin/\(bin).js"))
        }
        if record {
            try fx.file(fx.home(".bun/install/global/package.json"),
                        text: #"{"dependencies": {"\#(name)": "^\#(version)"}}"#)
        }
        return dir
    }

    @Test func bunGlobalShowsOnlyDirectDependencies() async throws {
        try bunPackage(name: "omo-ai", version: "5.1.19", bins: ["omo"])
        // 전이 의존성 — `omo-ai`가 쓰고 있으므로 지울 수 있는 항목이 아니다
        let transitive = fx.home(".bun/install/global/node_modules/kind-of")
        try fx.file(transitive.appendingPathComponent("package.json"), text: #"{"name": "kind-of", "version": "3.2.2"}"#)

        let report = await scan(PackageScanOptions(managers: [.bun], includeData: false, computeSizes: false))
        #expect(report.packages.map(\.package.name) == ["omo-ai"])
        let p = try #require(report.packages.first)
        #expect(p.package.version == "5.1.19")
        #expect(p.package.rootLabel == "~/.bun/install/global")
        #expect(p.package.executables == ["omo"])
        #expect(canon(p.package.installPaths) == canon([fx.home(".bun/install/global/node_modules/omo-ai"),
                                                       fx.home(".bun/bin/omo")]))
    }

    /// 기록(`package.json`)을 못 읽으면 전이 의존성까지 모두 보여 준다 — 숨기는 쪽이 더 위험하다
    @Test func bunWithoutRecordShowsEverything() async throws {
        try bunPackage(name: "omo-ai", record: false)
        let report = await scan(PackageScanOptions(managers: [.bun], includeData: false, computeSizes: false))
        #expect(report.packages.map(\.package.name) == ["omo-ai"])
    }

    /// 잠금 파일이 따로 있어 폴더만 옮겨도 되살아난다 → 옮기지 않고 제거 명령만 안내한다
    @Test func bunGlobalIsCommandOnly() async throws {
        try bunPackage(name: "omo-ai", bins: ["omo"])
        let report = await scan(PackageScanOptions(managers: [.bun], includeData: false, computeSizes: false))
        let p = try #require(report.packages.first)
        #expect(!p.isRemovable)
        #expect(p.installCandidates.allSatisfy { $0.protection == .detectOnly && !$0.isSelected })
        #expect(p.installCandidates.allSatisfy { $0.notes.contains { $0.key == .packageCommandOnly
            && $0.args == ["bun remove -g omo-ai"] } })
        // 계획에 아무것도 들어가지 않는다 (옮기면 다음 전역 설치 때 되살아난다)
        let plan = CleanupPlanner.plan(for: report, selectedPaths: Set(p.candidates.map(\.path)))
        #expect(plan.items.isEmpty)
    }

    @Test func pnpmGlobalIsCommandOnly() async throws {
        let dir = fx.home("Library/pnpm/global/5/node_modules/widget")
        try fx.file(dir.appendingPathComponent("package.json"), text: #"{"name": "widget", "version": "2.0.0"}"#)
        try fx.file(dir.appendingPathComponent("cli.js"), text: "#!/usr/bin/env node")
        try fx.symlink(fx.home("Library/pnpm/widget"), to: dir.appendingPathComponent("cli.js"))
        try fx.file(fx.home("Library/pnpm/global/5/package.json"), text: #"{"dependencies": {"widget": "^2.0.0"}}"#)

        let report = await scan(PackageScanOptions(managers: [.pnpm], includeData: false, computeSizes: false))
        let p = try #require(report.packages.first)
        #expect(p.package.name == "widget")
        #expect(p.package.rootLabel == "pnpm 5")
        #expect(p.package.executables == ["widget"])
        #expect(!p.isRemovable)
        #expect(p.installCandidates.first?.notes.contains { $0.args == ["pnpm remove -g widget"] } == true)
    }

    @Test func bunAndPnpmCachesAreCleanable() async throws {
        try fx.file(fx.home(".bun/install/cache/pkg"), bytes: 100)
        try fx.file(fx.home("Library/pnpm/store/v10/files/x"), bytes: 50)
        let report = await scan(PackageScanOptions(includeData: false, computeSizes: false))
        let names = Set(report.caches.map(\.url.lastPathComponent))
        #expect(names.contains("cache"))
        #expect(names.contains("store"))
        #expect(report.caches.filter { $0.url.lastPathComponent == "store" }
            .allSatisfy { $0.isSelected && $0.nature == .regenerable && $0.category == .caches })
        let bunOnly = await scan(PackageScanOptions(managers: [.bun], includeData: false, computeSizes: false))
        #expect(bunOnly.caches.map(\.url.lastPathComponent) == ["cache"])
    }

    /// 전역 설치 폴더 자체는 보호된다 (매니저 구조를 통째로 옮기지 못하게) — 아래 항목만 옮긴다
    @Test func bunAndPnpmRootsAreProtected() {
        let safety = SafetyGuard(paths: fx.paths)
        for rel in [".bun", ".bun/bin", ".bun/install/global/node_modules", "Library/pnpm", "Library/pnpm/global"] {
            if case .allowed = safety.verdict(for: fx.home(rel), bundleID: nil) { Issue.record("보호되지 않음: \(rel)") }
        }
        // 다운로드 캐시는 옮길 수 있어야 한다
        for rel in [".bun/install/cache", "Library/pnpm/store"] {
            if case .blocked = safety.verdict(for: fx.home(rel), bundleID: nil) { Issue.record("옮길 수 없어야 함: \(rel)") }
        }
    }

    /// 기록이 없는 폴더는 `node_modules/<name>`이 아니라 `<name>`으로 보인다 (경로 끝 슬래시 비교 함정 회귀)
    @Test func folderNameFallbackIgnoresParentFolder() async throws {
        let node = fx.home(".nvm/versions/node/v22.0.0")
        // `package.json` 없이 폴더만 있는 경우 (설치 도구 흔함)
        try fx.dir(node.appendingPathComponent("lib/node_modules/loose"))
        let report = await scan(PackageScanOptions(managers: [.npm], includeData: false, computeSizes: false))
        let p = try #require(report.packages.first { $0.package.name == "loose" })
        #expect(p.package.version == nil)
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
