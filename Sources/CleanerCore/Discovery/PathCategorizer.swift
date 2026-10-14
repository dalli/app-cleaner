import Foundation

/// 경로만 보고 카테고리·도메인·보호 여부를 정한다.
/// 경로 규칙이 아닌 정보원(영수증, Homebrew zap)이 찾은 항목에 쓴다.
struct PathCategorizer: Sendable {
    let paths: SystemPaths

    struct Result: Sendable {
        var category: ItemCategory
        var domain: Domain
        var protection: ProtectionReason?
        var nature: DataNature?
        var preferencesDomain: String?
        var launchService: LaunchServiceRef?
    }

    static let pluginDirs = ["Internet Plug-Ins", "QuickLook", "Services", "PreferencePanes", "Spotlight"]

    func categorize(_ url: URL) -> Result {
        if url.isInside(paths.userCacheDir) || url.isInside(paths.userTempDir) {
            return Result(category: .tempFiles, domain: .user)
        }
        if let rel = url.relativePath(from: paths.home) {
            return categorize(relative: rel, url: url, domain: .user)
        }
        if let rel = url.relativePath(from: paths.root) {
            return categorize(relative: rel, url: url, domain: .system)
        }
        return Result(category: .other, domain: .system)
    }

    private func categorize(relative rel: String, url: URL, domain: Domain) -> Result {
        let c = rel.split(separator: "/").map(String.init)
        guard let first = c.first else { return Result(category: .other, domain: domain) }
        func at(_ i: Int) -> String? { i < c.count ? c[i] : nil }

        if domain == .user && first.hasPrefix(".") { return Result(category: .dotfile, domain: domain) }
        if first == "Applications" { return Result(category: c.count == 2 && url.pathExtension == "app" ? .appBundle : .other, domain: domain) }
        if domain == .system && first == "private" && at(1) == "var" && at(2) == "db" && at(3) == "receipts" {
            return Result(category: .receipt, domain: .system)
        }
        guard first == "Library", let second = at(1) else { return Result(category: .other, domain: domain) }

        switch second {
        case "Containers": return Result(category: c.count == 3 ? .container : .containerItem, domain: domain)
        case "Group Containers": return Result(category: c.count == 3 ? .groupContainer : .containerItem, domain: domain)
        case "Mobile Documents":
            return Result(category: .iCloudContainer, domain: domain, protection: .iCloudData, nature: .synced)
        case "Application Support": return Result(category: .applicationSupport, domain: domain)
        case "Application Scripts": return Result(category: .applicationScripts, domain: domain)
        case "Caches": return Result(category: .caches, domain: domain)
        case "HTTPStorages": return Result(category: .httpStorage, domain: domain)
        case "WebKit": return Result(category: .webKit, domain: domain)
        case "Cookies": return Result(category: .cookies, domain: domain)
        case "Saved Application State": return Result(category: .savedState, domain: domain)
        case "Preferences":
            if at(2) == "ByHost" { return Result(category: .byHostPreferences, domain: domain) }
            var r = Result(category: .preferences, domain: domain)
            if c.count == 3, url.pathExtension == "plist" { r.preferencesDomain = url.deletingPathExtension().lastPathComponent }
            return r
        case "Logs":
            return Result(category: at(2) == "DiagnosticReports" ? .diagnosticReports : .logs, domain: domain)
        case "LaunchAgents", "LaunchDaemons":
            var r = Result(category: second == "LaunchAgents" ? .launchAgent : .launchDaemon, domain: domain)
            if c.count == 3, let plist = LaunchPlist.read(at: url) {
                r.launchService = LaunchServiceRef(label: plist.label ?? url.deletingPathExtension().lastPathComponent,
                                                   domain: domain == .user ? .user : .system, plistURL: url)
            }
            return r
        case "PrivilegedHelperTools": return Result(category: .privilegedHelper, domain: domain)
        case "Extensions":
            return Result(category: .kernelExtension, domain: domain, protection: .detectOnly)
        case "SystemExtensions":
            return Result(category: .systemExtension, domain: domain, protection: .detectOnly)
        default:
            if Self.pluginDirs.contains(second) { return Result(category: .plugin, domain: domain) }
            return Result(category: .other, domain: domain)
        }
    }

    /// 결과로 후보를 만든다.
    func candidate(_ url: URL, confidence: Confidence, evidence: [Evidence]) -> Candidate {
        let r = categorize(url)
        return Candidate(url: url, category: r.category, domain: r.domain, confidence: confidence, nature: r.nature,
                         evidence: evidence, protection: r.protection, launchService: r.launchService,
                         preferencesDomain: r.preferencesDomain)
    }
}
