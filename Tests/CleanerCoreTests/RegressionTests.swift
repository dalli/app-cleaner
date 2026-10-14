import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 기존 셸 스크립트 버그 재현 케이스 (plan.md 2.1, 9장 회귀 시나리오)
@Suite struct RegressionTests {
    /// #5: 짧은 이름 `Go` — 이름 기반 매칭은 Low·미선택, 부분 문자열 매칭 금지
    @Test func shortNameGo() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "Go", bundleID: "com.example.goapp")
        let byName = [fx.home("Library/Application Support/Go"), fx.home("Library/Caches/go"), fx.home("Library/Logs/GO"), fx.home(".go")]
        for u in byName { try fx.dir(u) }
        let unrelated = [fx.home("Library/Application Support/Google"), fx.home("Library/Application Support/GoLand"),
                         fx.home("Library/Caches/com.google.Chrome"), fx.home("Library/Caches/golang"), fx.home(".gopls")]
        for u in unrelated { try fx.dir(u) }
        let own = try fx.dir(fx.home("Library/Caches/com.example.goapp"))

        let report = try await ScanKit.scanner(fx).scan(appAt: app, inventory: InventorySnapshot(apps: []))
        for u in byName {
            let c = try #require(report.candidates.item(u), "\(u.lastPathComponent)")
            #expect(c.confidence == .low)
            #expect(!c.isSelected)
        }
        for u in unrelated { #expect(report.candidates.item(u) == nil, "\(u.lastPathComponent)") }
        #expect(report.candidates.item(own)?.isSelected == true)
    }

    /// #5: 흔한 이름 `Code`, `Mail`
    @Test func commonNamesCodeAndMail() async throws {
        let fx = try Fixture()
        let code = try fx.makeApp(name: "Code", bundleID: "com.microsoft.VSCode", displayName: "Code")
        try fx.dir(fx.home("Library/Application Support/Code/User"))
        try fx.dir(fx.home("Library/Logs/Code"))
        try fx.dir(fx.home("Library/Application Support/Xcode"))
        try fx.dir(fx.home("Library/Application Support/Code - Insiders"))
        try fx.dir(fx.home("Library/Caches/com.microsoft.VSCode.ShipIt"))
        try fx.dir(fx.home("Library/Caches/com.apple.dt.Xcode"))

        let r1 = try await ScanKit.scanner(fx).scan(appAt: code, inventory: InventorySnapshot(apps: []))
        let support = try #require(r1.candidates.item(fx.home("Library/Application Support/Code")))
        #expect(support.confidence == .low)
        #expect(!support.isSelected)
        #expect(support.notes.contains(SelectionPolicy.Notes.lowName))
        #expect(r1.candidates.item(fx.home("Library/Logs/Code"))?.isSelected == false)
        #expect(r1.candidates.item(fx.home("Library/Application Support/Xcode")) == nil)
        #expect(r1.candidates.item(fx.home("Library/Application Support/Code - Insiders")) == nil)
        #expect(r1.candidates.item(fx.home("Library/Caches/com.apple.dt.Xcode")) == nil)
        #expect(r1.candidates.item(fx.home("Library/Caches/com.microsoft.VSCode.ShipIt"))?.isSelected == true)

        let mail = try fx.makeApp(name: "Mail", bundleID: "com.example.mailclient")
        try fx.dir(fx.home("Library/Mail/V10"))
        try fx.dir(fx.home("Library/Containers/com.apple.mail"))
        try fx.dir(fx.home("Library/Application Support/Mail"))
        let r2 = try await ScanKit.scanner(fx).scan(appAt: mail, inventory: InventorySnapshot(apps: []))
        #expect(r2.candidates.item(fx.home("Library/Mail")) == nil)
        #expect(r2.candidates.item(fx.home("Library/Containers/com.apple.mail")) == nil)
        let m = try #require(r2.candidates.item(fx.home("Library/Application Support/Mail")))
        #expect(m.confidence == .low)
        #expect(!m.isSelected)
    }

    /// #6: 공백 포함 이름
    @Test func nameWithSpaces() async throws {
        let fx = try Fixture()
        let app = try fx.makeApp(name: "My App", bundleID: "com.example.my-app")
        let support = try fx.dir(fx.home("Library/Application Support/My App"))
        let caches = try fx.dir(fx.home("Library/Caches/my app"))
        try fx.dir(fx.home("Library/Application Support/My"))
        try fx.dir(fx.home("Library/Application Support/App"))
        try fx.dir(fx.home("Library/Application Support/My App Helper"))
        let agent = try fx.makeLaunchPlist(at: fx.home("Library/LaunchAgents/launcher.plist"), label: "launcher",
                                           arguments: ["/bin/sh", "-c", "exec \"\(app.path)/Contents/MacOS/My App\" --hidden"])

        let report = try await ScanKit.scanner(fx).scan(appAt: app, inventory: InventorySnapshot(apps: []))
        #expect(report.candidates.item(support)?.confidence == .medium)
        #expect(report.candidates.item(support)?.isSelected == true)
        #expect(report.candidates.item(caches)?.isSelected == true)
        for n in ["My", "App", "My App Helper"] {
            #expect(report.candidates.item(fx.home("Library/Application Support/\(n)")) == nil, "\(n)")
        }
        let a = try #require(report.candidates.item(agent))
        #expect(a.confidence == .high)
        #expect(a.isSelected)
        #expect(FileManager.default.fileExists(atPath: support.path), "검사는 아무것도 옮기지 않는다")
    }

    /// #3: 이름에 `$(…)` — 어떤 것도 실행되지 않아야 한다
    @Test func commandSubstitutionInNameIsNeverExecuted() async throws {
        let fx = try Fixture()
        let evil = "$(touch pwned)"
        let app = try fx.makeApp(name: evil, bundleID: "com.example.injection", executable: "$(touch pwned2)")
        let support = try fx.dir(fx.home("Library/Application Support/\(evil)"))
        try fx.dir(fx.home(".\(evil)"))
        try fx.file(fx.home("Library/Logs/DiagnosticReports/\(evil)-2026.ips"))
        let runner = StubCommandRunner()
        runner.on("mdfind", stdout: "\(app.path)\n")

        let cwd = FileManager.default.currentDirectoryPath
        let report = try await ScanKit.scanner(fx, runner: runner).scan(appAt: app, inventory: InventorySnapshot(apps: []))

        // 이름은 데이터로만 다뤄진다: 정확 일치 매칭과 키체인 검색어 그대로
        #expect(report.identity.name == evil)
        #expect(report.candidates.item(support) != nil)
        #expect(report.advisories.contains(.keychain(searchTerm: evil)))
        // 아무 파일도 생기지 않았다
        for dir in [fx.base, URL(fileURLWithPath: cwd)] {
            let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
            while let u = e?.nextObject() as? URL {
                #expect(u.lastPathComponent != "pwned" && u.lastPathComponent != "pwned2", "\(u.path)")
            }
        }
        // 외부 명령은 셸 없이 절대 경로 + 인자 배열로만 호출됐다
        #expect(!runner.calls.isEmpty)
        for call in runner.calls {
            #expect(call.executable.hasPrefix("/"))
            #expect(!LaunchPlist.shells.contains(call.executable), "\(call.executable)")
            #expect(!["sh", "bash", "zsh", "osascript"].contains(URL(fileURLWithPath: call.executable).lastPathComponent))
        }
        // Spotlight 질의에는 이름이 아니라 BID만 들어간다
        #expect(runner.calls.filter { $0.executable.hasSuffix("mdfind") }.allSatisfy { !$0.arguments.joined().contains("$(") })
    }

    /// #4: ToDesktop 공용 BID 접두사 — Cursor 제거가 다른 ToDesktop 앱의 캐시를 건드리면 안 된다
    @Test func toDesktopSharedVendorPrefix() async throws {
        let fx = try Fixture()
        let cursor = try fx.makeApp(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92")
        let own = [
            fx.home("Library/Caches/com.todesktop.230313mzl4w4u92"), fx.home("Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt"),
            fx.home("Library/HTTPStorages/com.todesktop.230313mzl4w4u92"),
            fx.home("Library/Saved Application State/com.todesktop.230313mzl4w4u92.savedState"),
        ]
        for u in own { try fx.dir(u) }
        try fx.file(fx.home("Library/Preferences/com.todesktop.230313mzl4w4u92.plist"))
        let other = [
            fx.home("Library/Caches/com.todesktop.999"), fx.home("Library/Caches/com.todesktop.999.ShipIt"),
            fx.home("Library/Application Support/com.todesktop.999"), fx.home("Library/HTTPStorages/com.todesktop.999"),
            fx.home("Library/Caches/com.todesktop.230313mzl4w4u92x"),
        ]
        for u in other { try fx.dir(u) }
        try fx.file(fx.home("Library/Preferences/com.todesktop.999.plist"))
        let cursorCask = try #require(ScanKit.bundled.casks.first { $0.token == "cursor" })

        let report = try await ScanKit.scanner(fx, casks: [cursorCask]).scan(appAt: cursor, inventory: InventorySnapshot(apps: []))
        for u in own { #expect(report.candidates.item(u)?.isSelected == true, "\(u.lastPathComponent)") }
        #expect(!report.candidates.paths.contains { $0.contains("com.todesktop.999") })
        for u in other { #expect(report.candidates.item(u) == nil, "\(u.lastPathComponent)") }
    }
}
