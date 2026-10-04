import SwiftUI

struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var page = 0
    @State private var askedMic = false

    private struct Page {
        let icon: String
        let title: String
        let text: String
    }

    private var pages: [Page] {
        [
            Page(icon: "lock.iphone", title: tr("Record, even locked"),
                 text: tr("Start Parley and put your iPhone down. It keeps recording with the screen locked, through calls and for hours.")),
            Page(icon: "person.2.wave.2", title: tr("Who said what"),
                 text: tr("A clean transcript with each speaker identified. Rename them in one tap, jump to any moment.")),
            Page(icon: "list.bullet.rectangle.portrait", title: tr("The summary, ready to share"),
                 text: tr("Key points, decisions and action items. Export to PDF, Notion or your notes.")),
        ]
    }

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                VStack(spacing: 24) {
                    Spacer()
                    ZStack {
                        Circle().fill(Theme.brand).frame(width: 150, height: 150)
                            .shadow(color: Theme.violet.opacity(0.4), radius: 30, y: 12)
                        Image(systemName: p.icon)
                            .font(.system(size: 62, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text(p.title)
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(p.text)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                    Spacer()
                    Button {
                        next(from: i)
                    } label: {
                        Text(i == pages.count - 1 ? tr("Allow the microphone") : tr("Continue"))
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 50)
                }
                .tag(i)
            }
            PaywallView(embedded: true, onClose: onFinish)
                .tag(pages.count)
        }
        .tabViewStyle(.page(indexDisplayMode: page < pages.count ? .always : .never))
        .indexViewStyle(.page(backgroundDisplayMode: .always))
        .background(Color(.systemBackground))
        .animation(.easeInOut, value: page)
    }

    private func next(from i: Int) {
        if i == pages.count - 1 {
            Task {
                if !askedMic {
                    askedMic = true
                    _ = await AudioRecorder.requestPermission()
                }
                page = pages.count
            }
        } else {
            page = i + 1
        }
    }
}
