import Observation
import SwiftUI
import UIKit
import UserNotifications

enum AppAlert: Identifiable {
    case microphoneDenied
    case message(String)
    case needsPlan(String)

    var id: String {
        switch self {
        case .microphoneDenied: return "mic"
        case .message(let m): return "m" + m
        case .needsPlan(let m): return "p" + m
        }
    }
}

/// App-wide state and navigation. Views get the services through the environment.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let store: RecordingStore
    let recorder: AudioRecorder
    let subscriptions: SubscriptionManager
    let processing: ProcessingService

    var path: [UUID] = []
    var showRecorder = false
    var showPaywall = false
    var transcribeTarget: UUID?
    var alert: AppAlert?
    var importing = false
    @ObservationIgnored private var launched = false
    @ObservationIgnored var pendingStart = false

    init() {
        store = RecordingStore()
        recorder = AudioRecorder(store: store)
        subscriptions = SubscriptionManager()
        processing = ProcessingService(store: store)
        recorder.onFinished = { [weak self] rec in self?.recordingFinished(rec) }
        Demo.apply(self)
    }

    func launch() async {
        guard !launched else { return }
        launched = true
        if Demo.isActive { return }
        LiveActivityManager.shared.endAll()
        await recorder.recoverInterrupted()
        await subscriptions.start()
        processing.startPolling()
        await NotificationManager.registerIfAuthorized()
        if pendingStart {
            pendingStart = false
            await startRecording()
        }
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        let active = phase == .active
        processing.isAppActive = active
        recorder.isUIVisible = active
        if active && launched {
            Task {
                await subscriptions.refreshAccount()
                processing.startPolling()
                await processing.refreshInFlight()
            }
        }
    }

    // MARK: recording

    func startRecording() async {
        if recorder.isActive {
            showRecorder = true
            return
        }
        do {
            try await recorder.start()
            showRecorder = true
        } catch AudioRecorder.RecorderError.permissionDenied {
            alert = .microphoneDenied
        } catch {
            alert = .message(error.localizedDescription)
        }
    }

    private func recordingFinished(_ rec: Recording) {
        showRecorder = false
        path = [rec.id]
        if Prefs.autoTranscribe, subscriptions.isActive, rec.duration >= 2 {
            let remaining = subscriptions.account?.remainingSeconds ?? 0
            let maxFile = subscriptions.account?.maxFileSeconds ?? 0
            if rec.duration <= remaining + 5, rec.duration <= maxFile + 5 {
                // Often stopped from the Lock Screen: ask iOS for time to create the job and hand the
                // upload to the background session before the app is suspended.
                Task {
                    await BackgroundTime.run("transcribe") {
                        await self.transcribe(rec.id, options: Prefs.defaultOptions, docs: [])
                    }
                }
            }
        }
    }

    // MARK: transcription

    /// Entry point of every "Transcribe" button: paywall first if needed, then the options sheet.
    func requestTranscription(_ id: UUID) {
        if subscriptions.isActive {
            transcribeTarget = id
        } else {
            showPaywall = true
        }
    }

    /// Returns the problem instead of showing it when `presentErrors` is false (the caller is a sheet,
    /// and an alert cannot appear behind it).
    @discardableResult
    func transcribe(_ id: UUID, options: ProcessingOptions, docs: [URL], presentErrors: Bool = true) async -> AppAlert? {
        var problem: AppAlert?
        do {
            try await processing.transcribe(id, options: options, docs: docs)
            await NotificationManager.requestIfNeeded()
            await subscriptions.refreshAccount(force: true)
        } catch let e as APIError where e.needsPlan {
            problem = .needsPlan(e.localizedDescription)
        } catch {
            problem = .message(error.localizedDescription)
        }
        if presentErrors, let problem { alert = problem }
        return problem
    }

    func retry(_ id: UUID) async {
        do {
            try await processing.retry(id)
        } catch let e as APIError where e.needsPlan {
            alert = .needsPlan(e.localizedDescription)
        } catch {
            alert = .message(error.localizedDescription)
        }
    }

    // MARK: import

    func importFiles(_ urls: [URL]) async {
        importing = true
        defer { importing = false }
        var last: UUID?
        for url in urls {
            do {
                last = try await importFile(url)
            } catch {
                alert = .message(error.localizedDescription)
            }
        }
        if let last { path = [last] }
    }

    private func importFile(_ url: URL) async throws -> UUID {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let title = url.deletingPathExtension().lastPathComponent
        var rec = Recording(id: id, title: title, createdAt: Date(), audioFile: "audio.m4a", source: .imported,
                            status: .saving, titleIsCustom: true)
        store.save(rec)
        do {
            let d = try await AudioConverter.importMedia(from: url, to: store.folder(id).appendingPathComponent("audio.m4a"))
            rec = store.recording(id) ?? rec
            rec.duration = d
            rec.status = .local
            store.save(rec)
        } catch {
            store.delete(id)
            throw error
        }
        // Files handed over by other apps land in Documents/Inbox: they are copies, clean them up.
        if url.path.contains("/Inbox/") { try? FileManager.default.removeItem(at: url) }
        return id
    }

    func handleOpenURL(_ url: URL) {
        if url.isFileURL {
            Task { await importFiles([url]) }
        } else if url.host == "record" {
            if launched { Task { await startRecording() } } else { pendingStart = true }
        }
    }

    func openJob(_ jobID: String) {
        if let id = processing.openJob(jobID) {
            path = [id]
        }
        Task { await processing.refreshInFlight() }
    }

    func delete(_ id: UUID) {
        path.removeAll { $0 == id }
        processing.delete(id)
    }
}

/// Extra execution time when work must finish after the app leaves the foreground.
@MainActor
enum BackgroundTime {
    private final class Box: @unchecked Sendable {
        var id = UIBackgroundTaskIdentifier.invalid
    }

    @discardableResult
    static func run<T>(_ name: String, _ work: () async -> T) async -> T {
        let box = Box()
        box.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated {
                UIApplication.shared.endBackgroundTask(box.id)
                box.id = .invalid
            }
        }
        let result = await work()
        if box.id != .invalid {
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
        return result
    }
}

enum NotificationManager {
    /// Asked the first time a transcription starts, when the benefit is obvious.
    static func requestIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { await MainActor.run { UIApplication.shared.registerForRemoteNotifications() } }
        }
    }

    static func registerIfAuthorized() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
        }
    }
}
