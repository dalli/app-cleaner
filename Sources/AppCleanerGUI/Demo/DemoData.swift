import CleanerCore
import Foundation

/// 데모 엔진의 가짜 데이터 (ui-ux.md 시나리오). 경로 문자열만 만들고 파일 시스템은 건드리지 않는다.
enum DemoData {
    static let ruleVersion = "2026.10.1"
    static let home = NSHomeDirectory()
    /// 실제 엔진(`SystemPaths.live`)과 같은 보류 폴더 위치
    static let holdingDir = "/Library/Application Support/\(SystemPaths.ourAppFolderName)/Holding"

    static let KB: Int64 = 1_000
    static let MB: Int64 = 1_000_000
    static let GB: Int64 = 1_000_000_000

    static func url(_ path: String) -> URL {
        URL(filePath: path.hasPrefix("~") ? home + path.dropFirst() : path, directoryHint: .notDirectory)
    }

    static func ago(days: Double, from now: Date = Date()) -> Date { now.addingTimeInterval(-days * 86_400) }

    // MARK: 후보 생성 도우미

    /// 기본 선택은 엔진 SelectionPolicy 규칙을 흉내 낸다 (plan.md 4.3).
    /// 앱 제거: 높음·보통 + 재생성/설정 + 단독 소유. 고아(`orphan: true`): 높음만.
    static func item(
        _ path: String, _ category: ItemCategory, _ confidence: Confidence,
        nature: DataNature? = nil, share: ShareStatus = .exclusive, domain: Domain = .user,
        evidence: [Evidence] = [], protection: ProtectionReason? = nil, selected: Bool? = nil,
        size: Int64?, files: Int? = nil, modifiedDaysAgo: Double? = 3,
        service: LaunchServiceRef? = nil, prefsDomain: String? = nil,
        children: [Candidate] = [], notes: [EngineText] = [], orphan: Bool = false
    ) -> Candidate {
        let n = nature ?? category.defaultNature
        let minimum: Confidence = orphan ? .high : .medium
        let isSelected = selected ?? (confidence >= minimum && n.selectableByDefault && !share.isShared && protection == nil)
        let total = children.isEmpty ? size : children.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        return Candidate(
            url: url(path), category: category, domain: domain, confidence: confidence, nature: n, share: share,
            evidence: evidence, protection: protection, isSelected: isSelected, size: total, fileCount: files,
            lastModified: modifiedDaysAgo.map { ago(days: $0) }, launchService: service,
            preferencesDomain: prefsDomain, children: children, notes: notes
        )
    }

    // MARK: S1 설치 앱

    struct DemoApp {
        var app: InstalledApp
        /// 처음에는 nil로 보여주고 `size(of:)`에서 계산
        var lazySize: Int64
        var teamID: String?
    }

    static func installedApps(now: Date = Date()) -> [DemoApp] {
        func a(_ name: String, _ bid: String, _ version: String, _ source: InstallSource, size: Int64,
               lazy: Bool = false, lastUsedDays: Double?, running: Bool = false, team: String? = nil) -> DemoApp {
            DemoApp(app: InstalledApp(url: url("/Applications/\(name).app"), bundleID: bid, name: name, version: version,
                                      source: source, size: lazy ? nil : size,
                                      lastUsed: lastUsedDays.map { ago(days: $0, from: now) }, isRunning: running),
                    lazySize: size, teamID: team)
        }
        return [
            a("Microsoft Word", "com.microsoft.Word", "16.89", .appStore, size: 2_100 * MB, lastUsedDays: 0, running: true, team: "UBF8T346G9"),
            a("Microsoft Excel", "com.microsoft.Excel", "16.89", .appStore, size: 1_900 * MB, lazy: true, lastUsedDays: 2, team: "UBF8T346G9"),
            a("Microsoft PowerPoint", "com.microsoft.Powerpoint", "16.89", .appStore, size: 1_700 * MB, lazy: true, lastUsedDays: 40, team: "UBF8T346G9"),
            a("Docker", "com.docker.docker", "4.34.2", .homebrew, size: 1_800 * MB, lastUsedDays: 14),
            a("Slack", "com.tinyspeck.slackmacgap", "4.41.97", .direct, size: 410 * MB, lastUsedDays: 1, team: "BQR82RBBHL"),
            a("Cursor", "com.todesktop.230313mzl4w4u92", "1.7.2", .direct, size: 612 * MB, lazy: true, lastUsedDays: 1),
            a("Figma", "com.figma.Desktop", "125.8", .direct, size: 520 * MB, lazy: true, lastUsedDays: 3),
            a("Zoom", "us.zoom.xos", "6.2.5", .package, size: 410 * MB, lastUsedDays: 92),
            a("Notion", "notion.id", "4.2.0", .homebrew, size: 305 * MB, lazy: true, lastUsedDays: 7),
            a("Spotify", "com.spotify.client", "1.2.47", .direct, size: 290 * MB, lastUsedDays: 200),
            a("Raycast", "com.raycast.macos", "1.84.3", .homebrew, size: 160 * MB, lazy: true, lastUsedDays: 0, running: true),
            a("Things 3", "com.culturedcode.ThingsMac", "3.21", .appStore, size: 98 * MB, lastUsedDays: 260),
            a("Keka", "com.aone.keka", "1.4.4", .homebrew, size: 54 * MB, lazy: true, lastUsedDays: 31),
            a("Pixelmator Pro", "com.pixelmatorteam.pixelmator.x", "3.6.8", .appStore, size: 780 * MB, lazy: true, lastUsedDays: 410),
        ]
    }

    // MARK: S2 검사 결과

    static func scanReport(for url: URL, apps: [DemoApp]) -> ScanReport {
        let match = apps.first { $0.app.url.path == url.path }
        let bid = match?.app.bundleID ?? "com.example." + url.deletingPathExtension().lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "")
        switch bid {
        case "com.microsoft.Word": return word(url)
        case "com.tinyspeck.slackmacgap": return slack(url)
        case "com.docker.docker": return docker(url)
        default: return generic(url, app: match)
        }
    }

    static func word(_ appURL: URL) -> ScanReport {
        let bid = "com.microsoft.Word"
        let container = "~/Library/Containers/\(bid)"
        let identity = AppIdentity(bundleURL: appURL, bundleID: bid, name: "Microsoft Word", version: "16.89",
                                   teamID: "UBF8T346G9", appGroups: ["UBF8T346G9.Office"], source: .appStore)
        let office = ["Microsoft Excel", "Microsoft PowerPoint", "Microsoft Outlook"]
        let candidates: [Candidate] = [
            item(appURL.path, .appBundle, .high, domain: .system,
                 evidence: [Evidence(.bundleIdentifier, .verbatim(L("선택한 앱 본체")))], size: 2_100 * MB, files: 6_812, modifiedDaysAgo: 12,
                 notes: []),
            item(container, .container, .high,
                 evidence: [Evidence(.containerMetadata, .verbatim(L("컨테이너 메타데이터의 번들 ID가 %@와 일치", bid)))],
                 size: nil, modifiedDaysAgo: 0, children: [
                    item(container + "/Data/Library/Caches", .containerItem, .high, nature: .regenerable,
                         evidence: [Evidence(.containerMetadata, .verbatim(L("앱 컨테이너 안의 캐시")))], size: 820 * MB, files: 3_120, modifiedDaysAgo: 0),
                    item(container + "/Data/Library/Preferences", .containerItem, .high, nature: .settings,
                         evidence: [Evidence(.containerMetadata, .verbatim(L("앱 컨테이너 안의 환경설정")))], size: 48 * KB, files: 6, modifiedDaysAgo: 0),
                    item(container + "/Data/Documents", .containerItem, .high, nature: .userData,
                         evidence: [Evidence(.containerMetadata, .verbatim(L("비어 있지 않은 Data/Documents")))], size: 1_200 * MB, files: 37,
                         modifiedDaysAgo: 2, notes: [.verbatim(L("문서 37개 포함 · 마지막 수정 2일 전 — 기본으로 남겨 둡니다"))]),
                 ]),
            item("~/Library/Group Containers/UBF8T346G9.Office", .groupContainer, .high,
                 share: .shared(usedBy: office, reason: .verbatim(L("이 폴더를 지우면 세 앱의 로그인 정보와 최근 문서 목록이 초기화됩니다."))),
                 evidence: [Evidence(.appGroup, .verbatim(L("코드 서명의 App Group과 정확히 일치"))), Evidence(.homebrewZap, .verbatim(L("Homebrew zap 규칙에 포함")))],
                 size: 3_100 * MB, files: 1_284, modifiedDaysAgo: 0.1),
            item("~/Library/LaunchAgents/com.microsoft.update.agent.plist", .launchAgent, .medium,
                 share: .shared(usedBy: ["Microsoft AutoUpdate"], reason: .verbatim(L("실행 파일이 앱 밖(/Library/Application Support/Microsoft/MAU2.0)에 있고 같은 개발사의 다른 앱이 설치되어 있습니다."))),
                 evidence: [Evidence(.launchPlist, .verbatim(L("Label이 같은 개발사(UBF8T346G9)의 업데이트 도구를 가리킴")))],
                 size: 4 * KB, modifiedDaysAgo: 30,
                 service: LaunchServiceRef(label: "com.microsoft.update.agent", domain: .user),
                 notes: [.verbatim(L("Microsoft AutoUpdate — 같은 개발사의 다른 앱이 사용"))]),
            item("~/Library/Caches/\(bid)", .caches, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("번들 ID 정확 일치")))], size: 60 * MB, files: 412, modifiedDaysAgo: 0),
            item("~/Library/HTTPStorages/\(bid)", .httpStorage, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("번들 ID 정확 일치")))], size: 2 * MB, modifiedDaysAgo: 0),
            item("~/Library/WebKit/\(bid)", .webKit, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("번들 ID 정확 일치")))], size: 12 * MB, modifiedDaysAgo: 1),
            item("~/Library/Saved Application State/\(bid).savedState", .savedState, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("<번들 ID>.savedState")))], size: 1 * MB, modifiedDaysAgo: 0),
            item("~/Library/Logs/Microsoft Word", .logs, .medium, evidence: [Evidence(.name, .verbatim(L("폴더 이름이 앱 이름과 정확히 일치")))], size: 21 * MB, modifiedDaysAgo: 0,
                 notes: [.verbatim(L("이름이 일치해서 찾았습니다 — 확인 후 정리하세요"))]),
            item("~/Library/Preferences/\(bid).plist", .preferences, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("번들 ID 정확 일치")))],
                 size: 72 * KB, modifiedDaysAgo: 0, prefsDomain: bid),
            item("~/Library/Preferences/ByHost/\(bid).8C1F2A7E-5B3D-4E21-9A0B-7D6C5E4F3A21.plist", .byHostPreferences, .high,
                 evidence: [Evidence(.bundleIdentifier, .verbatim(L("ByHost/<번들 ID>.<UUID>.plist")))], size: 48 * KB, modifiedDaysAgo: 5),
            item("~/Library/Logs/DiagnosticReports/Microsoft Word_2026-09-30-101522.ips", .diagnosticReports, .low,
                 evidence: [Evidence(.name, .verbatim(L("진단 리포트 파일 이름 패턴")))], size: 420 * KB, modifiedDaysAgo: 14),
            item("~/Library/Logs/DiagnosticReports/Microsoft Word_2026-08-11-084410.ips", .diagnosticReports, .low,
                 evidence: [Evidence(.name, .verbatim(L("진단 리포트 파일 이름 패턴")))], size: 380 * KB, modifiedDaysAgo: 64),
            item("~/Library/Application Support/Microsoft", .applicationSupport, .low,
                 share: .shared(usedBy: ["Microsoft Excel", "Microsoft PowerPoint"], reason: .verbatim(L("같은 개발사(UBF8T346G9)의 다른 앱이 설치되어 있어 벤더 공용 폴더로 판정했습니다."))),
                 evidence: [Evidence(.teamIdentifier, .verbatim(L("벤더 공용 폴더 이름")))], size: 2 * MB, modifiedDaysAgo: 3),
            item("~/Library/Caches/Microsoft", .caches, .low, evidence: [Evidence(.name, .verbatim(L("벤더 이름만 일치")))], size: 300 * KB, modifiedDaysAgo: 3),
        ]
        return ScanReport(identity: identity, candidates: candidates, warnings: [.appRunning],
                          advisories: [.loginItems, .keychain(searchTerm: "Microsoft")], ruleDataVersion: ruleVersion)
    }

    static func slack(_ appURL: URL) -> ScanReport {
        let bid = "com.tinyspeck.slackmacgap"
        let container = "~/Library/Containers/\(bid)"
        let identity = AppIdentity(bundleURL: appURL, bundleID: bid, name: "Slack", version: "4.41.97", teamID: "BQR82RBBHL", source: .direct)
        let candidates: [Candidate] = [
            item(appURL.path, .appBundle, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("선택한 앱 본체")))], size: 410 * MB, files: 1_904, modifiedDaysAgo: 9),
            item(container, .container, .high, evidence: [Evidence(.containerMetadata, .verbatim(L("컨테이너 메타데이터의 번들 ID가 %@와 일치", bid)))],
                 size: nil, children: [
                    item(container + "/Data/Library/Caches", .containerItem, .high, nature: .regenerable,
                         evidence: [Evidence(.containerMetadata, .verbatim(L("앱 컨테이너 안의 캐시")))], size: 180 * MB, modifiedDaysAgo: 1),
                    item(container + "/Data/Library/Preferences", .containerItem, .high, nature: .settings,
                         evidence: [Evidence(.containerMetadata, .verbatim(L("앱 컨테이너 안의 환경설정")))], size: 12 * KB, modifiedDaysAgo: 1),
                    item(container + "/Data/Library/Application Support/Slack", .containerItem, .high, nature: .userData,
                         evidence: [Evidence(.containerMetadata, .verbatim(L("메시지 데이터베이스(*.sqlite) 포함")))], size: 640 * MB, files: 214,
                         modifiedDaysAgo: 1, notes: [.verbatim(L("메시지 데이터베이스 포함 · 기본으로 남겨 둡니다"))]),
                 ]),
            item("~/Library/Mobile Documents/iCloud~com~tinyspeck~slackmacgap", .iCloudContainer, .high,
                 evidence: [Evidence(.bundleIdentifier, .verbatim(L("iCloud 컨테이너 이름이 번들 ID와 일치")))], protection: .iCloudData,
                 size: 3 * MB, modifiedDaysAgo: 20),
            item("~/Library/LaunchAgents/\(bid).ShipIt.plist", .launchAgent, .high,
                 evidence: [Evidence(.launchPlist, .verbatim(L("Program이 /Applications/Slack.app/Contents/Frameworks/Squirrel.framework/Resources/ShipIt을 가리킴")))],
                 size: 4 * KB, modifiedDaysAgo: 9, service: LaunchServiceRef(label: "\(bid).ShipIt", domain: .user)),
            item("~/Library/Caches/\(bid)", .caches, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("번들 ID 정확 일치")))], size: 210 * MB, modifiedDaysAgo: 1),
            item("~/Library/Caches/\(bid).ShipIt", .caches, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("<번들 ID>. 접두사")))], size: 84 * MB, modifiedDaysAgo: 9),
            item("~/Library/Saved Application State/\(bid).savedState", .savedState, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("<번들 ID>.savedState")))], size: 500 * KB, modifiedDaysAgo: 1),
            item("~/Library/Preferences/\(bid).plist", .preferences, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("번들 ID 정확 일치")))], size: 36 * KB, modifiedDaysAgo: 1, prefsDomain: bid),
            item("~/Library/Application Support/Slack", .applicationSupport, .medium, nature: .settings,
                 evidence: [Evidence(.name, .verbatim(L("폴더 이름이 앱 이름과 정확히 일치"))), Evidence(.homebrewZap, .verbatim(L("Homebrew zap 규칙에 포함")))],
                 size: 95 * MB, modifiedDaysAgo: 1, notes: [.verbatim(L("이름이 일치해서 찾았습니다 — 확인 후 정리하세요"))]),
            item("~/Library/Logs/DiagnosticReports/Slack_2026-10-01-120044.ips", .diagnosticReports, .low,
                 evidence: [Evidence(.name, .verbatim(L("진단 리포트 파일 이름 패턴")))], size: 220 * KB, modifiedDaysAgo: 13),
        ]
        return ScanReport(identity: identity, candidates: candidates, warnings: [],
                          advisories: [.loginItems, .keychain(searchTerm: "Slack")], ruleDataVersion: ruleVersion)
    }

    static func docker(_ appURL: URL) -> ScanReport {
        let bid = "com.docker.docker"
        let identity = AppIdentity(bundleURL: appURL, bundleID: bid, name: "Docker", version: "4.34.2", teamID: "9BNSXJN65R",
                                   appGroups: ["group.com.docker"], homebrewCask: "docker", source: .homebrew)
        let candidates: [Candidate] = [
            item(appURL.path, .appBundle, .high, evidence: [Evidence(.homebrewRecord, .verbatim(L("Caskroom 기록과 일치")))], size: 1_800 * MB, modifiedDaysAgo: 20),
            item("~/Library/Group Containers/group.com.docker", .groupContainer, .high, nature: .userData,
                 evidence: [Evidence(.appGroup, .verbatim(L("코드 서명의 App Group과 정확히 일치")))], size: 22_400 * MB, files: 41, modifiedDaysAgo: 14,
                 notes: [.verbatim(L("가상 디스크(Docker.raw) 포함 · 컨테이너와 이미지가 들어 있습니다"))]),
            item("/Library/LaunchDaemons/com.docker.vmnetd.plist", .launchDaemon, .high, domain: .system,
                 evidence: [Evidence(.launchPlist, .verbatim(L("Program이 /Library/PrivilegedHelperTools/com.docker.vmnetd를 가리킴")))],
                 size: 4 * KB, modifiedDaysAgo: 120, service: LaunchServiceRef(label: "com.docker.vmnetd", domain: .system)),
            item("/Library/PrivilegedHelperTools/com.docker.vmnetd", .privilegedHelper, .high, domain: .system,
                 evidence: [Evidence(.launchPlist, .verbatim(L("LaunchDaemon이 실행하는 헬퍼")))], size: 3 * MB, modifiedDaysAgo: 120),
            item("~/Library/Caches/\(bid)", .caches, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("번들 ID 정확 일치")))], size: 140 * MB, modifiedDaysAgo: 14),
            item("~/Library/Preferences/\(bid).plist", .preferences, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("번들 ID 정확 일치")))], size: 8 * KB, modifiedDaysAgo: 14, prefsDomain: bid),
            item("~/.docker", .dotfile, .low, nature: .settings, evidence: [Evidence(.name, .verbatim(L("이름 기반 dotfile")))], size: 18 * MB, modifiedDaysAgo: 14,
                 notes: [.verbatim(L("명령줄 도구 설정이 들어 있을 수 있습니다"))]),
        ]
        return ScanReport(identity: identity, candidates: candidates, warnings: [.otherCopies([url("/Volumes/Backup/Applications/Docker.app")])],
                          advisories: [.loginItems, .homebrewZap(token: "docker")], ruleDataVersion: ruleVersion)
    }

    static func generic(_ appURL: URL, app: DemoApp?) -> ScanReport {
        let name = app?.app.name ?? appURL.deletingPathExtension().lastPathComponent
        let bid = app?.app.bundleID ?? "com.example." + name.lowercased().replacingOccurrences(of: " ", with: "")
        let identity = AppIdentity(bundleURL: appURL, bundleID: bid, name: name, version: app?.app.version ?? "1.0",
                                   teamID: app?.teamID, source: app?.app.source ?? .direct)
        let candidates: [Candidate] = [
            item(appURL.path, .appBundle, .high, domain: app?.app.source == .appStore ? .system : .user,
                 evidence: [Evidence(.bundleIdentifier, .verbatim(L("선택한 앱 본체")))], size: app?.lazySize ?? 120 * MB, modifiedDaysAgo: 30),
            item("~/Library/Application Support/\(name)", .applicationSupport, .medium, evidence: [Evidence(.name, .verbatim(L("폴더 이름이 앱 이름과 정확히 일치")))],
                 size: 46 * MB, modifiedDaysAgo: 2, notes: [.verbatim(L("이름이 일치해서 찾았습니다 — 확인 후 정리하세요"))]),
            item("~/Library/Caches/\(bid)", .caches, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("번들 ID 정확 일치")))], size: 38 * MB, modifiedDaysAgo: 2),
            item("~/Library/Saved Application State/\(bid).savedState", .savedState, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("<번들 ID>.savedState")))], size: 300 * KB, modifiedDaysAgo: 2),
            item("~/Library/Preferences/\(bid).plist", .preferences, .high, evidence: [Evidence(.bundleIdentifier, .verbatim(L("번들 ID 정확 일치")))], size: 20 * KB, modifiedDaysAgo: 2, prefsDomain: bid),
            item("~/Library/Logs/DiagnosticReports/\(name)_2026-09-21-094012.ips", .diagnosticReports, .low,
                 evidence: [Evidence(.name, .verbatim(L("진단 리포트 파일 이름 패턴")))], size: 150 * KB, modifiedDaysAgo: 23),
        ]
        return ScanReport(identity: identity, candidates: candidates, advisories: [.loginItems, .keychain(searchTerm: name)],
                          ruleDataVersion: ruleVersion)
    }

    // MARK: S5 고아 잔여물

    // MARK: Homebrew

    static let brewPrefix = "/opt/homebrew"

    static func homebrewItems() -> [HomebrewItem] {
        func formula(_ name: String, _ version: String, dependency: Bool = false) -> HomebrewItem {
            HomebrewItem(kind: .formula, name: name, version: version, location: URL(filePath: "\(brewPrefix)/Cellar/\(name)"),
                         installedOnRequest: !dependency)
        }
        func cask(_ name: String, _ version: String, app: String? = nil) -> HomebrewItem {
            let room = URL(filePath: "\(brewPrefix)/Caskroom/\(name)")
            return HomebrewItem(kind: .cask, name: name, version: version, location: room,
                                contentPaths: [room] + (app.map { [URL(filePath: "/Applications/\($0)")] } ?? []),
                                apps: app.map { [$0] } ?? [])
        }
        return [
            formula("ffmpeg", "8.0_1"), formula("gh", "2.80.0"), formula("git", "2.51.0"), formula("node", "24.9.0"),
            formula("openssl@3", "3.5.4", dependency: true), formula("libpng", "1.6.50", dependency: true),
            formula("icu4c@77", "77.1_1", dependency: true),
            cask("docker", "4.34.2", app: "Docker.app"), cask("raycast", "1.84.3", app: "Raycast.app"),
            cask("font-jetbrains-mono", "2.304"),
        ]
    }

    static let homebrewSizes: [String: Int64] = [
        "\(brewPrefix)/Cellar/ffmpeg": 52 * MB, "\(brewPrefix)/Cellar/gh": 48 * MB, "\(brewPrefix)/Cellar/git": 61 * MB,
        "\(brewPrefix)/Cellar/node": 91 * MB, "\(brewPrefix)/Cellar/openssl@3": 34 * MB, "\(brewPrefix)/Cellar/libpng": 1_400 * KB,
        "\(brewPrefix)/Cellar/icu4c@77": 82 * MB, "\(brewPrefix)/Caskroom/docker": 12 * KB, "\(brewPrefix)/Caskroom/raycast": 8 * KB,
        "\(brewPrefix)/Caskroom/font-jetbrains-mono": 5_600 * KB,
    ]

    static func orphanGroups() -> [OrphanGroup] {
        let slackBID = "com.tinyspeck.slackmacgap"
        func o(_ path: String, _ cat: ItemCategory, _ conf: Confidence, nature: DataNature? = nil, share: ShareStatus = .exclusive,
               _ why: String, source: EvidenceSource = .inventory, size: Int64, days: Double, service: LaunchServiceRef? = nil) -> Candidate {
            item(path, cat, conf, nature: nature, share: share, evidence: [Evidence(source, .verbatim(why))], size: size,
                 modifiedDaysAgo: days, service: service, orphan: true)
        }
        let slack = OrphanGroup(id: slackBID, displayName: "Slack", nameIsGuess: false, bundleID: slackBID, items: [
            o("~/Library/LaunchAgents/\(slackBID).ShipIt.plist", .launchAgent, .high,
              L("실행 파일 /Applications/Slack.app/…/ShipIt 이 없음 (깨진 백그라운드 서비스)"), source: .launchPlist, size: 4 * KB, days: 226,
              service: LaunchServiceRef(label: "\(slackBID).ShipIt", domain: .user)),
            o("~/Library/Caches/\(slackBID).ShipIt", .caches, .high, L("같은 앱의 높음 근거와 묶여 승격 (원래 보통)"), size: 84 * MB, days: 226),
            o("~/Library/Application Support/Slack", .applicationSupport, .medium, nature: .userData,
              L("폴더 이름 \"Slack\"과 일치하는 설치 앱 없음"), source: .name, size: 1_100 * MB, days: 226),
            o("~/Library/Caches/\(slackBID)", .caches, .high, L("번들 ID와 일치하는 설치 앱 없음"), size: 96 * MB, days: 226),
            o("~/Library/Preferences/\(slackBID).plist", .preferences, .high, L("번들 ID와 일치하는 설치 앱 없음"), size: 36 * KB, days: 226),
            o("~/Library/Saved Application State/\(slackBID).savedState", .savedState, .high, L("번들 ID와 일치하는 설치 앱 없음"), size: 400 * KB, days: 226),
            o("~/Library/HTTPStorages/\(slackBID)", .httpStorage, .high, L("번들 ID와 일치하는 설치 앱 없음"), size: 2 * MB, days: 226),
            o("~/Library/WebKit/\(slackBID)", .webKit, .high, L("번들 ID와 일치하는 설치 앱 없음"), size: 9 * MB, days: 226),
            o("~/Library/Logs/Slack", .logs, .medium, L("폴더 이름 \"Slack\"과 일치하는 설치 앱 없음"), source: .name, size: 7 * MB, days: 226),
        ], confidence: .high)

        let skypeBID = "com.skype.skype"
        let skype = OrphanGroup(id: skypeBID, displayName: "Skype", nameIsGuess: false, bundleID: skypeBID, items: [
            o("~/Library/Containers/\(skypeBID)", .container, .high, L("컨테이너 메타데이터의 앱이 설치되어 있지 않음"), source: .containerMetadata, size: 210 * MB, days: 328),
            o("~/Library/Caches/\(skypeBID)", .caches, .high, L("번들 ID와 일치하는 설치 앱 없음"), size: 72 * MB, days: 328),
            o("~/Library/Preferences/\(skypeBID).plist", .preferences, .high, L("번들 ID와 일치하는 설치 앱 없음"), size: 24 * KB, days: 328),
            o("~/Library/Saved Application State/\(skypeBID).savedState", .savedState, .high, L("번들 ID와 일치하는 설치 앱 없음"), size: 200 * KB, days: 328),
            o("~/Library/HTTPStorages/\(skypeBID)", .httpStorage, .high, L("번들 ID와 일치하는 설치 앱 없음"), size: 3 * MB, days: 328),
            o("~/Library/Logs/Skype Helper", .logs, .high, L("같은 앱의 높음 근거와 묶여 승격"), size: 25 * MB, days: 328),
        ], confidence: .high)

        let davinci = OrphanGroup(id: "name:davinci resolve", displayName: "DaVinci Resolve", nameIsGuess: false, items: [
            o("~/Library/Application Support/Blackmagic Design/DaVinci Resolve", .applicationSupport, .low, nature: .userData,
              L("외장 볼륨의 앱을 확인하지 못해 낮음으로 낮춤"), source: .name, size: 240 * MB, days: 3),
            o("~/Library/Preferences/Blackmagic Design/DaVinci Resolve", .preferences, .low, L("외장 볼륨의 앱을 확인하지 못해 낮음으로 낮춤"), source: .name, size: 2 * MB, days: 3),
            o("~/Library/Caches/com.blackmagic-design.DaVinciResolve", .caches, .low, L("외장 볼륨의 앱을 확인하지 못해 낮음으로 낮춤"), size: 46 * MB, days: 3),
            o("~/Library/Logs/DaVinci Resolve", .logs, .low, L("외장 볼륨의 앱을 확인하지 못해 낮음으로 낮춤"), source: .name, size: 2 * MB, days: 3),
        ], confidence: .low, notes: [.verbatim(L("외장 볼륨 \"Media\"에 앱이 있을 수 있음"))])

        let charlesBID = "com.xk72.Charles"
        let charles = OrphanGroup(id: charlesBID, displayName: "Charles", nameIsGuess: true, bundleID: charlesBID, items: [
            o("~/Library/Application Support/Charles", .applicationSupport, .medium, L("번들 ID 접두사로만 판정"), source: .bundleIdentifier, size: 41 * MB, days: 125),
            o("~/Library/Preferences/\(charlesBID).plist", .preferences, .medium, L("번들 ID와 일치하는 설치 앱 없음 (이름은 추정)"), source: .bundleIdentifier, size: 16 * KB, days: 125),
            o("~/Library/Caches/\(charlesBID)", .caches, .medium, L("번들 ID와 일치하는 설치 앱 없음 (이름은 추정)"), source: .bundleIdentifier, size: 17 * MB, days: 125),
        ], confidence: .medium, notes: [.verbatim(L("번들 ID로만 판정"))])

        let google = OrphanGroup(id: "vendor:google", displayName: L("%@ 공용 폴더", "Google"), nameIsGuess: false, teamID: "EQHXZ8M8AV", items: [
            o("~/Library/Application Support/Google", .applicationSupport, .low,
              share: .shared(usedBy: ["Google Chrome"], reason: .verbatim(L("같은 개발사의 Chrome이 설치되어 있음"))),
              L("벤더 공용 폴더 — 같은 Team ID의 앱이 설치되어 있음"), source: .teamIdentifier, size: 38 * MB, days: 60),
            o("~/Library/Caches/Google", .caches, .low,
              share: .shared(usedBy: ["Google Chrome"], reason: .verbatim(L("같은 개발사의 Chrome이 설치되어 있음"))),
              L("벤더 공용 폴더 — 같은 Team ID의 앱이 설치되어 있음"), source: .teamIdentifier, size: 4 * MB, days: 60),
        ], confidence: .low, share: .shared(usedBy: ["Google Chrome"], reason: .verbatim(L("같은 개발사의 Chrome이 설치되어 있음"))),
           notes: [.verbatim(L("같은 개발사의 Chrome이 설치되어 있음"))])

        let adobe = OrphanGroup(id: "vendor:adobe", displayName: L("%@ 공용 폴더", "Adobe"), nameIsGuess: false, items: [
            o("~/Library/Application Support/Adobe", .applicationSupport, .low, L("벤더 공용 폴더"), source: .teamIdentifier, size: 120 * MB, days: 90),
        ], confidence: .low)
        let jetbrains = OrphanGroup(id: "vendor:jetbrains", displayName: L("%@ 공용 폴더", "JetBrains"), nameIsGuess: false, items: [
            o("~/Library/Application Support/JetBrains", .applicationSupport, .low, L("벤더 공용 폴더"), source: .teamIdentifier, size: 300 * MB, days: 50),
        ], confidence: .low)
        let steam = OrphanGroup(id: "name:steam", displayName: "Steam", nameIsGuess: true, items: [
            o("~/Library/Application Support/Steam", .applicationSupport, .medium, nature: .userData, L("폴더 이름과 일치하는 설치 앱 없음"), source: .name, size: 4_200 * MB, days: 40),
        ], confidence: .medium)

        return [slack, skype, davinci, charles, google, adobe, jetbrains, steam]
    }

    static func initialKeepList(now: Date = Date()) -> [KeepEntry] {
        [
            KeepEntry(kind: .group, key: "vendor:adobe", displayName: L("%@ 공용 폴더", "Adobe"), addedAt: ago(days: 41, from: now)),
            KeepEntry(kind: .item, key: home + "/Library/Application Support/Steam", displayName: "~/Library/Application Support/Steam", addedAt: ago(days: 41, from: now)),
            KeepEntry(kind: .group, key: "vendor:jetbrains", displayName: L("%@ 공용 폴더", "JetBrains"), addedAt: ago(days: 54, from: now)),
        ]
    }

    // MARK: S6 삭제 기록

    static func sessions(now: Date = Date()) -> [JournalSession] {
        func ji(_ path: String, _ dest: MoveDestination, _ size: Int64, _ cat: ItemCategory, sessionID: UUID,
                restored: Date? = nil, conf: Confidence = .high) -> JournalItem {
            let full = path.hasPrefix("~") ? home + path.dropFirst() : path
            let moved = dest == .trash
                ? home + "/.Trash/" + (full as NSString).lastPathComponent
                : holdingDir + "/\(sessionID.uuidString)" + full
            return JournalItem(originalPath: full, movedTo: moved, destination: dest, size: size, category: cat,
                               confidence: conf, share: .exclusive, nature: cat.defaultNature, sources: [.bundleIdentifier],
                               restoredAt: restored)
        }
        let steps = [CleanupStep.stopServices, .terminateApps, .flushPreferences, .moveItems].map(\.rawValue)

        let wordID = UUID()
        let wordBID = "com.microsoft.Word"
        let word = JournalSession(
            id: wordID, kind: .appRemoval, targetName: "Microsoft Word", targetBundleID: wordBID,
            startedAt: ago(days: 0.02, from: now), finishedAt: ago(days: 0.02, from: now).addingTimeInterval(6),
            ruleDataVersion: ruleVersion, steps: steps,
            items: [
                ji("/Applications/Microsoft Word.app", .trash, 2_100 * MB, .appBundle, sessionID: wordID),
                ji("~/Library/Containers/\(wordBID)/Data/Library/Caches", .trash, 820 * MB, .containerItem, sessionID: wordID),
                ji("~/Library/Preferences/\(wordBID).plist", .trash, 72 * KB, .preferences, sessionID: wordID),
                ji("~/Library/Caches/\(wordBID)", .trash, 60 * MB, .caches, sessionID: wordID),
                ji("~/Library/WebKit/\(wordBID)", .trash, 12 * MB, .webKit, sessionID: wordID),
            ],
            stoppedServices: [LaunchServiceRef(label: "com.microsoft.Word.helper", domain: .user)],
            preferencesBackups: [PreferencesBackup(domain: wordBID, backupPath: "/Library/Application Support/App Cleaner/Backups/\(wordBID).plist")],
            status: .restorable)

        let orphanID = UUID()
        let orphan = JournalSession(
            id: orphanID, kind: .orphanCleanup, targetName: L("%@ 외 %lld개", "Slack", 1), startedAt: ago(days: 1.1, from: now),
            finishedAt: ago(days: 1.1, from: now).addingTimeInterval(4), ruleDataVersion: ruleVersion,
            steps: [CleanupStep.stopServices.rawValue, CleanupStep.moveItems.rawValue],
            items: [
                ji("~/Library/LaunchAgents/com.tinyspeck.slackmacgap.ShipIt.plist", .trash, 4 * KB, .launchAgent, sessionID: orphanID),
                ji("~/Library/Caches/com.tinyspeck.slackmacgap.ShipIt", .trash, 84 * MB, .caches, sessionID: orphanID),
                ji("~/Library/Caches/com.skype.skype", .trash, 72 * MB, .caches, sessionID: orphanID),
            ],
            stoppedServices: [LaunchServiceRef(label: "com.tinyspeck.slackmacgap.ShipIt", domain: .user)],
            status: .restorable)

        let dockerID = UUID()
        let docker = JournalSession(
            id: dockerID, kind: .appRemoval, targetName: "Docker", targetBundleID: "com.docker.docker",
            startedAt: ago(days: 12, from: now), finishedAt: ago(days: 12, from: now).addingTimeInterval(14),
            ruleDataVersion: "2026.09.3", steps: steps,
            items: [
                ji("/Applications/Docker.app", .trash, 1_800 * MB, .appBundle, sessionID: dockerID),
                ji("/Library/LaunchDaemons/com.docker.vmnetd.plist", .holding, 4 * KB, .launchDaemon, sessionID: dockerID),
                ji("/Library/PrivilegedHelperTools/com.docker.vmnetd", .holding, 3 * MB, .privilegedHelper, sessionID: dockerID),
                ji("~/Library/Caches/com.docker.docker", .trash, 140 * MB, .caches, sessionID: dockerID),
                ji("~/Library/Preferences/com.docker.docker.plist", .trash, 8 * KB, .preferences, sessionID: dockerID),
            ],
            stoppedServices: [LaunchServiceRef(label: "com.docker.vmnetd", domain: .system)],
            status: .partiallyRestorable,
            missingItems: [home + "/Library/Caches/com.docker.docker", home + "/Library/Preferences/com.docker.docker.plist"])

        let zoomID = UUID()
        let zoomRestored = ago(days: 25, from: now)
        let zoom = JournalSession(
            id: zoomID, kind: .appRemoval, targetName: "Zoom", targetBundleID: "us.zoom.xos",
            startedAt: ago(days: 26, from: now), finishedAt: ago(days: 26, from: now).addingTimeInterval(5),
            ruleDataVersion: "2026.09.1", steps: steps,
            items: [
                ji("/Applications/zoom.us.app", .trash, 180 * MB, .appBundle, sessionID: zoomID, restored: zoomRestored),
                ji("~/Library/Caches/us.zoom.xos", .trash, 40 * MB, .caches, sessionID: zoomID, restored: zoomRestored),
            ],
            status: .restored)

        let oldID = UUID()
        let old = JournalSession(
            id: oldID, kind: .orphanCleanup, targetName: L("앱 %lld개의 잔여물", 4), startedAt: ago(days: 41, from: now),
            finishedAt: ago(days: 41, from: now).addingTimeInterval(9), ruleDataVersion: "2026.08.2",
            steps: [CleanupStep.stopServices.rawValue, CleanupStep.moveItems.rawValue],
            items: [
                ji("/Library/LaunchDaemons/com.example.olddaemon.plist", .holding, 4 * KB, .launchDaemon, sessionID: oldID),
                ji("/Library/Application Support/OldVendor", .holding, 640 * MB, .applicationSupport, sessionID: oldID),
                ji("~/Library/Caches/com.example.legacy", .trash, 210 * MB, .caches, sessionID: oldID),
            ],
            status: .partiallyRestorable,
            missingItems: [home + "/Library/Caches/com.example.legacy"])

        return [word, orphan, docker, zoom, old]
    }
}
