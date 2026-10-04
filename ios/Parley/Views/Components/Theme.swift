import SwiftUI
import UIKit

enum Theme {
    static let indigo = Color(hex: 0x5B4BDB)
    static let violet = Color(hex: 0xA34BD8)
    static let coral = Color(hex: 0xFF6F7D)
    static let red = Color(hex: 0xFF3B4E)
    static let night = Color(hex: 0x0F0E17)

    static let brand = LinearGradient(colors: [indigo, violet, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let recorderBackground = LinearGradient(colors: [Color(hex: 0x1A1636), Color(hex: 0x0F0E17)],
                                                   startPoint: .top, endPoint: .bottom)

    static let speakers: [Color] = [0x5B4BDB, 0xE0567A, 0x1FA67A, 0xF29D38, 0x2E8BE6, 0x9B59D0, 0x00A3A3, 0xD35400]
        .map { Color(hex: $0) }

    static func speakerColor(_ index: Int) -> Color { speakers[abs(index) % speakers.count] }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

struct CardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

extension View {
    func card() -> some View { modifier(CardStyle()) }
}

struct SpeakerAvatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 32

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap { $0.first.map(String.init) }.joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Live input level: a row of bars, newest on the right.
struct LevelBars: View {
    let levels: [CGFloat]
    var active: Bool
    var color: Color = .white

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(color.opacity(active ? 0.95 : 0.35))
                    .frame(width: 4, height: max(4, level * 90))
            }
        }
        .frame(height: 96)
        .animation(.easeOut(duration: 0.08), value: levels)
        .accessibilityHidden(true)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct ShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// Highlights every occurrence of `query` in `text`.
func highlighted(_ text: String, _ query: String) -> AttributedString {
    var a = AttributedString(text)
    let q = query.trimmingCharacters(in: .whitespaces)
    guard q.count >= 2 else { return a }
    var start = a.startIndex
    while start < a.endIndex,
          let r = a[start...].range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) {
        a[r].backgroundColor = Theme.coral.opacity(0.35)
        a[r].font = .body.bold()
        start = r.upperBound
    }
    return a
}
