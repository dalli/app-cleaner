import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct HomebrewInventoryTests {
    func receipt(_ fx: Fixture, _ url: URL, _ json: [String: Any]) throws {
        try fx.file(url, text: String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
    }

    @Test func readsFormulaeFromCellarReceipts() throws {
        let fx = try Fixture()
        let cellar = fx.root("opt/homebrew/Cellar")
        try receipt(fx, cellar.appendingPathComponent("gh/2.80.0/INSTALL_RECEIPT.json"),
                    ["installed_on_request": true, "time": 1_790_814_025])
        // 여러 버전이면 가장 높은 버전 (문자열 순서가 아니라 버전 순서)
        try receipt(fx, cellar.appendingPathComponent("openssl@3/3.9.0/INSTALL_RECEIPT.json"), ["installed_on_request": false])
        try receipt(fx, cellar.appendingPathComponent("openssl@3/3.10.1/INSTALL_RECEIPT.json"), ["installed_on_request": false])
        // 예전 기록: installed_on_request 없이 installed_as_dependency만
        try receipt(fx, cellar.appendingPathComponent("libpng/1.6.50/INSTALL_RECEIPT.json"), ["installed_as_dependency": true])
        // 기록이 없으면 직접 설치로 본다
        try fx.dir(cellar.appendingPathComponent("legacy/1.0"))
        // 숨김 폴더·빈 폴더는 항목이 아니다
        try fx.dir(cellar.appendingPathComponent(".keepme/1.0"))
        try fx.dir(cellar.appendingPathComponent("empty"))

        let items = HomebrewInventory(paths: fx.paths).items()
        #expect(items.map(\.name) == ["gh", "legacy", "libpng", "openssl@3"])
        #expect(items.allSatisfy { $0.kind == .formula })

        let gh = try #require(items.first { $0.name == "gh" })
        #expect(gh.version == "2.80.0")
        #expect(gh.installedOnRequest)
        #expect(gh.installedAt == Date(timeIntervalSince1970: 1_790_814_025))
        #expect(gh.contentPaths.map(\.standardizedFileURL.path) == [cellar.appendingPathComponent("gh").path])
        #expect(gh.uninstallCommand == "brew uninstall gh")

        let openssl = try #require(items.first { $0.name == "openssl@3" })
        #expect(openssl.version == "3.10.1")
        #expect(!openssl.installedOnRequest)
        #expect(items.first { $0.name == "libpng" }?.installedOnRequest == false)
        #expect(items.first { $0.name == "legacy" }?.installedOnRequest == true)
    }

    /// `.app`이 없는 cask(CLI·폰트)도 항목이다 — 앱 목록에서 Homebrew가 0으로 보이던 경우
    @Test func readsCasksIncludingNonAppCasks() throws {
        let fx = try Fixture()
        let room = fx.root("opt/homebrew/Caskroom")
        try receipt(fx, room.appendingPathComponent("gcloud-cli/.metadata/INSTALL_RECEIPT.json"), [
            "installed_on_request": true, "source": ["version": "545.0.0"],
            "uninstall_artifacts": [["binary": ["gcloud"]]],
        ])
        try fx.dir(room.appendingPathComponent("gcloud-cli/545.0.0"))
        try fx.symlink(room.appendingPathComponent("gcloud-cli/latest"), to: room.appendingPathComponent("gcloud-cli/545.0.0"))
        try fx.dir(room.appendingPathComponent("font-nanum-gothic/2.005"))

        let app = try fx.makeApp(name: "Docker", bundleID: "com.docker.docker")
        try receipt(fx, room.appendingPathComponent("docker/.metadata/INSTALL_RECEIPT.json"), [
            "source": ["version": "4.34.2"], "uninstall_artifacts": [["app": ["Docker.app"]]],
        ])
        try fx.dir(room.appendingPathComponent("docker/4.34.2"))

        let items = HomebrewInventory(paths: fx.paths).items()
        #expect(items.map(\.name) == ["docker", "font-nanum-gothic", "gcloud-cli"])
        #expect(items.allSatisfy { $0.kind == .cask && $0.installedOnRequest })

        let gcloud = try #require(items.first { $0.name == "gcloud-cli" })
        #expect(gcloud.version == "545.0.0")
        #expect(gcloud.apps.isEmpty)
        #expect(gcloud.uninstallCommand == "brew uninstall --cask gcloud-cli")
        // 기록이 없으면 버전 폴더 이름
        #expect(items.first { $0.name == "font-nanum-gothic" }?.version == "2.005")

        let docker = try #require(items.first { $0.name == "docker" })
        #expect(docker.apps == ["Docker.app"])
        #expect(docker.contentPaths.map(\.standardizedFileURL.path)
                == [room.appendingPathComponent("docker").path, app.standardizedFileURL.path])
    }

    func related(_ item: HomebrewItem?, _ kind: HomebrewRelatedPath.Kind) -> Set<String> {
        Set((item?.related ?? []).filter { $0.kind == kind }.map { real($0.url) })
    }

    /// 상위 폴더만 실제 경로로 (마지막 구성요소가 링크면 링크 자체)
    func real(_ url: URL) -> String {
        SafetyGuard.realpathOfExistingPrefix(url.deletingLastPathComponent().path) + "/" + url.lastPathComponent
    }

    @Test func collectsRelatedPathsForFormulae() throws {
        let fx = try Fixture()
        let brew = fx.root("opt/homebrew")
        let gh = brew.appendingPathComponent("Cellar/gh")
        try receipt(fx, gh.appendingPathComponent("2.80.0/INSTALL_RECEIPT.json"), ["installed_on_request": true])
        try fx.file(gh.appendingPathComponent("2.80.0/bin/gh"))
        let opt = try fx.symlink(brew.appendingPathComponent("opt/gh"), to: URL(fileURLWithPath: "../Cellar/gh/2.80.0"))
        let bin = try fx.symlink(brew.appendingPathComponent("bin/gh"), to: URL(fileURLWithPath: "../Cellar/gh/2.80.0/bin/gh"))
        let config = try fx.dir(fx.home(".config/gh"))
        let state = try fx.dir(fx.home(".local/state/gh"))
        let downloads = fx.home("Library/Caches/Homebrew/downloads")
        let bottle = try fx.file(downloads.appendingPathComponent("0f3c--gh--2.80.0.arm64_tahoe.bottle.tar.gz"))
        let manifest = try fx.file(downloads.appendingPathComponent("9a1b--gh-2.80.0.bottle_manifest.json"))
        // 이름이 gh로 시작하는 다른 formula의 캐시는 아니다
        try fx.file(downloads.appendingPathComponent("7c2d--ghostscript--10.05.bottle.tar.gz"))
        try fx.file(downloads.appendingPathComponent("5e6f--gh-cli-1.0.bottle_manifest.json"))

        let pg = brew.appendingPathComponent("Cellar/postgresql@17")
        try fx.dir(pg.appendingPathComponent("17.6"))
        let pgData = try fx.dir(brew.appendingPathComponent("var/postgresql@17"))
        let pgLog = try fx.file(brew.appendingPathComponent("var/log/postgresql@17.log"))
        let pgConfig = try fx.dir(fx.home("Library/Application Support/postgresql"))

        // 흔한 이름은 이름 기반 폴더를 찾지 않는다
        try fx.dir(brew.appendingPathComponent("Cellar/data/1.0"))
        try fx.dir(fx.home(".config/data"))

        let rules = RuleData(version: "t", commonNames: ["data"], exclusions: OrphanExclusions(), casks: [])
        let items = HomebrewInventory(paths: fx.paths).items(rules: rules)
        let ghItem = items.first { $0.name == "gh" }
        #expect(related(ghItem, .install) == [real(gh)])
        #expect(related(ghItem, .link) == [real(opt.deletingLastPathComponent()) + "/gh", real(bin.deletingLastPathComponent()) + "/gh"])
        #expect(related(ghItem, .data) == [real(config), real(state)])
        #expect(related(ghItem, .downloadCache) == [real(bottle), real(manifest)])
        #expect(related(ghItem, .prefixData).isEmpty)

        let pgItem = items.first { $0.name == "postgresql@17" }
        #expect(related(pgItem, .prefixData) == [real(pgData), real(pgLog)])
        #expect(related(pgItem, .data) == [real(pgConfig)])
        #expect(related(items.first { $0.name == "data" }, .data).isEmpty)
    }

    @Test func collectsZapFilesExecutableNamedDataAndCaskCache() throws {
        let fx = try Fixture()
        let brew = fx.root("opt/homebrew")
        let room = brew.appendingPathComponent("Caskroom/gcloud-cli")
        try receipt(fx, room.appendingPathComponent(".metadata/INSTALL_RECEIPT.json"), [
            "source": ["version": "545.0.0"],
            "uninstall_artifacts": [["binary": ["gcloud"]], ["zap": [["trash": ["~/.config/gcloud-zap", "~/Library/Caches/gcloud-*"]]]]],
        ])
        let exe = try fx.file(room.appendingPathComponent("545.0.0/google-cloud-sdk/bin/gcloud"))
        let link = try fx.symlink(brew.appendingPathComponent("bin/gcloud"), to: exe)
        let zapFile = try fx.dir(fx.home(".config/gcloud-zap"))
        let zapWild = try fx.dir(fx.home("Library/Caches/gcloud-logs"))
        // 실행 파일 이름(gcloud)으로 찾는 데이터 — cask 이름(gcloud-cli)과 다르다
        let data = try fx.dir(fx.home(".config/gcloud"))
        let cached = try fx.file(fx.home("Library/Caches/Homebrew/downloads/ab12--google-cloud-cli-darwin-arm.tar.gz"))
        try fx.symlink(fx.home("Library/Caches/Homebrew/Cask/gcloud-cli--545.0.0.tar.gz"), to: cached)

        let item = HomebrewInventory(paths: fx.paths).items().first { $0.name == "gcloud-cli" }
        #expect(related(item, .link) == [real(link.deletingLastPathComponent()) + "/gcloud"])
        #expect(related(item, .zap) == [real(zapFile), real(zapWild)])
        #expect(related(item, .data) == [real(data)])
        #expect(related(item, .downloadCache) == [real(cached)])
        #expect(item?.zapCommand == "brew uninstall --zap --cask gcloud-cli")
    }

    @Test func readsIntelPrefixAndEmptyWithoutHomebrew() throws {
        let fx = try Fixture()
        #expect(HomebrewInventory(paths: fx.paths).items().isEmpty)

        try receipt(fx, fx.root("usr/local/Cellar/wget/1.25.0/INSTALL_RECEIPT.json"), ["installed_on_request": true])
        try fx.dir(fx.root("usr/local/Caskroom/iterm2/3.5.0"))
        let items = HomebrewInventory(paths: fx.paths).items()
        #expect(items.map(\.name) == ["iterm2", "wget"])
        #expect(items.map(\.kind) == [.cask, .formula])
    }
}
