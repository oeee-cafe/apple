#if os(iOS)
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
/// What this never does is tell the site that something was bought. It hands
/// over the transaction id and the site takes that to Apple itself
/// (src/app_store.rs in oeee-cafe/web); a page cannot be trusted about a
/// purchase, and neither can an app. So the site's answer is what decides
/// whether the transaction is finished: one it did not record is left unfinished
/// and offered again the next time the page asks for prices, which is what keeps
/// a dropped connection from costing somebody the pack they paid for.
///
/// The Mac build is not sold through the Mac App Store -- no sandbox
/// entitlement -- so there is no store behind it to ask, and none of this is
/// built for it.
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
            "window.oeeeStorePrices && window.oeeeStorePrices(prices);",
            arguments: ["prices": prices],
            in: nil,
            contentWorld: .defaultClient
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
        var handed = false
        for await transaction in StoreKit.Transaction.unfinished {
            handed = await hand(over: transaction, in: webView, reloading: false) || handed
        }
        if handed {
            _ = try? await webView.evaluateJavaScript("location.reload();")
        }
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
                await hand(over: verification, in: webView, reloading: true)
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
        var handed = false
        for await entitlement in Transaction.currentEntitlements {
            handed = await hand(over: entitlement, in: webView, reloading: false) || handed
        }
        if handed {
            _ = try? await webView.evaluateJavaScript("location.reload();")
        }
    }

    /// Tells the site about one transaction and finishes it if the site took
    /// it. Returns whether it did.
    ///
    /// An envelope Apple could not verify is still offered: what it says is
    /// only a transaction id, and the site asks Apple about that id itself. It
    /// is not finished on anything but a plain yes, so nothing is thrown away
    /// on the strength of a 502 or a signed-out session.
    @discardableResult
    private static func hand(
        over verification: VerificationResult<StoreKit.Transaction>,
        in webView: WKWebView,
        reloading: Bool
    ) async -> Bool {
        let transaction = verification.unsafePayloadValue
        let script = """
        const body = new URLSearchParams();
        body.set("transaction_id", transactionID);
        const response = await fetch("/auth/apple/purchase", {
          method: "POST",
          credentials: "same-origin",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: body.toString(),
        });
        return response.status;
        """
        let answer = try? await webView.callAsyncJavaScript(
            script,
            arguments: ["transactionID": String(transaction.id)],
            in: nil,
            contentWorld: .defaultClient
        )
        guard let status = answer as? Int else {
            Logger.error("SupporterPack: the site did not answer about \(transaction.id)")
            return false
        }
        guard status == 204 else {
            // 401 is nobody signed in, 429 is too many at once, 502 is Apple
            // unreachable: all of them worth offering again rather than
            // finishing over.
            Logger.error("SupporterPack: the site answered \(status) about \(transaction.id)")
            return false
        }
        await transaction.finish()
        if reloading {
            _ = try? await webView.evaluateJavaScript("location.reload();")
        }
        return true
    }
}
#endif
