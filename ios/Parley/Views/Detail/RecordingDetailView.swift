import StoreKit
import SwiftUI
import UIKit

struct RecordingDetailView: View {
    let id: UUID
    @Environment(AppModel.self) private var model
    @Environment(RecordingStore.self) private var store
    @Environment(ProcessingService.self) private var processing
    @Environment(AudioRecorder.self) private var recorder
    @Environment(\.requestReview) private var requestReview
    @State private var player = AudioPlayer()
    @State private var tab: Tab = .summary
    @State private var share: ShareItem?
    @State private var renaming = false
    @State private var titleDraft = ""
    @State private var speakerToRename: String?
    @State private var speakerDraft = ""
    @State private var confirmDelete = false
    @State private var exportError: String?

    enum Tab: Hashable { case summary, transcript }

    var body: some View {
        Group {
            if let rec = store.recording(id) {
                content(rec)
            } else {
                ContentUnavailableView("Recording deleted", systemImage: "trash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $share) { item in
            ShareSheet(items: item.items).presentationDetents([.medium, .large])
        }
        .onDisappear { player.pause() }
        .onChange(of: processing.lastCompleted) { _, done in
            if done == id, Prefs.completedCount == 3 { requestReview() }
        }
    }

    @ViewBuilder
    private func content(_ rec: Recording) -> some View {
        let result = store.result(for: id)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(rec, result)
                        switch rec.status {
                        case .recording, .saving:
                            HStack(spacing: 10) {
                                ProgressView()
                                Text(rec.status == .saving ? tr("Saving the audio…") : tr("Recording in progress…"))
                            }
                            .card()
                        case .local:
                            TranscribeCard(rec: rec)
                        case .uploading, .processing:
                            ProgressCard(rec: rec)
                        case .failed:
                            FailureCard(rec: rec)
                        case .done:
                            if let result {
                                Picker("View", selection: $tab) {
                                    Text("Summary").tag(Tab.summary)
                                    Text("Transcript").tag(Tab.transcript)
                                }
                                .pickerStyle(.segmented)
                                if tab == .summary {
                                    SummaryView(rec: rec, result: result)
                                } else {
                                    TranscriptView(rec: rec, result: result, player: player, proxy: proxy,
                                                   onRenameSpeaker: { spk in
                                                       speakerDraft = result.displayName(spk, overrides: rec.speakerNames)
                                                       speakerToRename = spk
                                                   })
                                }
                            } else {
                                missingResult(rec)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            if player.isLoaded && rec.status != .recording && rec.status != .saving {
                PlayerBar(player: player, enabled: !recorder.isActive)
            }
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { player.load(store.audioURL(rec)) }
        .onChange(of: rec.audioFile) { _, _ in player.load(store.audioURL(rec)) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { menu(rec, result) }
        }
        .alert("Rename", isPresented: $renaming) {
            TextField("Title", text: $titleDraft)
            Button("Save") {
                let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { store.update(id) { $0.title = t; $0.titleIsCustom = true } }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename speaker", isPresented: Binding(get: { speakerToRename != nil },
                                                      set: { if !$0 { speakerToRename = nil } })) {
            TextField("Name", text: $speakerDraft)
            Button("Save") {
                if let spk = speakerToRename {
                    let n = speakerDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.update(id) { $0.speakerNames[spk] = n.isEmpty ? nil : n }
                }
                speakerToRename = nil
            }
            Button("Cancel", role: .cancel) { speakerToRename = nil }
        } message: {
            Text("Applies to the whole transcript and to exports.")
        }
        .confirmationDialog("Delete this recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { model.delete(id) }
        } message: {
            Text("The audio and its transcript will be deleted from this iPhone.")
        }
        .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    private func header(_ rec: Recording, _ result: TranscriptResult?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                titleDraft = rec.title
                renaming = true
            } label: {
                Text(rec.title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Text(Fmt.date(rec.createdAt))
                Text("·")
                Text(Fmt.duration(rec.duration))
                if let result, !result.speakers.isEmpty {
                    Text("·")
                    Image(systemName: "person.2.fill").font(.caption2)
                    Text(verbatim: "\(result.speakers.count)")
                }
                if let lang = result?.language {
                    Text("·")
                    Text(Fmt.languageName(lang))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func missingResult(_ rec: Recording) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("The transcript is ready on the server but not yet downloaded.")
            if let jobID = rec.jobID {
                Button("Download") { Task { await processing.fetchResult(id, jobID: jobID) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .card()
    }

    private func menu(_ rec: Recording, _ result: TranscriptResult?) -> some View {
        Menu {
            if let result {
                Section("Share") {
                    ForEach(Exporter.Format.allCases) { f in
                        Button { export(f, rec, result) } label: { Label(f.label, systemImage: f.icon) }
                    }
                    Button {
                        UIPasteboard.general.string = Exporter.summaryText(rec, result)
                    } label: { Label("Copy the summary", systemImage: "doc.on.doc") }
                }
            }
            Button {
                share = ShareItem(items: [store.audioURL(rec)])
            } label: { Label("Share the audio", systemImage: "waveform") }
            Section {
                Button {
                    titleDraft = rec.title
                    renaming = true
                } label: { Label("Rename", systemImage: "pencil") }
                if rec.status == .done || rec.status == .failed {
                    Button { model.requestTranscription(id) } label: {
                        Label("Transcribe again", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel(Text("More"))
    }

    private func export(_ f: Exporter.Format, _ rec: Recording, _ result: TranscriptResult) {
        do {
            share = ShareItem(items: [try Exporter.file(f, recording: rec, result: result)])
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - Status cards

struct TranscribeCard: View {
    let rec: Recording
    @Environment(AppModel.self) private var model
    @Environment(SubscriptionManager.self) private var subs

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ready to transcribe", systemImage: "text.bubble.fill")
                .font(.headline)
                .foregroundStyle(Theme.indigo)
            Text("Get the full transcript, who said what, a summary and the action items.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                model.requestTranscription(rec.id)
            } label: {
                Text(subs.isActive ? tr("Transcribe") : (subs.trialEligible ? tr("Start my free trial") : tr("See plans")))
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .foregroundStyle(.white)
                    .background(Theme.brand, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if let a = subs.account, a.active {
                Text(tr("Uses %@ of your %@ left", Fmt.duration(rec.duration), Fmt.duration(a.remainingSeconds)))
                    .font(.caption)
                    .foregroundStyle(rec.duration > a.remainingSeconds ? .orange : .secondary)
            }
        }
        .card()
    }
}

struct ProgressCard: View {
    let rec: Recording

    private var steps: [(key: String, label: String)] {
        var s: [(key: String, label: String)] = [("upload", tr("Sending the audio")), ("preparing", tr("Preparing")),
                                                 ("text", tr("Transcribing"))]
        if rec.options?.speakers ?? true { s.append(("speakers", tr("Identifying speakers"))) }
        if rec.options?.correct ?? true { s.append(("correcting", tr("Correcting names and terms"))) }
        if rec.options?.summary ?? true { s.append(("finalizing", tr("Writing the summary"))) }
        return s
    }

    private var current: String {
        if rec.status == .uploading { return "upload" }
        switch rec.stage ?? "" {
        case "queued", "retrying", "preparing", "": return "preparing"
        case "text": return "text"
        case "speakers": return "speakers"
        case "correcting": return "correcting"
        default: return "finalizing"
        }
    }

    private var overall: Double {
        rec.status == .uploading ? rec.uploadProgress * 0.15 : 0.15 + rec.progress * 0.85
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(rec.stage == "retrying" ? tr("Retrying…") : tr("Working on it…"))
                    .font(.headline)
                Spacer()
                Text(verbatim: "\(Int(overall * 100)) %")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: overall)
                .tint(Theme.violet)
                .animation(.easeInOut, value: overall)
            let idx = steps.firstIndex { $0.key == current } ?? 0
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                    HStack(spacing: 10) {
                        Group {
                            if i < idx {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            } else if i == idx {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.tertiary)
                            }
                        }
                        .frame(width: 20)
                        Text(step.label)
                            .foregroundStyle(i <= idx ? .primary : .secondary)
                        if step.key == "upload" && i == idx {
                            Spacer()
                            Text(verbatim: "\(Int(rec.uploadProgress * 100)) %").font(.caption.monospacedDigit())
                        }
                    }
                    .font(.subheadline)
                }
            }
            Label("You can close Parley: you will get a notification when it is ready.", systemImage: "bell.badge")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }
}

struct FailureCard: View {
    let rec: Recording
    @Environment(AppModel.self) private var model
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Transcription interrupted", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(rec.errorMessage ?? tr("Something went wrong."))
                .font(.subheadline)
            Text("Your recording is safe on this iPhone.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                working = true
                Task {
                    if rec.retryable {
                        await model.retry(rec.id)
                    } else {
                        model.requestTranscription(rec.id)
                    }
                    working = false
                }
            } label: {
                HStack {
                    if working { ProgressView().tint(.white) }
                    Text(rec.retryable ? tr("Resume") : tr("Transcribe again"))
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .foregroundStyle(.white)
                .background(Theme.indigo, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .disabled(working)
        }
        .card()
    }
}
