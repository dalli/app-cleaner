import CleanerCore
import Foundation

// 엔진 선택은 이 파일 한 곳에서만 한다.
//
// 통합 단계: `LiveCleanerEngine`이 생기면 아래 `makeEngine`의 마지막 줄을
// `return LiveCleanerEngine(...)`로 바꾼다. `--demo`는 계속 `DemoCleanerEngine`을 쓴다.

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
    // TODO(통합): return LiveCleanerEngine(paths: .live, runner: ProcessCommandRunner(), ...)
    return DemoCleanerEngine()
}
