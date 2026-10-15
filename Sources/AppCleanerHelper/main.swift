import Foundation
import CleanerCore

// App Cleaner 권한 헬퍼 (LaunchDaemon, plan.md 5.3).
//
// 앱 번들 `Contents/MacOS/AppCleanerHelper`에 있고 `SMAppService.daemon(plistName:)`로 등록된다
// (`Contents/Library/LaunchDaemons/<BID>.Helper.plist`의 `MachServices`로 필요할 때 launchd가 실행).
// 명령 처리·검증은 모두 CleanerCore `PrivilegedCommandProcessor`에 있고, 여기서는 리스너만 연다.
//
// 클라이언트 요구사항: 자기 서명의 Team ID + 앱·번들 CLI 식별자
//   anchor apple generic and certificate leaf[subject.OU] = "<TEAM>" and (identifier "<BID>" or identifier "<BID>.cli")
// Team ID가 없는(ad-hoc 서명) 빌드는 연결을 받지 않는다. 단, `APPCLEANER_HELPER_DEV` 조건으로 컴파일한 개발 빌드
// (`HELPER_DEV=1 scripts/build-app.sh`)만 식별자 요구사항으로 받는다 — 배포 빌드에 쓰지 않는다.

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("AppCleanerHelper: \(message)\n".utf8))
    exit(code)
}

guard geteuid() == 0 else { fail("root로 실행해야 합니다 (launchd 전용)", EX_NOPERM) }

let signing = SelfCodeSignature.current()
#if APPCLEANER_HELPER_DEV
let identity = signing?.identifier.flatMap(PrivilegedHelperIdentity.init(helperIdentifier:)) ?? .default
#else
guard let identifier = signing?.identifier, let identity = PrivilegedHelperIdentity(helperIdentifier: identifier) else {
    fail("서명 식별자가 <BID>.Helper 형식이 아닙니다", EX_CONFIG)
}
#endif

let requirement: String
if let team = signing?.teamID, let r = CodeSigningRequirement.make(teamID: team, identifiers: identity.clientIdentifiers) {
    requirement = r
} else {
    #if APPCLEANER_HELPER_DEV
    guard let r = CodeSigningRequirement.development(identifiers: identity.clientIdentifiers) else { fail("식별자 오류", EX_CONFIG) }
    requirement = r
    FileHandle.standardError.write(Data("AppCleanerHelper: 개발 모드 — Team ID 없이 식별자만 확인합니다\n".utf8))
    #else
    fail("Team ID가 없는 서명입니다 (개발 빌드는 HELPER_DEV=1)", EX_CONFIG)
    #endif
}

umask(0o077)
let service = PrivilegedHelperService(processor: .live(identity: identity))
let delegate = PrivilegedHelperListenerDelegate(clientRequirement: requirement, service: service)
let listener = NSXPCListener(machServiceName: identity.machServiceName)
listener.delegate = delegate
listener.resume()
dispatchMain()
