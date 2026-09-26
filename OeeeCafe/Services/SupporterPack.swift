import Foundation
import StoreKit
import WebKit
import os

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
    /// Every web view onto the site, any of which can hand a purchase to the
    /// site: the store script is on every page (app_store.jinja in
    /// oeee-cafe/web), and only /supporter reloads once the site has it.
    private static let webViews = NSHashTable<WKWebView>.weakObjects()

    /// The web view that last asked the store for something, which is showing
    /// the pack, or was: preferred, since /supporter shows a purchase taken.
    private static weak var page: WKWebView?

    private static var updates: Task<Void, Never>?

    /// A web view onto the site, for purchases that arrive unasked to be handed
    /// to.
    static func adopt(_ webView: WKWebView) {
        webViews.add(webView)
    }

    /// Listens, for as long as the app runs, for purchases that arrive other
    /// than as the answer to a press here -- one a parent approved after it was
    /// left pending, one bought on another device, a refund -- and hands each
    /// to the page that last asked the store for something, or else to any page
    /// open on the site.
    ///
    /// There is one listener, not one for each web view, so each purchase is
    /// handed over once. With no page open that takes it -- none at all, or one
    /// still loading as the app launches -- nothing is finished, and the
    /// purchase is offered again the next time /supporter asks for prices.
    static func listenForUpdates() {
        guard updates == nil else { return }
        updates = Task {
            for await update in StoreKit.Transaction.updates {
                guard let webView = page ?? webViews.anyObject else {
                    Logger.app.info("SupporterPack: \(update.unsafePayloadValue.id, privacy: .public) arrived with no page open")
                    continue
                }
                await hand(over: [update], in: webView)
            }
        }
    }

    /// What these products cost, in the reader's own currency and formatted
    /// the store's way, handed to the page for the buttons that are waiting
    /// for them. A product the store does not know is simply not in the
    /// answer, and its button keeps its price to itself.
    static func prices(of identifiers: [String], in webView: WKWebView) async {
        guard !identifiers.isEmpty else { return }
        page = webView
        let products: [Product]
        do {
            products = try await Product.products(for: identifiers)
        } catch {
            Logger.app.error("SupporterPack: could not read prices: \(String(describing: error), privacy: .public)")
            return
        }
        var prices: [String: String] = [:]
        for product in products {
            prices[product.id] = product.displayPrice
        }
        guard !prices.isEmpty else { return }
        _ = try? await webView.callAsyncJavaScript(
            Scripts.storePrices,
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
    /// the pack they paid for is not there, and as a page first says someone
    /// is signed in (WebController), which is the first a purchase can be
    /// taken by the site after the app launches or after one made signed out.
    /// `listenForUpdates` hears purchases as they arrive, but StoreKit gives
    /// it those left unfinished as the app launches, before any page is there
    /// to take them; this is what catches them.
    static func handUnfinished(in webView: WKWebView) async {
        var unfinished: [VerificationResult<StoreKit.Transaction>] = []
        for await transaction in StoreKit.Transaction.unfinished {
            unfinished.append(transaction)
        }
        await hand(over: unfinished, in: webView)
    }

    /// Sells `identifier`, and hands what comes back to the site.
    ///
    /// A purchase the person cancels, one the store leaves pending -- asking
    /// a parent, say -- and one that fails hand the page nothing, and are
    /// told to it as the way the press ended. The pending one is handed over
    /// when it goes through, if the app is open (`listenForUpdates`), and
    /// otherwise the next time the page asks for prices, like anything else
    /// the site never heard about.
    static func buy(_ identifier: String, in webView: WKWebView) async {
        page = webView
        do {
            guard let product = try await Product.products(for: [identifier]).first else {
                Logger.app.error("SupporterPack: the store has no \(identifier, privacy: .public)")
                await ended(.failed, in: webView)
                return
            }
            switch try await product.purchase() {
            case .success(let verification):
                await hand(over: [verification], in: webView)
            case .userCancelled:
                await ended(.cancelled, in: webView)
            case .pending:
                await ended(.pending, in: webView)
            @unknown default:
                await ended(.failed, in: webView)
            }
        } catch {
            Logger.app.error("SupporterPack: \(identifier, privacy: .public) could not be bought: \(String(describing: error), privacy: .public)")
            await ended(.failed, in: webView)
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
            Logger.app.error("SupporterPack: could not sync with the App Store: \(String(describing: error), privacy: .public)")
        }
        var entitlements: [VerificationResult<StoreKit.Transaction>] = []
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            entitlements.append(entitlement)
        }
        guard !entitlements.isEmpty else {
            await ended(.nothing, in: webView)
            return
        }
        await hand(over: entitlements, in: webView)
    }

    /// How a press ended when it hands the page no proof, for the page to say
    /// (`oeeeApp.store.ended`, app_store.jinja in oeee-cafe/web). A press that
    /// does hand proof over is told by the site's answer to it instead.
    enum Ending: String {
        case cancelled, pending, failed, nothing
    }

    private static func ended(_ ending: Ending, in webView: WKWebView) async {
        _ = try? await webView.callAsyncJavaScript(
            Scripts.storeEnded,
            arguments: ["outcome": ending.rawValue],
            in: nil,
            contentWorld: .page
        )
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
        if transactions.contains(where: { $0.environment == .xcode }) {
            // Signed by Xcode's StoreKit testing (the scheme's OeeeCafe.storekit),
            // not by Apple: the site asks Apple about the id and Apple has never
            // heard of it, so the site refuses it. Testing the whole way through
            // needs a sandbox purchase -- run without the StoreKit configuration.
            Logger.app.error("SupporterPack: handing over a transaction made in Xcode's StoreKit testing, which the site cannot confirm")
        }
        let answer: Any?
        do {
            answer = try await webView.callAsyncJavaScript(
                Scripts.storePurchased,
                arguments: ["ids": transactions.map { String($0.id) }],
                in: nil,
                contentWorld: .page
            )
        } catch {
            Logger.app.error("SupporterPack: the page did not answer about \(transactions.count) transaction(s): \(String(describing: error), privacy: .public)")
            return
        }
        let taken = Set((answer as? [Any] ?? []).compactMap { $0 as? String })
        for transaction in transactions {
            if taken.contains(String(transaction.id)) {
                await transaction.finish()
            } else {
                Logger.app.error("SupporterPack: the site did not take \(transaction.id, privacy: .public)")
            }
        }
    }
}
