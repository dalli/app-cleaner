import Foundation
import CleanerCore

// appcleaner CLI 진입점 (plan.md 7.3)
// 출력 언어: --lang → APPCLEANER_LANG → LC_ALL/LC_MESSAGES/LANG → 시스템 선호 언어 → 영어
let selection = CLILanguage.extract(Array(CommandLine.arguments.dropFirst()),
                                    environment: ProcessInfo.processInfo.environment,
                                    preferredLanguages: Locale.preferredLanguages)
let outputLanguage = selection.language
// 엔진이 시스템에 넘기는 문구(관리자 인증 안내, 복원 이름 표시)도 같은 언어로
AppLanguage.current = outputLanguage
let outputText = CLIText(language: outputLanguage)
let arguments = selection.rest
let command: Command
do {
    if let error = selection.error { throw error }
    command = try ArgumentParser.parse(arguments)
} catch {
    let message = (error as? UsageError)?.message(outputLanguage) ?? "\(error)"
    FileHandle.standardError.write(Data("\(message)\n\n\(ArgumentParser.usage(outputLanguage))\n".utf8))
    exit(64)
}

guard let engine = EngineFactory.make(demo: arguments.contains("--demo"), language: outputLanguage) else {
    FileHandle.standardError.write(Data((outputText("엔진을 초기화하지 못했습니다.") + "\n").utf8))
    exit(1)
}
let status = await CLI(engine: engine, language: outputLanguage).run(command)
exit(status)
