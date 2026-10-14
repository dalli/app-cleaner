import Foundation
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// privileged-op.sh를 **일반 사용자**로, `APPCLEANER_TEST_ROOT=<픽스처 루트>` 테스트 모드에서 실행한다.
/// 테스트 모드에서는 launchctl·pkgutil을 실행하지 않고, 픽스처 루트 밖의 파일을 건드리지 않는다.
@Suite struct PrivilegedScriptTests {
    static let sourceScriptURL: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/CleanerCore/Resources/Scripts/privileged-op.sh")

    static let session = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    struct Run {
        var status: Int32
        var lines: [String]
        var first: (ok: Bool, message: String) {
            let f = (lines.first ?? "").split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            return (f.first == "ok", f.count > 2 ? f[2] : "")
        }
    }

    /// 스크립트를 픽스처 안에서 실행 (작업 디렉토리도 픽스처)
    func run(_ fx: Fixture, _ args: [String], testRoot: Bool = true) throws -> Run {
        let env = testRoot ? ["APPCLEANER_TEST_ROOT": fx.paths.root.path] : ["APPCLEANER_TEST_ROOT": ""]
        let out = try EnvCommandRunner(environment: env, workingDirectory: fx.base)
            .run("/bin/sh", [Self.sourceScriptURL.path] + args)
        return Run(status: out.status, lines: out.lines)
    }

    func holding(_ fx: Fixture, _ logical: String) -> URL {
        AdminPaths.holdingURL(session: Self.session, logical: logical, holdingDir: fx.paths.holdingDir)
    }

    // MARK: 해시

    @Test func compiledHashMatchesScriptFile() throws {
        let actual = try #require(PrivilegedScript.sha256Hex(of: Self.sourceScriptURL))
        #expect(actual == PrivilegedScript.sha256, "privileged-op.sh를 바꿨다면 PrivilegedScript.sha256을 \(actual)로 갱신")
        let bundled = try #require(PrivilegedScript.bundledURL())
        #expect(PrivilegedScript.verify(bundled))
    }

    // MARK: 이동

    @Test func allowedRootMoveKeepsStructure() throws {
        let fx = try Fixture()
        let data = try fx.file(fx.root("Library/Caches/com.example.foo/sub/data.bin"))
        let daemon = try fx.makeLaunchPlist(at: fx.root("Library/LaunchDaemons/com.example.helper.plist"), label: "com.example.helper")
        let r1 = try run(fx, ["move-to-holding", Self.session.uuidString, "/Library/Caches/com.example.foo"])
        #expect(r1.status == 0 && r1.first.ok, "\(r1.lines)")
        let r2 = try run(fx, ["move-to-holding", Self.session.uuidString, "/Library/LaunchDaemons/com.example.helper.plist"])
        #expect(r2.status == 0 && r2.first.ok, "\(r2.lines)")

        #expect(!fx.exists(data) && !fx.exists(daemon))
        #expect(fx.exists(holding(fx, "/Library/Caches/com.example.foo/sub/data.bin")))
        #expect(fx.exists(holding(fx, "/Library/LaunchDaemons/com.example.helper.plist")))
        let sessionDir = fx.paths.holdingDir.appendingPathComponent(Self.session.uuidString)
        let attrs = try FileManager.default.attributesOfItem(atPath: sessionDir.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func pathOutsideWhitelistIsRejected() throws {
        let fx = try Fixture()
        try fx.file(fx.root("Users/me/file.txt"))
        try fx.file(fx.root("System/Library/thing"))
        try fx.file(fx.root("Library/Frameworks/x.framework/x"))
        for p in ["/Users/me/file.txt", "/System/Library/thing", "/Library/Frameworks/x.framework", "/Library/Caches",
                  "/Applications", "Library/Caches/rel"] {
            let r = try run(fx, ["move-to-holding", Self.session.uuidString, p])
            #expect(r.status == 1 && !r.first.ok, "\(p): \(r.lines)")
            #expect(["outside-allowed-root", "not-absolute"].contains(r.first.message), "\(p): \(r.lines)")
        }
        #expect(fx.exists(fx.root("Users/me/file.txt")))
    }

    @Test func symlinkedParentIsRejected() throws {
        let fx = try Fixture()
        let outside = try fx.file(fx.base.appendingPathComponent("outside/secret"), text: "do not move")
        try fx.dir(fx.root("Library/Caches"))
        try fx.symlink(fx.root("Library/Caches/Evil"), to: outside.deletingLastPathComponent())
        let r = try run(fx, ["move-to-holding", Self.session.uuidString, "/Library/Caches/Evil/secret"])
        #expect(r.status == 1 && r.first.message == "symlink", "\(r.lines)")
        #expect(fx.exists(outside))

        // 마지막 구성요소가 링크인 경우도 권한 쪽에서는 거부한다
        let r2 = try run(fx, ["move-to-holding", Self.session.uuidString, "/Library/Caches/Evil"])
        #expect(r2.first.message == "symlink", "\(r2.lines)")

        // /Library 자체가 링크로 바뀐 경우
        let fx2 = try Fixture()
        try FileManager.default.removeItem(at: fx2.root("Library"))
        try fx2.file(fx2.base.appendingPathComponent("fake/Caches/x/y"))
        try fx2.symlink(fx2.root("Library"), to: fx2.base.appendingPathComponent("fake"))
        let r3 = try run(fx2, ["move-to-holding", Self.session.uuidString, "/Library/Caches/x"])
        #expect(r3.first.message == "symlink", "\(r3.lines)")
    }

    @Test func dotDotIsRejected() throws {
        let fx = try Fixture()
        try fx.file(fx.root("etc/passwd"))
        try fx.dir(fx.root("Library/Caches"))
        for p in ["/Library/Caches/../../etc/passwd", "/Library/Caches/./x", "/Library/Caches/..", "/Library//Caches/x"] {
            let r = try run(fx, ["move-to-holding", Self.session.uuidString, p])
            #expect(r.status == 1, "\(p)")
            #expect(["dotdot", "bad-path"].contains(r.first.message), "\(p): \(r.lines)")
        }
        #expect(fx.exists(fx.root("etc/passwd")))
    }

    @Test func shellMetacharactersInFileNamesAreInert() throws {
        let fx = try Fixture()
        let names = ["$(touch pwned)", "`touch pwned2`", "a; touch pwned3", "x\" && touch pwned4 \"", "'q'$(id)"]
        for n in names { try fx.file(fx.root("Library/Caches/com.example.meta/\(n)"), text: n) }
        for n in names {
            let r = try run(fx, ["move-to-holding", Self.session.uuidString, "/Library/Caches/com.example.meta/\(n)"])
            #expect(r.status == 0 && r.first.ok, "\(n): \(r.lines)")
            #expect(fx.exists(holding(fx, "/Library/Caches/com.example.meta/\(n)")))
        }
        // 어디에도 pwned* 파일이 생기지 않았다 (작업 디렉토리 = 픽스처)
        let all = FileManager.default.enumerator(atPath: fx.base.path)?.allObjects as? [String] ?? []
        #expect(!all.contains { ($0 as NSString).lastPathComponent.hasPrefix("pwned") })

        // 배치 경로도 같은 이름을 그대로 다룬다
        try fx.file(fx.root("Library/Caches/com.example.meta2/$(touch pwned5)"))
        let ops = fx.base.appendingPathComponent("ops.txt")
        try "move-to-holding\t\(Self.session.uuidString)\t/Library/Caches/com.example.meta2/$(touch pwned5)\n"
            .write(to: ops, atomically: true, encoding: .utf8)
        let b = try run(fx, ["batch", ops.path])
        #expect(b.first.ok, "\(b.lines)")
        let after = FileManager.default.enumerator(atPath: fx.base.path)?.allObjects as? [String] ?? []
        #expect(!after.contains { ($0 as NSString).lastPathComponent == "pwned5" })
    }

    @Test func badLabelAndPackageCharsetsAreRejected() throws {
        let fx = try Fixture()
        for label in ["foo;rm -rf x", "$(id)", "-flag", ".hidden", "a b", "com.foo/../x", "x`y`"] {
            let r = try run(fx, ["bootout-system", label])
            #expect(r.status == 1 && r.first.message == "bad-identifier", "\(label): \(r.lines)")
        }
        #expect(try run(fx, ["bootout-system", "com.apple.mDNSResponder"]).first.message == "protected")
        #expect(try run(fx, ["pkg-forget", "com.example pkg"]).first.message == "bad-identifier")
        // 올바른 레이블은 테스트 모드에서 실제 launchctl/pkgutil 없이 성공으로 보고
        let okLabel = try run(fx, ["bootout-system", "com.example.helper"]).first
        #expect(okLabel.ok && okLabel.message == "test-mode")
        let okPkg = try run(fx, ["pkg-forget", "com.example.pkg"]).first
        #expect(okPkg.ok && okPkg.message == "test-mode")
        #expect(try run(fx, ["move-to-holding", "not-a-uuid", "/Library/Caches/x"]).first.message == "bad-session")
    }

    @Test func protectedListIsReappliedOnPrivilegedSide() throws {
        let fx = try Fixture()
        try fx.makeApp(name: "Pages", bundleID: "com.apple.iWork.Pages")
        try fx.file(fx.root("Library/Caches/com.apple.Safari/x"))
        try fx.file(fx.root("Library/Application Support/AppCleaner/Holding/other/x"))
        for p in ["/Applications/Pages.app", "/Library/Caches/com.apple.Safari", "/Library/Application Support/AppCleaner/Holding/other",
                  "/Library/Logs/DiagnosticReports"] {
            let r = try run(fx, ["move-to-holding", Self.session.uuidString, p])
            #expect(r.first.message == "protected", "\(p): \(r.lines)")
        }
        #expect(fx.exists(fx.root("Applications/Pages.app")))
    }

    @Test func refusesToRunWithoutRootOrTestRoot() throws {
        let fx = try Fixture()
        let r = try run(fx, ["purge-holding", Self.session.uuidString], testRoot: false)
        #expect(r.status == 77 && r.first.message == "not-root")
    }

    @Test func restoreAndPurgeRoundTrip() throws {
        let fx = try Fixture()
        let file = try fx.file(fx.root("Library/Preferences/com.example.foo.plist"), text: "v1")
        #expect(try run(fx, ["move-to-holding", Self.session.uuidString, "/Library/Preferences/com.example.foo.plist"]).first.ok)
        // 원래 위치에 같은 이름이 생기면 거부, 다른 이름으로 복원은 같은 폴더 안에서만
        try fx.file(file, text: "new")
        #expect(try run(fx, ["restore-from-holding", Self.session.uuidString, "/Library/Preferences/com.example.foo.plist"]).first.message == "exists")
        #expect(try run(fx, ["restore-from-holding", Self.session.uuidString, "/Library/Preferences/com.example.foo.plist",
                             "/Library/Caches/elsewhere.plist"]).first.message == "bad-restore-target")
        let renamed = "/Library/Preferences/com.example.foo (복원됨).plist"
        #expect(try run(fx, ["restore-from-holding", Self.session.uuidString, "/Library/Preferences/com.example.foo.plist", renamed]).first.ok)
        #expect(try String(contentsOf: fx.root(renamed), encoding: .utf8) == "v1")

        try fx.file(fx.root("Library/Caches/com.example.bar/x"))
        #expect(try run(fx, ["move-to-holding", Self.session.uuidString, "/Library/Caches/com.example.bar"]).first.ok)
        #expect(try run(fx, ["purge-holding", Self.session.uuidString]).first.ok)
        #expect(!fx.exists(fx.paths.holdingDir.appendingPathComponent(Self.session.uuidString)))
    }

    @Test func batchReportsEachOperationByIndex() throws {
        let fx = try Fixture()
        try fx.file(fx.root("Library/Caches/com.example.a/x"))
        let ops = fx.base.appendingPathComponent("ops.txt")
        try [
            "move-to-holding\t\(Self.session.uuidString)\t/Library/Caches/com.example.a",
            "move-to-holding\t\(Self.session.uuidString)\t/Users/x",
            "bootout-system\tbad label",
            "batch\t/tmp/x",
            "pkg-forget\tcom.example.pkg",
        ].joined(separator: "\n").write(to: ops, atomically: true, encoding: .utf8)
        let r = try run(fx, ["batch", ops.path])
        #expect(r.lines.count == 5)
        #expect(r.lines.map { $0.split(separator: "\t").prefix(2).joined(separator: " ") }
                == ["ok 1", "fail 2", "fail 3", "fail 4", "ok 5"])
    }

    // MARK: AppleScript 실행기 (osascript는 스텁 — 실제 인증창을 띄우지 않음)

    @Test func appleScriptExecutorPassesArgumentsOnlyThroughArgv() async throws {
        let fx = try Fixture()
        let stub = StubCommandRunner()
        let captured = OpsCapture()
        stub.on("osascript") { args in
            // 작업 목록 파일은 실행 중에만 존재한다
            if let ops = args.last { captured.set((try? String(contentsOfFile: ops, encoding: .utf8)) ?? "") }
            return CommandOutput(status: 0, stdout: Data("ok\t1\t/held\nfail\t2\tsymlink\n".utf8))
        }
        let exec = AppleScriptAdminExecutor(runner: stub, scriptURL: Self.sourceScriptURL, workDirectory: fx.base)
        let evil = "/Library/Caches/$(touch pwned)'\"x"
        let results = await exec.run([
            .moveToHolding(session: Self.session, path: evil),
            .moveToHolding(session: Self.session, path: "/Library/Caches/Evil/x"),
            .bootoutSystem(label: "bad;label"),
        ])
        #expect(results.map(\.succeeded) == [true, false, false])
        #expect(results[1].message == "symlink")
        #expect(results[2].message == "bad-identifier")   // Swift 쪽 사전 검증 — 스크립트로 보내지 않음

        let call = try #require(stub.calls.first)
        #expect(call.executable == "/usr/bin/osascript")
        var source: [String] = []
        var i = 0
        while i < call.arguments.count, call.arguments[i] == "-e" { source.append(call.arguments[i + 1]); i += 2 }
        #expect(source == PrivilegedScript.appleScriptSource)
        #expect(!source.joined().contains("pwned"))
        #expect(source.contains { $0.contains("quoted form of") })
        let positional = Array(call.arguments[i...])
        #expect(positional.count == 4)
        #expect(positional[0] == PrivilegedScript.launcherShell)
        #expect(positional[1] == Self.sourceScriptURL.path)
        #expect(positional[2] == PrivilegedScript.sha256)
        #expect(captured.value == "move-to-holding\t\(Self.session.uuidString)\t\(evil)\n"
                + "move-to-holding\t\(Self.session.uuidString)\t/Library/Caches/Evil/x\n")
        #expect(!FileManager.default.fileExists(atPath: positional[3]))   // 실행 후 정리
    }

    @Test func appleScriptExecutorRefusesTamperedScript() async throws {
        let fx = try Fixture()
        let stub = StubCommandRunner()
        let exec = AppleScriptAdminExecutor(runner: stub, scriptURL: Self.sourceScriptURL, expectedSHA256: String(repeating: "0", count: 64),
                                            workDirectory: fx.base)
        let results = await exec.run([.pkgForget(id: "com.example.pkg")])
        #expect(results.map(\.message) == ["script-hash-mismatch"])
        #expect(stub.calls.isEmpty)
    }

    @Test func appleScriptExecutorReportsCancelledAuthentication() async throws {
        let fx = try Fixture()
        let stub = StubCommandRunner()
        stub.on("osascript") { _ in CommandOutput(status: 1, stdout: Data(), stderr: "execution error: User canceled. (-128)") }
        let exec = AppleScriptAdminExecutor(runner: stub, scriptURL: Self.sourceScriptURL, workDirectory: fx.base)
        let results = await exec.run([.pkgForget(id: "com.example.pkg"), .purgeHolding(session: Self.session)])
        #expect(results.allSatisfy { !$0.succeeded && $0.message == "auth-cancelled" })
        #expect(results[0].localizedReason == "관리자 인증이 취소되었습니다")
    }

    @Test func directLauncherRunsRealScriptInTestMode() async throws {
        let fx = try Fixture()
        try fx.file(fx.root("Library/Logs/com.example.foo/log.txt"))
        let results = await scriptAdmin(fx).run([
            .moveToHolding(session: Self.session, path: "/Library/Logs/com.example.foo"),
            .moveToHolding(session: Self.session, path: "/Library/Logs/../../etc"),
            .pkgForget(id: "com.example.pkg"),
        ])
        #expect(results.map(\.succeeded) == [true, false, true])
        #expect(results[1].message == "dotdot")
        #expect(fx.exists(holding(fx, "/Library/Logs/com.example.foo/log.txt")))
    }
}

final class OpsCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = ""
    func set(_ v: String) { lock.lock(); _value = v; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return _value }
}
