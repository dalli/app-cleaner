import Foundation
import CleanerCore

// appcleaner CLI 진입점 (plan.md 7.3)
let arguments = Array(CommandLine.arguments.dropFirst())
let command: Command
do {
    command = try ArgumentParser.parse(arguments)
} catch {
    FileHandle.standardError.write(Data("\(error)\n\n\(ArgumentParser.usage)\n".utf8))
    exit(64)
}

guard let engine = EngineFactory.make(demo: arguments.contains("--demo")) else {
    FileHandle.standardError.write(Data("엔진을 초기화하지 못했습니다.\n".utf8))
    exit(1)
}
let status = await CLI(engine: engine).run(command)
exit(status)
