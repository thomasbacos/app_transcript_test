import Foundation

/// Everything that differs between deployments comes from `ios/Config/Parley.xcconfig`
/// (bundle id, team, API URL), surfaced through Info.plist.
enum AppConfig {
    static let apiBaseURL: URL = {
        let raw = (Bundle.main.object(forInfoDictionaryKey: "ParleyAPIBaseURL") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: raw), url.scheme?.hasPrefix("http") == true, url.host != nil {
            return url
        }
        return URL(string: "http://localhost:8000")!
    }()

    static var bundleID: String { Bundle.main.bundleIdentifier ?? "com.thomasbacos.parley" }

    /// Must match App Store Connect and `ios/Config/Products.storekit`.
    static let productSuffixes = ["essential.monthly", "pro.monthly", "pro.yearly"]
    static var productIDs: [String] { productSuffixes.map { "\(bundleID).\($0)" } }

    static var privacyURL: URL { apiBaseURL.appending(path: "legal/privacy") }
    static var supportURL: URL { apiBaseURL.appending(path: "support") }
    /// Apple's standard EULA, as allowed for subscription apps.
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    static var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(v) (\(b))"
    }

    static var apnsEnvironment: String {
        #if DEBUG
        return "development"
        #else
        return "production"
        #endif
    }

    static let trialDays = 7
    /// Fallback allowances shown before the server answers (the server is the source of truth).
    static let fallbackMinutes: [String: Int] = ["trial": 60, "essential": 240, "pro": 600]
}
