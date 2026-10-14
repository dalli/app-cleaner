import Foundation
import CleanerCore

/// 엔진 선택
enum EngineFactory {
    static func make(demo: Bool) -> (any CleanerEngine)? {
        if demo {
            FileHandle.standardError.write(Data("--demo는 GUI 전용입니다. CLI는 실제 엔진만 지원합니다.\n".utf8))
            return nil
        }
        return LiveCleanerEngine()
    }
}
