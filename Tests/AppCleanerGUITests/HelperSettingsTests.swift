import CleanerCore
import Foundation
import ServiceManagement
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

    /// 한 번도 등록하지 않은 헬퍼는 번들에 plist가 있어도 `.notFound` (macOS 27) — "사용할 수 없음"에 갇히지 않아야 한다
    @Test func notFoundStatusMeansNotInstalledWhenHelperCanConnect() {
        #expect(HelperInstallState(status: .notFound, canConnect: true) == .notInstalled)
        #expect(HelperInstallState(status: .notRegistered, canConnect: true) == .notInstalled)
        #expect(HelperInstallState(status: .enabled, canConnect: true) == .enabled)
        #expect(HelperInstallState(status: .requiresApproval, canConnect: true) == .requiresApproval)
        // 연결을 받지 않는 빌드(ad-hoc 배포본)는 설치를 권하지 않되, 이미 등록된 헬퍼는 제거할 수 있게 보인다
        #expect(HelperInstallState(status: .notFound, canConnect: false) == .unavailable)
        #expect(HelperInstallState(status: .notRegistered, canConnect: false) == .unavailable)
        #expect(HelperInstallState(status: .enabled, canConnect: false) == .enabled)
        #expect(HelperInstallState(status: .requiresApproval, canConnect: false) == .requiresApproval)
    }

    @Test func helperCanConnectOnlyWithTeamIDOrDevelopmentBundle() {
        #expect(SMAppServiceHelperInstaller.currentBuildCanConnect(signing: SigningInfo(teamID: "ABCDE12345")))
        #expect(!SMAppServiceHelperInstaller.currentBuildCanConnect(signing: SigningInfo(teamID: nil)))
        #expect(!SMAppServiceHelperInstaller.currentBuildCanConnect(signing: nil))
    }
}
