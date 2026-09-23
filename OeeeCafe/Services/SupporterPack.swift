import Foundation
import StoreKit
import WebKit

/// Selling the Supporter Pack, which is a year's.
///
/// The site's /supporter page asks through the bridge for the three things only
/// the store can do -- what a pack costs here, buying one, handing an old one
/// over again -- and this answers them (templates/app_bridge.jinja in
/// oeee-cafe/web, which is the contract). The product ids come from the site in
/// those messages rather than being built in: a pack is a year's, and the year
/// it sells is the site's to decide without a release of this app.
///
/// What this never does is tell the site that something was bought, or know
/// which of the site's addresses would hear about it. It hands the page the
/// transaction ids, and the page posts them to the site, which takes each one
/// to Apple itself (templates/app_store.jinja and src/app_store.rs in
/// oeee-cafe/web); a page cannot be trusted about a purchase, and neither can
/// an app. The page answers with the ids the site took, and only those are
/// finished: one the site did not record is left unfinished and offered again
/// the next time the page asks for prices, which is what keeps a dropped
/// connection from costing somebody the pack they paid for. Reloading to show
/// the pack is the page's to do as well, once it has answered.
///
/// Both platforms sell it. The Mac app is sandboxed (ENABLE_APP_SANDBOX) and
/// goes to the Mac App Store under the same bundle id as the iOS app, so it is
/// the same product in the same store, bought and restored the same way.
@MainActor
enum SupporterPack {
    /// What these products cost, in the reader's own currency and formatted
    /// the store's way, handed to the page for the buttons that are waiting
    /// for them. A product the store does not know is simply not in the
    /// answer, and its button keeps its price to itself.
    static func prices(of identifiers: [String], in webView: WKWebView) async {
        guard !identifiers.isEmpty else { return }
        let products: [Product]
        do {
            products = try await Product.products(for: identifiers)
        } catch {
            Logger.error("SupporterPack: could not read prices: \(error)")
            return
        }
        var prices: [String: String] = [:]
        for product in products {
            prices[product.id] = product.displayPrice
        }
        guard !prices.isEmpty else { return }
        _ = try? await webView.callAsyncJavaScript(
            """
            window.oeeeApp && window.oeeeApp.store && window.oeeeApp.store.prices \
            && window.oeeeApp.store.prices(prices);
            """,
            arguments: ["prices": prices],
            in: nil,
            contentWorld: .page
        )
        await handUnfinished(in: webView)
    }

    /// Offers the site every purchase the store still considers unfinished: one
    /// whose hand-over never reached the site, one made while nobody was signed
    /// in, one bought on another device.
    ///
    /// Done as the page asks for prices, which is the page someone opens when
    /// the pack they paid for is not there -- rather than from a listener
    /// living for as long as the app, which each tab would keep one of and each
    /// would hand the same purchase over again.
    private static func handUnfinished(in webView: WKWebView) async {
        var unfinished: [VerificationResult<StoreKit.Transaction>] = []
        for await transaction in StoreKit.Transaction.unfinished {
            unfinished.append(transaction)
        }
        await hand(over: unfinished, in: webView)
    }

    /// Sells `identifier`, and hands what comes back to the site.
    ///
    /// A purchase the person cancels and one the store leaves pending -- asking
    /// a parent, say -- both end here saying nothing. The pending one is still
    /// unfinished when it goes through, so it is handed over the next time this
    /// page asks for prices, like anything else the site never heard about.
    static func buy(_ identifier: String, in webView: WKWebView) async {
        do {
            guard let product = try await Product.products(for: [identifier]).first else {
                Logger.error("SupporterPack: the store has no \(identifier)")
                return
            }
            switch try await product.purchase() {
            case .success(let verification):
                await hand(over: [verification], in: webView)
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            Logger.error("SupporterPack: \(identifier) could not be bought: \(error)")
        }
    }

    /// Hands over what this Apple account has already bought.
    ///
    /// `AppStore.sync()` is what the App Store means by restoring -- it may ask
    /// the person to sign in -- and is only ever done because they pressed
    /// Restore. After it, everything they are entitled to goes to the site,
    /// which gives the pack back to whoever is signed in here. The site keys a
    /// purchase by the purchase rather than by the account, so this can hand a
    /// pack to another Oeee Cafe account but can never make a second one.
    static func restore(in webView: WKWebView) async {
        do {
            try await AppStore.sync()
        } catch {
            // A cancelled sign-in sheet lands here too, and the entitlements
            // already on the device are still worth offering.
            Logger.error("SupporterPack: could not sync with the App Store: \(error)")
        }
        var entitlements: [VerificationResult<StoreKit.Transaction>] = []
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            entitlements.append(entitlement)
        }
        await hand(over: entitlements, in: webView)
    }

    /// Gives the page these transactions' ids in one call, and finishes the
    /// ones it answers that the site took.
    ///
    /// All of them go at once so that the page, which reloads after an answer
    /// in which the site took anything, reloads once rather than once for each
    /// and does not leave while later ones are still being asked about.
    ///
    /// An envelope Apple could not verify is still offered: what it says is
    /// only a transaction id, and the site asks Apple about that id itself.
    /// Nothing is finished but what the page names in its answer, so an
    /// answer that never comes -- a page without the store script, one that
    /// navigated away -- finishes nothing, and it is all offered again.
    private static func hand(
        over verifications: [VerificationResult<StoreKit.Transaction>],
        in webView: WKWebView
    ) async {
        let transactions = verifications.map(\.unsafePayloadValue)
        guard !transactions.isEmpty else { return }
        let answer: Any?
        do {
            answer = try await webView.callAsyncJavaScript(
                """
                return window.oeeeApp && window.oeeeApp.store && window.oeeeApp.store.purchased \
                ? await window.oeeeApp.store.purchased(ids) : [];
                """,
                arguments: ["ids": transactions.map { String($0.id) }],
                in: nil,
                contentWorld: .page
            )
        } catch {
            Logger.error("SupporterPack: the page did not answer about \(transactions.count) transaction(s): \(error)")
            return
        }
        let taken = Set((answer as? [Any] ?? []).compactMap { $0 as? String })
        for transaction in transactions {
            if taken.contains(String(transaction.id)) {
                await transaction.finish()
            } else {
                Logger.error("SupporterPack: the site did not take \(transaction.id)")
            }
        }
    }
}
