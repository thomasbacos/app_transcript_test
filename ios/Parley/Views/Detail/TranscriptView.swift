import SwiftUI
import UIKit

struct TranscriptView: View {
    let rec: Recording
    let result: TranscriptResult
    let player: AudioPlayer
    let proxy: ScrollViewProxy
    var onRenameSpeaker: (String) -> Void

    @State private var query = ""
    @State private var plain = false
    @State private var follow = true

    private var showTurns: Bool { !plain && !result.turns.isEmpty }

    private var visibleTurns: [(index: Int, turn: Turn)] {
        let all = result.turns.enumerated().map { (index: $0.offset, turn: $0.element) }
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return all }
        return all.filter {
            $0.turn.text.localizedCaseInsensitiveContains(q)
                || result.displayName($0.turn.spk, overrides: rec.speakerNames).localizedCaseInsensitiveContains(q)
        }
    }

    private var playingIndex: Int? {
        guard player.isPlaying else { return nil }
        let t = player.currentTime
        return result.turns.lastIndex { $0.start <= t + 0.3 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !result.speakers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(result.speakers, id: \.self) { spk in
                            let name = result.displayName(spk, overrides: rec.speakerNames)
                            Button { onRenameSpeaker(spk) } label: {
                                HStack(spacing: 6) {
                                    SpeakerAvatar(name: name, color: Theme.speakerColor(result.speakerIndex(spk)), size: 22)
                                    Text(name).font(.subheadline.weight(.medium))
                                    Image(systemName: "pencil").font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(tr("Rename %@", name)))
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search the transcript", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                if !result.turns.isEmpty {
                    Menu {
                        Toggle("Plain text", isOn: $plain)
                        Toggle("Follow playback", isOn: $follow)
                        Button {
                            UIPasteboard.general.string = Exporter.transcriptText(rec, result)
                        } label: { Label("Copy the transcript", systemImage: "doc.on.doc") }
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                            .padding(10)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }

            if !rec.markers.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(rec.markers.enumerated()), id: \.offset) { _, m in
                            Button { player.seek(m, play: true) } label: {
                                Label(Fmt.clock(m), systemImage: "flag.fill")
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .padding(.vertical, 6).padding(.horizontal, 10)
                                    .background(Theme.coral.opacity(0.15), in: Capsule())
                                    .foregroundStyle(Theme.coral)
                            }
                        }
                    }
                }
            }

            if showTurns {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(visibleTurns, id: \.index) { item in
                        turnRow(item.index, item.turn)
                            .id(item.index)
                    }
                }
                if visibleTurns.isEmpty {
                    Text("No match.").foregroundStyle(.secondary)
                }
            } else {
                Text(highlighted(result.text, query))
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .card()
            }
        }
        .onChange(of: playingIndex) { _, idx in
            guard follow, query.isEmpty, let idx else { return }
            withAnimation { proxy.scrollTo(idx, anchor: .center) }
        }
    }

    private func turnRow(_ index: Int, _ t: Turn) -> some View {
        let name = result.displayName(t.spk, overrides: rec.speakerNames)
        let color = Theme.speakerColor(result.speakerIndex(t.spk))
        let isPlaying = playingIndex == index
        return HStack(alignment: .top, spacing: 12) {
            SpeakerAvatar(name: name, color: color)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                    Button {
                        player.seek(t.start, play: true)
                    } label: {
                        Text(Fmt.clock(t.start))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel(Text(tr("Play from %@", Fmt.clock(t.start))))
                }
                Text(highlighted(t.text, query))
                    .textSelection(.enabled)
                    .lineSpacing(3)
            }
        }
        .padding(10)
        .background(isPlaying ? color.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 14))
        .animation(.easeInOut(duration: 0.2), value: isPlaying)
    }
}

struct PlayerBar: View {
    let player: AudioPlayer
    var enabled: Bool = true
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private let speeds: [Float] = [0.75, 1, 1.25, 1.5, 2]

    var body: some View {
        VStack(spacing: 4) {
            Slider(value: Binding(get: { scrubbing ? scrubValue : player.currentTime }, set: { scrubValue = $0 }),
                   in: 0...max(player.duration, 1)) { editing in
                if editing {
                    scrubValue = player.currentTime
                    scrubbing = true
                } else {
                    player.seek(scrubValue)
                    scrubbing = false
                }
            }
            .tint(Theme.indigo)
            HStack {
                Text(Fmt.clock(scrubbing ? scrubValue : player.currentTime))
                Spacer()
                Text("-" + Fmt.clock(max(0, player.duration - (scrubbing ? scrubValue : player.currentTime))))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            HStack {
                Menu {
                    ForEach(speeds, id: \.self) { s in
                        Button(String(format: "%g×", s)) { player.rate = s }
                    }
                } label: {
                    Text(String(format: "%g×", player.rate))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .frame(width: 52, height: 36)
                }
                Spacer()
                Button { player.skip(-15) } label: { Image(systemName: "gobackward.15").font(.title3) }
                    .accessibilityLabel(Text("Back 15 seconds"))
                Spacer()
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 46))
                        .foregroundStyle(Theme.indigo)
                }
                .accessibilityLabel(Text(player.isPlaying ? tr("Pause") : tr("Play")))
                Spacer()
                Button { player.skip(15) } label: { Image(systemName: "goforward.15").font(.title3) }
                    .accessibilityLabel(Text("Forward 15 seconds"))
                Spacer()
                Color.clear.frame(width: 52, height: 36)
            }
        }
        .disabled(!enabled)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(.bar)
    }
}
