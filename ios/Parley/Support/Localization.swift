import Foundation

/// Localized string with printf-style arguments. Keys are the English text, translations live in
/// `Resources/Localizable.xcstrings`. Static SwiftUI literals (`Text("Record")`) use the same table.
func tr(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, locale: Locale.current, arguments: args)
}

enum Fmt {
    /// 04:07, 1:02:03
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.isFinite ? t : 0))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// 45s, 23min, 1h 05min (localized units)
    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        if t >= 3600 {
            f.allowedUnits = [.hour, .minute]
        } else if t >= 60 {
            f.allowedUnits = [.minute]
        } else {
            f.allowedUnits = [.second]
        }
        f.zeroFormattingBehavior = .dropAll
        return f.string(from: max(1, t)) ?? ""
    }

    static func date(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }

    static func day(_ d: Date) -> String {
        d.formatted(date: .long, time: .omitted)
    }

    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.localizedCapitalized ?? code
    }
}

enum Prefs {
    private static let d = UserDefaults.standard

    static var onboarded: Bool {
        get { d.bool(forKey: "onboarded") }
        set { d.set(newValue, forKey: "onboarded") }
    }

    static var autoTranscribe: Bool {
        get { d.object(forKey: "autoTranscribe") as? Bool ?? true }
        set { d.set(newValue, forKey: "autoTranscribe") }
    }

    /// The user agreed that recordings are sent to OpenAI for transcription.
    static var aiConsent: Bool {
        get { d.bool(forKey: "aiConsent") }
        set { d.set(newValue, forKey: "aiConsent") }
    }

    static var keepAwake: Bool {
        get { d.bool(forKey: "keepAwake") }
        set { d.set(newValue, forKey: "keepAwake") }
    }

    static var completedCount: Int {
        get { d.integer(forKey: "completedCount") }
        set { d.set(newValue, forKey: "completedCount") }
    }

    static var defaultOptions: ProcessingOptions {
        get {
            guard let data = d.data(forKey: "defaultOptions"),
                  let o = try? JSONDecoder().decode(ProcessingOptions.self, from: data) else { return ProcessingOptions() }
            return o
        }
        set { d.set(try? JSONEncoder().encode(newValue), forKey: "defaultOptions") }
    }
}
