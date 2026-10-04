import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(RecordingStore.self) private var store
    @Environment(AudioRecorder.self) private var recorder
    @State private var search = ""
    @State private var showImporter = false
    @State private var showSettings = false
    @State private var renameTarget: Recording?
    @State private var renameText = ""
    @State private var deleteTarget: Recording?

    private var filtered: [Recording] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return store.recordings }
        return store.recordings.filter {
            $0.title.localizedCaseInsensitiveContains(q) || store.searchableText($0.id).localizedCaseInsensitiveContains(q)
        }
    }

    private var groups: [(title: String, items: [Recording])] {
        let cal = Calendar.current
        var order: [String] = []
        var buckets: [String: [Recording]] = [:]
        for r in filtered {
            let key: String
            if cal.isDateInToday(r.createdAt) {
                key = tr("Today")
            } else if cal.isDateInYesterday(r.createdAt) {
                key = tr("Yesterday")
            } else if let d = cal.dateComponents([.day], from: r.createdAt, to: Date()).day, d < 7 {
                key = tr("This week")
            } else {
                key = r.createdAt.formatted(.dateTime.month(.wide).year()).localizedCapitalized
            }
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(r)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                Section {
                    UsageCard()
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                .listRowBackground(Color.clear)

                if store.recordings.isEmpty {
                    Section {
                        EmptyHomeView(onImport: { showImporter = true })
                    }
                    .listRowBackground(Color.clear)
                } else if filtered.isEmpty {
                    Section {
                        ContentUnavailableView.search(text: search)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(groups, id: \.title) { group in
                        Section(group.title) {
                            ForEach(group.items) { rec in
                                NavigationLink(value: rec.id) {
                                    RecordingRow(rec: rec)
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) { deleteTarget = rec } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button { renameTarget = rec; renameText = rec.title } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    .tint(Theme.indigo)
                                }
                                .contextMenu {
                                    Button { renameTarget = rec; renameText = rec.title } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    if rec.status == .local || rec.status == .failed {
                                        Button { model.requestTranscription(rec.id) } label: {
                                            Label("Transcribe", systemImage: "text.bubble")
                                        }
                                    }
                                    Button(role: .destructive) { deleteTarget = rec } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                Color.clear.frame(height: 96)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
            .searchable(text: $search, prompt: Text("Search titles and transcripts"))

            // Soft fade so the floating button never sits on top of a row's text.
            LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0), Color(.systemGroupedBackground)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 110)
                .allowsHitTesting(false)
                .ignoresSafeArea(edges: .bottom)

            RecordDock(onImport: { showImporter = true })
        }
        .navigationTitle("Parley")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel(Text("Settings"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showImporter = true } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .accessibilityLabel(Text("Import an audio or video file"))
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .movie, .mpeg4Movie, .quickTimeMovie],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { await model.importFiles(urls) }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("Rename", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let id = renameTarget?.id {
                    let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { store.update(id) { $0.title = t; $0.titleIsCustom = true } }
                }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("Delete this recording?", isPresented: Binding(get: { deleteTarget != nil },
                                                                             set: { if !$0 { deleteTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = deleteTarget?.id { model.delete(id) }
                deleteTarget = nil
            }
        } message: {
            Text("The audio and its transcript will be deleted from this iPhone.")
        }
    }
}

struct RecordingRow: View {
    let rec: Recording

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(rec.status == .done ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Color(.tertiarySystemFill)))
                Image(systemName: rec.source == .imported ? "doc.richtext" : "waveform")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(rec.status == .done ? Color.white : Theme.indigo)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(rec.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    Text(rec.createdAt.formatted(date: .omitted, time: .shortened))
                    Text("·")
                    Text(Fmt.duration(rec.duration))
                    if !rec.markers.isEmpty {
                        Text("·")
                        Image(systemName: "flag.fill").font(.caption2)
                        Text(verbatim: "\(rec.markers.count)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            StatusBadge(rec: rec)
        }
        .padding(.vertical, 4)
    }
}

struct StatusBadge: View {
    let rec: Recording

    var body: some View {
        switch rec.status {
        case .recording:
            Image(systemName: "record.circle").foregroundStyle(Theme.red).symbolEffect(.pulse)
        case .saving:
            ProgressView().controlSize(.small)
        case .local:
            Text("To transcribe")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Theme.indigo.opacity(0.12), in: Capsule())
                .foregroundStyle(Theme.indigo)
        case .uploading:
            ProgressRing(value: rec.uploadProgress * 0.15, color: Theme.indigo)
        case .processing:
            ProgressRing(value: 0.15 + rec.progress * 0.85, color: Theme.violet)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .done:
            EmptyView()
        }
    }
}

struct ProgressRing: View {
    let value: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 3)
            Circle().trim(from: 0, to: max(0.03, min(1, value)))
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut, value: value)
        }
        .frame(width: 22, height: 22)
    }
}

struct EmptyHomeView: View {
    var onImport: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 54))
                .foregroundStyle(Theme.brand)
                .padding(.top, 24)
            Text("Your first meeting starts here")
                .font(.title3.weight(.semibold))
            Text("Tap the button to record. You can lock your iPhone: Parley keeps listening. You get the transcript, who said what, and a summary.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onImport) {
                Label("Import an audio or video file", systemImage: "square.and.arrow.down")
                    .font(.subheadline.weight(.medium))
            }
            .padding(.top, 4)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Bottom of the home screen: the record button, or the live recording bar.
struct RecordDock: View {
    @Environment(AppModel.self) private var model
    @Environment(AudioRecorder.self) private var recorder
    var onImport: () -> Void

    var body: some View {
        Group {
            if recorder.isActive {
                Button { model.showRecorder = true } label: {
                    HStack(spacing: 12) {
                        Circle().fill(recorder.state == .paused ? Color.orange : Theme.red)
                            .frame(width: 10, height: 10)
                            .symbolEffect(.pulse, isActive: recorder.state == .recording)
                        Text(recorder.state == .paused ? tr("Paused") : tr("Recording"))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(Fmt.clock(recorder.elapsed))
                            .font(.subheadline.monospacedDigit())
                        Image(systemName: "chevron.up")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .frame(height: 56)
                    .background(Theme.night, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                }
                .padding(.horizontal, 20)
            } else {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "mic.fill")
                        Text("Record")
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(Theme.brand, in: Capsule())
                    .shadow(color: Theme.violet.opacity(0.4), radius: 14, y: 6)
                }
                .padding(.horizontal, 40)
                .sensoryFeedback(.impact, trigger: recorder.isActive)
                .accessibilityHint(Text("Starts recording. Recording continues when the screen is locked."))
            }
        }
        .padding(.bottom, 12)
    }
}

/// Plan, minutes left, trial status - or the invitation to start the trial.
struct UsageCard: View {
    @Environment(AppModel.self) private var model
    @Environment(SubscriptionManager.self) private var subs

    var body: some View {
        if let a = subs.account, a.active {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(subs.planName, systemImage: a.isTrial ? "gift.fill" : "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.indigo)
                    Spacer()
                    Text(tr("%@ left", Fmt.duration(a.remainingSeconds)))
                        .font(.subheadline.weight(.semibold))
                }
                ProgressView(value: a.usedFraction)
                    .tint(a.usedFraction > 0.85 ? .orange : Theme.indigo)
                HStack {
                    if a.isTrial, let end = a.expiresDate {
                        Text(tr("Trial ends %@", end.formatted(date: .abbreviated, time: .omitted)))
                    } else if let end = a.periodEndDate {
                        Text(tr("Renews %@", end.formatted(date: .abbreviated, time: .omitted)))
                    }
                    Spacer()
                    if a.usedFraction > 0.85 {
                        Button("More time") { model.showPaywall = true }
                            .font(.caption.weight(.semibold))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .card()
        } else {
            Button { model.showPaywall = true } label: {
                HStack(spacing: 14) {
                    Image(systemName: "sparkles")
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subs.trialEligible ? tr("Try Parley free for 7 days") : tr("Unlock transcription"))
                            .font(.headline)
                        Text("Transcript, speakers and AI summary")
                            .font(.caption)
                            .opacity(0.9)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(.white)
                .padding(16)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
    }
}
