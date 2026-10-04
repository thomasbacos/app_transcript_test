import AVFoundation
import Observation
import UIKit

/// Microphone recording that keeps going with the screen locked or the app in the background
/// (UIBackgroundModes: audio), survives phone calls (auto-resume) and crashes (PCM in a CAF file,
/// whose samples are recoverable even if the header was never finalized).
@MainActor
@Observable
final class AudioRecorder: NSObject {
    enum State: Equatable { case idle, recording, paused }

    enum RecorderError: LocalizedError {
        case permissionDenied, couldNotStart, lowDiskSpace

        var errorDescription: String? {
            switch self {
            case .permissionDenied: return tr("Parley needs access to the microphone to record.")
            case .couldNotStart: return tr("The recording could not start. Close other apps using the microphone and try again.")
            case .lowDiskSpace: return tr("Your iPhone is almost full. Free up some space to record.")
            }
        }
    }

    private(set) var state: State = .idle
    private(set) var elapsed: TimeInterval = 0
    private(set) var levels: [CGFloat] = Array(repeating: 0, count: 48)
    private(set) var markers: [TimeInterval] = []
    private(set) var currentID: UUID?
    private(set) var pausedBySystem = false
    private(set) var title: String = ""
    var lastError: String?
    /// Meters are only computed while someone can see them.
    var isUIVisible = true

    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let store: RecordingStore
    @ObservationIgnored var onFinished: ((Recording) -> Void)?

    static let sampleRate: Double = 24_000           // speech; the speaker model wants >= 24 kHz
    static let maxDuration: TimeInterval = 6 * 3600
    static let pcmFile = "recording.caf"

    init(store: RecordingStore) {
        self.store = store
        super.init()
        observeSession()
        RecordingControl.shared.togglePause = { [weak self] in self?.togglePause() }
        RecordingControl.shared.stop = { [weak self] in
            Task { await self?.stop() }
        }
        RecordingControl.shared.addMarker = { [weak self] in self?.addMarker() }
    }

    var isActive: Bool { state != .idle }

    static var hasPermission: Bool { AVAudioApplication.shared.recordPermission == .granted }
    static var permissionDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }

    static func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    // MARK: control

    func start() async throws {
        guard state == .idle else { return }
        guard await Self.requestPermission() else { throw RecorderError.permissionDenied }
        if let free = store.freeSpace, free < 300_000_000 { throw RecorderError.lowDiskSpace }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)

        let id = UUID()
        let now = Date()
        let name = tr("Recording of %@", now.formatted(date: .abbreviated, time: .shortened))
        let rec = Recording(id: id, title: name, createdAt: now, audioFile: Self.pcmFile, source: .microphone,
                            status: .recording)
        store.save(rec)
        let url = store.folder(id).appendingPathComponent(Self.pcmFile)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = true
            r.delegate = self
            guard r.prepareToRecord(), r.record() else { throw RecorderError.couldNotStart }
            recorder = r
        } catch {
            store.delete(id)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error is RecorderError ? error : RecorderError.couldNotStart
        }
        currentID = id
        title = name
        markers = []
        elapsed = 0
        levels = Array(repeating: 0, count: levels.count)
        state = .recording
        lastError = nil
        startMeter()
        LiveActivityManager.shared.start(title: name)
        UIApplication.shared.isIdleTimerDisabled = Prefs.keepAwake
    }

    func pause() {
        guard state == .recording, let r = recorder else { return }
        r.pause()
        elapsed = r.currentTime
        state = .paused
        pausedBySystem = false
        syncActivity()
    }

    func resume() {
        guard state == .paused, let r = recorder else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if r.record() {
            state = .recording
            pausedBySystem = false
            syncActivity()
        }
    }

    func togglePause() {
        state == .recording ? pause() : resume()
    }

    func addMarker() {
        guard state != .idle, let r = recorder, let id = currentID else { return }
        markers.append(r.currentTime)
        let m = markers
        store.update(id) { $0.markers = m }
        syncActivity()
    }

    func rename(_ newTitle: String) {
        let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let id = currentID else { return }
        title = t
        store.update(id) { $0.title = t; $0.titleIsCustom = true }
        LiveActivityManager.shared.rename(t)
    }

    /// Stops, compresses, and returns the saved recording.
    @discardableResult
    func stop() async -> Recording? {
        guard let r = recorder, let id = currentID else { return nil }
        let duration = r.currentTime
        r.stop()
        recorder = nil
        currentID = nil
        state = .idle
        pausedBySystem = false
        stopMeter()
        UIApplication.shared.isIdleTimerDisabled = false
        LiveActivityManager.shared.end()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let marks = markers
        store.update(id) {
            $0.status = .saving
            $0.duration = duration
            $0.markers = marks
        }
        // Compression keeps running if the recording was stopped from the Lock Screen.
        let saved = await BackgroundTime.run("finalize") {
            await self.finalize(id: id, fallbackDuration: duration)
        }
        if let saved { onFinished?(saved) }
        return saved
    }

    /// Screenshot mode only (see Demo): shows the recorder without touching the microphone.
    func startDemo(title: String) {
        self.title = title
        state = .recording
        elapsed = 1843
        markers = [612, 1290]
        levels = (0..<levels.count).map { i in
            let x = Double(i)
            return CGFloat(0.25 + 0.55 * abs(sin(x * 0.55) * cos(x * 0.21)))
        }
    }

    /// PCM -> AAC (about 7x smaller). If the PCM file is damaged, it is repaired first.
    private func finalize(id: UUID, fallbackDuration: TimeInterval) async -> Recording? {
        let folder = store.folder(id)
        let pcm = folder.appendingPathComponent(Self.pcmFile)
        let m4a = folder.appendingPathComponent("audio.m4a")
        var source = pcm
        if ((try? AVAudioFile(forReading: pcm))?.length ?? 0) == 0, let wav = try? CAFRepair.repair(pcm) {
            source = wav
        }
        do {
            let d = try await AudioConverter.toAAC(source: source, destination: m4a)
            try? FileManager.default.removeItem(at: pcm)
            if source != pcm { try? FileManager.default.removeItem(at: source) }
            store.update(id) {
                $0.audioFile = "audio.m4a"
                $0.duration = d > 0 ? d : fallbackDuration
                $0.status = .local
            }
        } catch {
            // Keep the original: it plays and uploads as is (the server reads CAF/WAV too).
            store.update(id) {
                $0.audioFile = source.lastPathComponent
                $0.status = .local
                if $0.duration == 0 { $0.duration = fallbackDuration }
            }
        }
        return store.recording(id)
    }

    /// At launch: recordings left in `recording`/`saving` state (the app was killed) are rescued.
    func recoverInterrupted() async {
        for rec in store.recordings where (rec.status == .recording || rec.status == .saving) && rec.id != currentID {
            let pcm = store.folder(rec.id).appendingPathComponent(Self.pcmFile)
            if FileManager.default.fileExists(atPath: pcm.path) {
                store.update(rec.id) {
                    if !$0.title.hasSuffix(tr("(recovered)")) { $0.title += " " + tr("(recovered)") }
                }
                _ = await finalize(id: rec.id, fallbackDuration: rec.duration)
            } else {
                store.update(rec.id) { $0.status = .local }
            }
        }
    }

    // MARK: meters

    private func startMeter() {
        meterTimer?.invalidate()
        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        meterTimer = t
    }

    private func stopMeter() {
        meterTimer?.invalidate()
        meterTimer = nil
        levels = Array(repeating: 0, count: levels.count)
    }

    private func tick() {
        guard let r = recorder else { return }
        if state == .recording {
            elapsed = r.currentTime
            if isUIVisible {
                r.updateMeters()
                let db = r.averagePower(forChannel: 0)            // -160 ... 0 dBFS
                let level = CGFloat(max(0, min(1, (db + 50) / 50)))
                levels.removeFirst()
                levels.append(level)
            }
        }
        if elapsed >= Self.maxDuration {
            Task { await stop() }
        }
    }

    private func syncActivity() {
        LiveActivityManager.shared.update(elapsed: elapsed, paused: state == .paused, markers: markers.count)
    }

    // MARK: interruptions (phone calls, Siri, alarms)

    private func observeSession() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                        queue: .main) { [weak self] n in
            let type = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated { self?.interruption(type) }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                        queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                self.lastError = tr("The audio system restarted. Your recording was saved.")
                Task { await self.stop() }
            }
        })
    }

    private func interruption(_ raw: UInt?) {
        guard let raw, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if state == .recording, let r = recorder {
                r.pause()
                elapsed = r.currentTime
                state = .paused
                pausedBySystem = true
                syncActivity()
            }
        case .ended:
            // Resume even without `.shouldResume`: the meeting is still going on.
            if pausedBySystem { resume() }
        @unknown default:
            break
        }
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.lastError = message
            await self.stop()
        }
    }
}
