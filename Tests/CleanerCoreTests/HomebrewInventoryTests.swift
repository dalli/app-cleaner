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
