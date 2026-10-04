import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

private let red = Color(red: 1.0, green: 0.23, blue: 0.31)
private let coral = Color(red: 1.0, green: 0.44, blue: 0.49)

/// Lock Screen + Dynamic Island while recording: live timer, pause / resume, mark, stop.
struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.82))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        RecordingDot(paused: context.state.pausedElapsed != nil)
                        Text(context.state.pausedElapsed != nil ? LocalizedStringKey("Paused") : LocalizedStringKey("Recording"))
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TimerText(state: context.state)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        Text(context.state.title)
                            .font(.caption)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                        Controls(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.pausedElapsed != nil ? "pause.fill" : "waveform")
                    .foregroundStyle(context.state.pausedElapsed != nil ? .orange : red)
            } compactTrailing: {
                TimerText(state: context.state)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "mic.fill")
                    .foregroundStyle(context.state.pausedElapsed != nil ? .orange : red)
            }
            .keylineTint(red)
        }
    }
}

private struct LockScreenView: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RecordingDot(paused: state.pausedElapsed != nil)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.pausedElapsed != nil ? LocalizedStringKey("Paused") : LocalizedStringKey("Parley is recording"))
                        .font(.subheadline.weight(.semibold))
                    Text(state.title)
                        .font(.caption)
                        .lineLimit(1)
                        .opacity(0.7)
                }
                Spacer()
                TimerText(state: state)
                    .font(.title2.weight(.semibold).monospacedDigit())
            }
            Controls(state: state)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

private struct RecordingDot: View {
    let paused: Bool

    var body: some View {
        Circle()
            .fill(paused ? Color.orange : red)
            .frame(width: 10, height: 10)
    }
}

private struct TimerText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if let p = state.pausedElapsed {
            Text(ActivityFormat.clock(p))
        } else {
            Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct Controls: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: AddMarkerIntent()) {
                Label {
                    if state.markers > 0 { Text(verbatim: "\(state.markers)") } else { Text("Mark") }
                } icon: {
                    Image(systemName: "flag.fill")
                }
                .frame(maxWidth: .infinity)
            }
            .tint(coral)
            Button(intent: TogglePauseRecordingIntent()) {
                Label(state.pausedElapsed != nil ? LocalizedStringKey("Resume") : LocalizedStringKey("Pause"),
                      systemImage: state.pausedElapsed != nil ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.white)
            Button(intent: StopRecordingIntent()) {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(red)
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
    }
}
