import Foundation
import Security

struct AccountStatus: Codable, Equatable {
    var plan: String
    var isTrial: Bool
    var productId: String?
    var active: Bool
    var expiresAt: String?
    var periodEnd: String?
    var quotaSeconds: Double
    var usedSeconds: Double
    var reservedSeconds: Double
    var remainingSeconds: Double
    var maxFileSeconds: Double

    var periodEndDate: Date? { periodEnd.flatMap(Self.parse) }
    var expiresDate: Date? { expiresAt.flatMap(Self.parse) }
    var usedFraction: Double { quotaSeconds > 0 ? min(1, (usedSeconds + reservedSeconds) / quotaSeconds) : 0 }

    private static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

struct JobStatus: Codable, Equatable {
    var id: String
    var status: String
    var stage: String?
    var progress: Double
    var errorCode: String?
    var errorMessage: String?
    var retryable: Bool
    var needsUpload: Bool
    var duration: Double?
    var title: String?
    var uploadPath: String?
}

struct PlansInfo: Codable, Equatable {
    struct Trial: Codable, Equatable { var days: Int; var minutes: Int; var maxFileMinutes: Int }
    struct Plan: Codable, Equatable { var id: String; var minutes: Int; var maxFileMinutes: Int; var products: [String] }
    var trial: Trial
    var plans: [Plan]

    func minutes(for planID: String) -> Int {
        plans.first { $0.id == planID }?.minutes ?? AppConfig.fallbackMinutes[planID] ?? 0
    }
}

private struct SessionResponse: Codable {
    var token: String
    var expiresAt: String
    var account: AccountStatus
    var rejectedTransactions: Int?
}

private struct ErrorEnvelope: Codable {
    struct Body: Codable {
        var code: String
        var message: String
        var remainingSeconds: Double?
        var maxFileSeconds: Double?
    }
    var error: Body
}

enum APIError: LocalizedError, Equatable {
    case server(status: Int, code: String, message: String, remaining: Double?, maxFile: Double?)
    case transport(String)
    case decoding

    static func from(status: Int, data: Data) -> APIError {
        if let e = try? APIClient.decoder.decode(ErrorEnvelope.self, from: data) {
            return .server(status: status, code: e.error.code, message: e.error.message,
                           remaining: e.error.remainingSeconds, maxFile: e.error.maxFileSeconds)
        }
        return .server(status: status, code: "http_\(status)", message: "HTTP \(status)", remaining: nil, maxFile: nil)
    }

    var code: String {
        switch self {
        case .server(_, let code, _, _, _): return code
        case .transport: return "network"
        case .decoding: return "decoding"
        }
    }

    var status: Int? {
        if case .server(let s, _, _, _, _) = self { return s }
        return nil
    }

    var isRetryable: Bool {
        switch self {
        case .transport: return true
        case .server(let s, let code, _, _, _):
            return s >= 500 || ["busy", "rate_limited", "too_many_jobs", "network"].contains(code)
        case .decoding: return false
        }
    }

    /// True when buying a plan (or a bigger one) is the way out.
    var needsPlan: Bool { ["subscription_required", "quota_exceeded", "file_too_long"].contains(code) }

    var errorDescription: String? {
        switch self {
        case .transport:
            return tr("No connection to the server. Check your network and try again.")
        case .decoding:
            return tr("Unexpected answer from the server.")
        case .server(_, let code, let message, let remaining, let maxFile):
            switch code {
            case "subscription_required": return tr("Start your free trial or subscribe to transcribe.")
            case "quota_exceeded":
                return tr("Not enough transcription time left (%@ remaining).", Fmt.duration(remaining ?? 0))
            case "file_too_long":
                return tr("This recording is longer than your plan allows per file (%@).", Fmt.duration(maxFile ?? 0))
            case "too_many_jobs": return tr("Two transcriptions are already running. Try again when one finishes.")
            case "daily_limit": return tr("Daily limit reached. Try again tomorrow.")
            case "rate_limited", "busy": return tr("The service is busy. Try again in a minute.")
            case "invalid_audio": return tr("This file could not be read as audio.")
            case "audio_too_short": return tr("The recording is too short to transcribe.")
            case "file_too_large": return tr("This file is too large to upload.")
            case "service_unavailable", "upstream_error", "network", "internal", "server_full":
                return tr("The transcription service is temporarily unavailable. Your recording is safe: try again later.")
            case "audio_missing": return tr("The upload needs to be sent again.")
            case "expired", "not_found": return tr("This transcription is no longer available on the server. Transcribe again.")
            case "unauthorized": return tr("Session expired. Try again.")
            default: return message
            }
        }
    }
}

/// HTTP client for the Parley server. Sessions are opened with the App Store transactions the device
/// holds; the server verifies them with Apple and answers with the allowance.
actor APIClient {
    static let shared = APIClient()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private let base = AppConfig.apiBaseURL
    private let http: URLSession
    private var token: String?
    private var tokenExpiry = Date.distantPast
    private var pushToken: String?
    private var transactions: (@Sendable () async -> [String])?
    private var refreshing: Task<AccountStatus, Error>?
    /// Transactions the server refused at the last session (see SubscriptionManager.serverRejectedPurchase).
    private(set) var rejectedTransactions = 0

    init() {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 30
        c.timeoutIntervalForResource = 300
        c.waitsForConnectivity = false
        http = URLSession(configuration: c)
    }

    func setTransactionProvider(_ p: @escaping @Sendable () async -> [String]) {
        transactions = p
    }

    func setPushToken(_ t: String) {
        guard t != pushToken else { return }
        pushToken = t
        tokenExpiry = .distantPast        // re-open the session to register it
    }

    // MARK: session

    @discardableResult
    func refreshSession() async throws -> AccountStatus {
        if let refreshing { return try await refreshing.value }
        let task = Task { try await self.openSession() }
        refreshing = task
        defer { refreshing = nil }
        return try await task.value
    }

    private func openSession() async throws -> AccountStatus {
        let jws = await transactions?() ?? []
        var body: [String: Any] = [
            "install_id": InstallID.value,
            "transactions": jws,
            "locale": Locale.current.identifier,
            "app_version": AppConfig.version,
        ]
        if let pushToken {
            body["apns_token"] = pushToken
            body["apns_env"] = AppConfig.apnsEnvironment
        }
        var req = URLRequest(url: url("v1/auth/session"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let out: SessionResponse = try await perform(req, auth: false)
        token = out.token
        tokenExpiry = Date().addingTimeInterval(10 * 3600)
        rejectedTransactions = out.rejectedTransactions ?? 0
        return out.account
    }

    private func validToken() async throws -> String {
        if let token, tokenExpiry > Date().addingTimeInterval(120) { return token }
        _ = try await refreshSession()
        guard let token else { throw APIError.transport("no session") }
        return token
    }

    // MARK: endpoints

    func account() async throws -> AccountStatus {
        try await perform(URLRequest(url: url("v1/account")))
    }

    func plans() async throws -> PlansInfo {
        try await perform(URLRequest(url: url("v1/plans")), auth: false)
    }

    func createJob(duration: TimeInterval, options: [String: Any], docs: [URL]) async throws -> JobStatus {
        let boundary = "parley-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("duration", String(format: "%.2f", duration))
        let opts = try JSONSerialization.data(withJSONObject: options)
        field("options", String(decoding: opts, as: UTF8.self))
        for doc in docs {
            guard let data = try? Data(contentsOf: doc) else { continue }
            let name = doc.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"docs\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        var req = URLRequest(url: url("v1/jobs"))
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        return try await perform(req)
    }

    /// Request for the background upload of the audio (the body is the file).
    func uploadRequest(jobID: String, fileExtension: String) async throws -> URLRequest {
        var req = URLRequest(url: url("v1/jobs/\(jobID)/audio"))
        req.httpMethod = "PUT"
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        req.setValue(fileExtension, forHTTPHeaderField: "X-Audio-Ext")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        return req
    }

    func job(_ id: String) async throws -> JobStatus {
        try await perform(URLRequest(url: url("v1/jobs/\(id)")))
    }

    func result(_ id: String) async throws -> Data {
        try await raw(URLRequest(url: url("v1/jobs/\(id)/result")))
    }

    func retry(_ id: String) async throws -> JobStatus {
        var req = URLRequest(url: url("v1/jobs/\(id)/retry"))
        req.httpMethod = "POST"
        return try await perform(req)
    }

    func deleteJob(_ id: String) async throws {
        var req = URLRequest(url: url("v1/jobs/\(id)"))
        req.httpMethod = "DELETE"
        _ = try await raw(req)
    }

    func deleteAccount() async throws {
        var req = URLRequest(url: url("v1/account"))
        req.httpMethod = "DELETE"
        _ = try await raw(req)
    }

    // MARK: plumbing

    private func url(_ path: String) -> URL { base.appending(path: path) }

    private func perform<T: Decodable>(_ request: URLRequest, auth: Bool = true) async throws -> T {
        let data = try await raw(request, auth: auth)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding
        }
    }

    private func raw(_ request: URLRequest, auth: Bool = true, retried: Bool = false) async throws -> Data {
        var req = request
        if auth {
            req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await http.data(for: req)
        } catch {
            throw APIError.transport(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, auth, !retried {
            tokenExpiry = .distantPast
            return try await raw(request, auth: auth, retried: true)
        }
        guard (200..<300).contains(status) else { throw APIError.from(status: status, data: data) }
        return data
    }
}

/// Random id for this installation, kept in the Keychain so it survives reinstalls.
enum InstallID {
    static let value: String = {
        if let v = Keychain.read("install-id") { return v }
        let v = UUID().uuidString
        Keychain.write("install-id", v)
        return v
    }()
}

enum Keychain {
    private static func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: AppConfig.bundleID,
         kSecAttrAccount as String: key]
    }

    static func read(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        let q = query(key)
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}
