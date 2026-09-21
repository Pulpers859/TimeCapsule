import Combine
import StoreKit

/// The app's single in-app purchase: a one-time, non-consumable unlock.
///
/// Deliberately not a subscription. The app has no server, no ongoing cost and
/// no continuously delivered content, so a recurring charge would be charging
/// rent for something already sitting on the user's phone — and reviewers say
/// so, loudly, in the only place that affects sales.
enum AtticPro {
    /// Must match the product identifier created in App Store Connect exactly.
    /// It does not have to match the bundle identifier, and deliberately does
    /// not, so that changing one never silently invalidates the other.
    static let productID = "attic.pro.lifetime"
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
/// works offline. There is no need — and no good reason — to mirror it as the
/// thing that *authorizes* Pro.
///
/// What this store does publish is `AtticDefaults.isProEntitled`, the last
/// answer it saw. That is not authorization: it exists because the widget
/// extension and the notification scheduler have to know whether the two Pro
/// settings apply, and neither can reach StoreKit. Every consumer of it is
/// built to tolerate it being briefly stale.
final class PurchaseStore: ObservableObject {
    @Published private(set) var isUnlocked = false
    @Published private(set) var product: Product?
    @Published private(set) var isLoadingProduct = false
    @Published private(set) var purchaseInFlight = false
    @Published private(set) var restoreInFlight = false

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
            if transaction.productID == AtticPro.productID {
                unlocked = true
            }
        }

        // Published to the shared suite so the widget and the notification
        // scheduler — neither of which can ask StoreKit — honour the same
        // answer. Nothing stored by the user is touched.
        //
        // An earlier version reset the two Pro settings to their free
        // defaults whenever the entitlement went away. That destroyed a
        // paying user's preferences on any reading that merely *looked*
        // empty, and there are several: an entitlement that fails
        // verification is skipped by the `guard` above exactly like an absent
        // one, and a device restored from backup brings the flag back while
        // the signed transaction store may still be syncing. Because the
        // reset also cleared the flag, nothing put the values back when the
        // entitlement reappeared. Gating at the point of use instead —
        // `MemoryWindow.dayWindow` and `dayStartHour` — makes a wrong reading
        // cost nothing but a temporary drop to free-tier behaviour.
        let wasEntitled = AtticDefaults.isProEntitled
        isUnlocked = unlocked
        AtticDefaults.isProEntitled = unlocked

        if wasEntitled != unlocked {
            // The effective memory window just changed, so the gallery has to
            // refetch and the notification schedule has to rebuild its counts
            // — the same post Settings makes when those values change.
            NotificationCenter.default.post(name: .timeCapsulePhotosDidChange, object: nil)
        }
    }

    /// Whether this error means "the user backed out" rather than
    /// "something went wrong".
    ///
    /// Matching `StoreKitError.userCancelled` alone was too narrow to rely
    /// on: `AppStore.sync()` surfaces a dismissed sign-in sheet through more
    /// than one type, and anything it does not match now shows a
    /// "couldn't reach the App Store" alert — so being wrong here turns a
    /// deliberate cancellation into a false error report. All three forms
    /// are checked, and the `SKError` one by domain and code so it does not
    /// depend on a bridged Swift type.
    private static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let storeKitError = error as? StoreKitError,
           case .userCancelled = storeKitError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == SKErrorDomain
            && nsError.code == SKError.Code.paymentCancelled.rawValue
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
            product = try await Product.products(for: [AtticPro.productID]).first
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
                // An unverified result here is not the same as one arriving
                // through `Transaction.updates`, where granting nothing and
                // saying nothing is right. The user has just tapped Buy and
                // the App Store has charged them: `.success` means the
                // purchase went through, and only the local signature check
                // failed. Falling through to `apply` — which drops an
                // unverified result on the floor — left the paywall sitting
                // on its own Unlock button with no error, no unlock and no
                // explanation, immediately after taking the money.
                //
                // The message names the likely cause rather than just
                // sending them to Restore. Restore alone cannot help here:
                // `refreshEntitlement` filters on the same
                // `guard case .verified`, and `AppStore.sync()` does not
                // repair a local signature check — so telling them to tap
                // it would have produced "No previous purchase was found",
                // which is both wrong and alarming right after a payment.
                // A wrong device clock is the usual reason verification
                // fails, and it is something they can actually fix.
                guard case .verified = verification else {
                    purchaseError = "Your purchase went through, but Attic couldn't verify it on this device. Check that your date and time are set correctly, then tap Restore Purchase. You won't be charged again."
                    break
                }
                await apply(verification)

            case .pending:
                // Ask to Buy, or a required banking action. The purchase is not
                // lost and not failed; it will arrive through Transaction.updates
                // if and when it is approved.
                pendingApprovalNotice = "This purchase needs approval before it can finish. Attic Pro will unlock automatically once it goes through."

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
        guard !restoreInFlight else { return }
        restoreInFlight = true
        defer { restoreInFlight = false }

        await refreshEntitlement()
        guard !isUnlocked else { return }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !isUnlocked {
                purchaseError = "No previous purchase was found for this Apple Account."
            }
        } catch {
            await refreshEntitlement()

            // Dismissing the sign-in sheet is a decision, not a failure, and
            // reporting it back as one would be noise.
            guard !Self.isUserCancellation(error) else { return }

            // Everything else is worth saying. This used to be silent for
            // all of it, so a restore attempted with no network — the
            // ordinary case, since `AppStore.sync()` is the only part of this
            // flow that needs one — did nothing at all and looked like a
            // dead button.
            if !isUnlocked {
                purchaseError = "Attic couldn't reach the App Store to restore your purchase. Check your connection and try again."
            }
        }
    }
}
