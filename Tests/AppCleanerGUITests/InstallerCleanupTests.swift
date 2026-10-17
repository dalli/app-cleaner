import CleanerCore
import Foundation
import Testing
@testable import AppCleanerGUI

@MainActor
@Suite("Installer cleanup")
struct InstallerCleanupTests {
    @Test func selectionFollowsDefaultsAndRunEjectsThenMoves() async {
        let engine = fastEngine()
        let report = await engine.installerLeftovers()
        let model = InstallerCleanupModel(report: report, engine: engine)
        // 기본 선택: 설치 파일 3개 + 다운로드 폴더의 이전 사본. 개발 빌드는 선택하지 않음
        #expect(model.selectedPaths.count == 4)
        #expect(!model.selectedPaths.contains { $0.contains("/dist/") })
        #expect(model.ejectMounts.count == 1)
        #expect(model.canRun)

        let devBuild = report.candidates.first { $0.path.contains("/dist/") }!
        model.toggle(devBuild)
        #expect(model.isSelected(devBuild))
        model.toggle(devBuild)
        #expect(!model.isSelected(devBuild))

        var finished = false
        model.onFinished = { finished = true }
        await model.run()
        #expect(model.phase == .finished)
        #expect(finished)
        #expect(model.ejectedCount == 1)
        #expect(model.result?.movedCount == 4)
        #expect(model.failures.isEmpty)
        #expect(!model.canRun)
    }

    @Test func nothingSelectedCannotRun() {
        let model = InstallerCleanupModel(report: InstallerLeftoverReport(ruleDataVersion: "t"), engine: fastEngine())
        #expect(model.report.isEmpty)
        #expect(!model.canRun)
    }

    @Test func manualCheckOpensSheetEvenWhenEmptyAndDismisses() async {
        let model = AppModel(engine: fastEngine(), settings: .inMemory(), isDemo: true)
        model.checkInstallerLeftovers(manual: true)
        #expect(await waitUntil { model.installerCleanup != nil })
        #expect(model.installerCleanup?.report.isEmpty == false)
        // 데모는 자동 확인하지 않고 확인 버전도 기록하지 않는다
        #expect(model.settings.installerCleanupCheckedVersion == nil)
        model.dismissInstallerCleanup()
        #expect(model.installerCleanup == nil)
    }
}
