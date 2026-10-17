import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

@Suite struct InstallerLeftoverTests {
    func selfApp(_ fx: Fixture, in dir: URL, version: String) throws -> URL {
        try fx.makeApp(name: "App Cleaner", bundleID: fx.paths.selfBundleID, in: dir, version: version)
    }

    func hdiutilInfo(_ images: [(image: String, mounts: [String])]) throws -> String {
        let plist: [String: Any] = ["images": images.map { image in
            ["image-path": image.image,
             "system-entities": [["dev-entry": "/dev/disk9"]] + image.mounts.map { ["dev-entry": "/dev/disk9s1", "mount-point": $0] }]
        }]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    func real(_ url: URL) -> String { SafetyGuard.realpathOfExistingPrefix(url.path) }

    @Test func findsMountedImagesInstallerFilesAndOldCopies() async throws {
        let fx = try Fixture()
        let downloads = fx.home("Downloads")
        let running = try selfApp(fx, in: fx.root("Applications"), version: "0.3.5")
        let oldCopy = try selfApp(fx, in: downloads, version: "0.3.0")
        let devBuild = try selfApp(fx, in: fx.home("works/app-cleaner/dist"), version: "0.1.0")
        let openCopy = try selfApp(fx, in: fx.home("Desktop"), version: "0.3.4")
        let trashed = try selfApp(fx, in: fx.paths.trash, version: "0.2.0")
        let nested = try selfApp(fx, in: fx.root("Applications/Tool.app/Contents/Resources"), version: "0.2.0")
        let other = try fx.makeApp(name: "Other", bundleID: "com.example.other", in: downloads)

        for name in ["AppCleaner-0.3.5-macos-arm64.dmg", "AppCleaner-0.3.3-macos-arm64 (1).dmg", "AppCleaner-0.3.0-macos-arm64.zip",
                     "appcleaner-0.3.5-macos-arm64.tar.gz",
                     // 릴리즈 산출물 이름이 아니면 건드리지 않는다
                     "AppCleaner-final.dmg", "AppCleanerNotes.txt", "OtherApp-1.0-macos-arm64.dmg"] {
            try fx.file(downloads.appendingPathComponent(name))
        }
        try fx.dir(downloads.appendingPathComponent("appcleaner-0.3.5-macos-arm64"))

        // 마운트된 이미지: 본 앱이 든 것만 꺼낼 대상, 그 안의 앱은 사본 후보가 아니다
        let mount = try fx.dir(fx.base.appendingPathComponent("mnt/App Cleaner"))
        let mountedApp = try selfApp(fx, in: mount, version: "0.3.5")
        let otherMount = try fx.dir(fx.base.appendingPathComponent("mnt/Other"))
        try fx.makeApp(name: "Other", bundleID: "com.example.other", in: otherMount)

        let runner = StubCommandRunner()
        let info = try hdiutilInfo([(downloads.appendingPathComponent("AppCleaner-0.3.5-macos-arm64.dmg").path, [mount.path]),
                                    ("/tmp/other.dmg", [otherMount.path])])
        runner.on("hdiutil", stdout: info)
        let indexed = [running, devBuild, openCopy, trashed, nested, mountedApp, other].map(\.path).joined(separator: "\n")
        runner.on("mdfind", stdout: indexed)

        let openKey = real(openCopy)
        let scanner = InstallerLeftoverScanner(paths: fx.paths, runner: runner, runningBundle: running,
                                               isRunningAt: { real($0) == openKey })
        let report = await scanner.scan(ruleDataVersion: "t")

        #expect(report.mounted.map { real($0.mountPoint) } == [real(mount)])
        #expect(report.mounted.first?.appVersion == "0.3.5")
        #expect(!report.runningOutsideApplications)

        let byName = Dictionary(report.candidates.map { (real($0.url), $0) }, uniquingKeysWith: { a, _ in a })
        let files = ["AppCleaner-0.3.5-macos-arm64.dmg", "AppCleaner-0.3.3-macos-arm64 (1).dmg", "AppCleaner-0.3.0-macos-arm64.zip",
                     "appcleaner-0.3.5-macos-arm64.tar.gz", "appcleaner-0.3.5-macos-arm64"].map { real(downloads.appendingPathComponent($0)) }
        let copies = [oldCopy, devBuild, openCopy].map(real)
        #expect(Set(byName.keys) == Set(files + copies))
        for f in files { #expect(byName[f]?.isSelected == true && byName[f]?.protection == nil) }

        // 다운로드 폴더의 이전 사본만 기본 선택. 본 앱 보호(selfApp)는 실행 중이 아닌 사본에서 풀린다
        #expect(byName[real(oldCopy)]?.isSelected == true)
        #expect(byName[real(oldCopy)]?.protection == nil)
        #expect(byName[real(devBuild)]?.isSelected == false)
        #expect(byName[real(devBuild)]?.notes.contains(EngineText(.installerCopyOutsideDownloads)) == true)
        #expect(byName[real(openCopy)]?.isSelected == false)
        #expect(byName[real(openCopy)]?.notes.contains(EngineText(.installerCopyRunning)) == true)
        #expect(byName[real(oldCopy)]?.size != nil)

        let plan = CleanupPlanner.plan(for: report, selectedPaths: Set(report.candidates.filter(\.isSelected).map(\.path)))
        #expect(plan.kind == .installerCleanup)
        #expect(plan.targetName == CleanupPlanner.installerTargetName)
        #expect(Set(plan.items.map { real($0.url) }) == Set(files + [real(oldCopy)]))
        #expect(plan.steps == [.moveItems])
    }

    @Test func runningFromDiskImageIsNotEjectedAndAsksToMove() async throws {
        let fx = try Fixture()
        let mount = try fx.dir(fx.base.appendingPathComponent("mnt/App Cleaner"))
        let running = try selfApp(fx, in: mount, version: "0.3.5")
        let runner = StubCommandRunner()
        runner.on("hdiutil", stdout: try hdiutilInfo([("/tmp/AppCleaner.dmg", [mount.path])]))
        runner.on("mdfind", stdout: running.path)

        let report = await InstallerLeftoverScanner(paths: fx.paths, runner: runner, runningBundle: running).scan(ruleDataVersion: "t")
        #expect(report.mounted.isEmpty)
        #expect(report.candidates.isEmpty)
        #expect(report.runningOutsideApplications)

        // hdiutil·mdfind가 실패해도 빈 결과
        let empty = await InstallerLeftoverScanner(paths: fx.paths, runner: StubCommandRunner(), runningBundle: nil).scan(ruleDataVersion: "t")
        #expect(empty.isEmpty && !empty.runningOutsideApplications)
    }

    /// 본 앱 보호는 "실행 중이 아닌 사본 .app"에서만 풀린다 — 데이터·보류 폴더와 일반 정리 경로는 그대로 막는다
    @Test func selfAppCopyExceptionIsNarrow() throws {
        let fx = try Fixture()
        let safety = SafetyGuard(paths: fx.paths)
        let running = try selfApp(fx, in: fx.root("Applications"), version: "0.3.5")
        let copy = try selfApp(fx, in: fx.home("Downloads"), version: "0.3.0")
        let data = try fx.file(fx.paths.appDataDir.appendingPathComponent("Journal/x.json"))

        #expect(safety.verdict(for: copy, allowingSelfAppCopy: running).isAllowed)
        #expect(safety.verdict(for: copy, allowingSelfAppCopy: nil).isAllowed)
        #expect(!safety.verdict(for: running, allowingSelfAppCopy: running).isAllowed)
        #expect(!safety.verdict(for: fx.root("Applications"), allowingSelfAppCopy: running).isAllowed)
        #expect(!safety.verdict(for: data, allowingSelfAppCopy: running).isAllowed)
        #expect(!safety.verdict(for: fx.paths.appDataDir, allowingSelfAppCopy: running).isAllowed)
        // 다른 정리 경로에서는 여전히 본 앱 사본을 막는다
        #expect(!safety.verdict(for: copy, bundleID: nil).isAllowed)
    }

    @Test func executorMovesInstallerItemsToTrashAndRecordsSession() async throws {
        let h = try Harness()
        let fx = h.fx
        let dmg = try fx.file(fx.home("Downloads/AppCleaner-0.3.3-macos-arm64.dmg"))
        let copy = try selfApp(fx, in: fx.home("Downloads"), version: "0.3.0")
        let report = InstallerLeftoverReport(candidates: [
            Candidate(url: dmg, category: .other, confidence: .high, isSelected: true),
            Candidate(url: copy, category: .appBundle, confidence: .high, isSelected: true),
        ], ruleDataVersion: "t")
        let plan = CleanupPlanner.plan(for: report, selectedPaths: [dmg.path, copy.path])
        let (result, _) = await h.execute(plan)
        #expect(result.failures.isEmpty)
        #expect(result.movedCount == 2)
        #expect(!fx.exists(dmg) && !fx.exists(copy))
        #expect(fx.exists(fx.paths.trash.appendingPathComponent("App Cleaner.app")))

        let sessions = await h.journal.sessions()
        #expect(sessions.first?.kind == .installerCleanup)
        #expect(sessions.first?.items.count == 2)
    }
}
