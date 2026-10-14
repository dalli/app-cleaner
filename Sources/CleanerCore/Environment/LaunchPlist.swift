import Foundation

/// LaunchAgent/Daemon plist 해석 (plan.md 4.2 #4, 4.5.3).
/// 앱 제거(LaunchPlistSource)와 고아 스캔(OrphanScanner)이 같은 규칙을 쓰도록 공용으로 둔다.
public struct LaunchPlist: Sendable, Hashable {
    public var url: URL
    public var label: String?
    /// `Program` 또는 `ProgramArguments[0]`
    public var program: String?
    public var arguments: [String]
    /// SMAppService 내장 plist의 `BundleProgram` (번들 기준 상대 경로)
    public var bundleProgram: String?
    public var keepAlive: Bool
    public var runAtLoad: Bool
    /// 셸·인터프리터를 거친 경우 실제 대상 경로. 추출 실패 시 nil.
    public var targetExecutable: String?
    /// 셸·인터프리터 경유인데 대상 경로를 추출하지 못함 → Low
    public var targetExtractionFailed: Bool

    public static let shells: Set<String> = ["/bin/sh", "/bin/bash", "/bin/zsh", "/bin/dash", "/bin/ksh", "/bin/csh", "/bin/tcsh",
                                             "/usr/bin/env"]
    public static let interpreters: [String] = ["python", "ruby", "perl", "node", "osascript", "php", "java"]

    public static func read(at url: URL) -> LaunchPlist? {
        guard let dict = PlistValue.readDictionary(at: url) else { return nil }
        let args = dict["ProgramArguments"]?.stringArray ?? []
        let program = dict["Program"]?.string ?? args.first
        let keepAlive: Bool = {
            if let b = dict["KeepAlive"]?.bool { return b }
            return dict["KeepAlive"]?.dictionary != nil
        }()
        var plist = LaunchPlist(
            url: url,
            label: dict["Label"]?.string,
            program: program,
            arguments: args,
            bundleProgram: dict["BundleProgram"]?.string,
            keepAlive: keepAlive,
            runAtLoad: dict["RunAtLoad"]?.bool ?? false,
            targetExecutable: nil,
            targetExtractionFailed: false
        )
        let (target, failed) = resolveTarget(program: program, arguments: args)
        plist.targetExecutable = target
        plist.targetExtractionFailed = failed
        return plist
    }

    /// 실행 파일이 셸·인터프리터·`open`이면 이후 인자에서 실제 대상 경로를 찾는다.
    static func resolveTarget(program: String?, arguments: [String]) -> (String?, Bool) {
        guard let program else { return (nil, false) }
        let rest = Array(arguments.dropFirst())
        let base = URL(fileURLWithPath: program).lastPathComponent
        let isShell = shells.contains(program)
        let isInterpreter = interpreters.contains { base == $0 || base.hasPrefix($0 + "3") || base.hasPrefix($0 + "2") }
        let isOpen = program == "/usr/bin/open"
        guard isShell || isInterpreter || isOpen else { return (program, false) }

        var tokens: [String] = []
        for arg in rest {
            if arg.hasPrefix("-") { continue }
            // `sh -c "exec '/Applications/Foo.app/Contents/MacOS/foo' --bar"` 같은 문자열은 토큰으로 나눈다.
            tokens.append(contentsOf: shellWords(arg))
        }
        if let path = tokens.first(where: { $0.hasPrefix("/") && !shells.contains($0) && !isInterpreterPath($0) }) {
            return (path, false)
        }
        return (nil, true)
    }

    private static func isInterpreterPath(_ path: String) -> Bool {
        let base = URL(fileURLWithPath: path).lastPathComponent
        return interpreters.contains { base == $0 || base.hasPrefix($0 + "3") || base.hasPrefix($0 + "2") }
    }

    /// 따옴표를 고려한 단순 단어 분리 (실행하지 않는다)
    static func shellWords(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for ch in s {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" && quote != "'" { escaped = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; continue }
            if ch == " " || ch == "\t" || ch == "\n" || ch == ";" || ch == "&" || ch == "|" {
                if !current.isEmpty { words.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// 대상 실행 파일(또는 program)이 `bundle` 안에 있는지
    public func points(into bundle: URL) -> Bool {
        let bundlePath = bundle.standardizedFileURL.path
        let candidates = [targetExecutable, program].compactMap { $0 }
        return candidates.contains { $0 == bundlePath || $0.hasPrefix(bundlePath + "/") }
    }

    /// 실제로 실행할 경로 (대상 추출 결과 우선)
    public var effectiveExecutable: String? { targetExecutable ?? program }
}
