import Foundation
import Observation
import StoreKit

/// StoreKit 2 subscriptions. The App Store holds the truth about purchases; the server verifies the
/// signed transactions and holds the truth about minutes.
@MainActor
@Observable
final class SubscriptionManager {
    enum PurchaseOutcome { case success, cancelled, pending }

    private(set) var products: [Product] = []
    private(set) var account: AccountStatus?
    private(set) var plans: PlansInfo?
    private(set) var trialEligible = true
    private(set) var loadingProducts = false
    private(set) var productsFailed = false
    private(set) var serverReachable = true
    /// StoreKit says there is an active subscription (even if the server cannot be reached).
    private(set) var hasLocalEntitlement = false
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh = Date.distantPast

    var isActive: Bool { account?.active == true }
    var isTrial: Bool { account?.isTrial == true }

    func start() async {
        await APIClient.shared.setTransactionProvider { await SubscriptionManager.currentTransactions() }
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refreshAccount(force: true)
            }
        }
        await loadProducts()
        await loadPlans()
        await refreshAccount(force: true)
    }

    nonisolated static func currentTransactions() async -> [String] {
        var out: [String] = []
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productType == .autoRenewable, t.revocationDate == nil {
                out.append(result.jwsRepresentation)
            }
        }
        return out
    }

    func loadProducts() async {
        loadingProducts = true
        defer { loadingProducts = false }
        do {
            let found = try await Product.products(for: AppConfig.productIDs)
            products = AppConfig.productIDs.compactMap { id in found.first { $0.id == id } }
            productsFailed = products.isEmpty
            if let any = products.first, let sub = any.subscription {
                trialEligible = await sub.isEligibleForIntroOffer
            }
        } catch {
            productsFailed = true
        }
    }

    func loadPlans() async {
        if let p = try? await APIClient.shared.plans() { plans = p }
    }

    func refreshAccount(force: Bool = false) async {
        guard force || Date().timeIntervalSince(lastRefresh) > 60 else { return }
        lastRefresh = Date()
        do {
            account = try await APIClient.shared.refreshSession()
            serverReachable = true
        } catch {
            serverReachable = (error as? APIError)?.code != "network"
        }
        hasLocalEntitlement = !(await Self.currentTransactions()).isEmpty
    }

    func purchase(_ product: Product) async throws -> PurchaseOutcome {
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else { return .cancelled }
            await transaction.finish()
            await refreshAccount(force: true)
            if let sub = product.subscription { trialEligible = await sub.isEligibleForIntroOffer }
            return .success
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            return .cancelled
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refreshAccount(force: true)
    }

    // MARK: display helpers

    func minutes(for planID: String) -> Int {
        plans?.minutes(for: planID) ?? AppConfig.fallbackMinutes[planID] ?? 0
    }

    var trialMinutes: Int { plans?.trial.minutes ?? AppConfig.fallbackMinutes["trial"] ?? 60 }

    var planName: String {
        guard let a = account, a.active else { return tr("No subscription") }
        if a.isTrial { return tr("Free trial") }
        return a.plan == "pro" ? "Pro" : tr("Essential")
    }
}

extension Product {
    var planID: String { id.hasSuffix(".essential.monthly") ? "essential" : "pro" }
    var isYearly: Bool { subscription?.subscriptionPeriod.unit == .year }
    var hasFreeTrial: Bool { subscription?.introductoryOffer?.paymentMode == .freeTrial }

    var planName: String { planID == "pro" ? "Pro" : tr("Essential") }

    var periodLabel: String { isYearly ? tr("per year") : tr("per month") }

    var monthlyEquivalent: String? {
        guard isYearly else { return nil }
        return (price / 12).formatted(priceFormatStyle)
    }
}
