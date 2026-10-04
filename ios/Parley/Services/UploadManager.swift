import Foundation

struct UploadEvent: Sendable {
    let jobID: String
    let status: Int
    let body: Data
    let error: String?
}

/// Audio uploads run in a background URLSession: they continue when the app is suspended or the phone
/// is locked, and iOS relaunches the app in the background to report the result.
final class UploadManager: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = UploadManager()

    private let lock = NSLock()
    private var bodies: [Int: Data] = [:]
    private var progressHandler: (@Sendable (String, Double) -> Void)?
    private var completionHandler: (@Sendable (UploadEvent) -> Void)?
    private var pending: [UploadEvent] = []
    /// Set by the app delegate when iOS wakes the app for this session's events.
    var backgroundEventsCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.background(withIdentifier: "\(AppConfig.bundleID).upload")
        c.sessionSendsLaunchEvents = true
        c.isDiscretionary = false
        c.allowsCellularAccess = true
        c.timeoutIntervalForResource = 24 * 3600
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// Reconnects to uploads started before the app was terminated.
    func activate() {
        _ = session
    }

    func setHandlers(progress: @escaping @Sendable (String, Double) -> Void,
                     completion: @escaping @Sendable (UploadEvent) -> Void) {
        lock.lock()
        progressHandler = progress
        completionHandler = completion
        let early = pending
        pending = []
        lock.unlock()
        early.forEach(completion)
    }

    func upload(file: URL, request: URLRequest, jobID: String) {
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = jobID
        task.resume()
    }

    func activeJobIDs() async -> Set<String> {
        let tasks = await session.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap(\.taskDescription))
    }

    func cancel(jobID: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription == jobID }.forEach { $0.cancel() }
        }
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let id = task.taskDescription, totalBytesExpectedToSend > 0 else { return }
        lock.lock()
        let h = progressHandler
        lock.unlock()
        h?(id, Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        bodies[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        lock.lock()
        let body = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        let h = completionHandler
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        let cancelled = (error as? URLError)?.code == .cancelled
        let event = UploadEvent(jobID: id, status: status, body: body,
                                error: cancelled ? nil : error?.localizedDescription)
        if h == nil, !cancelled { pending.append(event) }
        lock.unlock()
        if !cancelled { h?(event) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.backgroundEventsCompletion?()
            self.backgroundEventsCompletion = nil
        }
    }
}
