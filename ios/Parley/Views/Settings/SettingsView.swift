import StoreKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(SubscriptionManager.self) private var subs
    @Environment(RecordingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.requestReview) private var requestReview
    @State private var options = Prefs.defaultOptions
    @State private var autoTranscribe = Prefs.autoTranscribe
    @State private var keepAwake = Prefs.keepAwake
    @State private var manageSubscriptions = false
    @State private var confirmServerDelete = false
    @State private var confirmLocalDelete = false
    @State private var info: String?

    private var language: Binding<String> {
        Binding(get: { options.languages.first ?? "auto" },
                set: { options.languages = $0 == "auto" ? [] : [$0] })
    }

    var body: some View {
        NavigationStack {
            Form {
                subscriptionSection

                Section {
                    Toggle("Transcribe automatically after recording", isOn: $autoTranscribe)
                    Toggle("Keep the screen on while recording", isOn: $keepAwake)
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Recording continues with the screen locked either way.")
                }

                Section("Transcription defaults") {
                    Picker("Spoken language", selection: language) {
                        Text("Detect automatically").tag("auto")
                        ForEach(SpokenLanguages.codes, id: \.self) { Text(Fmt.languageName($0)).tag($0) }
                    }
                    Toggle("Identify speakers", isOn: $options.speakers)
                    Toggle("Smart correction", isOn: $options.correct)
                    Toggle("Summary and action items", isOn: $options.summary)
                    Picker("Summary language", selection: $options.summaryLanguage) {
                        Text("Same as the recording").tag("auto")
                        ForEach(["fr", "en", "es", "de", "it", "pt", "nl"], id: \.self) { Text(Fmt.languageName($0)).tag($0) }
                    }
                    TextField("Expected names and terms", text: $options.terms, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section {
                    Button("Delete my data from the server", role: .destructive) { confirmServerDelete = true }
                    Button("Delete all recordings on this iPhone", role: .destructive) { confirmLocalDelete = true }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Audio is deleted from the server as soon as it is transcribed, and the transcript as soon as this iPhone has downloaded it. Recordings you do not transcribe never leave your iPhone.")
                }

                Section("About") {
                    Button("Privacy policy") { openURL(AppConfig.privacyURL) }
                    Button("Terms of use") { openURL(AppConfig.termsURL) }
                    Button("Help and contact") { openURL(AppConfig.supportURL) }
                    Button("Rate Parley") { requestReview() }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(AppConfig.version).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .manageSubscriptionsSheet(isPresented: $manageSubscriptions)
            .onChange(of: options) { _, o in Prefs.defaultOptions = o }
            .onChange(of: autoTranscribe) { _, v in Prefs.autoTranscribe = v }
            .onChange(of: keepAwake) { _, v in Prefs.keepAwake = v }
            .task { await subs.refreshAccount(force: true) }
            .confirmationDialog("Delete your data from the server?", isPresented: $confirmServerDelete,
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await APIClient.shared.deleteAccount()
                            info = tr("Your data was deleted from the server. Your subscription is not affected.")
                        } catch {
                            info = error.localizedDescription
                        }
                    }
                }
            } message: {
                Text("Transcriptions in progress are cancelled. Recordings on this iPhone are kept.")
            }
            .confirmationDialog("Delete all recordings?", isPresented: $confirmLocalDelete, titleVisibility: .visible) {
                Button("Delete everything", role: .destructive) {
                    for r in store.recordings { model.delete(r.id) }
                }
            } message: {
                Text("Audio, transcripts and summaries on this iPhone. This cannot be undone.")
            }
            .alert("Parley", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(info ?? "")
            }
        }
    }

    /// Sheets cannot stack: close Settings first, then show the paywall from the root.
    private func openPaywall() {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            model.showPaywall = true
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        Section {
            if let a = subs.account, a.active {
                HStack {
                    Label(subs.planName, systemImage: a.isTrial ? "gift.fill" : "sparkles")
                        .foregroundStyle(Theme.indigo)
                    Spacer()
                    Text(tr("%@ left", Fmt.duration(a.remainingSeconds)))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: a.usedFraction).tint(Theme.indigo)
                if let end = a.isTrial ? a.expiresDate : a.periodEndDate {
                    Text(a.isTrial ? tr("Trial ends %@", Fmt.day(end)) : tr("Minutes renew %@", Fmt.day(end)))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Change plan") { openPaywall() }
                Button("Manage subscription") { manageSubscriptions = true }
            } else {
                Button {
                    openPaywall()
                } label: {
                    Label(subs.trialEligible ? tr("Start the 7-day free trial") : tr("See plans"), systemImage: "sparkles")
                }
                if subs.hasLocalEntitlement && !subs.serverReachable {
                    Text("Your subscription is active but the server cannot be reached right now.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Button("Restore purchases") { Task { await subs.restore() } }
        } header: {
            Text("Subscription")
        }
    }
}
