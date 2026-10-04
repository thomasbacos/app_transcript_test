import AVFoundation
import Observation

@MainActor
@Observable
final class AudioPlayer: NSObject {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isLoaded = false
    var rate: Float = 1 {
        didSet { player?.rate = rate }
    }

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var url: URL?

    func load(_ url: URL) {
        guard url != self.url else { return }
        stop()
        self.url = url
        player = try? AVAudioPlayer(contentsOf: url)
        player?.enableRate = true
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
        isLoaded = player != nil
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard let player else { return }
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {        // never disturb a recording in progress
            try? session.setCategory(.playback, mode: .spokenAudio)
        }
        try? session.setActive(true)
        player.rate = rate
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        stopTimer()
    }

    func seek(_ t: TimeInterval, play: Bool = false) {
        guard let player else { return }
        player.currentTime = max(0, min(t, duration))
        currentTime = player.currentTime
        if play && !isPlaying { self.play() }
    }

    func skip(_ delta: TimeInterval) { seek(currentTime + delta) }

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTimer()
            self.currentTime = 0
        }
    }
}
