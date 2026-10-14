import Foundation

/// 번들의 Info.plist 핵심 값. Bundle(url:)은 캐시되어 삭제·교체된 번들에 부정확하므로 plist를 직접 읽는다.
public struct BundleInfo: Sendable, Hashable {
    public var url: URL
    public var bundleID: String?
    public var name: String?
    public var displayName: String?
    public var executable: String?
    public var shortVersion: String?
    public var version: String?
    public var raw: [String: PlistValue]

    public var bestName: String {
        displayName ?? name ?? url.deletingPathExtension().lastPathComponent
    }

    /// `.app`이면 `Contents/Info.plist`, 아니면(iOS Wrapper 내부 번들 등) `Info.plist`
    public static func read(bundleAt url: URL) -> BundleInfo? {
        let candidates = [
            url.appendingPathComponent("Contents/Info.plist"),
            url.appendingPathComponent("Info.plist"),
        ]
        for plistURL in candidates {
            guard let dict = PlistValue.readDictionary(at: plistURL) else { continue }
            return BundleInfo(
                url: url,
                bundleID: dict["CFBundleIdentifier"]?.string,
                name: dict["CFBundleName"]?.string,
                displayName: dict["CFBundleDisplayName"]?.string,
                executable: dict["CFBundleExecutable"]?.string,
                shortVersion: dict["CFBundleShortVersionString"]?.string,
                version: dict["CFBundleVersion"]?.string,
                raw: dict
            )
        }
        return nil
    }
}

/// Sendable한 plist 값 표현
public enum PlistValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case date(Date)
    case data(Data)
    case array([PlistValue])
    case dictionary([String: PlistValue])

    public init?(_ any: Any) {
        switch any {
        case let v as String: self = .string(v)
        case let v as NSNumber:
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .bool(v.boolValue) } else { self = .number(v.doubleValue) }
        case let v as Date: self = .date(v)
        case let v as Data: self = .data(v)
        case let v as [Any]: self = .array(v.compactMap(PlistValue.init))
        case let v as [String: Any]:
            var d: [String: PlistValue] = [:]
            for (k, val) in v { if let p = PlistValue(val) { d[k] = p } }
            self = .dictionary(d)
        default: return nil
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [PlistValue]? { if case .array(let a) = self { return a }; return nil }
    public var dictionary: [String: PlistValue]? { if case .dictionary(let d) = self { return d }; return nil }
    public var stringArray: [String] { array?.compactMap(\.string) ?? [] }

    public subscript(key: String) -> PlistValue? { dictionary?[key] }

    public static func readDictionary(at url: URL) -> [String: PlistValue]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              case .dictionary(let dict)? = PlistValue(obj) else { return nil }
        return dict
    }
}
