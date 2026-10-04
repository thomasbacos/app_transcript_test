import StoreKit
import SwiftUI

struct PaywallView: View {
    /// Inside onboarding the paywall is a page, not a sheet.
    var embedded = false
    var onClose: (() -> Void)?

    @Environment(SubscriptionManager.self) private var subs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selectedID: String?
    @State private var purchasing = false
    @State private var restoring = false
    @State private var message: String?

    private var selected: Product? {
        subs.products.first { $0.id == selectedID } ?? subs.products.first { $0.isYearly } ?? subs.products.first
    }

    private var offersTrial: Bool { subs.trialEligible && (selected?.hasFreeTrial ?? true) }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    features
                    plans
                    cta
                    legal
                }
                .padding(.horizontal, 20)
                .padding(.top, 36)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)

            Button {
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.thinMaterial, in: Circle())
            }
            .padding(16)
            .accessibilityLabel(Text("Close"))
        }
        .background(Color(.systemGroupedBackground))
        .task {
            if subs.products.isEmpty { await subs.loadProducts() }
            if subs.plans == nil { await subs.loadPlans() }
            if selectedID == nil { selectedID = selected?.id }
        }
        .alert("Parley", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Theme.brand)
                    .frame(width: 76, height: 76)
                Image(systemName: "waveform")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Theme.violet.opacity(0.35), radius: 16, y: 8)
            Text(offersTrial ? tr("Try Parley free for 7 days") : tr("Choose your plan"))
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            Text("Every meeting, transcribed and summarized. Who said what, decisions, next steps.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var features: some View {
        VStack(alignment: .leading, spacing: 12) {
            feature("lock.iphone", tr("Records with the screen locked, for hours"))
            feature("person.2.wave.2", tr("Identifies who is speaking"))
            feature("list.bullet.rectangle", tr("Summary and action items in seconds"))
            feature("wand.and.stars", tr("Fixes names and jargon using your documents"))
            feature("lock.shield", tr("Audio deleted from our servers after processing"))
        }
        .card()
    }

    private func feature(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.indigo)
                .frame(width: 26)
            Text(text).font(.subheadline)
        }
    }

    @ViewBuilder
    private var plans: some View {
        if subs.products.isEmpty {
            VStack(spacing: 10) {
                if subs.loadingProducts {
                    ProgressView()
                } else {
                    Text("The plans could not be loaded. Check your connection.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") { Task { await subs.loadProducts() } }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            VStack(spacing: 10) {
                ForEach(subs.products, id: \.id) { p in
                    planCard(p)
                }
            }
        }
    }

    private func planCard(_ p: Product) -> some View {
        let isSelected = p.id == selected?.id
        let hours = subs.minutes(for: p.planID) / 60
        return Button {
            selectedID = p.id
        } label: {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Theme.indigo : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(p.planName).font(.headline)
                        Text(p.isYearly ? tr("Yearly") : tr("Monthly"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        if p.isYearly {
                            Text("Best value")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Theme.coral, in: Capsule())
                                .foregroundStyle(.white)
                        }
                    }
                    Text(tr("%lld h of transcription per month", hours))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(p.displayPrice).font(.headline)
                    if let m = p.monthlyEquivalent {
                        Text(tr("%@/month", m)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(p.periodLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? Theme.indigo : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cta: some View {
        VStack(spacing: 10) {
            Button {
                buy()
            } label: {
                ZStack {
                    if purchasing {
                        ProgressView().tint(.white)
                    } else {
                        Text(offersTrial ? tr("Start my 7-day free trial") : tr("Subscribe"))
                            .font(.headline)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .foregroundStyle(.white)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(selected == nil || purchasing)

            if let p = selected {
                Text(offersTrial
                     ? tr("Free for 7 days (%lld min of transcription), then %@ %@. Cancel anytime.", subs.trialMinutes, p.displayPrice, p.periodLabel)
                     : tr("%@ %@. Cancel anytime.", p.displayPrice, p.periodLabel))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var legal: some View {
        VStack(spacing: 12) {
            HStack(spacing: 18) {
                Button(restoring ? tr("Restoring…") : tr("Restore purchases")) {
                    restoring = true
                    Task {
                        await subs.restore()
                        restoring = false
                        if subs.isActive { close() } else { message = tr("No active subscription found for this Apple ID.") }
                    }
                }
                Button("Terms") { openURL(AppConfig.termsURL) }
                Button("Privacy") { openURL(AppConfig.privacyURL) }
            }
            .font(.footnote.weight(.medium))
            Text("Payment is charged to your Apple ID at the end of the free trial, or at confirmation if no trial applies. The subscription renews automatically unless cancelled at least 24 hours before the end of the current period. Manage or cancel it in your App Store account settings.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func buy() {
        guard let p = selected else { return }
        purchasing = true
        Task {
            defer { purchasing = false }
            do {
                switch try await subs.purchase(p) {
                case .success: close()
                case .pending: message = tr("Your purchase is waiting for approval.")
                case .cancelled: break
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
