import CleanerCore
import Foundation

// 엔진 선택은 이 파일 한 곳에서만 한다. `--demo`는 가짜 데이터, 그 외에는 실제 엔진.

/// `--demo` 또는 `--demo-*` 인자가 있으면 데모 모드
func isDemoMode(arguments: [String]) -> Bool {
    arguments.contains { $0 == "--demo" || $0.hasPrefix("--demo-") }
}

func makeEngine(arguments: [String] = CommandLine.arguments) -> any CleanerEngine {
    if isDemoMode(arguments: arguments) {
        var options = DemoCleanerEngine.Options()
        if arguments.contains("--demo-no-fda") { options.fullDiskAccess = .denied }
        if arguments.contains("--demo-fast") { options.delayScale = 0.2 }
        if arguments.contains("--demo-no-hang") { options.simulateUnresponsiveApp = false }
        return DemoCleanerEngine(options: options)
    }
    let engine = LiveCleanerEngine()
    engine.prewarm()
    return engine
}

/// 관리자 헬퍼 설치 (S7). 데모는 상태만 바꾸는 가짜, 그 외에는 `SMAppService`.
func makeHelperInstaller(arguments: [String] = CommandLine.arguments) -> any HelperInstalling {
    isDemoMode(arguments: arguments) ? DemoHelperInstaller() : SMAppServiceHelperInstaller()
}
