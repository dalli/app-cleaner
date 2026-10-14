import Foundation
import Darwin

/// 소유자·그룹·권한(mode)·확장 속성(xattr)·ACL 기록과 복원 (plan.md 6.2 "메타데이터 보존").
/// 심볼릭 링크는 따라가지 않는다 (`lstat`, `XATTR_NOFOLLOW`, `acl_get_link_np`).
public enum FileMetadataIO {
    public static func capture(_ url: URL) -> FileMetadata? {
        let path = url.path
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileMetadata(ownerID: st.st_uid, groupID: st.st_gid, mode: UInt16(st.st_mode & 0o7777),
                            xattrs: readXattrs(path), acl: readACL(path))
    }

    /// 적용하지 못한 부분은 경고 문구로 돌려준다 (복원 자체는 실패로 보지 않음).
    @discardableResult
    public static func apply(_ meta: FileMetadata, to url: URL) -> [String] {
        let path = url.path
        var warnings: [String] = []
        var st = stat()
        guard lstat(path, &st) == 0 else { return ["메타데이터를 적용할 항목이 없습니다"] }
        let isLink = (st.st_mode & S_IFMT) == S_IFLNK

        if st.st_uid != meta.ownerID || st.st_gid != meta.groupID {
            if lchown(path, meta.ownerID, meta.groupID) != 0 && errno != EPERM {
                warnings.append("소유자를 되돌리지 못했습니다")
            }
        }
        if !isLink, UInt16(st.st_mode & 0o7777) != meta.mode {
            if chmod(path, mode_t(meta.mode)) != 0 { warnings.append("권한(mode)을 되돌리지 못했습니다") }
        }
        for (name, value) in meta.xattrs {
            let rc = value.withUnsafeBytes { buf in
                setxattr(path, name, buf.baseAddress, buf.count, 0, XATTR_NOFOLLOW)
            }
            if rc != 0 { warnings.append("확장 속성을 되돌리지 못했습니다: \(name)") }
        }
        if let text = meta.acl, !text.isEmpty {
            if let acl = acl_from_text(text) {
                if acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) != 0 { warnings.append("ACL을 되돌리지 못했습니다") }
                acl_free(UnsafeMutableRawPointer(acl))
            } else {
                warnings.append("ACL을 해석하지 못했습니다")
            }
        }
        return warnings
    }

    static func readXattrs(_ path: String) -> [String: Data] {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: size)
        let got = listxattr(path, &names, size, XATTR_NOFOLLOW)
        guard got > 0 else { return [:] }
        var out: [String: Data] = [:]
        var start = 0
        for i in 0..<got where names[i] == 0 {
            let bytes = names[start..<i].map { UInt8(bitPattern: $0) }
            start = i + 1
            guard !bytes.isEmpty else { continue }
            let name = String(decoding: bytes, as: UTF8.self)
            let len = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard len >= 0 else { continue }
            var value = Data(count: len)
            let read = value.withUnsafeMutableBytes { buf in
                getxattr(path, name, buf.baseAddress, len, 0, XATTR_NOFOLLOW)
            }
            if read >= 0 { out[name] = value.prefix(read) }
        }
        return out
    }

    static func readACL(_ path: String) -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        let s = String(cString: text)
        return s.isEmpty ? nil : s
    }
}
