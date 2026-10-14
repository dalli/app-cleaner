import Foundation

/// LaunchAgent/Daemon 내용 분석 (plan.md 3.1, 3.2, 4.2 #4).
///
/// `~/Library/LaunchAgents`, `/Library/LaunchAgents`, `/Library/LaunchDaemons`의 모든 plist를 읽어
/// - 파일명 또는 `Label`이 `<BID>`/`<BID>.`와 일치하거나 번들 내장 서비스 Label과 같으면,
/// - 또는 실행 파일(셸·인터프리터 경유 시 실제 대상)이 앱 번들 안이나 이 앱의 권한 헬퍼를 가리키면 후보로 등록한다.
/// 셸 경유인데 대상 추출에 실패하면 Low. `/Library/PrivilegedHelperTools/<BID>*`는 대응 LaunchDaemon과 쌍으로 묶는다.
public struct LaunchPlistSource: CandidateSource {
    public let paths: SystemPaths

    public var sourceName: String { "launchPlists" }

    public init(paths: SystemPaths) {
        self.paths = paths
    }

    struct Location {
        var dir: URL
        var category: ItemCategory
        var domain: Domain
        /// bootout 대상 도메인: `~/Library/LaunchAgents`와 `/Library/LaunchAgents`는 사용자 GUI 세션(gui/<uid>),
        /// `/Library/LaunchDaemons`는 system
        var serviceDomain: LaunchServiceRef.LaunchDomain
    }

    var locations: [Location] {
        [
            Location(dir: paths.userLibrary.appendingPathComponent("LaunchAgents"), category: .launchAgent, domain: .user, serviceDomain: .user),
            Location(dir: paths.systemLibrary.appendingPathComponent("LaunchAgents"), category: .launchAgent, domain: .system, serviceDomain: .user),
            Location(dir: paths.systemLibrary.appendingPathComponent("LaunchDaemons"), category: .launchDaemon, domain: .system, serviceDomain: .system),
        ]
    }

    var helperDir: URL { paths.systemLibrary.appendingPathComponent("PrivilegedHelperTools") }

    public func candidates(for identity: AppIdentity) throws -> [Candidate] {
        let fm = FileManager.default
        let bids = BundleIDMatcher(identity: identity)
        let embeddedLabels = Set(identity.embeddedLaunchServices.map { $0.label.lowercased() })
        let bundle = identity.bundleURL

        // 1. 권한 헬퍼 `/Library/PrivilegedHelperTools/<BID>*`
        var helpers: [String: Candidate] = [:]
        for child in fm.children(of: helperDir) {
            guard let bid = bids.match(child.lastPathComponent) else { continue }
            helpers[child.standardizedFileURL.path] = Candidate(
                url: child, category: .privilegedHelper, domain: .system, confidence: bids.confidence(forMatched: bid),
                evidence: [Evidence(.bundleIdentifier, "권한 헬퍼 이름이 번들 ID \(bid)와 일치")])
        }

        // 2. Launch plist
        var out: [Candidate] = []
        for loc in locations {
            for url in fm.children(of: loc.dir).filter({ $0.pathExtension == "plist" }) {
                let stem = url.deletingPathExtension().lastPathComponent
                guard let plist = LaunchPlist.read(at: url) else {
                    // 읽을 수 없는 plist: 파일명만으로 판단 → Low
                    if let bid = bids.match(stem) {
                        out.append(Candidate(url: url, category: loc.category, domain: loc.domain, confidence: .low,
                                             evidence: [Evidence(.bundleIdentifier, "파일명이 번들 ID \(bid)와 일치 (plist를 읽지 못함)")],
                                             launchService: LaunchServiceRef(label: stem, domain: loc.serviceDomain, plistURL: url)))
                    }
                    continue
                }
                let label = plist.label ?? stem
                var evidence: [Evidence] = []
                var confidence: Confidence?

                let exeURL = plist.effectiveExecutable.flatMap(paths.mapExternalPath)
                let intoBundle = plist.points(into: bundle) || exeURL.map { $0.isInside(bundle) } == true
                var pairedHelper: URL?
                if let exeURL, exeURL.isStrictlyInside(helperDir) {
                    let helperName = exeURL.relativePath(from: helperDir)?.split(separator: "/").first.map(String.init) ?? ""
                    if bids.match(helperName) != nil { pairedHelper = helperDir.appendingPathComponent(helperName) }
                }
                if intoBundle {
                    confidence = .high
                    evidence.append(Evidence(.launchPlist, "실행 파일이 앱 번들 안을 가리킴: \(plist.effectiveExecutable ?? "")"))
                } else if let pairedHelper {
                    confidence = .high
                    evidence.append(Evidence(.launchPlist, "이 앱의 권한 헬퍼 \(pairedHelper.lastPathComponent)를 실행"))
                }

                var nameMatched = false
                if let bid = bids.match(stem) ?? bids.match(label) {
                    nameMatched = true
                    evidence.append(Evidence(.bundleIdentifier, "파일명/Label이 번들 ID \(bid)와 일치"))
                    confidence = max(confidence ?? .low, bids.confidence(forMatched: bid))
                }
                if embeddedLabels.contains(label.lowercased()) {
                    nameMatched = true
                    evidence.append(Evidence(.embeddedLaunchPlist, "앱 번들에 내장된 서비스 Label \(label)"))
                    confidence = .high
                }
                if associatedBundleIDs(at: url).contains(where: { bids.match($0) != nil }) {
                    nameMatched = true
                    evidence.append(Evidence(.launchPlist, "AssociatedBundleIdentifiers에 이 앱이 등록됨"))
                    confidence = max(confidence ?? .low, .high)
                }
                guard var conf = confidence else { continue }

                var notes: [String] = []
                if nameMatched && !intoBundle && pairedHelper == nil && plist.targetExtractionFailed {
                    // 셸·인터프리터 경유인데 실제 대상을 알 수 없음 (plan.md 4.2 #4)
                    conf = .low
                    notes.append("셸·스크립트를 거쳐 실행돼 실제 실행 대상을 확인하지 못했습니다")
                }
                let ref = LaunchServiceRef(label: label, domain: loc.serviceDomain, plistURL: url)
                out.append(Candidate(url: url, category: loc.category, domain: loc.domain, confidence: conf, evidence: evidence,
                                     launchService: ref, notes: notes))

                // 헬퍼와 쌍으로 묶기
                if let exeURL, exeURL.isStrictlyInside(helperDir), loc.category == .launchDaemon, conf >= .medium {
                    let helperName = exeURL.relativePath(from: helperDir)?.split(separator: "/").first.map(String.init) ?? ""
                    let helperURL = helperDir.appendingPathComponent(helperName)
                    guard !helperName.isEmpty, fm.itemExists(helperURL) else { continue }
                    let key = helperURL.standardizedFileURL.path
                    var h = helpers[key] ?? Candidate(url: helperURL, category: .privilegedHelper, domain: .system, confidence: conf,
                                                      evidence: [])
                    h.evidence.append(Evidence(.launchPlist, "LaunchDaemon \(label)이 실행하는 권한 헬퍼"))
                    h.launchService = h.launchService ?? ref
                    helpers[key] = h
                }
            }
        }

        // 3. 이름으로 찾은 헬퍼에 대응 LaunchDaemon이 없으면 Label = 헬퍼 이름으로 연결
        for (key, var h) in helpers where h.launchService == nil {
            let name = h.url.lastPathComponent
            if let daemon = out.first(where: { $0.category == .launchDaemon && $0.launchService?.label == name }) {
                h.launchService = daemon.launchService
                helpers[key] = h
            }
        }
        out += helpers.keys.sorted().compactMap { helpers[$0] }
        return out.mergedByPath()
    }

    /// `AssociatedBundleIdentifiers` (문자열 또는 배열)
    func associatedBundleIDs(at url: URL) -> [String] {
        guard let dict = PlistValue.readDictionary(at: url), let v = dict["AssociatedBundleIdentifiers"] else { return [] }
        if let s = v.string { return [s] }
        return v.stringArray
    }
}
