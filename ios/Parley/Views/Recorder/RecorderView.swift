import SwiftUI

struct RecorderView: View {
    @Environment(AudioRecorder.self) private var recorder
    @Environment(\.dismiss) private var dismiss
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var stopping = false
    @State private var markerTick = 0

    var body: some View {
        ZStack {
            Theme.recorderBackground.ignoresSafeArea()
            VStack(spacing: 22) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.title3.weight(.semibold))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(Text("Minimize"))
                    Spacer()
                    if !recorder.markers.isEmpty {
                        Label { Text(verbatim: "\(recorder.markers.count)") } icon: { Image(systemName: "flag.fill") }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.coral)
                    }
                }
                .padding(.horizontal, 8)

                Button {
                    titleDraft = recorder.title
                    renaming = true
                } label: {
                    HStack(spacing: 6) {
                        Text(recorder.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Image(systemName: "pencil").font(.footnote).opacity(0.6)
                    }
                }
                .padding(.horizontal, 24)

                Spacer()

                Text(Fmt.clock(recorder.elapsed))
                    .font(.system(size: 68, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.default, value: Int(recorder.elapsed))

                statusLine

                LevelBars(levels: recorder.levels, active: recorder.state == .recording,
                          color: recorder.state == .recording ? Theme.coral : .white)
                    .padding(.horizontal, 24)

                Spacer()

                HStack(spacing: 40) {
                    roundButton(icon: "flag.fill", label: tr("Mark"), size: 60) {
                        recorder.addMarker()
                        markerTick += 1
                    }
                    .sensoryFeedback(.success, trigger: markerTick)

                    roundButton(icon: recorder.state == .paused ? "play.fill" : "pause.fill",
                                label: recorder.state == .paused ? tr("Resume") : tr("Pause"), size: 76) {
                        recorder.togglePause()
                    }
                    .sensoryFeedback(.impact, trigger: recorder.state)

                    Button {
                        stopping = true
                        Task { await recorder.stop() }
                    } label: {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle().fill(Theme.red).frame(width: 60, height: 60)
                                if stopping {
                                    ProgressView().tint(.white)
                                } else {
                                    RoundedRectangle(cornerRadius: 5).fill(.white).frame(width: 22, height: 22)
                                }
                            }
                            Text("Stop").font(.caption.weight(.medium))
                        }
                    }
                    .disabled(stopping)
                    .accessibilityLabel(Text("Stop and save"))
                }

                Label("Let participants know they are being recorded.", systemImage: "person.2.wave.2")
                    .font(.footnote)
                    .opacity(0.55)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
            }
            .foregroundStyle(.white)
        }
        .preferredColorScheme(.dark)
        .onChange(of: recorder.state) { _, state in
            if state == .idle { dismiss() }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $titleDraft)
            Button("Save") { recorder.rename(titleDraft) }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if recorder.state == .paused {
            Text(recorder.pausedBySystem ? tr("Paused by a call — resumes automatically") : tr("Paused"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
        } else {
            HStack(spacing: 8) {
                Circle().fill(Theme.red).frame(width: 8, height: 8)
                Text("Recording — you can lock your iPhone")
            }
            .font(.subheadline)
            .opacity(0.8)
        }
    }

    private func roundButton(icon: String, label: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: size * 0.34, weight: .semibold))
                    .frame(width: size, height: size)
                    .background(.white.opacity(0.14), in: Circle())
                Text(label).font(.caption.weight(.medium))
            }
        }
        .accessibilityLabel(Text(label))
    }
}
