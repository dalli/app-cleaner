import Foundation

/// 권한 상태 확인 (ui-ux.md S7·S8). TCC는 상태를 묻는 공개 API가 없으므로 보호된 파일을 열어 본다.
public enum PermissionProbe {
    /// 전체 디스크 접근: 전체 디스크 접근 권한이 있어야만 읽을 수 있는 파일을 열어 본다.
    public static func fullDiskAccess(paths: SystemPaths) -> PermissionStatus.State {
        let probes = [
            paths.home("Library/Application Support/com.apple.TCC/TCC.db"),
            paths.home("Library/Safari/Bookmarks.plist"),
            paths.home("Library/Containers/com.apple.stocks"),
        ]
        var sawDenied = false
        for url in probes {
            guard FileManager.default.itemExists(url) else { continue }
            if FileManager.default.isDirectory(url) {
                if (try? FileManager.default.contentsOfDirectory(atPath: url.path)) != nil { return .granted }
                sawDenied = true
                continue
            }
            let fd = open(url.path, O_RDONLY)
            if fd >= 0 { close(fd); return .granted }
            if errno == EPERM || errno == EACCES { sawDenied = true }
        }
        return sawDenied ? .denied : .unknown
    }
}
