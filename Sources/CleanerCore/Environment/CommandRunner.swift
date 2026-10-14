import Foundation

public struct CommandOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data, stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var string: String { String(decoding: stdout, as: UTF8.self) }
    public var succeeded: Bool { status == 0 }
    public var lines: [String] { string.split(separator: "\n").map(String.init) }
}

public enum CommandError: Error, Sendable, CustomStringConvertible {
    case launchFailed(String, String)
    case nonZeroExit(String, Int32, String)

    public var description: String {
        switch self {
        case .launchFailed(let cmd, let why): return "\(cmd) 실행 실패: \(why)"
        case .nonZeroExit(let cmd, let code, let err): return "\(cmd) 종료 코드 \(code): \(err)"
        }
    }
}

/// 외부 명령 실행 (pkgutil, launchctl, mdfind, mdutil, brew, defaults, tccutil, codesign …).
/// **셸을 거치지 않는다** — 실행 파일 경로와 인자 배열만 받는다 (plan.md 2.1 #3 명령 주입 방지).
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput
}

extension CommandRunning {
    /// 실패 시 nil
    public func output(_ executable: String, _ arguments: [String]) -> CommandOutput? {
        guard let out = try? run(executable, arguments), out.succeeded else { return nil }
        return out
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 60) {
        self.timeout = timeout
    }

    public func run(_ executable: String, _ arguments: [String]) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(executable, error.localizedDescription)
        }
        // 파이프 버퍼가 차서 멈추지 않도록 종료 전에 읽는다.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return CommandOutput(status: process.terminationStatus, stdout: outData,
                             stderr: String(decoding: errData, as: UTF8.self))
    }
}
