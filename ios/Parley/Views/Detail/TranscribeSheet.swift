import SwiftUI
import UniformTypeIdentifiers

/// Options before sending a recording: language, speakers, correction, summary, vocabulary, documents.
struct TranscribeSheet: View {
    let recordingID: UUID
    @Environment(AppModel.self) private var model
    @Environment(RecordingStore.self) private var store
    @Environment(SubscriptionManager.self) private var subs
    @Environment(\.dismiss) private var dismiss
    @State private var options = Prefs.defaultOptions
    @State private var docs: [URL] = []
    @State private var showDocPicker = false
    @State private var saveAsDefault = false
    @State private var sending = false
    @State private var loaded = false
    @State private var problem: AppAlert?

    private static let docTypes: [UTType] = {
        var t: [UTType] = [.pdf, .plainText, .commaSeparatedText, .json, .html, .rtf]
        for ext in ["docx", "pptx", "xlsx", "md"] {
            if let u = UTType(filenameExtension: ext) { t.append(u) }
        }
        return t
    }()

    private var recording: Recording? { store.recording(recordingID) }

    private var language: Binding<String> {
        Binding(get: { options.languages.first ?? "auto" },
                set: { options.languages = $0 == "auto" ? [] : [$0] })
    }

    var body: some View {
        NavigationStack {
            Form {
                if let rec = recording, let a = subs.account {
                    Section {
                        HStack {
                            Label(Fmt.duration(rec.duration), systemImage: "waveform")
                            Spacer()
                            Text(tr("%@ left", Fmt.duration(a.remainingSeconds)))
                                .foregroundStyle(rec.duration > a.remainingSeconds ? .orange : .secondary)
                        }
                        if rec.duration > a.maxFileSeconds + 5 {
                            Label(tr("Your plan transcribes up to %@ per recording.", Fmt.duration(a.maxFileSeconds)),
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        } else if rec.duration > a.remainingSeconds + 5 {
                            Label("Not enough time left this month for this recording.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    Picker("Spoken language", selection: language) {
                        Text("Detect automatically").tag("auto")
                        ForEach(SpokenLanguages.codes, id: \.self) { code in
                            Text(Fmt.languageName(code)).tag(code)
                        }
                    }
                } footer: {
                    Text("Choose it for strong accents or unusual languages: it avoids passages coming out translated.")
                }

                Section("Results") {
                    Toggle(isOn: $options.speakers) {
                        Label("Identify speakers", systemImage: "person.2")
                    }
                    Toggle(isOn: $options.correct) {
                        Label("Smart correction", systemImage: "wand.and.stars")
                    }
                    Toggle(isOn: $options.summary) {
                        Label("Summary and action items", systemImage: "list.bullet.rectangle")
                    }
                    if options.summary {
                        Picker("Summary language", selection: $options.summaryLanguage) {
                            Text("Same as the recording").tag("auto")
                            ForEach(["fr", "en", "es", "de", "it", "pt", "nl"], id: \.self) { code in
                                Text(Fmt.languageName(code)).tag(code)
                            }
                        }
                    }
                }

                Section {
                    TextField("Names, acronyms, jargon…", text: $options.terms, axis: .vertical)
                        .lineLimit(2...5)
                } header: {
                    Text("Expected names and terms")
                } footer: {
                    Text("Separated by commas. Helps spell people, products and jargon correctly.")
                }

                Section {
                    ForEach(docs, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "doc.text")
                            .lineLimit(1)
                    }
                    .onDelete { docs.remove(atOffsets: $0) }
                    if docs.count < 5 {
                        Button {
                            showDocPicker = true
                        } label: {
                            Label("Add a document", systemImage: "plus.circle")
                        }
                    }
                } header: {
                    Text("Reference documents")
                } footer: {
                    Text("Agenda, slides, notes (PDF, Word, PowerPoint, Excel, text). Used only to get names and terms right, then deleted from the server.")
                }

                Section {
                    Toggle("Use these settings by default", isOn: $saveAsDefault)
                }
            }
            .navigationTitle("Transcribe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        start()
                    } label: {
                        if sending { ProgressView() } else { Text("Start").bold() }
                    }
                    .disabled(sending || recording == nil)
                }
            }
            .fileImporter(isPresented: $showDocPicker, allowedContentTypes: Self.docTypes,
                          allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    docs.append(contentsOf: urls.prefix(max(0, 5 - docs.count)))
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let rec = recording {
                    if let o = rec.options { options = o }
                    docs = store.docs(for: rec.id)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .alert("Transcription", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            if case .needsPlan = problem {
                Button("See plans") {
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(650))
                        model.showPaywall = true
                    }
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(problemText)
        }
    }

    private func start() {
        sending = true
        if saveAsDefault { Prefs.defaultOptions = options }
        let opts = options
        let files = docs
        Task {
            let issue = await model.transcribe(recordingID, options: opts, docs: files, presentErrors: false)
            sending = false
            if let issue { problem = issue } else { dismiss() }
        }
    }

    private var problemText: String {
        switch problem {
        case .needsPlan(let m), .message(let m): return m
        case .microphoneDenied, .aiConsent, .none: return ""
        }
    }
}
