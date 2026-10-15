import CleanerCore
import Foundation
import Testing
@testable import AppCleanerGUI

/// S7 관리자 헬퍼 설치/제거 (#17). 실제 `SMAppService` 대신 데모 설치기로 상태 흐름만 확인한다.
@MainActor
@Suite("Privileged helper settings (S7)")
struct HelperSettingsTests {
    @Test func installApproveAndRemoveFlow() async {
        let helper = DemoHelperInstaller()
        let model = AppModel(engine: fastEngine(), settings: .inMemory(), isDemo: true, helper: helper)
        #expect(model.helperState == .notInstalled)

        // 등록하면 로그인 항목에서 허용할 때까지 "승인 필요"
        model.installHelper()
        #expect(model.helperState == .requiresApproval)
        #expect(model.helperError == nil)
        model.openHelperApproval()
        #expect(model.helperState == .enabled)

        model.uninstallHelper()
        #expect(await waitUntil { !model.helperBusy })
        #expect(model.helperState == .notInstalled)
    }

    @Test func unavailableInstallerReportsErrorAndKeepsPasswordPath() {
        let model = AppModel(engine: fastEngine(), settings: .inMemory())
        #expect(model.helperState == .unavailable)
        model.installHelper()
        #expect(model.helperState == .unavailable)
        #expect(model.helperError?.isEmpty == false)
    }

    @Test func demoModeUsesDemoInstaller() {
        #expect(makeHelperInstaller(arguments: ["app", "--demo"]) is DemoHelperInstaller)
        #expect(makeHelperInstaller(arguments: ["app"]) is SMAppServiceHelperInstaller)
        // `swift run`·테스트처럼 .app 번들 밖에서는 설치할 수 없다
        #expect(SMAppServiceHelperInstaller().state() == .unavailable)
    }
}
