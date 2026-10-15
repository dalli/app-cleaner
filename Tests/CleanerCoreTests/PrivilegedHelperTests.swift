import Foundation
import Security
import Testing
@testable import CleanerCore
import CleanerTestSupport

/// 권한 헬퍼 (#17, plan.md 5.3) — plan.md 9장 "권한 경로 보안 테스트"를 헬퍼 경로로 다시 실행한다.
///
/// 명령 처리기(`PrivilegedCommandProcessor`)와 fd 기반 이동(`SecureFileOperations`)은 root가 아니어도 픽스처 루트에서
/// 그대로 동작하므로, 헬퍼가 실제로 실행하는 코드를 일반 사용자 권한으로 검증한다. 테스트 모드(`runner: nil`)에서는
/// launchctl·pkgutil을 실행하지 않는다. launchd 등록·root 실행 자체는 여기서 검증하지 않는다 (docs/development.md).
@Suite struct PrivilegedHelperTests {
    static let session = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!

    func files(_ fx: Fixture) -> SecureFileOperations {
        SecureFileOperations(rootPath: fx.paths.root.path)
    }

    func processor(_ fx: Fixture, files: SecureFileOperations? = nil, runner: CommandRunning? = nil) -> PrivilegedCommandProcessor {
        PrivilegedCommandProcessor(files: files ?? self.files(fx), paths: fx.paths, identity: .default, runner: runner)
    }

    func move(_ p: PrivilegedCommandProcessor, _ path: String, session: UUID = Self.session) -> AdminOperationResult {
        p.perform(.moveToHolding(session: session, path: path))
    }

    func holding(_ fx: Fixture, _ logical: String, session: UUID = Self.session) -> URL {
        AdminPaths.holdingURL(session: session, logical: logical, holdingDir: fx.paths.holdingDir)
    }

    func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    /// 픽스처 경로는 `/var/folders`, 헬퍼가 돌려주는 경로는 실제 경로(`/private/var/folders`) — 비교 전에 맞춘다
    func real(_ path: String) -> String { SafetyGuard.realpathOfExistingPrefix(path) }

    func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: 이동

    @Test func allowedRootMoveKeepsStructureInPrivateHolding() throws {
        let fx = try Fixture()
        let p = processor(fx)
        let data = try fx.file(fx.root("Library/Caches/com.example.foo/sub/data.bin"))
        let daemon = try fx.makeLaunchPlist(at: fx.root("Library/LaunchDaemons/com.example.helper.plist"), label: "com.example.helper")
        let app = try fx.makeApp(name: "Foo", bundleID: "com.example.foo")

        for path in ["/Library/Caches/com.example.foo", "/Library/LaunchDaemons/com.example.helper.plist", "/Applications/Foo.app"] {
            let r = move(p, path)
            #expect(r.succeeded, "\(path): \(r.message)")
            #expect(real(r.message) == real(holding(fx, path).path))
        }
        #expect(!fx.exists(data) && !fx.exists(daemon) && !fx.exists(app))
        #expect(fx.exists(holding(fx, "/Library/Caches/com.example.foo/sub/data.bin")))
        #expect(fx.exists(holding(fx, "/Library/LaunchDaemons/com.example.helper.plist")))
        #expect(fx.exists(holding(fx, "/Applications/Foo.app/Contents/Info.plist")))
        // 보류 폴더·세션 폴더·원래 구조 폴더 모두 0700
        #expect(try mode(fx.paths.holdingDir) == 0o700)
        #expect(try mode(fx.paths.holdingDir.appendingPathComponent(Self.session.uuidString)) == 0o700)
        #expect(try mode(holding(fx, "/Library/Caches")) == 0o700)
        #expect(try mode(fx.paths.holdingDir.deletingLastPathComponent()) == 0o755)
    }

    @Test func pathOutsideAllowedRootsIsRejected() throws {
        let fx = try Fixture()
        let p = processor(fx)
        try fx.file(fx.root("Users/me/file.txt"))
        try fx.file(fx.root("System/Library/thing"))
        try fx.file(fx.root("Library/Frameworks/x.framework/x"))
        try fx.file(fx.root("private/etc/sudoers"))
        for path in ["/Users/me/file.txt", "/System/Library/thing", "/Library/Frameworks/x.framework", "/Library/Caches",
                     "/Applications", "/private/etc/sudoers", "/library/caches/x", "Library/Caches/rel", ""] {
            let r = move(p, path)
            #expect(!r.succeeded, "\(path)")
            #expect(["outside-allowed-root", "not-absolute"].contains(r.message), "\(path): \(r.message)")
        }
        #expect(fx.exists(fx.root("Users/me/file.txt")) && fx.exists(fx.root("private/etc/sudoers")))
        #expect(!fx.exists(fx.paths.holdingDir))
    }

    @Test func malformedPathsAreRejected() throws {
        let fx = try Fixture()
        let p = processor(fx)
        try fx.file(fx.root("etc/passwd"))
        let cases: [(String, String)] = [
            ("/Library/Caches/../../etc/passwd", "dotdot"), ("/Library/Caches/./x", "dotdot"), ("/Library/Caches/..", "dotdot"),
            ("/Library//Caches/x", "bad-path"), ("/Library/Caches/x/", "bad-path"),
            ("/Library/Caches/a\tb", "bad-char"), ("/Library/Caches/a\nb", "bad-char"), ("/Library/Caches/a\0b", "bad-char"),
            ("/Library/Caches/" + String(repeating: "x", count: 256), "bad-path"),
        ]
        for (path, code) in cases {
            #expect(move(p, path).message == code, "\(path.debugDescription)")
        }
        #expect(fx.exists(fx.root("etc/passwd")))
    }

    @Test func symlinkedParentIsRejected() throws {
        let fx = try Fixture()
        let p = processor(fx)
        let outside = try fx.file(fx.base.appendingPathComponent("outside/secret"), text: "do not move")
        try fx.symlink(fx.root("Library/Caches/Evil"), to: outside.deletingLastPathComponent())
        #expect(move(p, "/Library/Caches/Evil/secret").message == "symlink")
        // 마지막 구성요소가 링크인 경우도 거부한다
        #expect(move(p, "/Library/Caches/Evil").message == "symlink")
        #expect(fx.exists(outside))

        // 허용 루트 자체(/Library)가 링크로 바뀐 경우
        let fx2 = try Fixture()
        try FileManager.default.removeItem(at: fx2.root("Library"))
        try fx2.file(fx2.base.appendingPathComponent("fake/Caches/x/y"))
        try fx2.symlink(fx2.root("Library"), to: fx2.base.appendingPathComponent("fake"))
        #expect(move(processor(fx2), "/Library/Caches/x").message == "symlink")
        #expect(fx2.exists(fx2.base.appendingPathComponent("fake/Caches/x/y")))
    }

    /// 검사 직후(상위 폴더 fd를 얻고 마지막 구성요소를 확인한 다음) 상위 폴더를 바깥을 가리키는 링크로 바꿔도
    /// 이미 연 fd 기준으로 옮기므로 원래 항목이 옮겨지고 바깥 파일은 그대로다.
    @Test func parentSwappedForSymlinkRightAfterCheckDoesNotRedirectMove() throws {
        let fx = try Fixture()
        let inside = try fx.file(fx.root("Library/Caches/Vendor/secret"), text: "inside")
        let outside = try fx.file(fx.base.appendingPathComponent("outside/secret"), text: "outside")
        let vendor = fx.root("Library/Caches/Vendor")
        let stash = fx.root("Library/Caches/VendorReal")
        let outsideDir = outside.deletingLastPathComponent()
        var ops = files(fx)
        ops.hook = { stage in
            guard stage == .sourceVerified else { return }
            try? FileManager.default.moveItem(at: vendor, to: stash)
            try? FileManager.default.createSymbolicLink(at: vendor, withDestinationURL: outsideDir)
        }
        let r = move(processor(fx, files: ops), "/Library/Caches/Vendor/secret")
        #expect(r.succeeded, "\(r.message)")
        #expect(isSymlink(vendor))                                  // 바꿔치기는 실제로 일어났다
        #expect(text(outside) == "outside")                          // 바깥 파일은 그대로
        #expect(text(holding(fx, "/Library/Caches/Vendor/secret")) == "inside")
        // 원래 폴더(지금은 VendorReal)에서 빠졌다 — `Vendor/secret`은 이제 링크를 통해 바깥 파일을 가리킨다
        #expect(!fx.exists(stash.appendingPathComponent("secret")))
        #expect(text(inside) == "outside")
    }

    /// 마지막 구성요소를 검사 직후 링크로 바꾸면 링크 자체가 옮겨진다 (대상은 따라가지 않음).
    @Test func finalComponentSwappedForSymlinkMovesOnlyTheLink() throws {
        let fx = try Fixture()
        let item = try fx.file(fx.root("Library/Logs/com.example.log"), text: "log")
        let outside = try fx.file(fx.base.appendingPathComponent("outside/important"), text: "outside")
        var ops = files(fx)
        ops.hook = { stage in
            guard stage == .sourceVerified else { return }
            try? FileManager.default.removeItem(at: item)
            try? FileManager.default.createSymbolicLink(at: item, withDestinationURL: outside)
        }
        let r = move(processor(fx, files: ops), "/Library/Logs/com.example.log")
        #expect(r.succeeded, "\(r.message)")
        #expect(isSymlink(holding(fx, "/Library/Logs/com.example.log")))
        #expect(text(outside) == "outside")
    }

    /// 경쟁 조건 반복 실행: 다른 스레드가 상위 폴더를 실제 폴더 ↔ 바깥을 가리키는 링크로 계속 바꾸는 동안
    /// 이동을 반복한다. 어떤 순서로 끼어들어도 바깥 파일은 하나도 옮겨지지 않아야 한다.
    @Test func repeatedSymlinkSwapRaceNeverMovesOutsideFiles() throws {
        let fx = try Fixture()
        let count = 1500
        let vendor = fx.root("Library/Caches/Vendor")
        let stash = fx.root("Library/Caches/VendorReal")
        let link = fx.root("Library/Caches/VendorLink")
        let outsideDir = fx.base.appendingPathComponent("outside", isDirectory: true)
        for i in 0..<count {
            try fx.file(vendor.appendingPathComponent("secret\(i)"), text: "inside")
            try fx.file(outsideDir.appendingPathComponent("secret\(i)"), text: "outside")
        }
        try fx.symlink(link, to: outsideDir)

        let stop = StopFlag()
        let swapper = Thread {
            while !stop.isSet {
                rename(vendor.path, stash.path)        // Vendor → 링크
                rename(link.path, vendor.path)
                rename(vendor.path, link.path)         // Vendor → 실제 폴더
                rename(stash.path, vendor.path)
                usleep(20)                              // 실제 폴더인 구간을 조금 둬 성공 경로도 섞이게
            }
            stop.markFinished()
        }
        swapper.start()
        let p = processor(fx)
        var outcomes: [String: Int] = [:]
        for i in 0..<count {
            let r = move(p, "/Library/Caches/Vendor/secret\(i)")
            outcomes[r.succeeded ? "ok" : r.message, default: 0] += 1
        }
        stop.set()
        stop.waitFinished()

        for i in 0..<count {
            #expect(text(outsideDir.appendingPathComponent("secret\(i)")) == "outside", "secret\(i)")
            let held = holding(fx, "/Library/Caches/Vendor/secret\(i)")
            if fx.exists(held) { #expect(text(held) == "inside", "secret\(i)") }
        }
        // 거부 사유는 끼어든 시점에 따라 다르다 (링크 / 잠시 없음 / 검사 사이에 종류가 바뀜)
        #expect(Set(outcomes.keys).isSubset(of: ["ok", "symlink", "missing", "bad-path"]), "\(outcomes)")
        #expect(outcomes["ok", default: 0] > 0, "\(outcomes)")
    }

    @Test func shellMetacharacterNamesAreInert() throws {
        let fx = try Fixture()
        let p = processor(fx)
        let names = ["$(touch pwned)", "`touch pwned2`", "a; touch pwned3", "x\" && touch pwned4 \"", "'q'$(id)", "*", "-rf"]
        for n in names { try fx.file(fx.root("Library/Caches/com.example.meta/\(n)"), text: n) }
        for n in names {
            let r = move(p, "/Library/Caches/com.example.meta/\(n)")
            #expect(r.succeeded, "\(n): \(r.message)")
            #expect(text(holding(fx, "/Library/Caches/com.example.meta/\(n)")) == n)
        }
        let all = FileManager.default.enumerator(atPath: fx.base.path)?.allObjects as? [String] ?? []
        #expect(!all.contains { ($0 as NSString).lastPathComponent.hasPrefix("pwned") })
        // 레이블·패키지 ID에 셸 메타문자가 있으면 거부
        for id in ["foo;rm -rf x", "$(id)", "x`y`", "a b", "a|b", "a&b"] {
            #expect(processor(fx).perform(.bootoutSystem(label: id)).message == "bad-identifier", "\(id)")
            #expect(processor(fx).perform(.pkgForget(id: id)).message == "bad-identifier", "\(id)")
        }
    }

    // MARK: RENAME_EXCL

    @Test func existingDestinationIsNeverOverwritten() throws {
        let fx = try Fixture()
        let p = processor(fx)
        let src = try fx.file(fx.root("Library/Preferences/com.example.a.plist"), text: "new")
        try fx.file(holding(fx, "/Library/Preferences/com.example.a.plist"), text: "held")
        let r = move(p, "/Library/Preferences/com.example.a.plist")
        #expect(!r.succeeded && r.message == "exists")
        #expect(text(src) == "new" && text(holding(fx, "/Library/Preferences/com.example.a.plist")) == "held")
    }

    /// 존재 확인 뒤 `renameatx_np` 직전에 같은 이름이 생겨도 RENAME_EXCL로 덮어쓰지 않는다.
    @Test func destinationCreatedJustBeforeRenameIsNotOverwritten() throws {
        let fx = try Fixture()
        let src = try fx.file(fx.root("Library/Caches/com.example.b"), text: "source")
        let dest = holding(fx, "/Library/Caches/com.example.b")
        var ops = files(fx)
        ops.hook = { stage in
            if stage == .beforeRename { try? "raced".write(to: dest, atomically: false, encoding: .utf8) }
        }
        let r = move(processor(fx, files: ops), "/Library/Caches/com.example.b")
        #expect(r.message == "exists")
        #expect(text(src) == "source" && text(dest) == "raced")

        // 복원도 같다: 원래 위치에 직전에 생긴 파일을 덮어쓰지 않는다
        let fx2 = try Fixture()
        let file = try fx2.file(fx2.root("Library/Logs/com.example.c.log"), text: "v1")
        #expect(move(processor(fx2), "/Library/Logs/com.example.c.log").succeeded)
        var ops2 = files(fx2)
        ops2.hook = { stage in
            if stage == .beforeRename { try? "raced".write(to: file, atomically: false, encoding: .utf8) }
        }
        let rr = processor(fx2, files: ops2).perform(.restoreFromHolding(session: Self.session, originalPath: "/Library/Logs/com.example.c.log", restoreTo: nil))
        #expect(rr.message == "exists")
        #expect(text(file) == "raced" && text(holding(fx2, "/Library/Logs/com.example.c.log")) == "v1")
    }

    // MARK: 보호 목록 (헬퍼가 독립적으로 재검증)

    @Test func protectedListIsReappliedByHelper() throws {
        let fx = try Fixture()
        let p = processor(fx)
        try fx.makeApp(name: "Pages", bundleID: "com.apple.iWork.Pages")
        try fx.makeApp(name: "Cleaner Copy", bundleID: "com.dallisoft.AppCleaner")
        try fx.file(fx.root("Library/Caches/com.apple.Safari/x"))
        try fx.file(fx.root("Library/Caches/com.dallisoft.AppCleaner/x"))
        try fx.file(fx.root("Library/Application Support/AppCleaner/Holding/other/x"))
        try fx.file(fx.root("Library/Application Support/Apple/x"))
        try fx.file(fx.root("Library/Application Support/MobileSync/Backup/x"))
        try fx.file(fx.root("Library/Logs/DiagnosticReports/x.ips"))
        for path in ["/Applications/Pages.app", "/Applications/Cleaner Copy.app", "/Library/Caches/com.apple.Safari",
                     "/Library/Caches/com.dallisoft.AppCleaner", "/Library/Application Support/AppCleaner/Holding/other",
                     "/Library/Application Support/AppCleaner", "/Library/Application Support/Apple/x",
                     "/Library/Application Support/MobileSync/Backup", "/Library/Logs/DiagnosticReports",
                     "/Library/LaunchDaemons/com.dallisoft.AppCleaner.Helper.plist", "/Applications/Utilities"] {
            #expect(move(p, path).message == "protected", "\(path)")
        }
        #expect(fx.exists(fx.root("Applications/Pages.app")))
        #expect(fx.exists(fx.root("Library/Application Support/AppCleaner/Holding/other/x")))
    }

    /// fd로 읽은 Info.plist의 번들 ID로도 보호 대상을 거른다 (SafetyGuard와 별개로).
    @Test func appBundleIDIsReadThroughDescriptors() throws {
        let fx = try Fixture()
        try fx.makeApp(name: "Numbers", bundleID: "com.apple.iWork.Numbers")
        var seen: [String] = []
        #expect(throws: SecureFileOperations.Failure("protected")) {
            _ = try files(fx).moveToHolding(session: Self.session, logicalPath: "/Applications/Numbers.app") { bid in
                seen.append(bid)
                return SafeIdentifier.isApple(bid)
            }
        }
        #expect(seen == ["com.apple.iWork.Numbers"])
        #expect(fx.exists(fx.root("Applications/Numbers.app")))
    }

    // MARK: 소유자·권한

    @Test func untrustedOwnerOfAllowedRootAncestorIsRejected() throws {
        let fx = try Fixture()
        try fx.file(fx.root("Library/Caches/com.example.x"))
        // 운영과 같이 root만 신뢰하면, 사용자 소유인 픽스처 /Library는 안전하지 않은 상위 폴더다
        let rootOnly = SecureFileOperations(rootPath: fx.paths.root.path, trustedOwners: [0])
        #expect(move(processor(fx, files: rootOnly), "/Library/Caches/com.example.x").message == "unsafe-parent")
        #expect(fx.exists(fx.root("Library/Caches/com.example.x")))
    }

    @Test func worldWritableAllowedRootNeedsStickyBit() throws {
        let fx = try Fixture()
        let caches = try fx.dir(fx.root("Library/Caches"))
        try fx.file(fx.root("Library/Caches/com.example.x"))
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: caches.path)
        #expect(move(processor(fx), "/Library/Caches/com.example.x").message == "unsafe-parent")
        // /Library/Caches처럼 sticky 비트가 있으면 허용
        try FileManager.default.setAttributes([.posixPermissions: 0o1777], ofItemAtPath: caches.path)
        #expect(move(processor(fx), "/Library/Caches/com.example.x").succeeded)
    }

    @Test func holdingFolderMustBeHelperOwnedDirectory() throws {
        let fx = try Fixture()
        let p = processor(fx)
        try fx.file(fx.root("Library/Caches/com.example.x"))
        let evil = try fx.dir(fx.base.appendingPathComponent("evil"))
        // 보류 폴더 상위가 링크로 바뀌어 있으면 거부
        try fx.symlink(fx.root("Library/Application Support/AppCleaner"), to: evil)
        #expect(move(p, "/Library/Caches/com.example.x").message == "holding-unsafe")
        #expect(fx.exists(fx.root("Library/Caches/com.example.x")))
        #expect((try FileManager.default.contentsOfDirectory(atPath: evil.path)).isEmpty)

        // 권한이 느슨한 보류 폴더는 0700으로 바로잡는다
        try FileManager.default.removeItem(at: fx.root("Library/Application Support/AppCleaner"))
        try fx.dir(fx.paths.holdingDir)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: fx.paths.holdingDir.path)
        #expect(move(p, "/Library/Caches/com.example.x").succeeded)
        #expect(try mode(fx.paths.holdingDir) == 0o700)
    }

    // MARK: 복원·영구 삭제

    @Test func restoreAndPurgeRoundTrip() throws {
        let fx = try Fixture()
        let p = processor(fx)
        let file = try fx.file(fx.root("Library/Preferences/com.example.foo.plist"), text: "v1")
        #expect(move(p, "/Library/Preferences/com.example.foo.plist").succeeded)
        try fx.file(file, text: "new")
        func restore(_ to: String?) -> AdminOperationResult {
            p.perform(.restoreFromHolding(session: Self.session, originalPath: "/Library/Preferences/com.example.foo.plist", restoreTo: to))
        }
        #expect(restore(nil).message == "exists")
        #expect(restore("/Library/Caches/elsewhere.plist").message == "bad-restore-target")
        #expect(restore("/Library/Preferences/com.apple.x.plist").message == "protected")
        let renamed = "/Library/Preferences/com.example.foo (복원됨).plist"
        let r = restore(renamed)
        #expect(r.succeeded && real(r.message) == real(fx.root(renamed).path))
        #expect(text(fx.root(renamed)) == "v1" && text(file) == "new")
        #expect(restore(nil).message == "missing")

        // 원래 상위 폴더가 없어졌으면 허용 루트 아래에서 다시 만든다
        try fx.file(fx.root("Library/Application Support/Vendor/Sub/data"), text: "d")
        #expect(move(p, "/Library/Application Support/Vendor/Sub/data").succeeded)
        try FileManager.default.removeItem(at: fx.root("Library/Application Support/Vendor"))
        #expect(p.perform(.restoreFromHolding(session: Self.session, originalPath: "/Library/Application Support/Vendor/Sub/data",
                                               restoreTo: nil)).succeeded)
        #expect(text(fx.root("Library/Application Support/Vendor/Sub/data")) == "d")

        // 세션 폴더 안의 링크는 따라가지 않고 링크만 지운다
        try fx.file(fx.root("Library/Caches/com.example.bar/x"))
        #expect(move(p, "/Library/Caches/com.example.bar").succeeded)
        let outside = try fx.file(fx.base.appendingPathComponent("outside/keep"), text: "keep")
        try fx.symlink(holding(fx, "/Library/Caches/com.example.bar/link"), to: outside.deletingLastPathComponent())
        #expect(p.perform(.purgeHolding(session: Self.session)).message == "purged")
        #expect(!fx.exists(fx.paths.holdingDir.appendingPathComponent(Self.session.uuidString)))
        #expect(text(outside) == "keep")
        // 없는 세션도 성공 (이미 지움)
        #expect(p.perform(.purgeHolding(session: UUID())).succeeded)
    }

    @Test func restoreRejectsSymlinkedTargetParent() throws {
        let fx = try Fixture()
        let p = processor(fx)
        try fx.file(fx.root("Library/Caches/Vendor/x"), text: "x")
        #expect(move(p, "/Library/Caches/Vendor/x").succeeded)
        let outside = try fx.dir(fx.base.appendingPathComponent("outside"))
        try FileManager.default.removeItem(at: fx.root("Library/Caches/Vendor"))
        try fx.symlink(fx.root("Library/Caches/Vendor"), to: outside)
        let r = p.perform(.restoreFromHolding(session: Self.session, originalPath: "/Library/Caches/Vendor/x", restoreTo: nil))
        #expect(r.message == "symlink")
        #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty)
    }

    // MARK: launchctl · pkgutil

    @Test func serviceAndReceiptCommandsUseFixedExecutablesAndValidatedIdentifiers() throws {
        let fx = try Fixture()
        let stub = StubCommandRunner()
        stub.on("/bin/launchctl") { args in CommandOutput(status: args.first == "bootout" ? 113 : 0, stdout: Data()) }
        stub.on("/usr/sbin/pkgutil", stdout: "")
        let p = processor(fx, runner: stub)
        let plist = try fx.makeLaunchPlist(at: fx.root("Library/LaunchDaemons/com.example.d.plist"), label: "com.example.d")

        #expect(p.perform(.bootoutSystem(label: "com.example.d")).message == "bootout")
        #expect(p.perform(.pkgForget(id: "com.example.pkg")).message == "forgot")
        #expect(p.perform(.bootstrapSystem(plistPath: "/Library/LaunchDaemons/com.example.d.plist")).message == "bootstrap")
        #expect(stub.calls.map(\.executable) == ["/bin/launchctl", "/usr/sbin/pkgutil", "/bin/launchctl"])
        #expect(stub.calls.map(\.arguments) == [["bootout", "system/com.example.d"], ["--forget", "com.example.pkg"],
                                                ["bootstrap", "system", real(plist.path)]])

        // 보호 식별자·헬퍼 자신은 실행 전에 거부
        for label in ["com.apple.mDNSResponder", "com.dallisoft.AppCleaner.Helper", "COM.APPLE.x"] {
            #expect(p.perform(.bootoutSystem(label: label)).message == "protected", "\(label)")
        }
        #expect(p.perform(.pkgForget(id: "com.apple.pkg.Core")).message == "protected")
        for bad in ["-flag", ".hidden", "com.foo/../x", ""] {
            #expect(p.perform(.bootoutSystem(label: bad)).message == "bad-identifier", "\(bad)")
        }
        // bootstrap은 /Library/LaunchDaemons 바로 아래의 링크 아닌 plist만
        let target = try fx.makeLaunchPlist(at: fx.base.appendingPathComponent("outside/x.plist"), label: "x")
        try fx.symlink(fx.root("Library/LaunchDaemons/com.example.link.plist"), to: target)
        #expect(p.perform(.bootstrapSystem(plistPath: "/Library/LaunchDaemons/com.example.link.plist")).message == "symlink")
        #expect(p.perform(.bootstrapSystem(plistPath: "/Library/LaunchAgents/com.example.d.plist")).message == "outside-allowed-root")
        #expect(p.perform(.bootstrapSystem(plistPath: "/Library/LaunchDaemons/sub/x.plist")).message == "outside-allowed-root")
        #expect(p.perform(.bootstrapSystem(plistPath: "/Library/LaunchDaemons/com.apple.x.plist")).message == "protected")
        #expect(stub.calls.count == 3)

        stub.on("/bin/launchctl", stdout: "", status: 5)
        #expect(p.perform(.bootoutSystem(label: "com.example.e")).message == "launchctl-5")
        // 테스트 모드(runner 없음)에서는 외부 명령을 실행하지 않는다
        #expect(processor(fx).perform(.pkgForget(id: "com.example.pkg")).message == "test-mode")
    }

    // MARK: 전송 형식

    @Test func wireFormatRoundTripsEveryOperation() throws {
        let ops: [AdminOperation] = [
            .moveToHolding(session: Self.session, path: "/Library/Caches/x"),
            .restoreFromHolding(session: Self.session, originalPath: "/Library/Caches/x", restoreTo: "/Library/Caches/y"),
            .restoreFromHolding(session: Self.session, originalPath: "/Library/Caches/x", restoreTo: nil),
            .purgeHolding(session: Self.session),
            .bootoutSystem(label: "com.example.d"),
            .bootstrapSystem(plistPath: "/Library/LaunchDaemons/com.example.d.plist"),
            .pkgForget(id: "com.example.pkg"),
        ]
        for op in ops {
            #expect(try HelperWireOperation(op).operation().get() == op)
        }
        #expect(HelperWireOperation(op: "shell", path: "/bin/sh").operation() == .failure(.init("unknown-op")))
        #expect(HelperWireOperation(op: "moveToHolding", session: "nope", path: "/x").operation() == .failure(.init("bad-session")))
        #expect(HelperWireOperation(op: "pkgForget").operation() == .failure(.init("bad-identifier")))
    }

    @Test func serviceRejectsMalformedRequestsAndProcessesValidOnes() throws {
        let fx = try Fixture()
        try fx.file(fx.root("Library/Caches/com.example.w/x"))
        let service = PrivilegedHelperService(processor: processor(fx))
        func decode(_ d: Data) throws -> HelperWireReply { try JSONDecoder().decode(HelperWireReply.self, from: d) }

        #expect(try decode(service.handle(Data("not json".utf8))).error == "bad-request")
        let old = try JSONEncoder().encode(HelperWireRequest(operations: [], version: 99))
        #expect(try decode(service.handle(old)).error == "bad-version")

        let request = HelperWireRequest(operations: [
            HelperWireOperation(.moveToHolding(session: Self.session, path: "/Library/Caches/com.example.w")),
            HelperWireOperation(op: "runShell", path: "rm -rf /"),
            HelperWireOperation(.moveToHolding(session: Self.session, path: "/etc/passwd")),
        ])
        let reply = try decode(service.handle(try JSONEncoder().encode(request)))
        #expect(reply.error == nil)
        #expect(reply.results.map(\.ok) == [true, false, false])
        #expect(reply.results.map(\.message).dropFirst() == ["unknown-op", "outside-allowed-root"])
        #expect(fx.exists(holding(fx, "/Library/Caches/com.example.w/x")))
    }

    // MARK: 코드 서명 요구사항

    @Test func codeSigningRequirementIsBuiltFromValidatedValues() {
        let id = PrivilegedHelperIdentity.default
        #expect(id.helperLabel == "com.dallisoft.AppCleaner.Helper")
        #expect(id.machServiceName == id.helperLabel)
        #expect(id.plistName == "com.dallisoft.AppCleaner.Helper.plist")
        #expect(id.clientIdentifiers == ["com.dallisoft.AppCleaner", "com.dallisoft.AppCleaner.cli"])
        #expect(PrivilegedHelperIdentity(helperIdentifier: "com.example.Foo.Helper")?.appBundleID == "com.example.Foo")
        #expect(PrivilegedHelperIdentity(helperIdentifier: "com.example.Foo") == nil)
        #expect(PrivilegedHelperIdentity(helperIdentifier: "x\" or true.Helper") == nil)

        let req = CodeSigningRequirement.make(teamID: "ABCDE12345", identifiers: id.clientIdentifiers)
        #expect(req == #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and (identifier "com.dallisoft.AppCleaner" or identifier "com.dallisoft.AppCleaner.cli")"#)
        #expect(req.map(CodeSigningRequirement.compiles) == true)
        let single = CodeSigningRequirement.make(teamID: "ABCDE12345", identifiers: [id.helperLabel])
        #expect(single == #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345" and identifier "com.dallisoft.AppCleaner.Helper""#)
        #expect(single.map(CodeSigningRequirement.compiles) == true)
        // Team ID·식별자로 요구사항 언어를 주입할 수 없다
        for team in ["abcde12345", "ABCDE1234", "ABCDE123456", "ABCD\"12345", "", "XXXXXXXXX "] {
            #expect(CodeSigningRequirement.make(teamID: team, identifiers: ["a.b"]) == nil, "\(team)")
        }
        #expect(CodeSigningRequirement.make(teamID: "ABCDE12345", identifiers: ["a\" or anchor apple"]) == nil)
        #expect(CodeSigningRequirement.make(teamID: "ABCDE12345", identifiers: []) == nil)
        #expect(CodeSigningRequirement.development(identifiers: ["com.dallisoft.AppCleaner"]).map(CodeSigningRequirement.compiles) == true)
    }

    // MARK: XPC (같은 프로세스의 익명 리스너 — launchd 없이 클라이언트 서명 검사 경로를 실행)

    /// 요구사항을 만족하는 클라이언트는 헬퍼로 실행된다 (XPC 왕복 + fd 기반 이동).
    @Test func xpcClientMatchingRequirementIsServed() async throws {
        let fx = try Fixture()
        try fx.file(fx.root("Library/Caches/com.example.xpc/x"))
        let me = try #require(SelfCodeSignature.current()?.identifier, "테스트 프로세스에 서명 식별자가 없음")
        let requirement = try #require(CodeSigningRequirement.development(identifiers: [me]))
        // 같은 요구사항을 먼저 자기 프로세스에 검사한다 — 실패 원인이 서명인지 XPC인지 구분하고, CI 러너에서는 이 검사 없이
        // 첫 동적 검증을 XPC가 하면 연결이 거부되는 경우가 있었다 (로컬은 항상 통과)
        try #require(SelfCodeCheck.status(requirement) == errSecSuccess, "테스트 프로세스가 자기 서명 요구사항을 통과하지 못함")
        let server = AnonymousHelper(processor: processor(fx), clientRequirement: requirement)

        let results = try #require(await server.executor().runIfReachable([
            .moveToHolding(session: Self.session, path: "/Library/Caches/com.example.xpc"),
            .moveToHolding(session: Self.session, path: "/Library/Caches/a\tb"),   // 앱 쪽 사전 검증 — 보내지 않음
            .bootoutSystem(label: "com.apple.x"),
        ]))
        #expect(results.map(\.succeeded) == [true, false, false])
        #expect(results.map(\.message).dropFirst() == ["bad-char", "protected"])
        #expect(fx.exists(holding(fx, "/Library/Caches/com.example.xpc/x")))
    }

    /// 서명이 다른 클라이언트의 요청은 헬퍼가 처리하지 않는다 (audit token 기반 `setCodeSigningRequirement`).
    /// 앱은 연결 실패로 보고 대체 경로를 쓴다 — 헬퍼 쪽에서는 아무 파일도 옮기지 않는다.
    @Test func xpcClientWithDifferentSignatureIsRejected() async throws {
        let fx = try Fixture()
        try fx.file(fx.root("Library/Caches/com.example.xpc/x"))
        let requirement = try #require(CodeSigningRequirement.make(teamID: "ABCDE12345", identifiers: PrivilegedHelperIdentity.default.clientIdentifiers))
        let server = AnonymousHelper(processor: processor(fx), clientRequirement: requirement)

        let op = AdminOperation.moveToHolding(session: Self.session, path: "/Library/Caches/com.example.xpc")
        #expect(await server.executor().runIfReachable([op]) == nil)
        #expect(fx.exists(fx.root("Library/Caches/com.example.xpc/x")))
        #expect(!fx.exists(fx.paths.holdingDir))

        let fallback = RecordingAdmin(paths: fx.paths)
        let results = await FallbackAdminExecutor(helper: server.executor(), fallback: fallback).run([op])
        #expect(fallback.batches == [[op]])
        #expect(results.map(\.succeeded) == [true])
    }

    /// 앱 쪽도 헬퍼의 서명을 검사한다: 요구사항을 만족하지 않는 상대에게는 작업을 보내지 않는다.
    @Test func xpcServerWithDifferentSignatureIsNotTrusted() async throws {
        let fx = try Fixture()
        try fx.file(fx.root("Library/Caches/com.example.xpc/x"))
        let me = try #require(SelfCodeSignature.current()?.identifier)
        let server = AnonymousHelper(processor: processor(fx), clientRequirement: try #require(CodeSigningRequirement.development(identifiers: [me])))
        let helperRequirement = CodeSigningRequirement.make(teamID: "ABCDE12345", identifiers: [PrivilegedHelperIdentity.default.helperLabel])
        let exec = server.executor(helperRequirement: helperRequirement)
        #expect(await exec.runIfReachable([.moveToHolding(session: Self.session, path: "/Library/Caches/com.example.xpc")]) == nil)
        #expect(fx.exists(fx.root("Library/Caches/com.example.xpc/x")))
    }

    /// 헬퍼가 설치되지 않았으면(Mach 서비스 없음) 바로 대체 경로로 간다.
    @Test func missingHelperFallsBackWithoutSendingOperations() async throws {
        let fx = try Fixture()
        let name = "com.dallisoft.AppCleaner.tests.missing-\(UUID().uuidString)"
        let helper = HelperAdminExecutor(identity: .default, helperRequirement: nil) { NSXPCConnection(machServiceName: name) }
        let fallback = RecordingAdmin(paths: fx.paths)
        let ops: [AdminOperation] = [.pkgForget(id: "com.example.pkg")]
        let results = await FallbackAdminExecutor(helper: helper, fallback: fallback).run(ops)
        #expect(fallback.batches == [ops])
        #expect(results.map(\.succeeded) == [true])
        #expect(await helper.run(ops).map(\.message) == ["helper-unavailable"])
        #expect(PrivilegedScript.reason("helper-unavailable") == EngineText(.adminLaunchFailed))
        #expect(PrivilegedScript.reason("unsafe-parent") == EngineText(.adminUnsafeParent))
    }
}

/// 테스트 프로세스가 요구사항을 동적 서명 검사로 통과하는지 (XPC가 audit token으로 하는 검사와 같은 종류)
enum SelfCodeCheck {
    static func status(_ text: String) -> OSStatus {
        var code: SecCode?
        var requirement: SecRequirement?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement
        else { return errSecParam }
        return SecCodeCheckValidity(code, [], requirement)
    }
}

/// 같은 프로세스 안의 익명 XPC 리스너에 헬퍼 서비스를 띄운다 (테스트 전용).
final class AnonymousHelper: @unchecked Sendable {
    let listener = NSXPCListener.anonymous()
    let delegate: PrivilegedHelperListenerDelegate

    init(processor: PrivilegedCommandProcessor, clientRequirement: String) {
        delegate = PrivilegedHelperListenerDelegate(clientRequirement: clientRequirement,
                                                    service: PrivilegedHelperService(processor: processor))
        listener.delegate = delegate
        listener.resume()
    }

    deinit { listener.invalidate() }

    func executor(helperRequirement: String? = nil) -> HelperAdminExecutor {
        let endpoint = EndpointBox(listener.endpoint)
        // CI 러너에서는 첫 서명 검증(큰 테스트 바이너리 해시)이 수 초 걸려 짧은 ping 제한 시간을 넘긴다
        return HelperAdminExecutor(identity: .default, helperRequirement: helperRequirement, pingTimeout: 60, operationTimeout: 60) {
            NSXPCConnection(listenerEndpoint: endpoint.value)
        }
    }
}

final class EndpointBox: @unchecked Sendable {
    let value: NSXPCListenerEndpoint
    init(_ value: NSXPCListenerEndpoint) { self.value = value }
}

/// 경쟁 조건 테스트의 스레드 정지 신호
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stop = false
    private let finished = DispatchSemaphore(value: 0)
    var isSet: Bool { lock.withLock { stop } }
    func set() { lock.withLock { stop = true } }
    func markFinished() { finished.signal() }
    func waitFinished() { finished.wait() }
}
