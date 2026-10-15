import Foundation
import Darwin

/// 권한 헬퍼의 fd 기반 파일 작업 (plan.md 5.3 "TOCTOU 대응").
///
/// 경로 문자열로 검사한 뒤 같은 문자열로 옮기지 않는다. 시스템 루트부터 구성요소마다
/// `openat(…, O_NOFOLLOW | O_DIRECTORY)`로 디렉토리 fd를 얻으며 내려가고, 최종 이동은 확보한 fd 기준
/// `renameatx_np(…, RENAME_EXCL)`로 한다. 검사 뒤 상위 디렉토리가 심볼릭 링크로 바뀌어도 이미 연 fd는 원래
/// 디렉토리를 가리키므로 다른 위치의 파일이 옮겨지지 않고, 마지막 구성요소가 링크로 바뀌면 링크 자체가 옮겨진다.
///
/// - 허용 루트(`allowedRoots`)까지의 상위 폴더는 소유자가 `trustedOwners`이고 다른 사용자가 쓸 수 없어야 한다
///   (sticky 비트가 있으면 허용 — `/Library/Caches`). 허용 루트 아래 폴더는 링크만 아니면 된다.
/// - 보류 폴더는 헬퍼가 만든 `trustedOwners` 소유 디렉토리만 쓴다 (`Holding`·세션 폴더 `0700`, 운영에서는 root:wheel).
/// - root가 아니어도 동작하므로(`rootPath` = 픽스처 루트) 단위 테스트에서 그대로 검증한다.
///
/// 실패는 privileged-op.sh와 같은 사유 코드(`Failure.code`)로 알린다 — `PrivilegedScript.reason(_:)`이 사용자 문구로 바꾼다.
public struct SecureFileOperations: Sendable {
    public struct Failure: Error, Sendable, Hashable, CustomStringConvertible {
        public var code: String
        public init(_ code: String) { self.code = code }
        public var description: String { code }
    }

    /// 테스트 전용 훅 단계 (검사 직후 경로를 바꿔치기하는 경쟁 조건 재현)
    enum Stage: Sendable, Hashable {
        /// 원본의 상위 폴더 fd를 얻고 마지막 구성요소까지 검사한 직후 (보류 폴더를 열기 전)
        case sourceVerified
        /// `renameatx_np` 직전
        case beforeRename
    }

    /// 허용 루트 화이트리스트 (plan.md 5.3). 이 폴더 "아래"만 대상이 된다 (폴더 자체는 불가).
    public static let allowedRoots: [String] = [
        "/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools",
        "/Library/Application Support", "/Library/Caches", "/Library/Preferences", "/Library/Logs", "/Applications",
    ]

    /// 보류 폴더 (시스템 루트 기준 논리 경로) — `SystemPaths.holdingDir`와 같은 위치
    public static let holdingParent = "/Library/Application Support/\(SystemPaths.ourAppFolderName)"
    public static let holding = holdingParent + "/Holding"

    /// 시스템 루트의 실제 경로 (운영 `/`, 테스트는 픽스처 루트). 이 접두사 자체는 검사하지 않는다.
    public let rootPath: String
    /// 허용 루트까지의 상위 폴더·보류 폴더가 가져도 되는 소유자 (운영: root만)
    public let trustedOwners: Set<uid_t>
    /// root로 실행 중이면 새로 만든 보류 폴더를 root:wheel로 바꾼다
    let chownCreatedToRoot: Bool
    /// 테스트 전용 (`@testable`)
    var hook: (@Sendable (Stage) -> Void)?

    /// - Parameter trustedOwners: nil이면 root, root가 아니면(테스트) root + 현재 사용자
    public init(rootPath: String = "/", trustedOwners: Set<uid_t>? = nil) {
        let normalized = SafetyGuard.normalize(rootPath)
        self.rootPath = normalized == "/" ? "/" : SafetyGuard.realpathOfExistingPrefix(normalized)
        let euid = geteuid()
        self.trustedOwners = trustedOwners ?? (euid == 0 ? [0] : [0, euid])
        self.chownCreatedToRoot = euid == 0
    }

    // MARK: 경로 검증 (파일 시스템을 보지 않음)

    /// 논리 경로의 구성요소. 절대 경로, 빈·`.`·`..` 구성요소 금지, 제어 문자 금지, 길이 제한.
    public static func components(of logical: String) throws -> [String] {
        guard logical.hasPrefix("/") else { throw Failure("not-absolute") }
        if logical.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            throw Failure("bad-char")
        }
        let parts = logical.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains(where: { $0 == "." || $0 == ".." }) { throw Failure("dotdot") }
        if parts.contains(where: \.isEmpty) { throw Failure("bad-path") }
        if logical.utf8.count >= Int(PATH_MAX) || parts.contains(where: { $0.utf8.count > Int(NAME_MAX) }) {
            throw Failure("bad-path")
        }
        return parts
    }

    /// 허용 루트 아래 경로면 그 허용 루트의 구성요소 수 (`/Library/Caches/x` → 2), 아니면 nil
    public static func allowedRootDepth(_ components: [String]) -> Int? {
        for root in allowedRoots {
            let rc = root.dropFirst().split(separator: "/").map(String.init)
            if components.count > rc.count && Array(components.prefix(rc.count)) == rc { return rc.count }
        }
        return nil
    }

    /// 구문 + 허용 루트 검사를 통과한 구성요소와 허용 루트 깊이
    public static func target(_ logical: String) throws -> (components: [String], rootDepth: Int) {
        let comps = try components(of: logical)
        guard let depth = allowedRootDepth(comps) else { throw Failure("outside-allowed-root") }
        return (comps, depth)
    }

    // MARK: 작업

    /// 항목을 `<보류 폴더>/<session>/<원래 논리 경로>`로 옮긴다. 성공하면 보류 폴더 안의 전체 경로.
    /// - Parameter isProtectedBundleID: 앱 번들이면 fd로 읽은 `CFBundleIdentifier`를 넘겨 보호 대상인지 묻는다.
    public func moveToHolding(session: UUID, logicalPath: String,
                              isProtectedBundleID: (String) -> Bool = { _ in false }) throws -> String {
        let (comps, depth) = try Self.target(logicalPath)
        let root = try openRoot()
        let srcParent = try descend(from: root, through: comps.dropLast(), trustedDepth: depth)
        let name = comps[comps.count - 1]
        let st = try lstatEntry(srcParent, name)
        if (st.st_mode & S_IFMT) == S_IFLNK { throw Failure("symlink") }
        if (st.st_mode & S_IFMT) == S_IFDIR, name.lowercased().hasSuffix(".app"),
           let bid = bundleIdentifier(ofAppNamed: name, in: srcParent), isProtectedBundleID(bid) {
            throw Failure("protected")
        }
        hook?(.sourceVerified)

        let sessionDir = try openHoldingSession(root, session: session, create: true)
        var destParent = sessionDir
        for comp in comps.dropLast() {
            destParent = try openHoldingChild(destParent, comp, create: true)
        }
        hook?(.beforeRename)
        try rename(srcParent, name, destParent, name)
        return Self.join(rootPath, Self.holding + "/" + session.uuidString + logicalPath)
    }

    /// 보류 폴더의 항목을 원래 위치(또는 같은 폴더 안의 `restoreTo`)로 되돌린다. 성공하면 복원한 전체 경로.
    /// 원래 위치에 같은 이름이 있으면 덮어쓰지 않고 `exists`.
    public func restoreFromHolding(session: UUID, originalPath: String, restoreTo: String?,
                                   isProtectedBundleID: (String) -> Bool = { _ in false }) throws -> String {
        let (orig, _) = try Self.target(originalPath)
        let targetPath = restoreTo ?? originalPath
        let (dest, depth) = try Self.target(targetPath)
        guard dest.dropLast() == orig.dropLast() else { throw Failure("bad-restore-target") }

        let root = try openRoot()
        let sessionDir = try openHoldingSession(root, session: session, create: false)
        var srcParent = sessionDir
        for comp in orig.dropLast() {
            srcParent = try openHoldingChild(srcParent, comp, create: false)
        }
        let srcName = orig[orig.count - 1]
        let st = try lstatEntry(srcParent, srcName)
        if (st.st_mode & S_IFMT) == S_IFDIR, srcName.lowercased().hasSuffix(".app"),
           let bid = bundleIdentifier(ofAppNamed: srcName, in: srcParent), isProtectedBundleID(bid) {
            throw Failure("protected")
        }
        // 원래 상위 폴더가 사라졌으면 허용 루트 아래에서만 만든다 (0755)
        let destParent = try descend(from: root, through: dest.dropLast(), trustedDepth: depth, createMode: 0o755)
        hook?(.beforeRename)
        try rename(srcParent, srcName, destParent, dest[dest.count - 1])
        return Self.join(rootPath, targetPath)
    }

    /// 세션 보류 폴더를 지운다 (fd 기준 재귀 삭제 — 링크는 따라가지 않고 링크 자체를 지운다). 없으면 성공.
    public func purgeHolding(session: UUID) throws {
        let root = try openRoot()
        let holding: FD
        do {
            holding = try openHolding(root, create: false)
        } catch let f as Failure where f.code == "missing" {
            return
        }
        var st = stat()
        if fstatat(holding.raw, session.uuidString, &st, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw Failure("remove-failed")
        }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw Failure("holding-unsafe") }
        try removeTree(holding, session.uuidString)
    }

    /// `/Library/LaunchDaemons/<이름>.plist`가 링크 없이 일반 파일로 있는지 (`launchctl bootstrap` 전에 확인)
    public func verifyLaunchDaemonPlist(_ logical: String) throws {
        let comps = try Self.components(of: logical)
        guard comps.count == 3, comps[0] == "Library", comps[1] == "LaunchDaemons",
              comps[2].hasSuffix(".plist"), comps[2].count > 6 else { throw Failure("outside-allowed-root") }
        let root = try openRoot()
        let parent = try descend(from: root, through: comps.dropLast(), trustedDepth: 2)
        let st = try lstatEntry(parent, comps[2])
        switch st.st_mode & S_IFMT {
        case S_IFREG: return
        case S_IFLNK: throw Failure("symlink")
        default: throw Failure("bad-path")
        }
    }

    /// 논리 경로 → 전체 경로
    public func fullPath(_ logical: String) -> String { Self.join(rootPath, logical) }

    // MARK: fd 도구

    /// 열린 디렉토리 fd. 범위를 벗어나면 닫는다.
    final class FD: @unchecked Sendable {
        let raw: Int32
        init(_ raw: Int32) { self.raw = raw }
        deinit { close(raw) }
    }

    private func openRoot() throws -> FD {
        let fd = open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("missing") }
        return FD(fd)
    }

    /// 루트부터 `components`를 차례로 연다. 앞쪽 `trustedDepth`개(허용 루트까지)는 소유자·쓰기 권한도 검사한다.
    /// `createMode`가 있으면 허용 루트 아래의 없는 폴더를 만든다.
    private func descend(from root: FD, through components: ArraySlice<String>, trustedDepth: Int,
                         createMode: mode_t? = nil) throws -> FD {
        var current = root
        for (i, comp) in components.enumerated() {
            let trusted = i < trustedDepth
            let (fd, _) = try openDirectory(current, comp, createMode: trusted ? nil : createMode)
            if trusted {
                var st = stat()
                guard fstat(fd.raw, &st) == 0 else { throw Failure("bad-path") }
                if !trustedOwners.contains(st.st_uid) { throw Failure("unsafe-parent") }
                if (st.st_mode & S_IWOTH) != 0 && (st.st_mode & S_ISVTX) == 0 { throw Failure("unsafe-parent") }
            }
            current = fd
        }
        return current
    }

    /// 디렉토리 구성요소 하나를 `O_NOFOLLOW | O_DIRECTORY`로 연다 (만들었으면 두 번째 값이 true).
    private func openDirectory(_ parent: FD, _ name: String, createMode: mode_t? = nil) throws -> (FD, Bool) {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = openat(parent.raw, name, flags)
        var created = false
        if fd < 0, errno == ENOENT, let mode = createMode {
            if mkdirat(parent.raw, name, mode) == 0 {
                created = true
            } else if errno != EEXIST {
                throw Failure("mkdir-failed")
            }
            fd = openat(parent.raw, name, flags)
        }
        guard fd >= 0 else { throw classifyOpenFailure(parent, name) }
        let dir = FD(fd)
        if created {
            // umask와 상위 폴더 그룹 상속에 기대지 않고 명시적으로 맞춘다
            if let mode = createMode, fchmod(dir.raw, mode) != 0 { throw Failure("chmod-failed") }
            if chownCreatedToRoot, fchown(dir.raw, 0, 0) != 0 { throw Failure("chown-failed") }
        }
        return (dir, created)
    }

    /// `openat` 실패 사유. `O_NOFOLLOW`가 링크에서 내는 `ELOOP`을 먼저 보고, `ENOTDIR`이면 링크인지 일반 파일인지 다시 본다.
    private func classifyOpenFailure(_ parent: FD, _ name: String) -> Failure {
        let err = errno
        switch err {
        case ELOOP: return Failure("symlink")
        case ENOENT: return Failure("missing")
        case EACCES, EPERM: return Failure("move-failed")
        default:
            var st = stat()
            if fstatat(parent.raw, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
                return Failure("symlink")
            }
            return Failure("bad-path")
        }
    }

    private func lstatEntry(_ parent: FD, _ name: String) throws -> stat {
        var st = stat()
        guard fstatat(parent.raw, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Failure(errno == ENOENT ? "missing" : "bad-path")
        }
        return st
    }

    private func rename(_ srcParent: FD, _ srcName: String, _ destParent: FD, _ destName: String) throws {
        guard renameatx_np(srcParent.raw, srcName, destParent.raw, destName, UInt32(RENAME_EXCL)) == 0 else {
            switch errno {
            case EEXIST: throw Failure("exists")
            case ENOENT: throw Failure("missing")
            default: throw Failure("move-failed")
            }
        }
    }

    // MARK: 보류 폴더

    /// `<루트>/Library/Application Support/AppCleaner/Holding`. `/Library`·`Application Support`는 허용 루트와 같은
    /// 검사, `AppCleaner`(0755)·`Holding`(0700)은 신뢰하는 소유자 + 다른 사용자 쓰기 불가.
    private func openHolding(_ root: FD, create: Bool) throws -> FD {
        let parentComps = Self.holdingParent.dropFirst().split(separator: "/").map(String.init)
        var current = root
        do {
            // `Library`, `Application Support` — 허용 루트와 같은 소유자·쓰기 검사 (없으면 만든다: 새 설치·픽스처)
            for comp in parentComps.dropLast() {
                let (fd, _) = try openDirectory(current, comp, createMode: create ? 0o755 : nil)
                var st = stat()
                guard fstat(fd.raw, &st) == 0, trustedOwners.contains(st.st_uid),
                      (st.st_mode & S_IWOTH) == 0 || (st.st_mode & S_ISVTX) != 0 else { throw Failure("holding-unsafe") }
                current = fd
            }
        } catch let f as Failure where f.code == "symlink" || f.code == "bad-path" {
            throw Failure("holding-unsafe")
        }
        let app = try openHoldingDirectory(current, parentComps[parentComps.count - 1], mode: 0o755, create: create)
        return try openHoldingDirectory(app, "Holding", mode: 0o700, create: create)
    }

    private func openHoldingSession(_ root: FD, session: UUID, create: Bool) throws -> FD {
        let holding = try openHolding(root, create: create)
        return try openHoldingDirectory(holding, session.uuidString, mode: 0o700, create: create)
    }

    /// 세션 폴더 안의 하위 폴더 (원래 경로 구조). 세션 폴더가 0700이라 다른 사용자가 바꿀 수 없지만 똑같이 검사한다.
    private func openHoldingChild(_ parent: FD, _ name: String, create: Bool) throws -> FD {
        try openHoldingDirectory(parent, name, mode: 0o700, create: create)
    }

    private func openHoldingDirectory(_ parent: FD, _ name: String, mode: mode_t, create: Bool) throws -> FD {
        let dir: FD
        do {
            (dir, _) = try openDirectory(parent, name, createMode: create ? mode : nil)
        } catch let f as Failure where f.code == "symlink" || f.code == "bad-path" {
            throw Failure("holding-unsafe")
        }
        var st = stat()
        guard fstat(dir.raw, &st) == 0, trustedOwners.contains(st.st_uid) else { throw Failure("holding-unsafe") }
        // 다른 사용자가 쓸 수 있으면 안 된다. 0700이어야 하는 폴더에 그룹·기타 권한이 있으면 바로잡는다.
        if (st.st_mode & (S_IWGRP | S_IWOTH)) != 0 || (mode == 0o700 && (st.st_mode & 0o077) != 0) {
            guard fchmod(dir.raw, mode) == 0 else { throw Failure("holding-unsafe") }
        }
        return dir
    }

    // MARK: 삭제

    private func removeTree(_ parent: FD, _ name: String) throws {
        let st = try lstatEntry(parent, name)
        if (st.st_mode & S_IFMT) == S_IFDIR {
            let (dir, _) = try openDirectory(parent, name)
            for child in try entries(of: dir) { try removeTree(dir, child) }
            guard unlinkat(parent.raw, name, AT_REMOVEDIR) == 0 else { throw Failure("remove-failed") }
        } else {
            guard unlinkat(parent.raw, name, 0) == 0 else { throw Failure("remove-failed") }
        }
    }

    private func entries(of dir: FD) throws -> [String] {
        let copy = dup(dir.raw)
        guard copy >= 0, let stream = fdopendir(copy) else {
            if copy >= 0 { close(copy) }
            throw Failure("remove-failed")
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    // MARK: 앱 번들

    /// `<name>/Contents/Info.plist`를 fd로 읽은 번들 ID (링크는 따라가지 않음)
    private func bundleIdentifier(ofAppNamed name: String, in parent: FD) -> String? {
        guard let (app, _) = try? openDirectory(parent, name),
              let (contents, _) = try? openDirectory(app, "Contents") else { return nil }
        let fd = openat(contents.raw, "Info.plist", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: 4 << 20),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["CFBundleIdentifier"] as? String
    }

    static func join(_ root: String, _ logical: String) -> String {
        root == "/" ? logical : root + logical
    }
}
