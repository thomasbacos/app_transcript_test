import ActivityKit
import Foundation

@MainActor
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    private var activity: Activity<RecordingActivityAttributes>?
    private var state: RecordingActivityAttributes.ContentState?

    func start(title: String) {
        endAll()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let s = RecordingActivityAttributes.ContentState(startedAt: Date(), pausedElapsed: nil, markers: 0, title: title)
        state = s
        do {
            activity = try Activity.request(attributes: RecordingActivityAttributes(),
                                            content: ActivityContent(state: s, staleDate: nil), pushType: nil)
        } catch {
            activity = nil
        }
    }

    func update(elapsed: TimeInterval, paused: Bool, markers: Int) {
        guard var s = state else { return }
        s.startedAt = Date().addingTimeInterval(-elapsed)
        s.pausedElapsed = paused ? elapsed : nil
        s.markers = markers
        push(s)
    }

    func rename(_ title: String) {
        guard var s = state else { return }
        s.title = title
        push(s)
    }

    private func push(_ s: RecordingActivityAttributes.ContentState) {
        state = s
        guard let activity else { return }
        Task { await activity.update(ActivityContent(state: s, staleDate: nil)) }
    }

    func end() {
        state = nil
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// Leftovers from a previous run (crash): never leave a "recording" timer on the Lock Screen.
    func endAll() {
        for a in Activity<RecordingActivityAttributes>.activities where a.id != activity?.id {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
