import Foundation
import CleanerCore

/// 엔진 선택
enum EngineFactory {
    static func make(demo: Bool, language: AppLanguage) -> (any CleanerEngine)? {
        if demo {
            let t = CLIText(language: language)
            FileHandle.standardError.write(Data((t("--demo는 GUI 전용입니다. CLI는 실제 엔진만 지원합니다.") + "\n").utf8))
            return nil
        }
        return LiveCleanerEngine()
    }
}
