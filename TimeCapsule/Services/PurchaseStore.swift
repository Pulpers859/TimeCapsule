import Combine
import StoreKit

/// The app's single in-app purchase: a one-time, non-consumable unlock.
///
/// Deliberately not a subscription. The app has no server, no ongoing cost and
/// no continuously delivered content, so a recurring charge would be charging
/// rent for something already sitting on the user's phone — and reviewers say
/// so, loudly, in the only place that affects sales.
enum TimeCapsulePro {
    /// Must match the product identifier created in App Store Connect exactly.
    /// It does not have to match the bundle identifier, and deliberately does
    /// not, so that changing one never silently invalidates the other.
    static let productID = "timecapsule.pro.lifetime"
}

/// Owns entitlement state for the lifetime of the app.
///
/// The source of truth is always `Transaction.currentEntitlements`, never a
/// cached flag of our own. That matters for three cases that a cached
/// `UserDefaults` bool gets wrong:
///
/// - **Refunds and revocations.** Apple removes the entitlement; a cached flag
///   would keep the app unlocked forever after a refund.
/// - **Family Sharing.** A family member's entitlement appears here without
///   them ever purchasing, and our own flag would never have been set.
/// - **Reinstalls and new devices.** The entitlement follows the Apple Account,
///   so it is already present before the user thinks to tap Restore.
///
/// `currentEntitlements` reads the on-device signed transaction store, so it
/// works offline. There is no need — and no good reason — to mirror it.
final class PurchaseStore: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var product: Product?
    @Published private(set) var isLoadingProduct = false
    @Published private(set) var purchaseInFlight = false

    /// Set when a purchase needs the user to go and do something — Ask to Buy
    /// approval, or a banking step — rather than having failed.
    @Published var pendingApprovalNotice: String?
    @Published var purchaseError: String?

    private var updatesTask: Task<Void, Never>?

    init() {
        // Started before any purchase can be attempted and never cancelled
        // while the app lives. This is the only path by which an interrupted
        // purchase, an Ask to Buy approval granted later, or a refund reaches
        // the app, and StoreKit will replay unfinished transactions into it.
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                await self.apply(update)
            }
        }

        Task { await refreshEntitlement() }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Entitlement

    func refreshEntitlement() async {
        var unlocked = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            if transaction.productID == TimeCapsulePro.productID {
                unlocked = true
            }
        }

        let hadEntitlement = isUnlocked
        isUnlocked = unlocked
        if hadEntitlement && !unlocked {
            releaseProSettings()
        }
    }

    /// Returns the settings Pro unlocks to their free defaults.
    ///
    /// Without this, two of the three Pro features survive a refund forever,
    /// and no jailbreak is needed to get there: buy Pro, widen the memory range
    /// and set a late day start, then ask Apple for a refund. The entitlement
    /// correctly disappears and the pickers correctly re-lock — but the values
    /// live in `UserDefaults`, and `MemoryWindow` reads them directly with no
    /// idea an entitlement was ever involved. Only the recap is gated at the
    /// point of use and so is genuinely revoked.
    ///
    /// The reset belongs here rather than inside `MemoryWindow`. That type is
    /// `nonisolated` and is read from a detached task in the notification
    /// scheduler; it has no access to this store and should not grow one.
    ///
    /// Reached only on a true -> false transition, so a first launch (which
    /// starts at false) never wipes anything.
    private func releaseProSettings() {
        let defaults = UserDefaults.standard
        defaults.set(MemoryWindow.defaultDayWindow, forKey: MemoryWindow.storageKey)
        defaults.set(MemoryWindow.defaultDayStartHour, forKey: MemoryWindow.dayStartHourKey)

        // Same post Settings uses when these change: the gallery refetches and
        // the notification schedule rebuilds with the corrected counts.
        NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)
    }

    private func apply(_ result: VerificationResult<Transaction>) async {
        // An unverified transaction is one StoreKit could not prove came from
        // Apple. Finishing it would tell StoreKit we handled it, so it is left
        // alone deliberately and simply grants nothing.
        guard case .verified(let transaction) = result else { return }
        await refreshEntitlement()
        await transaction.finish()
    }

    // MARK: - Products

    func loadProduct() async {
        guard product == nil, !isLoadingProduct else { return }
        isLoadingProduct = true
        defer { isLoadingProduct = false }
        do {
            product = try await Product.products(for: [TimeCapsulePro.productID]).first
        } catch {
            // Offline, or the product is not yet approved in App Store Connect.
            // The paywall shows its unavailable state; nothing is broken.
            product = nil
        }
    }

    // MARK: - Purchase

    func purchase() async {
        guard let product, !purchaseInFlight else { return }
        purchaseInFlight = true
        defer { purchaseInFlight = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                await apply(verification)

            case .pending:
                // Ask to Buy, or a required banking action. The purchase is not
                // lost and not failed; it will arrive through Transaction.updates
                // if and when it is approved.
                pendingApprovalNotice = "This purchase needs approval before it can finish. Time Capsule Pro will unlock automatically once it goes through."

            case .userCancelled:
                break

            @unknown default:
                break
            }
        } catch {
            purchaseError = "The purchase couldn't be completed. You have not been charged."
        }
    }

    /// Restores a purchase made on another device or before a reinstall.
    ///
    /// `currentEntitlements` alone covers almost every real case, so this is
    /// tried first and the App Store is only contacted if it comes back empty.
    /// App Review requires a visible restore control for non-consumables
    /// regardless, and this is it.
    func restore() async {
        await refreshEntitlement()
        guard !isUnlocked else { return }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !isUnlocked {
                purchaseError = "No previous purchase was found for this Apple Account."
            }
        } catch {
            // A cancelled sign-in sheet lands here too, which is not an error
            // worth interrupting the user over.
            await refreshEntitlement()
        }
    }
}
