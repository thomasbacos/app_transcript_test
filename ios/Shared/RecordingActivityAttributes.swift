import ActivityKit
import Foundation

/// Live Activity shown on the Lock Screen and in the Dynamic Island while recording.
/// Compiled into both the app and the widget extension.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// While recording, elapsed time = now - startedAt (the system animates the timer).
        var startedAt: Date
        /// Set while paused: the frozen elapsed time.
        var pausedElapsed: TimeInterval?
        var markers: Int
        var title: String
    }
}

enum ActivityFormat {
    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
