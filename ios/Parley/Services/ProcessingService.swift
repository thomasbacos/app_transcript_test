import Foundation
import Observation

/// Drives a recording through the server: create job -> background upload -> poll -> fetch result ->
/// delete the server copy. Survives app restarts: state lives in each recording's meta.json.
@MainActor
@Observable
final class ProcessingService {
    private let store: RecordingStore
    @ObservationIgnored private let api = APIClient.shared
    @ObservationIgnored private let uploads = UploadManager.shared
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var fetching = Set<UUID>()
    @ObservationIgnored private var starting = Set<UUID>()          // job being created
    @ObservationIgnored private var uploadsStarting = Set<String>()  // upload being handed to the session
    @ObservationIgnored private var refreshing = false
    var isAppActive = true
    /// Set when a transcript lands (drives the review prompt and the UI).
    private(set) var lastCompleted: UUID?

    init(store: RecordingStore) {
        self.store = store
        uploads.setHandlers(
            progress: { [weak self] jobID, p in
                Task { @MainActor in self?.uploadProgress(jobID, p) }
            },
            completion: { [weak self] event in
                Task { @MainActor in self?.uploadFinished(event) }
            })
    }

    var hasWorkInFlight: Bool { store.recordings.contains { $0.isBusy } }

    // MARK: start

    func transcribe(_ id: UUID, options: ProcessingOptions, docs: [URL]) async throws {
        guard let rec = store.recording(id), !rec.isBusy, !starting.contains(id) else { return }
        starting.insert(id)
        defer { starting.remove(id) }
        if let old = rec.jobID {                 // a previous attempt: free its reserved minutes
            uploads.cancel(jobID: old)
            try? await api.deleteJob(old)
        }
        let docFiles = store.copyDocs(docs, to: id)
        let job: JobStatus
        do {
            job = try await api.createJob(duration: rec.duration, options: options.payload(), docs: docFiles)
        } catch let e as APIError where e.code == "subscription_required" {
            // The trial may have just converted, or a renewal not yet been seen by the server: send the
            // device's current transactions again, then retry once.
            _ = try? await api.refreshSession()
            job = try await api.createJob(duration: rec.duration, options: options.payload(), docs: docFiles)
        }
        store.update(id) {
            $0.status = .uploading
            $0.jobID = job.id
            $0.options = options
            $0.uploadProgress = 0
            $0.progress = 0
            $0.stage = nil
            $0.errorCode = nil
            $0.errorMessage = nil
            $0.retryable = false
            $0.docNames = docFiles.map(\.lastPathComponent)
        }
        try await startUpload(id)
        startPolling()
    }

    private func startUpload(_ id: UUID) async throws {
        guard let rec = store.recording(id), let jobID = rec.jobID, !uploadsStarting.contains(jobID) else { return }
        uploadsStarting.insert(jobID)
        defer { uploadsStarting.remove(jobID) }
        if await uploads.activeJobIDs().contains(jobID) { return }       // already on its way
        let file = store.audioURL(rec)
        let req = try await api.uploadRequest(jobID: jobID, fileExtension: file.pathExtension.lowercased())
        uploads.upload(file: file, request: req, jobID: jobID)
    }

    // MARK: upload events

    private func uploadProgress(_ jobID: String, _ p: Double) {
        guard let r = store.recording(jobID: jobID), r.status == .uploading else { return }
        if p - r.uploadProgress >= 0.02 || p >= 1 {
            store.update(r.id) { $0.uploadProgress = p }
        }
    }

    private func uploadFinished(_ e: UploadEvent) {
        guard let r = store.recording(jobID: e.jobID) else { return }
        if let message = e.error {
            Task { await self.uploadErrored(r.id, jobID: e.jobID, message: message) }
            return
        }
        if e.status == 401 {                     // the session in the upload request expired: just resend
            store.update(r.id) {
                $0.status = .failed
                $0.errorCode = "upload_failed"
                $0.errorMessage = APIError.server(status: 401, code: "unauthorized", message: "", remaining: nil,
                                                  maxFile: nil).localizedDescription
                $0.retryable = true
            }
            return
        }
        if (200..<300).contains(e.status) {
            store.update(r.id) {
                $0.status = .processing
                $0.uploadProgress = 1
                $0.stage = "queued"
            }
            startPolling()
            return
        }
        let err = APIError.from(status: e.status, data: e.body)
        store.update(r.id) {
            $0.status = .failed
            $0.errorCode = err.code
            $0.errorMessage = err.localizedDescription
            $0.retryable = err.isRetryable
        }
    }

    private func uploadErrored(_ id: UUID, jobID: String, message: String) async {
        if let job = try? await api.job(jobID), job.status != "awaiting_audio" {
            apply(job, to: id, uploadActive: false)
            startPolling()
            return
        }
        store.update(id) {
                $0.status = .failed
                $0.errorCode = "upload_failed"
                $0.errorMessage = tr("The upload was interrupted (%@).", message)
                $0.retryable = true
            }
    }

    // MARK: polling

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let more = await self.refreshInFlight()
                if !more { break }
                try? await Task.sleep(for: .seconds(self.isAppActive ? 3 : 15))
            }
            self?.pollTask = nil
        }
    }

    /// One pass over every recording in flight. Returns false when nothing is in flight.
    @discardableResult
    func refreshInFlight() async -> Bool {
        let inflight = store.recordings.filter { $0.isBusy && $0.jobID != nil }
        guard !inflight.isEmpty else { return false }
        guard !refreshing else { return true }
        refreshing = true
        defer { refreshing = false }
        let activeUploads = await uploads.activeJobIDs()
        for rec in inflight {
            guard let jobID = rec.jobID else { continue }
            do {
                let job = try await api.job(jobID)
                apply(job, to: rec.id, uploadActive: activeUploads.contains(jobID))
            } catch let e as APIError where e.status == 404 {
                store.update(rec.id) {
                    $0.status = .failed
                    $0.errorCode = "not_found"
                    $0.errorMessage = e.localizedDescription
                    $0.retryable = false
                }
            } catch {
                // offline: try again on the next pass
            }
        }
        return true
    }

    private func apply(_ job: JobStatus, to id: UUID, uploadActive: Bool) {
        switch job.status {
        case "awaiting_audio":
            if !uploadActive {               // the upload was lost (app killed before it started...)
                Task { try? await self.startUpload(id) }
            }
        case "queued", "processing":
            store.update(id) {
                $0.status = .processing
                $0.stage = job.stage
                $0.progress = job.progress
                $0.uploadProgress = 1
            }
        case "done":
            Task { await self.fetchResult(id, jobID: job.id) }
        case "failed":
            let message = APIError.server(status: 0, code: job.errorCode ?? "internal", message: job.errorMessage ?? "",
                                          remaining: nil, maxFile: nil).localizedDescription
            store.update(id) {
                $0.status = .failed
                $0.errorCode = job.errorCode
                $0.errorMessage = message
                $0.retryable = job.retryable
            }
        case "cancelled", "expired", "deleted":
            store.update(id) {
                $0.status = .failed
                $0.errorCode = "expired"
                $0.errorMessage = APIError.server(status: 410, code: "expired", message: "", remaining: nil,
                                                  maxFile: nil).localizedDescription
                $0.retryable = false
            }
        default:
            break
        }
    }

    func fetchResult(_ id: UUID, jobID: String) async {
        guard !fetching.contains(id) else { return }
        fetching.insert(id)
        defer { fetching.remove(id) }
        do {
            let data = try await api.result(jobID)
            let result = try store.saveResult(data, for: id)
            store.update(id) { r in
                r.status = .done
                r.hasResult = true
                r.progress = 1
                r.stage = "done"
                if !r.titleIsCustom, let t = result.summary?.title, !t.isEmpty { r.title = t }
            }
            try? await api.deleteJob(jobID)          // the server keeps nothing once we have it
            Prefs.completedCount += 1
            lastCompleted = id
        } catch {
            // next poll will try again
        }
    }

    // MARK: retry / delete

    func retry(_ id: UUID) async throws {
        guard let rec = store.recording(id) else { return }
        if let jobID = rec.jobID, rec.retryable {
            if rec.errorCode == "upload_failed" || rec.errorCode == "audio_missing" {
                store.update(id) { $0.status = .uploading; $0.uploadProgress = 0; $0.errorMessage = nil }
                try await startUpload(id)
            } else {
                let job = try await api.retry(jobID)
                if job.needsUpload {
                    store.update(id) { $0.status = .uploading; $0.uploadProgress = 0; $0.errorMessage = nil }
                    try await startUpload(id)
                } else {
                    store.update(id) { $0.status = .processing; $0.errorMessage = nil; $0.stage = job.stage }
                }
            }
            startPolling()
        } else {
            try await transcribe(id, options: rec.options ?? Prefs.defaultOptions, docs: store.docs(for: id))
        }
    }

    /// Deletes locally right away; the server copy (if any) is cleaned up in the background.
    func delete(_ id: UUID) {
        if let jobID = store.recording(id)?.jobID {
            uploads.cancel(jobID: jobID)
            Task { try? await api.deleteJob(jobID) }
        }
        store.delete(id)
    }

    func openJob(_ jobID: String) -> UUID? {
        store.recording(jobID: jobID)?.id
    }
}
