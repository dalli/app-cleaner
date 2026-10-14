import Foundation

/// 크기·날짜·경로 표시 형식
enum Fmt {
    // MARK: 크기

    static func bytes(_ value: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.includesActualByteCount = false
        return f.string(fromByteCount: value)
    }

    /// 크기를 모르면 "계산 중…"
    static func size(_ value: Int64?) -> String {
        guard let value else { return L("계산 중…") }
        return bytes(value)
    }

    /// 합계. 일부 크기를 모르면 "약 …"
    static func total(_ value: Int64, approximate: Bool) -> String {
        approximate ? L("약 %@", bytes(value)) : bytes(value)
    }

    /// VoiceOver용 크기 ("3.1 기가바이트")
    static func spokenSize(_ value: Int64?) -> String {
        guard let value else { return L("크기 계산 중") }
        let v = Double(value)
        let unit: UnitInformationStorage
        let amount: Double
        switch v {
        case 1e12...: unit = .terabytes; amount = v / 1e12
        case 1e9...: unit = .gigabytes; amount = v / 1e9
        case 1e6...: unit = .megabytes; amount = v / 1e6
        case 1e3...: unit = .kilobytes; amount = v / 1e3
        default: unit = .bytes; amount = v
        }
        let f = MeasurementFormatter()
        f.locale = L10n.locale
        f.unitStyle = .long
        f.unitOptions = .providedUnit
        f.numberFormatter.maximumFractionDigits = 1
        return f.string(from: Measurement(value: amount, unit: unit))
    }

    // MARK: 숫자

    static func number(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = L10n.locale
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: 날짜

    /// "오늘", "어제", "2주 전", "3개월 전"
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return L("기록 없음") }
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return L("오늘") }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return L("어제") }
        let f = RelativeDateTimeFormatter()
        f.locale = L10n.locale
        f.unitsStyle = .full
        f.dateTimeStyle = .numeric
        return f.localizedString(for: date, relativeTo: now)
    }

    static func dateTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = L10n.locale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f.string(from: date)
    }

    /// 오늘이면 시각만, 아니면 날짜 + 시각 ("오늘 14:02")
    static func sessionTime(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let tf = DateFormatter()
        tf.locale = L10n.locale
        tf.dateStyle = .none
        tf.timeStyle = .short
        if cal.isDate(date, inSameDayAs: now) { return L("오늘 %@", tf.string(from: date)) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) {
            return L("어제 %@", tf.string(from: date))
        }
        return Self.date(date)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.allowedUnits = seconds >= 60 ? [.minute, .second] : [.second]
        var cal = Calendar.current
        cal.locale = L10n.locale
        f.calendar = cal
        return f.string(from: max(seconds, 0).rounded()) ?? "\(Int(seconds))s"
    }

    static func daysSince(_ date: Date, now: Date = Date()) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0)
    }

    // MARK: 경로

    /// 홈 폴더를 `~`로 줄인다 (표시 전용)
    static func path(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// 부모 폴더 (표시용)
    static func parent(_ path: String) -> String {
        Self.path((path as NSString).deletingLastPathComponent)
    }

    static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}

// MARK: - 한국어 조사

enum Josa {
    /// 받침 여부에 따라 "이"/"가"를 붙인다 ("Excel이", "Word가"). 영어 UI에서는 그대로 돌려준다.
    static func iGa(_ word: String) -> String {
        guard L10n.isKorean else { return word }
        return word + (hasFinalConsonant(word) ? "이" : "가")
    }

    /// "을"/"를" ("Word를", "Slack을")
    static func eulReul(_ word: String) -> String {
        guard L10n.isKorean else { return word }
        return word + (hasFinalConsonant(word) ? "을" : "를")
    }

    /// "은"/"는"
    static func eunNeun(_ word: String) -> String {
        guard L10n.isKorean else { return word }
        return word + (hasFinalConsonant(word) ? "은" : "는")
    }

    /// "으로"/"로" (받침이 없거나 ㄹ 받침이면 "로")
    static func euRo(_ word: String) -> String {
        guard L10n.isKorean else { return word }
        return word + (hasFinalConsonant(word) && !endsWithRieul(word) ? "으로" : "로")
    }

    static func endsWithRieul(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard let last = trimmed.unicodeScalars.last else { return false }
        if (0xAC00...0xD7A3).contains(last.value) { return (last.value - 0xAC00) % 28 == 8 }
        let lower = trimmed.lowercased()
        return lower.hasSuffix("l") || lower.hasSuffix("le") || lower.hasSuffix("1") || lower.hasSuffix("7") || lower.hasSuffix("8")
    }

    /// 마지막 글자의 받침(종성) 여부. 영문은 한국어 발음을 어림한다.
    static func hasFinalConsonant(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard let last = trimmed.unicodeScalars.last else { return false }
        let v = last.value
        if (0xAC00...0xD7A3).contains(v) { return (v - 0xAC00) % 28 != 0 }
        if let digit = Int(String(last)) {
            // 영 일 이 삼 사 오 육 칠 팔 구
            return [true, true, false, true, false, false, true, true, true, false][digit]
        }
        var lower = trimmed.lowercased()
        // 묵음 e: Chrome → 크롬, Adobe → 어도비(be는 모음)
        if lower.count > 2, lower.hasSuffix("e") {
            let beforeE = lower[lower.index(lower.endIndex, offsetBy: -2)]
            if "lmn".contains(beforeE) { lower.removeLast() }
        }
        if lower.hasSuffix("ng") || lower.hasSuffix("ck") { return true }
        guard let ch = lower.last else { return false }
        return "lmnkgbp".contains(ch)
    }
}
