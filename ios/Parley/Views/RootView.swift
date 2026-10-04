import SwiftUI
import UIKit

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var onboarded = Prefs.onboarded

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            HomeView()
                .navigationDestination(for: UUID.self) { id in
                    RecordingDetailView(id: id)
                }
        }
        .fullScreenCover(isPresented: $model.showRecorder) {
            RecorderView()
        }
        .sheet(isPresented: $model.showPaywall) {
            PaywallView()
        }
        .sheet(item: $model.transcribeTarget) { id in
            TranscribeSheet(recordingID: id)
        }
        .fullScreenCover(isPresented: Binding(get: { !onboarded }, set: { onboarded = !$0 })) {
            OnboardingView {
                Prefs.onboarded = true
                onboarded = true
            }
        }
        .alert(alertTitle, isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } }),
               presenting: model.alert) { alert in
            switch alert {
            case .microphoneDenied:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            case .needsPlan:
                Button("See plans") { model.showPaywall = true }
                Button("Not now", role: .cancel) {}
            case .message:
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case .microphoneDenied:
                Text("Allow microphone access in Settings to record.")
            case .needsPlan(let m), .message(let m):
                Text(m)
            }
        }
        .overlay {
            if model.importing {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Importing…").font(.subheadline)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .task { await model.launch() }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .onOpenURL { model.handleOpenURL($0) }
    }

    private var alertTitle: String {
        switch model.alert {
        case .microphoneDenied: return tr("Microphone access")
        case .needsPlan: return tr("Transcription time")
        default: return tr("Parley")
        }
    }
}
