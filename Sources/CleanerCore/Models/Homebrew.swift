import Foundation

public enum HomebrewKind: String, Codable, Sendable, CaseIterable {
    /// `brew install <formula>` — `<prefix>/Cellar/<name>/<version>`
    case formula
    /// `brew install --cask <token>` — `<prefix>/Caskroom/<token>/<version>`
    case cask
}

/// Homebrew 항목과 관련된 경로 (표시용 — 정리 대상 아님)
public struct HomebrewRelatedPath: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Cellar·Caskroom 폴더, cask가 설치한 앱
        case install
        /// `<prefix>/opt`·`bin`·`sbin`에서 설치 폴더를 가리키는 링크
        case link
        /// `<prefix>/etc/<이름>`, `<prefix>/var/<이름>` — `brew uninstall`이 남기는 설정·데이터
        case prefixData
        /// cask zap 규칙에 있는 파일 (`brew uninstall --zap`이 지움)
        case zap
        /// 홈 폴더의 이름이 같은 폴더 (`~/.config/<이름>` 등) — 다른 프로그램 것일 수 있음
        case data
        /// Homebrew 다운로드 캐시 (`brew cleanup`이 지움)
        case downloadCache
    }

    public var kind: Kind
    public var url: URL

    public var id: String { "\(kind.rawValue):\(url.path)" }

    public init(_ kind: Kind, _ url: URL) {
        self.kind = kind
        self.url = url
    }
}

/// Homebrew로 설치한 formula·cask 1개 (GUI "Homebrew" 화면 표시용).
///
/// 파일 이동으로는 의존성·`opt`·`bin` 링크·Homebrew 기록을 함께 정리할 수 없으므로(docs/packages.md "남은 작업")
/// 정리 대상이 아니라 목록·크기·`brew uninstall` 명령 안내에만 쓴다.
public struct HomebrewItem: Codable, Sendable, Hashable, Identifiable {
    public var kind: HomebrewKind
    public var name: String
    /// 설치된 버전 (여러 버전이 있으면 가장 높은 것)
    public var version: String?
    /// `<prefix>/Cellar/<name>` 또는 `<prefix>/Caskroom/<token>`
    public var location: URL
    /// 사용자가 직접 설치했는지. false면 다른 formula의 의존성으로 설치됨
    public var installedOnRequest: Bool
    public var installedAt: Date?
    /// 크기를 셀 경로: Cellar 폴더 / Caskroom 폴더 + cask가 설치한 앱
    public var contentPaths: [URL]
    /// cask가 설치한 앱 파일명 (예: "Docker.app")
    public var apps: [String]
    /// 관련 경로 (설치 위치·링크·남는 설정과 데이터·캐시). 존재하는 것만
    public var related: [HomebrewRelatedPath]

    public var id: String { "\(kind.rawValue):\(location.path)" }

    /// Homebrew 제거 명령 (안내용 — 실행하지 않는다)
    public var uninstallCommand: String {
        switch kind {
        case .formula: return "brew uninstall \(name)"
        case .cask: return "brew uninstall --cask \(name)"
        }
    }

    /// cask의 zap 포함 제거 명령 (zap 규칙으로 찾은 파일이 있을 때만)
    public var zapCommand: String? {
        kind == .cask && related.contains { $0.kind == .zap } ? "brew uninstall --zap --cask \(name)" : nil
    }

    public init(kind: HomebrewKind, name: String, version: String? = nil, location: URL, installedOnRequest: Bool = true,
                installedAt: Date? = nil, contentPaths: [URL]? = nil, apps: [String] = [], related: [HomebrewRelatedPath] = []) {
        self.kind = kind
        self.name = name
        self.version = version
        self.location = location
        self.installedOnRequest = installedOnRequest
        self.installedAt = installedAt
        self.contentPaths = contentPaths ?? [location]
        self.apps = apps
        self.related = related
    }
}
